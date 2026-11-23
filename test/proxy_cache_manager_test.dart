import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/ffi/native_worker.dart';
import 'package:fujistudio_mobile/core/storage/asset_pairing_engine.dart';
import 'package:fujistudio_mobile/core/storage/proxy_cache_manager.dart';
import 'package:fujistudio_mobile/core/storage/storage_gateway.dart';

PairedAsset _jpgPair(String id, {int size = 1000, int mod = 100}) {
  return PairedAsset(
    pairKey: 'dcim|img_$id',
    stem: 'IMG_$id',
    normalizedDir: 'dcim',
    kind: AssetPairKind.jpgOnly,
    primaryAsset: RawMediaFileDescriptor(
      mediaId: id,
      uri: 'content://media/external/images/media/$id',
      displayName: 'IMG_$id.JPG',
      relativePath: 'DCIM/',
      mimeType: 'image/jpeg',
      sizeBytes: size,
      dateTakenMs: mod * 1000,
      dateModifiedSec: mod,
      width: 4000,
      height: 3000,
    ),
    capturedAtMs: mod * 1000,
  );
}

PairedAsset _rafPair(String id, String rafPath) {
  return PairedAsset(
    pairKey: 'dcim|raf_$id',
    stem: 'RAF_$id',
    normalizedDir: 'dcim',
    kind: AssetPairKind.rafOnly,
    primaryAsset: RawMediaFileDescriptor(
      mediaId: id,
      uri: rafPath,
      displayName: 'RAF_$id.RAF',
      relativePath: 'DCIM/',
      mimeType: 'image/x-fuji-raf',
      sizeBytes: 5000,
      dateTakenMs: 1000,
      dateModifiedSec: 100,
    ),
    capturedAtMs: 1000,
  );
}

final class _FakeStorageGateway implements StorageGateway {
  _FakeStorageGateway({required this.proxyDir});

  final String proxyDir;
  final List<String> decodeOrder = <String>[];
  final List<String> closedHandles = <String>[];
  final Map<String, Completer<void>> gates = <String, Completer<void>>{};
  OpenedNativeFd? nextOpenedFd;
  int decodeBytesToWrite = 128;

  @override
  Future<void> closeFd(String handleId) async {
    closedHandles.add(handleId);
  }

  @override
  Future<ProxyDecodeResult> decodeToProxyJpeg({
    required String source,
    required bool isContentUri,
    required String outJpegPath,
    int maxLongEdge = 1600,
    int? orientationOverride,
  }) async {
    decodeOrder.add(source);
    final gate = gates[source];
    if (gate != null) {
      await gate.future;
    }
    final out = File(outJpegPath);
    out.parent.createSync(recursive: true);
    await out.writeAsBytes(List<int>.filled(decodeBytesToWrite, 0xAB));
    return ProxyDecodeResult(
      width: 1600,
      height: 1067,
      byteSize: decodeBytesToWrite,
    );
  }

  @override
  Future<StoragePermissionState> getPermissionState() async =>
      StoragePermissionState.granted;

  @override
  Future<String> getProxyCacheDirectory() async => proxyDir;

  @override
  Future<String> getSessionStorageDirectory() async => proxyDir;

  @override
  Future<List<MediaAlbumDescriptor>> listAlbums() async =>
      const <MediaAlbumDescriptor>[];

  @override
  Future<List<RawMediaFileDescriptor>> listMediaInAlbum({
    required String albumId,
    int limit = 200,
    int offset = 0,
  }) async => const <RawMediaFileDescriptor>[];

  @override
  Future<OpenedNativeFd?> openReadOnlyFd(String uri) async => nextOpenedFd;

  @override
  Future<StoragePermissionState> requestReadPermission() async =>
      StoragePermissionState.granted;

  @override
  Future<String> getExportTempDirectory() async => '$proxyDir/export_tmp';

  @override
  Future<int> getAvailableExportSpaceBytes() async => 4 * 1024 * 1024 * 1024;

  @override
  Future<int> getDeviceTotalRamBytes() async => 8 * 1024 * 1024 * 1024;

  @override
  Future<int> cleanOrphanExportTempFiles({int olderThanSeconds = 3600}) async =>
      0;

  @override
  Future<DecodedExportRawResult> decodeSourceForExportToRawFile({
    required String source,
    required bool isContentUri,
    required String outRawPath,
    required int maxDecodeLongEdge,
    int? orientationOverride,
  }) async => DecodedExportRawResult(width: 1, height: 1, rawPath: outRawPath);

  @override
  Future<SavedExportResult> encodeRgbaFileAndSaveExport({
    required String rawRgbaPath,
    required int width,
    required int height,
    required int jpegQuality,
    required String displayName,
    String? exifSource,
    bool exifSourceIsContentUri = true,
    required bool preserveExif,
    required bool stripGps,
  }) async => SavedExportResult(
    contentUri: 'content://media/external/images/media/999',
    displayName: displayName,
    byteSize: 128,
    width: width,
    height: height,
  );
}

void main() {
  group('ProxyCacheManager', () {
    late Directory tempDir;
    late NativeWorker worker;
    late _FakeStorageGateway gateway;
    late int clockMs;

    setUpAll(() async {
      worker = await NativeWorker.spawn();
    });

    tearDownAll(() async {
      await worker.dispose();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fujistudio_proxy_test_');
      gateway = _FakeStorageGateway(proxyDir: tempDir.path);
      clockMs = 1000;
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'schedules activeViewer FIFO ahead of gridViewport LIFO and cancels queued tasks immediately',
      () async {
        final manager = ProxyCacheManager(
          storageGateway: gateway,
          nativeWorker: worker,
          maxConcurrent: 1,
          nowMsProvider: () => ++clockMs,
        );
        await manager.initialize();

        final a1 = _jpgPair('1');
        final a2 = _jpgPair('2');
        final a3 = _jpgPair('3');
        final a4 = _jpgPair('4');
        final v1 = _jpgPair('v1');
        final v2 = _jpgPair('v2');

        final gate1 = Completer<void>();
        gateway.gates[a1.primaryAsset.uri] = gate1;

        final f1 = manager.requestProxy(a1, priority: ProxyPriority.gridViewport);
        final token2 = ProxyCancelToken();
        final f2 = manager.requestProxy(
          a2,
          priority: ProxyPriority.gridViewport,
          cancelToken: token2,
        );
        final f3 = manager.requestProxy(a3, priority: ProxyPriority.gridViewport);
        final f4 = manager.requestProxy(a4, priority: ProxyPriority.gridViewport);
        final fv1 = manager.requestProxy(v1, priority: ProxyPriority.activeViewer);
        final fv2 = manager.requestProxy(v2, priority: ProxyPriority.activeViewer);

        // Cancel a2 while still queued -> must resolve null immediately and skip decode.
        token2.cancel();
        expect(await f2, isNull);

        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(gateway.decodeOrder, equals(<String>[a1.primaryAsset.uri]));

        gate1.complete();
        await Future.wait(<Future<File?>>[f1, f3, f4, fv1, fv2]);

        expect(
          gateway.decodeOrder,
          equals(<String>[
            a1.primaryAsset.uri,
            v1.primaryAsset.uri, // activeViewer FIFO #1
            v2.primaryAsset.uri, // activeViewer FIFO #2
            a4.primaryAsset.uri, // gridViewport LIFO (newest first)
            a3.primaryAsset.uri, // gridViewport LIFO (older second)
          ]),
        );
        expect(gateway.decodeOrder, isNot(contains(a2.primaryAsset.uri)));

        await manager.dispose();
      },
    );

    test(
      'deduplicates in-flight requests via refCount and completes atomic disk write if cancelled mid-flight',
      () async {
        final manager = ProxyCacheManager(
          storageGateway: gateway,
          nativeWorker: worker,
          maxConcurrent: 1,
          nowMsProvider: () => ++clockMs,
        );
        await manager.initialize();

        final asset = _jpgPair('dup');
        final gate = Completer<void>();
        gateway.gates[asset.primaryAsset.uri] = gate;

        final tokA = ProxyCancelToken();
        final tokB = ProxyCancelToken();
        final reqA = manager.requestProxy(asset, cancelToken: tokA);
        final reqB = manager.requestProxy(asset, cancelToken: tokB);

        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(gateway.decodeOrder, hasLength(1));

        // Cancel both while running -> callers receive null, disk file still finishes.
        tokA.cancel();
        tokB.cancel();
        expect(await reqA, isNull);
        expect(await reqB, isNull);

        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final cached = File(
          '${tempDir.path}${Platform.pathSeparator}${manager.cacheKeyFor(asset)}.jpg',
        );
        expect(cached.existsSync(), isTrue);
        await manager.dispose();
      },
    );

    test(
      'RAF branch always calls closeFd even when C++ extraction returns an error',
      () async {
        final manager = ProxyCacheManager(
          storageGateway: gateway,
          nativeWorker: worker,
          nowMsProvider: () => ++clockMs,
        );
        await manager.initialize();

        gateway.nextOpenedFd = const OpenedNativeFd(
          handleId: 'handle_xyz',
          fd: -999,
          sizeBytes: 1024,
        );
        final raf = _rafPair('bad', 'content://media/external/file/bad_raf');

        await expectLater(
          manager.requestProxy(raf),
          throwsA(isA<StateError>()),
        );
        expect(gateway.closedHandles, equals(<String>['handle_xyz']));

        await manager.dispose();
      },
    );

    test(
      'Disk LRU evicts oldest unpinned entries down to targetCacheBytes while protecting pinnedKeys',
      () async {
        gateway.decodeBytesToWrite = 100;
        final manager = ProxyCacheManager(
          storageGateway: gateway,
          nativeWorker: worker,
          maxCacheBytes: 250,
          targetCacheBytes: 200,
          nowMsProvider: () => ++clockMs,
        );
        await manager.initialize();

        final a1 = _jpgPair('lru1');
        final a2 = _jpgPair('lru2');
        final a3 = _jpgPair('lru3');

        final f1 = await manager.requestProxy(a1);
        final f2 = await manager.requestProxy(a2);
        // Pin a1 (oldest) so eviction must target a2 instead when a3 pushes total to 300 > 250.
        manager.pinKeys(<String>{manager.cacheKeyFor(a1)});
        final f3 = await manager.requestProxy(a3);

        expect(f1!.existsSync(), isTrue); // Pinned -> protected
        expect(f2!.existsSync(), isFalse); // Evicted
        expect(f3!.existsSync(), isTrue); // Newest -> kept
        expect(manager.totalCacheBytes, equals(200));

        await manager.dispose();
      },
    );

    test(
      'initialize cleans orphan .tmp files and rebuilds lru_index.json when missing or corrupt',
      () async {
        final tmpLeftover = File(
          '${tempDir.path}${Platform.pathSeparator}abc123.jpg.tmp.99',
        );
        await tmpLeftover.writeAsBytes(<int>[1, 2, 3]);

        final orphanProxy = File(
          '${tempDir.path}${Platform.pathSeparator}deadbeefcafebabe.jpg',
        );
        await orphanProxy.writeAsBytes(List<int>.filled(64, 7));

        final corruptIndex = File(
          '${tempDir.path}${Platform.pathSeparator}lru_index.json',
        );
        await corruptIndex.writeAsString('{corrupt_json');

        final manager = ProxyCacheManager(
          storageGateway: gateway,
          nativeWorker: worker,
        );
        await manager.initialize();

        expect(tmpLeftover.existsSync(), isFalse);
        expect(manager.totalCacheBytes, equals(64));

        final rebuilt =
            jsonDecode(await corruptIndex.readAsString()) as Map<String, Object?>;
        final entries = rebuilt['entries'] as List<Object?>;
        expect(entries, hasLength(1));
        expect(
          (entries.first as Map<String, Object?>)['key'],
          equals('deadbeefcafebabe'),
        );

        await manager.dispose();
      },
    );

    test(
      'never evicts an in-flight key even when pinnedKeys >= targetCacheBytes and total exceeds maxCacheBytes',
      () async {
        gateway.decodeBytesToWrite = 100;
        final manager = ProxyCacheManager(
          storageGateway: gateway,
          nativeWorker: worker,
          maxCacheBytes: 150,
          targetCacheBytes: 100,
          nowMsProvider: () => ++clockMs,
        );
        await manager.initialize();

        final a1 = _jpgPair('pinned_100');
        final f1 = await manager.requestProxy(a1);
        expect(f1!.existsSync(), isTrue);
        manager.pinKeys(<String>{manager.cacheKeyFor(a1)});

        // Request a2 which pushes totalCacheBytes to 200 > maxCacheBytes (150)
        // while pinned a1 already equals targetCacheBytes (100).
        // Because a2 is still in _inFlight during _evictIfNeeded(), it must NOT be evicted.
        final a2 = _jpgPair('inflight_100');
        final f2 = await manager.requestProxy(a2);

        expect(f2, isNotNull);
        expect(f2!.existsSync(), isTrue);
        expect(f1.existsSync(), isTrue);
        expect(manager.totalCacheBytes, equals(200));

        await manager.dispose();
      },
    );
  });
}
