import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../schema/session_document.dart';
import '../storage/storage_gateway.dart';

/// Metadata summary stored in `<sessionRoot>/recent_index.json` (max 10 entries).
@immutable
final class RecentSessionEntry {
  const RecentSessionEntry({
    required this.albumId,
    required this.albumKey,
    required this.albumName,
    this.coverUri,
    required this.keepCount,
    required this.totalCount,
    required this.updatedAtIso,
  });

  final String albumId;
  final String albumKey;
  final String albumName;
  final String? coverUri;
  final int keepCount;
  final int totalCount;
  final String updatedAtIso;

  factory RecentSessionEntry.fromJson(Map<String, Object?> json) {
    return RecentSessionEntry(
      albumId: json['album_id'] as String? ?? '',
      albumKey: json['album_key'] as String? ?? '',
      albumName: json['album_name'] as String? ?? 'Album',
      coverUri: json['cover_uri'] as String?,
      keepCount: (json['keep_count'] as num?)?.toInt() ?? 0,
      totalCount: (json['total_count'] as num?)?.toInt() ?? 0,
      updatedAtIso: json['updated_at'] as String? ?? '',
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'album_id': albumId,
      'album_key': albumKey,
      'album_name': albumName,
      'cover_uri': coverUri,
      'keep_count': keepCount,
      'total_count': totalCount,
      'updated_at': updatedAtIso,
    };
  }
}

/// Atomic, crash-safe JSON persistence store for [SessionDocument] (v2.4.2).
///
/// Guarantees:
/// - Single-Writer Queue per album session key
/// - 400ms trailing debounce (`scheduleSave`) + explicit `flushNow()`
/// - `RandomAccessFile.writeFrom` + `flush` into `.tmp.<seq>`
/// - `.bak` rotation prior to atomic rename into `.fujistudio_session.json`
/// - Corrupt primary quarantine (`.corrupt.<timestamp>`) & `.bak` auto-recovery
final class SessionStore {
  SessionStore({
    this._storageGateway,
    this._explicitSessionRoot,
    this.debounceDuration = const Duration(milliseconds: 400),
    int Function()? nowMsProvider,
  }) : _nowMs = nowMsProvider ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const String sessionFileName = '.fujistudio_session.json';
  static const String backupFileName = '.fujistudio_session.json.bak';
  static const String recentIndexFileName = 'recent_index.json';
  static const int maxRecentEntries = 10;

  final StorageGateway? _storageGateway;
  final String? _explicitSessionRoot;
  final Duration debounceDuration;
  final int Function() _nowMs;

  Directory? _rootDir;
  Future<Directory>? _rootFuture;
  final Map<String, _AlbumWriteState> _writers = <String, _AlbumWriteState>{};
  Future<void> _recentWriteChain = Future<void>.value();
  int _tempSeq = 0;

  /// Computes the deterministic 16-hex-character session directory key for [albumId].
  static String albumKeyFor(String albumId) {
    return sha256.convert(utf8.encode(albumId)).toString().substring(0, 16);
  }

  Future<Directory> _ensureRootDir() {
    if (_rootDir != null) return Future<Directory>.value(_rootDir!);
    return _rootFuture ??= () async {
      final path =
          _explicitSessionRoot ??
          await _storageGateway!.getSessionStorageDirectory();
      final dir = Directory(path);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      _rootDir = dir;
      return dir;
    }();
  }

  Future<Directory> albumDirectory(String albumKey) async {
    final root = await _ensureRootDir();
    final dir = Directory('${root.path}${Platform.pathSeparator}$albumKey');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// Loads a [SessionDocument] for [albumKey], cleaning orphan `.tmp.*` files
  /// and recovering from `.bak` if the primary file is truncated or corrupt.
  Future<SessionDocument?> loadSession(String albumKey) async {
    final root = await _ensureRootDir();
    final dir = Directory('${root.path}${Platform.pathSeparator}$albumKey');
    if (!dir.existsSync()) {
      return null;
    }

    _cleanupOrphanTemps(dir);

    final primaryFile = File(
      '${dir.path}${Platform.pathSeparator}$sessionFileName',
    );
    final backupFile = File(
      '${dir.path}${Platform.pathSeparator}$backupFileName',
    );

    if (primaryFile.existsSync()) {
      final parsed = await _tryParseSessionFile(primaryFile);
      if (parsed != null) {
        return parsed;
      }
      // Primary file exists but is corrupt/truncated -> quarantine it.
      final corruptPath =
          '${primaryFile.path}.corrupt.${_nowMs()}';
      try {
        await primaryFile.rename(corruptPath);
      } catch (_) {
        // Best-effort quarantine.
      }
    }

    if (backupFile.existsSync()) {
      final recovered = await _tryParseSessionFile(backupFile);
      if (recovered != null) {
        // Restore valid backup back to primary atomically.
        await _writeJsonAtomically(primaryFile, recovered.toJson());
        return recovered;
      }
    }

    return null;
  }

  /// Schedules a trailing-debounced (400ms) save for [albumKey] serialized
  /// through the Single-Writer Queue.
  Future<void> scheduleSave(
    String albumKey,
    SessionDocument document, {
    RecentSessionEntry? recentEntry,
  }) {
    final state = _writers.putIfAbsent(albumKey, _AlbumWriteState.new);
    state.pendingDoc = document;
    if (recentEntry != null) {
      state.pendingRecent = recentEntry;
    }
    state.pendingCompleter ??= Completer<void>();
    final future = state.pendingCompleter!.future;

    state.debounceTimer?.cancel();
    state.debounceTimer = Timer(debounceDuration, () {
      unawaited(flushNow(albumKey).catchError((_) {}));
    });
    return future;
  }

  /// Enqueues an immediate write for [albumKey] through the Single-Writer Queue
  /// without waiting for the debounce window.
  Future<void> saveNow(
    String albumKey,
    SessionDocument document, {
    RecentSessionEntry? recentEntry,
  }) {
    final state = _writers.putIfAbsent(albumKey, _AlbumWriteState.new);
    state.pendingDoc = document;
    if (recentEntry != null) {
      state.pendingRecent = recentEntry;
    }
    state.debounceTimer?.cancel();
    state.debounceTimer = null;
    return flushNow(albumKey);
  }

  /// Immediately flushes any pending debounced write for [albumKey] and waits
  /// for the Single-Writer Queue to drain.
  Future<void> flushNow(String albumKey) async {
    final state = _writers[albumKey];
    if (state == null) return;

    state.debounceTimer?.cancel();
    state.debounceTimer = null;

    final doc = state.pendingDoc;
    final recent = state.pendingRecent;
    final completer = state.pendingCompleter;
    state.pendingDoc = null;
    state.pendingRecent = null;
    state.pendingCompleter = null;

    if (doc != null) {
      final op = state.writeChain.catchError((_) {}).then((_) async {
        await _writeSessionFiles(albumKey, doc);
        if (recent != null) {
          await _upsertRecentEntry(recent);
        }
      });
      state.writeChain = op.catchError((_) {});

      if (completer != null && !completer.isCompleted) {
        unawaited(
          op.then(
            (_) {
              if (!completer.isCompleted) completer.complete();
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!completer.isCompleted) {
                completer.completeError(error, stackTrace);
              }
            },
          ),
        );
      }

      await op;
      return;
    } else if (completer != null && !completer.isCompleted) {
      completer.complete();
    }

    await state.writeChain;
  }

  /// Flushes all pending album writes across the store.
  Future<void> flushAll() async {
    final keys = _writers.keys.toList(growable: false);
    for (final key in keys) {
      await flushNow(key);
    }
    await _recentWriteChain;
  }

  /// Reads up to [maxRecentEntries] recent sessions from `recent_index.json`.
  Future<List<RecentSessionEntry>> loadRecentSessions() async {
    final root = await _ensureRootDir();
    _cleanupOrphanTemps(root);
    final file = File(
      '${root.path}${Platform.pathSeparator}$recentIndexFileName',
    );
    if (!file.existsSync()) {
      return const <RecentSessionEntry>[];
    }
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map || raw['sessions'] is! List) {
        return const <RecentSessionEntry>[];
      }
      final entries = <RecentSessionEntry>[];
      for (final item in raw['sessions'] as List<Object?>) {
        if (item is Map<String, Object?>) {
          entries.add(RecentSessionEntry.fromJson(item));
        } else if (item is Map) {
          entries.add(
            RecentSessionEntry.fromJson(
              item.map((k, v) => MapEntry(k.toString(), v)),
            ),
          );
        }
      }
      return List<RecentSessionEntry>.unmodifiable(entries);
    } catch (_) {
      return const <RecentSessionEntry>[];
    }
  }

  /// Returns the set of album keys that currently have a saved session file.
  Future<Set<String>> savedAlbumKeys() async {
    final root = await _ensureRootDir();
    final keys = <String>{};
    for (final entity in root.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final sessionFile = File(
        '${entity.path}${Platform.pathSeparator}$sessionFileName',
      );
      final backupFile = File(
        '${entity.path}${Platform.pathSeparator}$backupFileName',
      );
      if (sessionFile.existsSync() || backupFile.existsSync()) {
        final sep = entity.path.lastIndexOf(Platform.pathSeparator);
        final name = sep >= 0 ? entity.path.substring(sep + 1) : entity.path;
        keys.add(name);
      }
    }
    return Set<String>.unmodifiable(keys);
  }

  Future<void> _writeSessionFiles(
    String albumKey,
    SessionDocument document,
  ) async {
    final dir = await albumDirectory(albumKey);
    final primaryFile = File(
      '${dir.path}${Platform.pathSeparator}$sessionFileName',
    );
    final backupFile = File(
      '${dir.path}${Platform.pathSeparator}$backupFileName',
    );

    final encoded = utf8.encode(jsonEncode(document.toJson()));
    final seq = ++_tempSeq;
    final tmpFile = File('${primaryFile.path}.tmp.$seq');

    RandomAccessFile? raf;
    try {
      raf = await tmpFile.open(mode: FileMode.writeOnly);
      await raf.writeFrom(encoded);
      await raf.flush();
      await raf.close();
      raf = null;

      if (primaryFile.existsSync()) {
        // Rotate current valid primary into .bak atomically before replacing primary.
        final existingBytes = await primaryFile.readAsBytes();
        final bakTmp = File('${backupFile.path}.tmp.$seq');
        RandomAccessFile? bakRaf;
        try {
          bakRaf = await bakTmp.open(mode: FileMode.writeOnly);
          await bakRaf.writeFrom(existingBytes);
          await bakRaf.flush();
          await bakRaf.close();
          bakRaf = null;
          await bakTmp.rename(backupFile.path);
        } catch (_) {
          await bakRaf?.close();
          if (bakTmp.existsSync()) {
            try {
              await bakTmp.delete();
            } catch (_) {}
          }
          rethrow;
        }
      }

      await tmpFile.rename(primaryFile.path);
    } catch (_) {
      await raf?.close();
      if (tmpFile.existsSync()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> _upsertRecentEntry(RecentSessionEntry entry) {
    final op = _recentWriteChain.catchError((_) {}).then((_) async {
      final root = await _ensureRootDir();
      final existing = await loadRecentSessions();
      final updated = <RecentSessionEntry>[
        entry,
        for (final item in existing)
          if (item.albumKey != entry.albumKey) item,
      ];
      if (updated.length > maxRecentEntries) {
        updated.removeRange(maxRecentEntries, updated.length);
      }
      final file = File(
        '${root.path}${Platform.pathSeparator}$recentIndexFileName',
      );
      await _writeJsonAtomically(file, <String, Object?>{
        'version': 1,
        'sessions': updated.map((e) => e.toJson()).toList(growable: false),
      });
    });
    _recentWriteChain = op.catchError((_) {});
    return op;
  }

  Future<SessionDocument?> _tryParseSessionFile(File file) async {
    try {
      final text = await file.readAsString();
      if (text.trim().isEmpty) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final map = decoded is Map<String, Object?>
          ? decoded
          : decoded.map((k, v) => MapEntry(k.toString(), v));
      return SessionDocument.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeJsonAtomically(
    File target,
    Map<String, Object?> json,
  ) async {
    final seq = ++_tempSeq;
    final tmp = File('${target.path}.tmp.$seq');
    final bytes = utf8.encode(jsonEncode(json));
    RandomAccessFile? raf;
    try {
      raf = await tmp.open(mode: FileMode.writeOnly);
      await raf.writeFrom(bytes);
      await raf.flush();
      await raf.close();
      raf = null;
      await tmp.rename(target.path);
    } catch (_) {
      await raf?.close();
      if (tmp.existsSync()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  void _cleanupOrphanTemps(Directory dir) {
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final sep = entity.path.lastIndexOf(Platform.pathSeparator);
      final name = sep >= 0 ? entity.path.substring(sep + 1) : entity.path;
      if (name.contains('.tmp.')) {
        try {
          entity.deleteSync();
        } catch (_) {}
      }
    }
  }
}

final class _AlbumWriteState {
  SessionDocument? pendingDoc;
  RecentSessionEntry? pendingRecent;
  Completer<void>? pendingCompleter;
  Timer? debounceTimer;
  Future<void> writeChain = Future<void>.value();
}
