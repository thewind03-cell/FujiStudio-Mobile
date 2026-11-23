import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/storage/storage_gateway.dart';

/// Single exported artifact record stored in `<sessionRoot>/<album_key>/mobile_export_log.json`.
///
/// Kept strictly separate from `.fujistudio_session.json` so Android `content://`
/// MediaStore URIs never pollute cross-platform Desktop v2.4.2 JSON sessions.
@immutable
final class MobileExportLogEntry {
  const MobileExportLogEntry({
    required this.itemIdOrCollageId,
    required this.displayName,
    required this.contentUri,
    required this.width,
    required this.height,
    required this.byteSize,
    required this.exportedAtUtc,
    required this.profileId,
  });

  final String itemIdOrCollageId;
  final String displayName;
  final String contentUri;
  final int width;
  final int height;
  final int byteSize;
  final String exportedAtUtc;
  final String profileId;

  factory MobileExportLogEntry.fromJson(Map<String, Object?> json) {
    return MobileExportLogEntry(
      itemIdOrCollageId: json['itemIdOrCollageId'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      contentUri: json['contentUri'] as String? ?? '',
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      byteSize: (json['byteSize'] as num?)?.toInt() ?? 0,
      exportedAtUtc: json['exportedAtUtc'] as String? ?? '',
      profileId: json['profileId'] as String? ?? '',
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'itemIdOrCollageId': itemIdOrCollageId,
      'displayName': displayName,
      'contentUri': contentUri,
      'width': width,
      'height': height,
      'byteSize': byteSize,
      'exportedAtUtc': exportedAtUtc,
      'profileId': profileId,
    };
  }
}

/// Atomic, crash-safe JSON log for Android exports, isolated per album key.
///
/// Guarantees:
/// - Single-Writer Queue per `albumKey` with `catchError` isolation
/// - `RandomAccessFile.writeFrom` + `flush` into `.tmp.<seq>` -> `.bak` rotation -> `rename`
/// - Corrupt primary quarantine (`.corrupt.<timestamp>`) & `.bak` auto-recovery
/// - Live [ChangeNotifier] notifications so grid `EXP` badges update immediately
final class MobileExportLogStore extends ChangeNotifier {
  MobileExportLogStore({
    this._storageGateway,
    this._explicitSessionRoot,
    int Function()? nowMsProvider,
  }) : _nowMs = nowMsProvider ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const String logFileName = 'mobile_export_log.json';
  static const String backupFileName = 'mobile_export_log.json.bak';

  final StorageGateway? _storageGateway;
  final String? _explicitSessionRoot;
  final int Function() _nowMs;

  Directory? _rootDir;
  Future<Directory>? _rootFuture;
  final Map<String, _LogWriteState> _writers = <String, _LogWriteState>{};
  final Map<String, Set<String>> _exportedIdsByAlbum = <String, Set<String>>{};
  final Set<String> _loadedAlbums = <String>{};
  int _tempSeq = 0;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  /// Returns cached exported item/collage IDs for [albumKey] synchronously.
  Set<String> exportedIdsForAlbum(String albumKey) {
    return _exportedIdsByAlbum[albumKey] ?? const <String>{};
  }

  /// Loads and caches exported IDs for [albumKey] if not yet loaded.
  Future<Set<String>> ensureLoaded(String albumKey) async {
    if (_loadedAlbums.contains(albumKey)) {
      return exportedIdsForAlbum(albumKey);
    }
    final entries = await loadEntries(albumKey);
    return entries.map((e) => e.itemIdOrCollageId).toSet();
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

  /// Loads export log entries for [albumKey], cleaning orphan `.tmp.*` files
  /// and recovering from `.bak` if primary JSON is corrupt or truncated.
  Future<List<MobileExportLogEntry>> loadEntries(String albumKey) async {
    final root = await _ensureRootDir();
    final dir = Directory('${root.path}${Platform.pathSeparator}$albumKey');
    if (!dir.existsSync()) {
      _loadedAlbums.add(albumKey);
      return const <MobileExportLogEntry>[];
    }

    _cleanupOrphanTemps(dir);

    final primaryFile = File(
      '${dir.path}${Platform.pathSeparator}$logFileName',
    );
    final backupFile = File(
      '${dir.path}${Platform.pathSeparator}$backupFileName',
    );

    if (!primaryFile.existsSync() && !backupFile.existsSync()) {
      _loadedAlbums.add(albumKey);
      return const <MobileExportLogEntry>[];
    }

    if (primaryFile.existsSync()) {
      final parsed = await _tryParseLogFile(primaryFile);
      if (parsed != null) {
        _cacheEntries(albumKey, parsed);
        return parsed;
      }
      final corruptPath = '${primaryFile.path}.corrupt.${_nowMs()}';
      try {
        await primaryFile.rename(corruptPath);
      } catch (_) {
        // Best-effort quarantine.
      }
    }

    if (backupFile.existsSync()) {
      final recovered = await _tryParseLogFile(backupFile);
      if (recovered != null) {
        await _writeLogFiles(albumKey, recovered, skipRotateIfMissing: true);
        _cacheEntries(albumKey, recovered);
        return recovered;
      }
    }

    _loadedAlbums.add(albumKey);
    return const <MobileExportLogEntry>[];
  }

  /// Appends [entry] atomically through the Single-Writer Queue for [albumKey].
  ///
  /// Each operation is serialized via `writeChain` with `.catchError((_) {})`
  /// isolation so a transient I/O failure never poisons subsequent writes.
  Future<void> recordExport(String albumKey, MobileExportLogEntry entry) {
    final state = _writers.putIfAbsent(albumKey, _LogWriteState.new);
    final op = state.writeChain.catchError((_) {}).then((_) async {
      final current = await _loadEntriesWithoutQueue(albumKey);
      final updated = <MobileExportLogEntry>[...current, entry];
      await _writeLogFiles(albumKey, updated);
      _cacheEntries(albumKey, updated);
    });
    state.writeChain = op.catchError((_) {});
    return op;
  }

  /// Waits for all queued writes across albums to drain.
  Future<void> flushAll() async {
    final states = _writers.values.toList(growable: false);
    for (final state in states) {
      await state.writeChain.catchError((_) {});
    }
  }

  void _cacheEntries(String albumKey, List<MobileExportLogEntry> entries) {
    final ids = entries
        .map((e) => e.itemIdOrCollageId)
        .where((id) => id.isNotEmpty)
        .toSet();
    final prev = _exportedIdsByAlbum[albumKey];
    _exportedIdsByAlbum[albumKey] = Set<String>.unmodifiable(ids);
    _loadedAlbums.add(albumKey);
    if (!_disposed && !setEquals(prev, ids)) {
      notifyListeners();
    }
  }

  Future<List<MobileExportLogEntry>> _loadEntriesWithoutQueue(
    String albumKey,
  ) async {
    final dir = await albumDirectory(albumKey);
    _cleanupOrphanTemps(dir);
    final primaryFile = File(
      '${dir.path}${Platform.pathSeparator}$logFileName',
    );
    final backupFile = File(
      '${dir.path}${Platform.pathSeparator}$backupFileName',
    );

    if (primaryFile.existsSync()) {
      final parsed = await _tryParseLogFile(primaryFile);
      if (parsed != null) return parsed;
      final corruptPath = '${primaryFile.path}.corrupt.${_nowMs()}';
      try {
        await primaryFile.rename(corruptPath);
      } catch (_) {}
    }

    if (backupFile.existsSync()) {
      final recovered = await _tryParseLogFile(backupFile);
      if (recovered != null) return recovered;
    }

    return const <MobileExportLogEntry>[];
  }

  Future<void> _writeLogFiles(
    String albumKey,
    List<MobileExportLogEntry> entries, {
    bool skipRotateIfMissing = false,
  }) async {
    final dir = await albumDirectory(albumKey);
    final primaryFile = File(
      '${dir.path}${Platform.pathSeparator}$logFileName',
    );
    final backupFile = File(
      '${dir.path}${Platform.pathSeparator}$backupFileName',
    );

    final payload = <String, Object?>{
      'version': 1,
      'entries': entries.map((e) => e.toJson()).toList(growable: false),
    };
    final encoded = utf8.encode(jsonEncode(payload));
    final seq = ++_tempSeq;
    final tmpFile = File('${primaryFile.path}.tmp.$seq');

    RandomAccessFile? raf;
    try {
      raf = await tmpFile.open(mode: FileMode.writeOnly);
      await raf.writeFrom(encoded);
      await raf.flush();
      await raf.close();
      raf = null;

      if (!skipRotateIfMissing && primaryFile.existsSync()) {
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

  Future<List<MobileExportLogEntry>?> _tryParseLogFile(File file) async {
    try {
      final text = await file.readAsString();
      if (text.trim().isEmpty) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map || decoded['entries'] is! List) {
        return null;
      }
      final out = <MobileExportLogEntry>[];
      for (final raw in decoded['entries'] as List<Object?>) {
        if (raw is Map<String, Object?>) {
          out.add(MobileExportLogEntry.fromJson(raw));
        } else if (raw is Map) {
          out.add(
            MobileExportLogEntry.fromJson(
              raw.map((k, v) => MapEntry(k.toString(), v)),
            ),
          );
        } else {
          return null;
        }
      }
      return List<MobileExportLogEntry>.unmodifiable(out);
    } catch (_) {
      return null;
    }
  }

  void _cleanupOrphanTemps(Directory dir) {
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final sep = entity.path.lastIndexOf(Platform.pathSeparator);
      final name = sep >= 0 ? entity.path.substring(sep + 1) : entity.path;
      if (name.startsWith(logFileName) && name.contains('.tmp.')) {
        try {
          entity.deleteSync();
        } catch (_) {}
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final class _LogWriteState {
  Future<void> writeChain = Future<void>.value();
}
