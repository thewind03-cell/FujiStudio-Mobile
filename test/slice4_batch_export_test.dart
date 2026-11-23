import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/ffi/bindings.g.dart';
import 'package:fujistudio_mobile/core/ffi/native_worker.dart';
import 'package:fujistudio_mobile/core/schema/collage_spec.dart';
import 'package:fujistudio_mobile/core/schema/edit_recipe.dart';
import 'package:fujistudio_mobile/core/session/session_store.dart';
import 'package:fujistudio_mobile/core/storage/asset_pairing_engine.dart';
import 'package:fujistudio_mobile/core/storage/proxy_cache_manager.dart';
import 'package:fujistudio_mobile/core/storage/storage_gateway.dart';
import 'package:fujistudio_mobile/features/session_picker/session_controller.dart';
import 'package:fujistudio_mobile/features/social_export/batch_export_controller.dart';
import 'package:fujistudio_mobile/features/social_export/export_mapper.dart';
import 'package:fujistudio_mobile/features/social_export/mobile_export_log_store.dart';
import 'package:fujistudio_mobile/features/social_export/social_export_service.dart';

final class _BatchFakeStorageGateway implements StorageGateway {
  _BatchFakeStorageGateway({
    required this.proxyDir,
    required this.sessionDir,
    required this.exportTmpDir,
    required this.files,
  });

  final String proxyDir;
  final String sessionDir;
  final String exportTmpDir;
  final List<RawMediaFileDescriptor> files;

  int activeDecodes = 0;
  int peakConcurrentDecodes = 0;
  int activeEncodes = 0;
  int peakConcurrentEncodes = 0;
  int decodeCalls = 0;
  int encodeCalls = 0;
  int openedFdCount = 0;
  int closedFdCount = 0;
  int availableSpaceBytes = 4 * 1024 * 1024 * 1024;
  int deviceTotalRamBytes = 8 * 1024 * 1024 * 1024;
  int cleanOrphanCalls = 0;
  int? lastCleanOlderThanSeconds;
  final List<int> requestedDecodeLongEdges = <int>[];
  final List<bool> decodeIsContentUris = <bool>[];
  final List<bool> encodeExifIsContentUris = <bool>[];
  final List<String> savedDisplayNames = <String>[];
  final Set<String> activeFdHandles = <String>{};
  bool throwOnGetExportTempDirectory = false;

  Future<void> Function(int callIndex)? onBeforeDecode;
  Future<void> Function(int callIndex)? onAfterEncode;

  @override
  Future<OpenedNativeFd?> openReadOnlyFd(String uri) async {
    openedFdCount++;
    final id = 'fd_$openedFdCount';
    activeFdHandles.add(id);
    return OpenedNativeFd(handleId: id, fd: 42 + openedFdCount, sizeBytes: 1024);
  }

  @override
  Future<void> closeFd(String handleId) async {
    closedFdCount++;
    activeFdHandles.remove(handleId);
  }

  @override
  Future<DecodedExportRawResult> decodeSourceForExportToRawFile({
    required String source,
    required bool isContentUri,
    required String outRawPath,
    required int maxDecodeLongEdge,
    int? orientationOverride,
  }) async {
    decodeCalls++;
    final callIdx = decodeCalls;
    decodeIsContentUris.add(isContentUri);
    requestedDecodeLongEdges.add(maxDecodeLongEdge);
    activeDecodes++;
    if (activeDecodes > peakConcurrentDecodes) {
      peakConcurrentDecodes = activeDecodes;
    }
    try {
      await onBeforeDecode?.call(callIdx);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final f = File(outRawPath);
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(List<int>.filled(4 * 4 * 4, 128));
      return DecodedExportRawResult(width: 4, height: 4, rawPath: outRawPath);
    } finally {
      activeDecodes--;
    }
  }

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
  }) async {
    encodeCalls++;
    final callIdx = encodeCalls;
    activeEncodes++;
    if (activeEncodes > peakConcurrentEncodes) {
      peakConcurrentEncodes = activeEncodes;
    }
    try {
      encodeExifIsContentUris.add(exifSourceIsContentUri);
      expect(File(rawRgbaPath).existsSync(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      savedDisplayNames.add(displayName);
      await onAfterEncode?.call(callIdx);
      return SavedExportResult(
        contentUri: 'content://media/external/images/media/${9000 + callIdx}',
        displayName: displayName,
        byteSize: 204800,
        width: width,
        height: height,
      );
    } finally {
      activeEncodes--;
    }
  }

  @override
  Future<ProxyDecodeResult> decodeToProxyJpeg({
    required String source,
    required bool isContentUri,
    required String outJpegPath,
    int maxLongEdge = 1600,
    int? orientationOverride,
  }) async {
    return const ProxyDecodeResult(width: 1, height: 1, byteSize: 10);
  }

  @override
  Future<String> getExportTempDirectory() async {
    if (throwOnGetExportTempDirectory) {
      throw StateError('Simulated getExportTempDirectory failure');
    }
    return exportTmpDir;
  }

  @override
  Future<int> getAvailableExportSpaceBytes() async => availableSpaceBytes;

  @override
  Future<int> getDeviceTotalRamBytes() async => deviceTotalRamBytes;

  @override
  Future<int> cleanOrphanExportTempFiles({int olderThanSeconds = 3600}) async {
    cleanOrphanCalls++;
    lastCleanOlderThanSeconds = olderThanSeconds;
    return 0;
  }

  @override
  Future<StoragePermissionState> getPermissionState() async =>
      StoragePermissionState.granted;

  @override
  Future<String> getProxyCacheDirectory() async => proxyDir;

  @override
  Future<String> getSessionStorageDirectory() async => sessionDir;

  @override
  Future<List<MediaAlbumDescriptor>> listAlbums() async =>
      const <MediaAlbumDescriptor>[];

  @override
  Future<List<RawMediaFileDescriptor>> listMediaInAlbum({
    required String albumId,
    int limit = 200,
    int offset = 0,
  }) async => offset == 0 ? files : const <RawMediaFileDescriptor>[];

  @override
  Future<StoragePermissionState> requestReadPermission() async =>
      StoragePermissionState.granted;
}

final class _FakeNativePipeline implements SocialExportNativePipeline {
  int activePipelineRuns = 0;
  int peakConcurrentPipelineRuns = 0;
  int rafExtractions = 0;

  @override
  Future<RafExtractionResult> extractRafPreviewFromFd({
    required int fd,
    required String outJpegPath,
  }) async {
    rafExtractions++;
    final f = File(outJpegPath);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(const <int>[0xFF, 0xD8, 0xFF, 0xD9]);
    return RafExtractionResult(
      statusCode: FsStatusCode.FS_OK.value,
      elapsedMicroseconds: 100,
      jpegOffset: 100,
      jpegLength: 4,
      jpegWidth: 6240,
      jpegHeight: 4160,
      exifOrientation: 6,
      hasExifTag: true,
      cameraModel: 'X-T5',
    );
  }

  @override
  Future<RafExtractionResult> extractRafPreviewFromPath({
    required String rafPath,
    required String outJpegPath,
  }) async {
    return extractRafPreviewFromFd(fd: 1, outJpegPath: outJpegPath);
  }

  @override
  Future<ExportRgbaResult> runExportPipelineOnRawFile({
    required String rawInputPath,
    required int srcWidth,
    required int srcHeight,
    required String rawOutputPath,
    required DnaRescueNativeParams? dnaRescue,
    required GeometryNativeParams? geometry,
    required int targetMaxLongEdge,
    required OutputUsmNativeParams? outputUsm,
  }) async {
    activePipelineRuns++;
    if (activePipelineRuns > peakConcurrentPipelineRuns) {
      peakConcurrentPipelineRuns = activePipelineRuns;
    }
    try {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final bytes = File(rawInputPath).readAsBytesSync();
      File(rawOutputPath).writeAsBytesSync(bytes);
      return ExportRgbaResult(
        statusCode: FsStatusCode.FS_OK.value,
        renderTimeMicros: 500,
        width: targetMaxLongEdge == 0 ? 6240 : 2048,
        height: targetMaxLongEdge == 0 ? 4160 : 1365,
        rawOutputPath: rawOutputPath,
      );
    } finally {
      activePipelineRuns--;
    }
  }

  @override
  Future<ExportRgbaResult> renderCollageToRawFile({
    required List<CollageRawFileSlot> slots,
    required CollageNativeConfig config,
    required OutputUsmNativeParams? outputUsm,
    required String rawOutputPath,
  }) async {
    File(rawOutputPath).writeAsBytesSync(List<int>.filled(16, 255));
    return ExportRgbaResult(
      statusCode: FsStatusCode.FS_OK.value,
      renderTimeMicros: 800,
      width: config.canvasWidth,
      height: config.canvasHeight,
      rawOutputPath: rawOutputPath,
    );
  }
}

void main() {
  group('Slice 4B Batch Export Queue, Cancel & MobileExportLogStore Tests', () {
    late Directory tempDir;
    late NativeWorker worker;
    late _BatchFakeStorageGateway gateway;
    late SessionStore sessionStore;
    late ProxyCacheManager proxyManager;
    late SessionController sessionController;
    late MobileExportLogStore exportLogStore;
    late _FakeNativePipeline nativePipeline;
    late SocialExportService exportService;

    setUpAll(() async {
      worker = await NativeWorker.spawn();
    });

    tearDownAll(() async {
      await worker.dispose();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fujistudio_slice4b_');
      final proxyDir = Directory('${tempDir.path}${Platform.pathSeparator}proxy')
        ..createSync();
      final sessionDir = Directory('${tempDir.path}${Platform.pathSeparator}sess')
        ..createSync();
      final exportTmpDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}export_tmp',
      )..createSync();

      // Use non-content URIs for source files so we can verify strictly that
      // .fujistudio_session.json never contains any `content://` export URIs.
      final files = List<RawMediaFileDescriptor>.generate(10, (i) {
        final idx = i + 1;
        return RawMediaFileDescriptor(
          mediaId: 'm_$idx',
          uri: '/storage/emulated/0/DCIM/100_FUJI/DSCF${1000 + idx}.JPG',
          displayName: 'DSCF${1000 + idx}.JPG',
          relativePath: 'DCIM/100_FUJI/',
          mimeType: 'image/jpeg',
          sizeBytes: 12000 + idx,
          dateTakenMs: 1000000 - idx,
          dateModifiedSec: 1000 - idx,
          width: 6240,
          height: 4160,
        );
      });

      gateway = _BatchFakeStorageGateway(
        proxyDir: proxyDir.path,
        sessionDir: sessionDir.path,
        exportTmpDir: exportTmpDir.path,
        files: files,
      );
      sessionStore = SessionStore(
        explicitSessionRoot: sessionDir.path,
        debounceDuration: const Duration(milliseconds: 50),
      );
      proxyManager = ProxyCacheManager(
        storageGateway: gateway,
        nativeWorker: worker,
        lruSaveDebounce: const Duration(seconds: 10),
      );
      await proxyManager.initialize();

      sessionController = SessionController(
        storageGateway: gateway,
        sessionStore: sessionStore,
        proxyCacheManager: proxyManager,
        bindAppLifecycle: false,
      );
      await sessionController.openAlbum(
        const MediaAlbumDescriptor(
          albumId: 'album_batch_10',
          name: '100_FUJI',
          count: 10,
        ),
      );

      exportLogStore = MobileExportLogStore(
        explicitSessionRoot: sessionDir.path,
      );
      nativePipeline = _FakeNativePipeline();
      exportService = SocialExportService(
        storageGateway: gateway,
        nativePipeline: nativePipeline,
        exportLogStore: exportLogStore,
        sessionController: sessionController,
      );
    });

    tearDown(() async {
      await sessionController.flushPendingSave();
      sessionController.dispose();
      await sessionStore.flushAll();
      await exportLogStore.flushAll();
      exportLogStore.dispose();
      await proxyManager.dispose();
      if (tempDir.existsSync()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test(
      'batch exports 10 images strictly sequentially (maxConcurrent = 1), cleans all temp files, and keeps .fujistudio_session.json free of content:// URIs',
      () async {
        // Seed an orphan stale file in export_tmp/ to verify startup cleanup.
        final orphanFile = File(
          '${gateway.exportTmpDir}${Platform.pathSeparator}stale_orphan.rgba',
        )..writeAsBytesSync(const <int>[1, 2, 3, 4]);
        expect(orphanFile.existsSync(), isTrue);

        final batchController = BatchExportController(
          exportService: exportService,
        );
        addTearDown(batchController.dispose);

        final targets = <BatchExportTarget>[
          for (final id in sessionController.state.galleryOrderedItemIds)
            BatchExportTarget(
              itemId: id,
              pairedAsset: sessionController.pairedAssetForItem(id)!,
              recipe: sessionController.editRecipeForItem(id)!,
            ),
        ];
        expect(targets, hasLength(10));

        final overrideProfile = ExportMapper.applyPreset(
          ExportProfileSpec(format: 'jpeg', quality: 92, maxLongEdgePx: 2048),
          SocialExportPreset.facebook2048,
          preserveExif: true,
          stripGps: true,
        );

        // Fire twice to verify double-tap guard (`if (state.isRunning) return;`).
        final f1 = batchController.startBatch(
          targets: targets,
          exportProfileOverride: overrideProfile,
          albumKey: sessionController.currentAlbumKey,
        );
        final f2 = batchController.startBatch(
          targets: targets,
          exportProfileOverride: overrideProfile,
          albumKey: sessionController.currentAlbumKey,
        );
        final state1 = await f1;
        await f2;

        expect(state1.isDone, isTrue);
        expect(state1.isCancelled, isFalse);
        expect(state1.totalCount, equals(10));
        expect(state1.completedCount, equals(10));
        expect(state1.failedCount, equals(0));
        expect(state1.cancelledCount, equals(0));

        // Strict sequential execution (peak concurrency == 1 across all stages).
        expect(gateway.decodeCalls, equals(10));
        expect(gateway.encodeCalls, equals(10));
        expect(gateway.peakConcurrentDecodes, equals(1));
        expect(gateway.peakConcurrentEncodes, equals(1));
        expect(nativePipeline.peakConcurrentPipelineRuns, equals(1));

        // Every single temp file + orphan must be deleted.
        expect(
          Directory(gateway.exportTmpDir).listSync(followLinks: false),
          isEmpty,
        );

        // Flush session JSON and export log.
        await sessionController.flushPendingSave();
        await exportLogStore.flushAll();

        final albumKey = sessionController.currentAlbumKey!;
        final albumDir = await sessionStore.albumDirectory(albumKey);
        final sessionJsonFile = File(
          '${albumDir.path}${Platform.pathSeparator}${SessionStore.sessionFileName}',
        );
        final sessionJsonText = sessionJsonFile.readAsStringSync();
        expect(sessionJsonText, isNot(contains('content://')));

        final entries = await exportLogStore.loadEntries(albumKey);
        expect(entries, hasLength(10));
        expect(entries.first.contentUri, startsWith('content://'));
        expect(entries.first.profileId, equals('facebook_2048'));
        expect(
          exportLogStore.exportedIdsForAlbum(albumKey),
          hasLength(10),
        );
      },
    );

    test(
      'cooperative cancel on item 3/10 stops cleanly without processing items 4..10 or leaving temp leftovers',
      () async {
        final batchController = BatchExportController(
          exportService: exportService,
        );
        addTearDown(batchController.dispose);

        gateway.onAfterEncode = (callIndex) async {
          if (callIndex == 3) {
            batchController.cancel();
          }
        };

        final targets = <BatchExportTarget>[
          for (final id in sessionController.state.galleryOrderedItemIds)
            BatchExportTarget(
              itemId: id,
              pairedAsset: sessionController.pairedAssetForItem(id)!,
              recipe: sessionController.editRecipeForItem(id)!,
            ),
        ];

        final finalState = await batchController.startBatch(
          targets: targets,
          albumKey: sessionController.currentAlbumKey,
        );

        expect(finalState.isDone, isTrue);
        expect(finalState.isCancelled, isTrue);
        expect(finalState.totalCount, equals(10));
        expect(finalState.completedCount, equals(3));
        expect(finalState.cancelledCount, equals(7));
        expect(finalState.failedCount, equals(0));
        expect(gateway.decodeCalls, equals(3));
        expect(gateway.encodeCalls, equals(3));
        expect(
          Directory(gateway.exportTmpDir).listSync(followLinks: false),
          isEmpty,
        );

        final entries = await exportLogStore.loadEntries(
          sessionController.currentAlbumKey!,
        );
        expect(entries, hasLength(3));
      },
    );

    test(
      'MobileExportLogStore writes atomically, quarantines corrupt primary JSON, and auto-recovers from .bak',
      () async {
        final albumKey = sessionController.currentAlbumKey!;
        await exportLogStore.recordExport(
          albumKey,
          const MobileExportLogEntry(
            itemIdOrCollageId: 'item_1',
            displayName: 'DSCF1001_fb2048.jpg',
            contentUri: 'content://media/external/images/media/101',
            width: 2048,
            height: 1365,
            byteSize: 420000,
            exportedAtUtc: '2026-11-23T12:00:00Z',
            profileId: 'facebook_2048',
          ),
        );
        await exportLogStore.recordExport(
          albumKey,
          const MobileExportLogEntry(
            itemIdOrCollageId: 'item_2',
            displayName: 'DSCF1002_fb2048.jpg',
            contentUri: 'content://media/external/images/media/102',
            width: 2048,
            height: 1365,
            byteSize: 430000,
            exportedAtUtc: '2026-11-23T12:01:00Z',
            profileId: 'facebook_2048',
          ),
        );

        final albumDir = await exportLogStore.albumDirectory(albumKey);
        final primaryFile = File(
          '${albumDir.path}${Platform.pathSeparator}${MobileExportLogStore.logFileName}',
        );
        final backupFile = File(
          '${albumDir.path}${Platform.pathSeparator}${MobileExportLogStore.backupFileName}',
        );
        expect(primaryFile.existsSync(), isTrue);
        expect(backupFile.existsSync(), isTrue);

        // Corrupt primary file with truncated invalid JSON.
        primaryFile.writeAsStringSync('{"version": 1, "entries": [{"bad": ');

        // Fresh store instance simulates cold restart recovery.
        final recoveredStore = MobileExportLogStore(
          explicitSessionRoot: gateway.sessionDir,
        );
        addTearDown(recoveredStore.dispose);

        final recovered = await recoveredStore.loadEntries(albumKey);
        // Backup held the previous valid state (item_1) prior to rotation.
        expect(recovered, hasLength(1));
        expect(recovered.first.itemIdOrCollageId, equals('item_1'));
        expect(
          recovered.first.contentUri,
          equals('content://media/external/images/media/101'),
        );

        // Corrupt primary must have been quarantined and primary restored.
        final corruptFiles = albumDir
            .listSync(followLinks: false)
            .where((e) => e.path.contains('.corrupt.'))
            .toList();
        expect(corruptFiles, hasLength(1));
        expect(jsonDecode(primaryFile.readAsStringSync()), isA<Map<String, Object?>>());
      },
    );

    test(
      'computeDecodeLongEdge scales up for 40% crop and rafOnly closes FD and deletes rafTempJpeg',
      () async {
        expect(
          SocialExportService.computeDecodeLongEdge(
            targetMaxLongEdge: 2048,
            geometry: GeometrySpec(rotationDeg: 0.0),
          ),
          equals(2400),
        );
        expect(
          SocialExportService.computeDecodeLongEdge(
            targetMaxLongEdge: 2048,
            geometry: GeometrySpec(
              rotationDeg: 0.0,
              aspectRatio: '4:5',
              cropBox: const <double>[0.30, 0.30, 0.40, 0.40],
            ),
          ),
          greaterThanOrEqualTo(5120),
        );
        expect(
          SocialExportService.computeDecodeLongEdge(
            targetMaxLongEdge: 0,
            geometry: GeometrySpec(rotationDeg: 0.0),
          ),
          equals(0),
        );

        // Verify .RAF-only branch opens FD, extracts JPEG, decodes, closes FD, cleans temp.
        final rafPair = PairedAsset(
          pairKey: 'dcim|dscf_raf',
          stem: 'DSCF_RAF',
          normalizedDir: 'dcim',
          kind: AssetPairKind.rafOnly,
          primaryAsset: const RawMediaFileDescriptor(
            mediaId: 'raf_1',
            uri: 'content://media/external/file/999',
            displayName: 'DSCF_RAF.RAF',
            relativePath: 'DCIM/100_FUJI/',
            mimeType: 'image/x-fuji-raf',
            sizeBytes: 30000000,
            dateTakenMs: 100000,
            dateModifiedSec: 100,
          ),
          capturedAtMs: 100000,
        );

        final res = await exportService.exportSingleItem(
          itemId: 'item_raf_only',
          pairedAsset: rafPair,
          recipe: EditRecipe(
            dnaRescue: DnaRescueSpec(enabled: true, shadowLift: 35.0),
            geometry: GeometrySpec(
              rotationDeg: 1.0,
              aspectRatio: '4:5',
              cropBox: const <double>[0.30, 0.30, 0.40, 0.40],
            ),
            lut: LutSpec(enabled: false, intensity: 0.0),
            exportProfile: ExportMapper.applyPreset(
              ExportProfileSpec(format: 'jpeg', quality: 92, maxLongEdgePx: 2048),
              SocialExportPreset.facebook2048,
            ),
          ),
        );

        expect(res.displayName, equals('DSCF_RAF_fb2048.jpg'));
        expect(nativePipeline.rafExtractions, equals(1));
        expect(gateway.openedFdCount, equals(1));
        expect(gateway.closedFdCount, equals(1));
        expect(gateway.activeFdHandles, isEmpty);
        expect(gateway.requestedDecodeLongEdges.single, greaterThanOrEqualTo(5120));
        expect(
          Directory(gateway.exportTmpDir).listSync(followLinks: false),
          isEmpty,
        );
      },
    );

    test(
      'rejects batch export immediately when StatFs available space is below max(150 MB, N * 60 MB)',
      () async {
        // 10 items require max(150 MB, 10 * 60 MB) = 600 MB.
        gateway.availableSpaceBytes = 500 * 1024 * 1024;

        final batchController = BatchExportController(
          exportService: exportService,
        );
        addTearDown(batchController.dispose);

        final targets = <BatchExportTarget>[
          for (final id in sessionController.state.galleryOrderedItemIds)
            BatchExportTarget(
              itemId: id,
              pairedAsset: sessionController.pairedAssetForItem(id)!,
              recipe: sessionController.editRecipeForItem(id)!,
            ),
        ];

        final finalState = await batchController.startBatch(
          targets: targets,
          albumKey: sessionController.currentAlbumKey,
        );

        expect(finalState.isRunning, isFalse);
        expect(finalState.isDone, isTrue);
        expect(finalState.completedCount, equals(0));
        expect(finalState.failedCount, equals(10));
        expect(finalState.errorMessage, contains('Không đủ dung lượng trống'));
        expect(gateway.decodeCalls, equals(0));
        expect(gateway.encodeCalls, equals(0));

        // Single export requires >= 150 MB.
        gateway.availableSpaceBytes = 100 * 1024 * 1024;
        final singleId = sessionController.state.galleryOrderedItemIds.first;
        await expectLater(
          exportService.exportSingleItem(itemId: singleId),
          throwsA(isA<ExportInsufficientSpaceException>()),
        );
        expect(gateway.decodeCalls, equals(0));
      },
    );

    test(
      'clamps decode ceiling <= 4608px for 40MP (7728x5152) deep crop on 6 GB RAM device',
      () async {
        const sixGbRam = 6 * 1024 * 1024 * 1024;
        final deepCropGeom = GeometrySpec(
          rotationDeg: 2.0,
          aspectRatio: '4:5',
          cropBox: const <double>[0.30, 0.30, 0.40, 0.40],
        );

        expect(
          SocialExportService.computeDecodeLongEdge(
            targetMaxLongEdge: 2048,
            geometry: deepCropGeom,
            deviceTotalRamBytes: sixGbRam,
          ),
          lessThanOrEqualTo(4608),
        );
        expect(
          SocialExportService.computeDecodeLongEdge(
            targetMaxLongEdge: 0,
            geometry: GeometrySpec(rotationDeg: 0.0),
            deviceTotalRamBytes: sixGbRam,
          ),
          lessThanOrEqualTo(4608),
        );

        gateway.deviceTotalRamBytes = sixGbRam;
        final sensor40MpPair = PairedAsset(
          pairKey: 'dcim|dscf_40mp',
          stem: 'DSCF_40MP',
          normalizedDir: 'dcim',
          kind: AssetPairKind.jpgOnly,
          primaryAsset: const RawMediaFileDescriptor(
            mediaId: 'm_40mp',
            uri: '/storage/emulated/0/DCIM/100_FUJI/DSCF_40MP.JPG',
            displayName: 'DSCF_40MP.JPG',
            relativePath: 'DCIM/100_FUJI/',
            mimeType: 'image/jpeg',
            sizeBytes: 24000000,
            dateTakenMs: 200000,
            dateModifiedSec: 200,
            width: 7728,
            height: 5152,
          ),
          capturedAtMs: 200000,
        );

        await exportService.exportSingleItem(
          itemId: 'item_40mp',
          pairedAsset: sensor40MpPair,
          recipe: EditRecipe(
            dnaRescue: DnaRescueSpec(enabled: false, shadowLift: 0.0),
            geometry: deepCropGeom,
            lut: LutSpec(enabled: false, intensity: 0.0),
            exportProfile: ExportMapper.applyPreset(
              ExportProfileSpec(format: 'jpeg', quality: 92, maxLongEdgePx: 2048),
              SocialExportPreset.facebook2048,
            ),
          ),
        );

        expect(gateway.requestedDecodeLongEdges.single, lessThanOrEqualTo(4608));
      },
    );

    test(
      'startup cleanup invokes MediaStore IS_PENDING cleaner and removes orphan export_tmp files',
      () async {
        final orphan = File(
          '${gateway.exportTmpDir}${Platform.pathSeparator}boot_orphan.tmp',
        )..writeAsBytesSync(const <int>[9, 8, 7]);
        expect(orphan.existsSync(), isTrue);

        await exportService.cleanupOrphanTempFiles();

        expect(orphan.existsSync(), isFalse);
        expect(gateway.cleanOrphanCalls, equals(1));
        expect(gateway.lastCleanOlderThanSeconds, equals(3600));
      },
    );

    test(
      'local .JPG path (/tmp/DSCF0001.JPG) passes isContentUri: false and exifSourceIsContentUri: false',
      () async {
        final localJpgPair = PairedAsset(
          pairKey: 'tmp|dscf0001',
          stem: 'DSCF0001',
          normalizedDir: 'tmp',
          kind: AssetPairKind.jpgOnly,
          primaryAsset: const RawMediaFileDescriptor(
            mediaId: 'local_1',
            uri: '/tmp/DSCF0001.JPG',
            displayName: 'DSCF0001.JPG',
            relativePath: 'tmp/',
            mimeType: 'image/jpeg',
            sizeBytes: 12000,
            dateTakenMs: 100000,
            dateModifiedSec: 100,
            width: 3000,
            height: 2000,
          ),
          capturedAtMs: 100000,
        );

        await exportService.exportSingleItem(
          itemId: 'item_local_jpg',
          pairedAsset: localJpgPair,
        );

        expect(gateway.decodeIsContentUris, equals(<bool>[false]));
        expect(gateway.encodeExifIsContentUris, equals(<bool>[false]));
      },
    );

    test(
      'exception in getExportTempDirectory does not leak _activeExports > 0 during exportSingleItem or exportCollage',
      () async {
        // Trigger initial startup cleanup once so subsequent calls isolate export paths.
        await exportService.exportSingleItem(
          itemId: sessionController.state.galleryOrderedItemIds.first,
        );
        final baselineCleanCalls = gateway.cleanOrphanCalls;

        gateway.throwOnGetExportTempDirectory = true;

        await expectLater(
          exportService.exportSingleItem(
            itemId: sessionController.state.galleryOrderedItemIds.first,
          ),
          throwsStateError,
        );

        await exportService.cleanupOrphanTempFiles();
        expect(gateway.cleanOrphanCalls, equals(baselineCleanCalls + 1));

        final ids = sessionController.state.galleryOrderedItemIds;
        await expectLater(
          exportService.exportCollage(
            spec: CollageSpec(
              collageId: 'col_err',
              templateId: 'split_2_v',
              aspectRatio: '9:16',
              slots: <CollageSlot>[
                CollageSlot(slotIndex: 0, itemId: ids[0]),
                CollageSlot(slotIndex: 1, itemId: ids[1]),
              ],
            ),
          ),
          throwsStateError,
        );

        await exportService.cleanupOrphanTempFiles();
        expect(gateway.cleanOrphanCalls, equals(baselineCleanCalls + 2));
      },
    );
  });
}
