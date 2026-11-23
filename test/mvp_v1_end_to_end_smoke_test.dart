import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/di/app_providers.dart';
import 'package:fujistudio_mobile/core/ffi/bindings.g.dart';
import 'package:fujistudio_mobile/core/ffi/native_worker.dart';
import 'package:fujistudio_mobile/core/schema/edit_recipe.dart';
import 'package:fujistudio_mobile/core/session/session_store.dart';
import 'package:fujistudio_mobile/core/storage/asset_pairing_engine.dart';
import 'package:fujistudio_mobile/core/storage/proxy_cache_manager.dart';
import 'package:fujistudio_mobile/core/storage/storage_gateway.dart';
import 'package:fujistudio_mobile/core/theme/fuji_theme.dart';
import 'package:fujistudio_mobile/features/session_picker/album_picker_screen.dart';
import 'package:fujistudio_mobile/features/session_picker/quick_loupe_screen.dart';
import 'package:fujistudio_mobile/features/session_picker/session_controller.dart';
import 'package:fujistudio_mobile/features/session_picker/session_grid_screen.dart';
import 'package:fujistudio_mobile/features/social_export/batch_export_sheet.dart';
import 'package:fujistudio_mobile/features/social_export/mobile_export_log_store.dart';
import 'package:fujistudio_mobile/features/social_export/social_export_service.dart';
import 'package:fujistudio_mobile/features/story_collage/story_collage_controller.dart';
import 'package:fujistudio_mobile/features/story_collage/story_collage_screen.dart';
import 'package:fujistudio_mobile/features/studio_editor/studio_editor_controller.dart';
import 'package:fujistudio_mobile/features/studio_editor/studio_editor_screen.dart';
import 'package:material_ui/material_ui.dart';

final List<int> _kTinyValidPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

final class _SmokeStorageGateway implements StorageGateway {
  _SmokeStorageGateway({
    required this.proxyDir,
    required this.sessionDir,
    required this.exportTmpDir,
    required this.files,
  });

  final String proxyDir;
  final String sessionDir;
  final String exportTmpDir;
  final List<RawMediaFileDescriptor> files;
  int _exportSeq = 0;
  int cleanOrphanCalls = 0;

  @override
  Future<StoragePermissionState> getPermissionState() async =>
      StoragePermissionState.granted;

  @override
  Future<StoragePermissionState> requestReadPermission() async =>
      StoragePermissionState.granted;

  @override
  Future<List<MediaAlbumDescriptor>> listAlbums() async =>
      <MediaAlbumDescriptor>[
        MediaAlbumDescriptor(
          albumId: 'album_mvp_100',
          name: '100_FUJI',
          count: files.length,
        ),
      ];

  @override
  Future<List<RawMediaFileDescriptor>> listMediaInAlbum({
    required String albumId,
    int limit = 200,
    int offset = 0,
  }) async => offset == 0 ? files : const <RawMediaFileDescriptor>[];

  @override
  Future<OpenedNativeFd?> openReadOnlyFd(String uri) async => null;

  @override
  Future<void> closeFd(String handleId) async {}

  @override
  Future<ProxyDecodeResult> decodeToProxyJpeg({
    required String source,
    required bool isContentUri,
    required String outJpegPath,
    int maxLongEdge = 1600,
    int? orientationOverride,
  }) async {
    final out = File(outJpegPath);
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(_kTinyValidPngBytes);
    return ProxyDecodeResult(
      width: 64,
      height: 48,
      byteSize: _kTinyValidPngBytes.length,
    );
  }

  @override
  Future<String> getProxyCacheDirectory() async => proxyDir;

  @override
  Future<String> getSessionStorageDirectory() async => sessionDir;

  @override
  Future<String> getExportTempDirectory() async => exportTmpDir;

  @override
  Future<int> getAvailableExportSpaceBytes() async => 4 * 1024 * 1024 * 1024;

  @override
  Future<int> getDeviceTotalRamBytes() async => 8 * 1024 * 1024 * 1024;

  @override
  Future<int> cleanOrphanExportTempFiles({int olderThanSeconds = 3600}) async {
    cleanOrphanCalls++;
    return 0;
  }

  @override
  Future<DecodedExportRawResult> decodeSourceForExportToRawFile({
    required String source,
    required bool isContentUri,
    required String outRawPath,
    required int maxDecodeLongEdge,
    int? orientationOverride,
  }) async {
    const w = 96;
    const h = 64;
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i + 0] = 32;
      rgba[i + 1] = 64;
      rgba[i + 2] = 96;
      rgba[i + 3] = 255;
    }
    final out = File(outRawPath);
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(rgba);
    return DecodedExportRawResult(width: w, height: h, rawPath: outRawPath);
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
    _exportSeq++;
    expect(File(rawRgbaPath).existsSync(), isTrue);
    return SavedExportResult(
      contentUri: 'content://media/external/images/media/${90000 + _exportSeq}',
      displayName: displayName,
      byteSize: 1468006,
      width: width,
      height: height,
    );
  }
}

final class _SmokeStudioGateway implements StudioNativeGateway {
  int _nextId = 1;

  @override
  Future<int> openStudioSurface({
    required int width,
    required int height,
    required Uint8List sourceRgba,
  }) async => _nextId++;

  @override
  Future<StudioRenderResult> renderStudioSurface({
    required int surfaceId,
    required DnaRescueNativeParams params,
  }) async {
    return StudioRenderResult(
      statusCode: FsStatusCode.FS_OK.value,
      renderTimeMicros: 1500,
      width: 4,
      height: 4,
      rgbaBytes: Uint8List.fromList(List<int>.filled(4 * 4 * 4, 255)),
    );
  }

  @override
  Future<DnaRescueSuggestionResult> analyzeStudioSurface({
    required int surfaceId,
  }) async {
    return DnaRescueSuggestionResult(
      statusCode: FsStatusCode.FS_OK.value,
      elapsedMicroseconds: 300,
      recommendedShadowLift: 0.45,
      p10Luma: 0.06,
      p50Luma: 0.40,
      p95Luma: 0.88,
      shadowPixelRatio: 0.35,
      recommendedMode: FsDnaRescueMode.FS_DNA_MODE_SOOC_SAFE.value,
    );
  }

  @override
  Future<GeometryProposalNative> analyzeGeometryOnSurface({
    required int surfaceId,
    required int targetAspectPreset,
  }) async {
    return GeometryProposalNative(
      statusCode: FsStatusCode.FS_OK.value,
      elapsedMicroseconds: 400,
      suggestedRotationDeg: -1.2,
      horizonConfidence: 0.90,
      suggestedCropBox: const NormCropBoxData(
        left: 0.05,
        top: 0.05,
        right: 0.95,
        bottom: 0.95,
      ),
      cropConfidence: 0.88,
      saliencyCx: 0.5,
      saliencyCy: 0.5,
      hasHorizonLine: true,
      targetAspectPreset: FsAspectPreset.FS_ASPECT_4_5.value,
    );
  }

  @override
  Future<StudioRenderResult> renderGeometryOnSurface({
    required int surfaceId,
    required GeometryNativeParams params,
    required int outWidth,
    required int outHeight,
  }) async {
    return StudioRenderResult(
      statusCode: FsStatusCode.FS_OK.value,
      renderTimeMicros: 800,
      width: outWidth,
      height: outHeight,
      rgbaBytes: Uint8List(outWidth * outHeight * 4),
    );
  }

  @override
  Future<void> closeStudioSurface(int surfaceId) async {}
}

final class _SmokeSocialExportPipeline implements SocialExportNativePipeline {
  @override
  Future<RafExtractionResult> extractRafPreviewFromFd({
    required int fd,
    required String outJpegPath,
  }) async {
    return extractRafPreviewFromPath(rafPath: '', outJpegPath: outJpegPath);
  }

  @override
  Future<RafExtractionResult> extractRafPreviewFromPath({
    required String rafPath,
    required String outJpegPath,
  }) async {
    final file = File(outJpegPath);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(const <int>[0xFF, 0xD8, 0xFF, 0xD9]);
    return RafExtractionResult(
      statusCode: FsStatusCode.FS_OK.value,
      elapsedMicroseconds: 100,
      jpegOffset: 0,
      jpegLength: 4,
      jpegWidth: 6240,
      jpegHeight: 4160,
      exifOrientation: 1,
      hasExifTag: true,
      cameraModel: 'X-T5',
    );
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
    final bytes = File(rawInputPath).readAsBytesSync();
    File(rawOutputPath).writeAsBytesSync(bytes);
    return ExportRgbaResult(
      statusCode: FsStatusCode.FS_OK.value,
      renderTimeMicros: 350,
      width: targetMaxLongEdge == 0 ? 6240 : 2048,
      height: targetMaxLongEdge == 0 ? 4160 : 1365,
      rawOutputPath: rawOutputPath,
    );
  }

  @override
  Future<ExportRgbaResult> renderCollageToRawFile({
    required List<CollageRawFileSlot> slots,
    required CollageNativeConfig config,
    required OutputUsmNativeParams? outputUsm,
    required String rawOutputPath,
  }) async {
    File(rawOutputPath).writeAsBytesSync(List<int>.filled(64, 255));
    return ExportRgbaResult(
      statusCode: FsStatusCode.FS_OK.value,
      renderTimeMicros: 500,
      width: config.canvasWidth,
      height: config.canvasHeight,
      rawOutputPath: rawOutputPath,
    );
  }
}

Future<StudioDecodedFrame> _smokeFrameLoader(PairedAsset asset) async {
  final rgba = Uint8List(4 * 4 * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i + 0] = 30;
    rgba[i + 1] = 30;
    rgba[i + 2] = 30;
    rgba[i + 3] = 255;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    4,
    4,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final img = await completer.future;
  return StudioDecodedFrame(
    width: 4,
    height: 4,
    rgbaBytes: rgba,
    originalImage: img,
  );
}

Future<StoryCollageSlotFrame> _smokeSlotLoader(
  String itemId,
  PairedAsset asset,
  DnaRescueSpec dnaRescue,
) async {
  const w = 32;
  const h = 24;
  final rgba = Uint8List(w * h * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i + 0] = 80;
    rgba[i + 1] = 140;
    rgba[i + 2] = 200;
    rgba[i + 3] = 255;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    w,
    h,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final img = await completer.future;
  return StoryCollageSlotFrame(
    itemId: itemId,
    width: w,
    height: h,
    rgbaBytes: rgba,
    image: img,
  );
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxSteps = 20,
}) async {
  for (var i = 0; i < maxSteps; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _flushSessionInTest(
  WidgetTester tester,
  SessionController controller,
) async {
  var done = false;
  unawaited(
    controller.flushPendingSave().whenComplete(() {
      done = true;
    }),
  );
  for (var i = 0; i < 150 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done, isTrue);
}

void main() {
  group('MVP v1.0 End-to-End Smoke Test', () {
    late Directory tempDir;
    late NativeWorker worker;
    late _SmokeStorageGateway storageGateway;
    late SessionStore sessionStore;
    late ProxyCacheManager proxyManager;
    late MobileExportLogStore exportLogStore;
    late SessionController sessionController;
    late SocialExportService exportService;
    late _SmokeStudioGateway studioGateway;

    setUpAll(() async {
      worker = await NativeWorker.spawn();
    });

    tearDownAll(() async {
      await worker.dispose();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fujistudio_mvp_smoke_');
      final proxyDir = Directory('${tempDir.path}${Platform.pathSeparator}proxy')
        ..createSync();
      final sessionDir = Directory('${tempDir.path}${Platform.pathSeparator}sess')
        ..createSync();
      final exportTmpDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}export_tmp',
      )..createSync();

      final files = List<RawMediaFileDescriptor>.generate(3, (i) {
        final idx = i + 1;
        return RawMediaFileDescriptor(
          mediaId: 'mvp_$idx',
          uri: '/storage/emulated/0/DCIM/100_FUJI/DSCF500$idx.JPG',
          displayName: 'DSCF500$idx.JPG',
          relativePath: 'DCIM/100_FUJI/',
          mimeType: 'image/jpeg',
          sizeBytes: 15000 + idx,
          dateTakenMs: 200000 - idx,
          dateModifiedSec: 200 - idx,
          width: 6240,
          height: 4160,
        );
      });

      storageGateway = _SmokeStorageGateway(
        proxyDir: proxyDir.path,
        sessionDir: sessionDir.path,
        exportTmpDir: exportTmpDir.path,
        files: files,
      );
      sessionStore = SessionStore(
        explicitSessionRoot: sessionDir.path,
        debounceDuration: const Duration(seconds: 5),
      );
      proxyManager = ProxyCacheManager(
        storageGateway: storageGateway,
        nativeWorker: worker,
        lruSaveDebounce: const Duration(seconds: 10),
      );
      await proxyManager.initialize();

      exportLogStore = MobileExportLogStore(
        explicitSessionRoot: sessionDir.path,
      );
      sessionController = SessionController(
        storageGateway: storageGateway,
        sessionStore: sessionStore,
        proxyCacheManager: proxyManager,
        bindAppLifecycle: false,
      );
      exportService = SocialExportService(
        storageGateway: storageGateway,
        nativePipeline: _SmokeSocialExportPipeline(),
        exportLogStore: exportLogStore,
        sessionController: sessionController,
      );
      studioGateway = _SmokeStudioGateway();
    });

    tearDown(() async {
      if (sessionController.mounted) {
        sessionController.dispose();
      }
      await sessionStore.flushAll().timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      await exportLogStore.flushAll().timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      if (!exportLogStore.isDisposed) {
        exportLogStore.dispose();
      }
      await proxyManager.dispose().timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      if (tempDir.existsSync()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    });

    testWidgets(
      'Album -> Cull KEEP -> Loupe -> Studio DNA & 4:5 Crop -> Export 2048 -> Story Collage Export -> Batch Export -> EXP badge & JSON persistence',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(412, 915);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          PaintingBinding.instance.imageCache.clear();
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              storageGatewayProvider.overrideWithValue(storageGateway),
              nativeWorkerProvider.overrideWithValue(worker),
              sessionStoreProvider.overrideWithValue(sessionStore),
              proxyCacheManagerProvider.overrideWithValue(proxyManager),
              sessionControllerProvider.overrideWith((_) => sessionController),
              mobileExportLogStoreProvider.overrideWith((_) => exportLogStore),
              socialExportServiceProvider.overrideWithValue(exportService),
              studioNativeGatewayProvider.overrideWithValue(studioGateway),
              studioFrameLoaderProvider.overrideWithValue(_smokeFrameLoader),
              collageSlotLoaderProvider.overrideWithValue(_smokeSlotLoader),
            ],
            child: MaterialApp(
              theme: FujiTheme.dark(),
              home: const AlbumPickerScreen(),
            ),
          ),
        );

        // 1. Open Album from AlbumPickerScreen
        await _pumpUntilFound(tester, find.text('100_FUJI'));
        expect(find.text('100_FUJI'), findsOneWidget);

        await tester.tap(find.text('100_FUJI'));
        await tester.pump(const Duration(milliseconds: 250));
        await _pumpUntilFound(
          tester,
          find.byKey(const Key('session_photo_grid')),
        );
        await _flushSessionInTest(tester, sessionController);
        expect(find.byType(SessionGridScreen), findsOneWidget);
        expect(find.text('0 / 3'), findsOneWidget);

        // 2. Select KEEP on the first 2 photos via long-press on SessionGridScreen
        final tiles = find.byType(PhotoGridTile);
        await tester.longPress(tiles.at(0));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.longPress(tiles.at(1));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('2 / 3'), findsOneWidget);

        final orderedIds = sessionController.state.galleryOrderedItemIds;
        final item0Id = orderedIds[0];
        final item1Id = orderedIds[1];

        // 3. Open QuickLoupeScreen -> enter StudioEditorScreen
        await tester.tap(tiles.at(0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await _pumpUntilFound(
          tester,
          find.byKey(const Key('loupe_develop_button')),
        );
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(QuickLoupeScreen), findsOneWidget);

        await tester.tap(find.byKey(const Key('loupe_develop_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await _pumpUntilFound(
          tester,
          find.byKey(const Key('studio_image_viewport')),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(StudioEditorScreen), findsOneWidget);

        // 4. Apply Zero-Haze DNA Rescue + Horizon/Crop 4:5
        await tester.tap(find.byKey(const Key('studio_auto_button')));
        await _pumpUntilFound(tester, find.text('45'));
        expect(find.text('45'), findsOneWidget);

        await tester.tap(find.byKey(const Key('studio_tab_crop')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('geometry_auto_button')));
        await _pumpUntilFound(
          tester,
          find.byKey(const Key('geometry_proposal_accept')),
        );
        await tester.tap(find.byKey(const Key('geometry_proposal_accept')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('geometry_aspect_4_5')));
        await tester.pump();

        // 5. Switch to [ XUẤT 2048 ] tab and export (verify no placeholder exists)
        await tester.tap(find.byKey(const Key('studio_tab_export')));
        await tester.pump();
        expect(find.text('Sẵn sàng ở Lát cắt 4'), findsNothing);
        expect(
          find.byKey(const Key('studio_export_execute_button')),
          findsOneWidget,
        );

        await _flushSessionInTest(tester, sessionController);
        await tester.tap(find.byKey(const Key('studio_export_execute_button')));
        await tester.pump();
        await _pumpUntilFound(
          tester,
          find.byKey(const Key('studio_export_result_banner')),
          maxSteps: 240,
        );
        final bannerText = tester
            .widget<Text>(find.byKey(const Key('studio_export_result_banner')))
            .data!;
        expect(bannerText, contains('Pictures/FujiStudio/'));
        expect(find.text('Sẵn sàng ở Lát cắt 4'), findsNothing);

        // Return to SessionGridScreen
        await _flushSessionInTest(tester, sessionController);
        await tester.tap(find.byKey(const Key('studio_back_button')));
        await tester.pump();
        await _pumpUntilFound(
          tester,
          find.byKey(const Key('loupe_develop_button')),
          maxSteps: 40,
        );
        await tester.pump(const Duration(milliseconds: 350));

        await tester.pageBack();
        await tester.pump();
        await _pumpUntilFound(
          tester,
          find.byKey(const Key('grid_collage_button')),
          maxSteps: 40,
        );
        await tester.pump(const Duration(milliseconds: 350));

        // 6. Open StoryCollageScreen -> export 2048 -> return to SessionGridScreen
        await tester.tap(find.byKey(const Key('grid_collage_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await _pumpUntilFound(
          tester,
          find.byKey(const Key('collage_interactive_canvas')),
        );
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(StoryCollageScreen), findsOneWidget);

        await tester.tap(find.byKey(const Key('collage_save_button')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('collage_export_button')));
        await _pumpUntilFound(
          tester,
          find.textContaining('Pictures/FujiStudio/FujiCollage_'),
          maxSteps: 240,
        );
        expect(
          find.textContaining('Pictures/FujiStudio/FujiCollage_'),
          findsOneWidget,
        );
        expect(find.text('Sẵn sàng ở Lát cắt 4'), findsNothing);

        await _flushSessionInTest(tester, sessionController);
        await tester.tap(find.byKey(const Key('collage_back_button')));
        await tester.pump();
        await _pumpUntilFound(
          tester,
          find.byKey(const Key('grid_batch_export_button')),
          maxSteps: 60,
        );
        await tester.pump(const Duration(milliseconds: 350));

        // 7. Open BatchExportSheet from SessionGridScreen and export all KEEP items
        await tester.tap(find.byKey(const Key('grid_batch_export_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await _pumpUntilFound(
          tester,
          find.byKey(const Key('batch_export_sheet')),
        );
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(BatchExportSheet), findsOneWidget);

        await tester.tap(find.byKey(const Key('batch_export_start_button')));
        await _pumpUntilFound(
          tester,
          find.byKey(const Key('batch_export_summary_text')),
          maxSteps: 240,
        );
        expect(
          find.text('Đã xuất 2/2 ảnh vào Pictures/FujiStudio/'),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('batch_export_close_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.byType(BatchExportSheet), findsNothing);

        // 8. Verify EXP badges appear on both exported KEEP tiles
        await tester.pump();
        expect(find.byKey(Key('exp_badge_$item0Id')), findsOneWidget);
        expect(find.byKey(Key('exp_badge_$item1Id')), findsOneWidget);

        // 9. Flush all writes & re-read SessionStore + MobileExportLogStore from disk
        await _flushSessionInTest(tester, sessionController);
        await tester.runAsync(() async {
          await sessionStore.flushAll();
          await exportLogStore.flushAll();
          await proxyManager.dispose();
        });

        final albumKey = sessionController.currentAlbumKey!;
        final freshSessionStore = SessionStore(
          explicitSessionRoot: storageGateway.sessionDir,
        );
        final reloadedDoc = await tester.runAsync(
          () => freshSessionStore.loadSession(albumKey),
        );
        expect(reloadedDoc, isNotNull);
        expect(reloadedDoc!.collages, hasLength(1));
        expect(reloadedDoc.actionProposals, hasLength(1));
        expect(reloadedDoc.actionProposals.first.accepted, isTrue);

        final reloadedItem0 = reloadedDoc.items.firstWhere(
          (i) => i.id == item0Id,
        );
        expect(reloadedItem0.cullResult?.status, equals('keep'));
        expect(reloadedItem0.editRecipe.dnaRescue.enabled, isTrue);
        expect(reloadedItem0.editRecipe.dnaRescue.shadowLift, equals(45.0));
        expect(reloadedItem0.editRecipe.geometry.aspectRatio, equals('4:5'));
        expect(reloadedItem0.editRecipe.geometry.cropBox, isNotNull);
        expect(
          reloadedItem0.editRecipe.exportProfile.maxLongEdgePx,
          equals(2048),
        );

        // Confirm zero content:// export URIs leaked into .fujistudio_session.json
        final albumDir = await tester.runAsync(
          () => freshSessionStore.albumDirectory(albumKey),
        );
        final sessionFile = File(
          '${albumDir!.path}${Platform.pathSeparator}${SessionStore.sessionFileName}',
        );
        expect(sessionFile.readAsStringSync(), isNot(contains('content://')));

        // Confirm MobileExportLogStore recorded all 4 exports (1 single + 1 collage + 2 batch)
        final freshLogStore = MobileExportLogStore(
          explicitSessionRoot: storageGateway.sessionDir,
        );
        addTearDown(freshLogStore.dispose);
        final logEntries = await tester.runAsync(
          () => freshLogStore.loadEntries(albumKey),
        );
        expect(logEntries, hasLength(4));
        expect(
          Directory(storageGateway.exportTmpDir).listSync(followLinks: false),
          isEmpty,
        );
        expect(storageGateway.cleanOrphanCalls, greaterThanOrEqualTo(1));

        await tester.pump(const Duration(seconds: 15));
        await tester.pumpWidget(const SizedBox.shrink());
        PaintingBinding.instance.imageCache.clear();
        expect(tester.takeException(), isNull);
      },
    );
  });
}
