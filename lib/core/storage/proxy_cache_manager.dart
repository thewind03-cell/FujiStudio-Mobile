import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../ffi/native_worker.dart';
import 'asset_pairing_engine.dart';
import 'storage_gateway.dart';

/// Scheduling lane for proxy generation requests.
enum ProxyPriority { activeViewer, gridViewport }

/// Cooperative cancellation token passed by UI tiles/viewers to [ProxyCacheManager].
final class ProxyCancelToken {
  bool _isCancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _isCancelled;

  void addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    final snapshot = _listeners.toList(growable: false);
    _listeners.clear();
    for (final listener in snapshot) {
      listener();
    }
  }
}

/// Manages the 1600px JPEG proxy disk LRU cache with:
/// - In-flight deduplication via `refCount`
/// - Bounded priority scheduling (`maxConcurrent = 2`, FIFO `activeViewer`,
///   LIFO `gridViewport`)
/// - Cooperative cancellation (`ProxyCancelToken`)
/// - Safe POSIX FD lifecycle for `.RAF` extraction
/// - Soft/target Disk LRU hysteresis & active-session pinning
final class ProxyCacheManager {
  ProxyCacheManager({
    required this._storageGateway,
    required this._nativeWorker,
    this._explicitProxyDir,
    this.maxLongEdge = 1600,
    this.maxConcurrent = 2,
    this.maxCacheBytes = 250 * 1024 * 1024,
    this.targetCacheBytes = 200 * 1024 * 1024,
    this.lruSaveDebounce = const Duration(seconds: 2),
    int Function()? nowMsProvider,
  }) : _nowMs = nowMsProvider ?? (() => DateTime.now().millisecondsSinceEpoch);

  final StorageGateway _storageGateway;
  final NativeWorker _nativeWorker;
  final String? _explicitProxyDir;
  final int maxLongEdge;
  final int maxConcurrent;
  final int maxCacheBytes;
  final int targetCacheBytes;
  final Duration lruSaveDebounce;
  final int Function() _nowMs;

  Directory? _proxyDir;
  Future<void>? _initFuture;
  bool _initialized = false;
  bool _disposed = false;

  final Map<String, _LruEntry> _lruEntries = <String, _LruEntry>{};
  int _totalCacheBytes = 0;
  Set<String> _pinnedKeys = const <String>{};

  final Map<String, _InFlightTask> _inFlight = <String, _InFlightTask>{};
  final Queue<_InFlightTask> _activeViewerQueue = Queue<_InFlightTask>();
  final List<_InFlightTask> _gridViewportQueue = <_InFlightTask>[];
  int _runningCount = 0;
  int _tempSeq = 0;
  int _cancelledQueuedCount = 0;
  int _cancelledRunningCount = 0;

  @visibleForTesting
  int get cancelledQueuedCount => _cancelledQueuedCount;

  @visibleForTesting
  int get cancelledRunningCount => _cancelledRunningCount;

  Timer? _lruSaveTimer;
  bool _lruDirty = false;
  Future<void> _lruWriteChain = Future<void>.value();

  /// Computes the deterministic 16-hex-character cache key for [asset].
  String cacheKeyFor(PairedAsset asset) {
    final primary = asset.primaryAsset;
    final raw =
        '${primary.uri}|${primary.sizeBytes}|${primary.dateModifiedSec}|$maxLongEdge|v1';
    return sha256.convert(utf8.encode(raw)).toString().substring(0, 16);
  }

  /// Current total bytes tracked in the Disk LRU index.
  int get totalCacheBytes => _totalCacheBytes;

  /// Current pinned cache keys protected from LRU eviction.
  Set<String> get pinnedKeys => _pinnedKeys;

  /// Replaces the set of cache keys pinned by the active session.
  void pinKeys(Set<String> keys) {
    _pinnedKeys = Set<String>.unmodifiable(keys);
  }

  /// Initializes the proxy directory, cleans stale `.tmp` files, and loads
  /// or rebuilds `lru_index.json`.
  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initFuture ??= _performInitialize();
  }

  Future<void> _performInitialize() async {
    final path = _explicitProxyDir ?? await _storageGateway.getProxyCacheDirectory();
    final dir = Directory(path);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _proxyDir = dir;

    _cleanupTempFiles(dir);
    await _loadOrRebuildLruIndex(dir);
    _initialized = true;
  }

  /// Requests a `1600px` proxy JPEG file for [asset].
  ///
  /// Returns `null` if cancelled via [cancelToken] before delivery or if the
  /// manager has been disposed.
  Future<File?> requestProxy(
    PairedAsset asset, {
    ProxyPriority priority = ProxyPriority.gridViewport,
    ProxyCancelToken? cancelToken,
  }) async {
    if (_disposed || (cancelToken?.isCancelled ?? false)) {
      return null;
    }
    await initialize();
    if (_disposed || (cancelToken?.isCancelled ?? false)) {
      return null;
    }

    final dir = _proxyDir!;
    final key = cacheKeyFor(asset);
    final targetFile = File('${dir.path}${Platform.pathSeparator}$key.jpg');

    if (targetFile.existsSync()) {
      final len = targetFile.lengthSync();
      if (len > 0) {
        _touchLruEntry(key, len);
        return targetFile;
      }
    }

    final existing = _inFlight[key];
    if (existing != null) {
      if (priority == ProxyPriority.activeViewer &&
          existing.priority == ProxyPriority.gridViewport &&
          existing.state == _TaskState.queued) {
        _gridViewportQueue.remove(existing);
        existing.priority = ProxyPriority.activeViewer;
        _activeViewerQueue.addLast(existing);
      }
      return _attachWaiter(existing, cancelToken);
    }

    final task = _InFlightTask(
      key: key,
      asset: asset,
      targetPath: targetFile.path,
      priority: priority,
    );
    _inFlight[key] = task;

    final future = _attachWaiter(task, cancelToken);
    if (priority == ProxyPriority.activeViewer) {
      _activeViewerQueue.addLast(task);
    } else {
      _gridViewportQueue.add(task);
    }
    _pumpScheduler();
    return future;
  }

  Future<File?> _attachWaiter(
    _InFlightTask task,
    ProxyCancelToken? cancelToken,
  ) {
    final waiter = _TaskWaiter();
    task.waiters.add(waiter);
    task.refCount += 1;

    if (cancelToken != null) {
      void onCancel() {
        if (waiter.completer.isCompleted) return;
        waiter.completer.complete(null);
        task.waiters.remove(waiter);
        task.refCount = math.max(0, task.refCount - 1);
        if (task.refCount == 0 && task.state == _TaskState.queued) {
          _cancelledQueuedCount += 1;
          _cancelQueuedTask(task);
        } else if (task.refCount == 0 && task.state == _TaskState.running) {
          _cancelledRunningCount += 1;
        }
      }

      waiter.cancelCleanup = () => cancelToken.removeListener(onCancel);
      cancelToken.addListener(onCancel);
    }

    return waiter.completer.future;
  }

  void _cancelQueuedTask(_InFlightTask task) {
    task.state = _TaskState.cancelled;
    _activeViewerQueue.remove(task);
    _gridViewportQueue.remove(task);
    _inFlight.remove(task.key);
  }

  void _pumpScheduler() {
    if (_disposed) return;
    while (_runningCount < maxConcurrent) {
      _InFlightTask? next;
      if (_activeViewerQueue.isNotEmpty) {
        next = _activeViewerQueue.removeFirst();
      } else if (_gridViewportQueue.isNotEmpty) {
        next = _gridViewportQueue.removeLast();
      }
      if (next == null) {
        break;
      }
      if (next.state == _TaskState.cancelled || next.refCount == 0) {
        _inFlight.remove(next.key);
        continue;
      }
      next.state = _TaskState.running;
      _runningCount += 1;
      unawaited(_runTask(next));
    }
  }

  Future<void> _runTask(_InFlightTask task) async {
    try {
      final file = await _materializeProxy(task);
      task.state = _TaskState.completed;
      if (file.existsSync()) {
        final len = file.lengthSync();
        if (len > 0) {
          _touchLruEntry(task.key, len);
          await _evictIfNeeded();
        }
      }
      for (final waiter in task.waiters) {
        waiter.cancelCleanup?.call();
        if (!waiter.completer.isCompleted) {
          waiter.completer.complete(file);
        }
      }
    } catch (error, stackTrace) {
      task.state = _TaskState.completed;
      for (final waiter in task.waiters) {
        waiter.cancelCleanup?.call();
        if (!waiter.completer.isCompleted) {
          waiter.completer.completeError(error, stackTrace);
        }
      }
    } finally {
      task.waiters.clear();
      _inFlight.remove(task.key);
      _runningCount = math.max(0, _runningCount - 1);
      _pumpScheduler();
    }
  }

  Future<File> _materializeProxy(_InFlightTask task) async {
    final dir = _proxyDir!;
    final asset = task.asset;
    final targetPath = task.targetPath;

    if (asset.kind == AssetPairKind.rafOnly) {
      final raf = asset.primaryAsset;
      final seq = ++_tempSeq;
      final tempExtractedPath =
          '${dir.path}${Platform.pathSeparator}extract_${task.key}_$seq.tmp.jpg';
      OpenedNativeFd? openedFd;
      try {
        openedFd = await _storageGateway.openReadOnlyFd(raf.uri);
        final RafExtractionResult meta;
        if (openedFd != null) {
          meta = await _nativeWorker.extractRafPreviewFromFd(
            fd: openedFd.fd,
            outJpegPath: tempExtractedPath,
          );
        } else {
          meta = await _nativeWorker.extractRafPreviewFromPath(
            rafPath: raf.uri,
            outJpegPath: tempExtractedPath,
          );
        }

        if (!meta.isOk) {
          throw StateError(
            'RAF embedded preview extraction failed (${meta.statusCode}) for ${raf.displayName}',
          );
        }

        final longEdge = math.max(meta.jpegWidth, meta.jpegHeight);
        final canFastPath =
            longEdge > 0 &&
            longEdge <= maxLongEdge &&
            meta.exifOrientation == 1;

        if (canFastPath) {
          final extractedFile = File(tempExtractedPath);
          final targetFile = File(targetPath);
          if (targetFile.existsSync()) {
            targetFile.deleteSync();
          }
          extractedFile.renameSync(targetPath);
          return targetFile;
        }

        await _storageGateway.decodeToProxyJpeg(
          source: tempExtractedPath,
          isContentUri: false,
          outJpegPath: targetPath,
          maxLongEdge: maxLongEdge,
          orientationOverride: meta.exifOrientation,
        );
        return File(targetPath);
      } finally {
        if (openedFd != null) {
          await _storageGateway.closeFd(openedFd.handleId);
        }
        final tempFile = File(tempExtractedPath);
        if (tempFile.existsSync()) {
          try {
            tempFile.deleteSync();
          } catch (_) {
            // Best-effort cleanup of temp extracted file.
          }
        }
      }
    }

    // `.JPG` SOOC (both `jpgOnly` and `jpgPlusRaf` at v1.0).
    final primary = asset.primaryAsset;
    final isContentUri = primary.uri.startsWith('content://');
    await _storageGateway.decodeToProxyJpeg(
      source: primary.uri,
      isContentUri: isContentUri,
      outJpegPath: targetPath,
      maxLongEdge: maxLongEdge,
    );
    return File(targetPath);
  }

  void _touchLruEntry(String key, int sizeBytes) {
    final existing = _lruEntries[key];
    if (existing != null) {
      _totalCacheBytes -= existing.sizeBytes;
    }
    _lruEntries[key] = _LruEntry(
      key: key,
      sizeBytes: sizeBytes,
      lastAccessMs: _nowMs(),
    );
    _totalCacheBytes += sizeBytes;
    _scheduleLruSave();
  }

  Future<void> _evictIfNeeded() async {
    if (_totalCacheBytes <= maxCacheBytes) return;
    final dir = _proxyDir;
    if (dir == null) return;

    final candidates = _lruEntries.values
        .where(
          (e) =>
              !_pinnedKeys.contains(e.key) && !_inFlight.containsKey(e.key),
        )
        .toList()
      ..sort((a, b) => a.lastAccessMs.compareTo(b.lastAccessMs));

    for (final entry in candidates) {
      if (_totalCacheBytes <= targetCacheBytes) break;
      final file = File('${dir.path}${Platform.pathSeparator}${entry.key}.jpg');
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {
          continue;
        }
      }
      _lruEntries.remove(entry.key);
      _totalCacheBytes = math.max(0, _totalCacheBytes - entry.sizeBytes);
      _scheduleLruSave();
    }
  }

  void _scheduleLruSave() {
    _lruDirty = true;
    _lruSaveTimer?.cancel();
    if (_disposed) return;
    _lruSaveTimer = Timer(lruSaveDebounce, () {
      unawaited(flushLruIndex().catchError((_) {}));
    });
  }

  /// Persists `lru_index.json` atomically to disk.
  Future<void> flushLruIndex() {
    _lruSaveTimer?.cancel();
    _lruSaveTimer = null;
    if (!_lruDirty || _proxyDir == null) {
      return _lruWriteChain;
    }
    _lruDirty = false;
    final dir = _proxyDir!;
    final snapshot = <String, Object?>{
      'version': 1,
      'entries': _lruEntries.values
          .map(
            (e) => <String, Object?>{
              'key': e.key,
              'size_bytes': e.sizeBytes,
              'last_access_ms': e.lastAccessMs,
            },
          )
          .toList(growable: false),
    };
    final op = _lruWriteChain.catchError((_) {}).then((_) async {
      await _writeJsonAtomically(
        File('${dir.path}${Platform.pathSeparator}lru_index.json'),
        snapshot,
      );
    });
    _lruWriteChain = op.catchError((_) {});
    return op;
  }

  Future<void> dispose() async {
    _disposed = true;
    _lruSaveTimer?.cancel();
    _lruSaveTimer = null;

    for (final task in _activeViewerQueue) {
      task.state = _TaskState.cancelled;
      for (final w in task.waiters) {
        w.cancelCleanup?.call();
        if (!w.completer.isCompleted) w.completer.complete(null);
      }
    }
    _activeViewerQueue.clear();
    for (final task in _gridViewportQueue) {
      task.state = _TaskState.cancelled;
      for (final w in task.waiters) {
        w.cancelCleanup?.call();
        if (!w.completer.isCompleted) w.completer.complete(null);
      }
    }
    _gridViewportQueue.clear();

    await flushLruIndex();
  }

  void _cleanupTempFiles(Directory dir) {
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.isEmpty
          ? entity.path
          : entity.uri.pathSegments.last;
      if (name.contains('.tmp')) {
        try {
          entity.deleteSync();
        } catch (_) {
          // Ignore locked/vanished temp file.
        }
      }
    }
  }

  Future<void> _loadOrRebuildLruIndex(Directory dir) async {
    _lruEntries.clear();
    _totalCacheBytes = 0;

    final indexFile = File('${dir.path}${Platform.pathSeparator}lru_index.json');
    var loadedOk = false;
    if (indexFile.existsSync()) {
      try {
        final raw = jsonDecode(await indexFile.readAsString());
        if (raw is Map && raw['entries'] is List) {
          for (final item in raw['entries'] as List<Object?>) {
            if (item is! Map) continue;
            final key = item['key'];
            final lastAccess = item['last_access_ms'];
            if (key is! String || lastAccess is! num) continue;
            final f = File('${dir.path}${Platform.pathSeparator}$key.jpg');
            if (!f.existsSync()) continue;
            final size = f.lengthSync();
            _lruEntries[key] = _LruEntry(
              key: key,
              sizeBytes: size,
              lastAccessMs: lastAccess.toInt(),
            );
            _totalCacheBytes += size;
          }
          loadedOk = true;
        }
      } catch (_) {
        loadedOk = false;
      }
    }

    if (!loadedOk) {
      _lruEntries.clear();
      _totalCacheBytes = 0;
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final path = entity.path;
        if (!path.toLowerCase().endsWith('.jpg')) continue;
        final sepIdx = math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
        final fileName = sepIdx >= 0 ? path.substring(sepIdx + 1) : path;
        if (fileName.contains('.tmp')) continue;
        final key = fileName.substring(0, fileName.length - 4);
        final stat = entity.statSync();
        _lruEntries[key] = _LruEntry(
          key: key,
          sizeBytes: stat.size,
          lastAccessMs: stat.modified.millisecondsSinceEpoch,
        );
        _totalCacheBytes += stat.size;
      }
      _lruDirty = true;
      await flushLruIndex();
    }
  }

  Future<void> _writeJsonAtomically(
    File target,
    Map<String, Object?> payload,
  ) async {
    final seq = ++_tempSeq;
    final tmp = File('${target.path}.tmp.$seq');
    final bytes = utf8.encode(jsonEncode(payload));
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
}

enum _TaskState { queued, running, completed, cancelled }

final class _TaskWaiter {
  final Completer<File?> completer = Completer<File?>();
  void Function()? cancelCleanup;
}

final class _InFlightTask {
  _InFlightTask({
    required this.key,
    required this.asset,
    required this.targetPath,
    required this.priority,
  });

  final String key;
  final PairedAsset asset;
  final String targetPath;
  ProxyPriority priority;
  _TaskState state = _TaskState.queued;
  int refCount = 0;
  final List<_TaskWaiter> waiters = <_TaskWaiter>[];
}

final class _LruEntry {
  const _LruEntry({
    required this.key,
    required this.sizeBytes,
    required this.lastAccessMs,
  });

  final String key;
  final int sizeBytes;
  final int lastAccessMs;
}
