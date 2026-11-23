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
import 'package:fujistudio_mobile/core/session/session_store.dart';
import 'package:fujistudio_mobile/core/storage/asset_pairing_engine.dart';
import 'package:fujistudio_mobile/core/storage/proxy_cache_manager.dart';
import 'package:fujistudio_mobile/core/storage/storage_gateway.dart';
import 'package:fujistudio_mobile/core/theme/fuji_theme.dart';
import 'package:fujistudio_mobile/features/session_picker/quick_loupe_screen.dart';
import 'package:fujistudio_mobile/features/session_picker/session_controller.dart';
import 'package:fujistudio_mobile/features/studio_editor/studio_editor_controller.dart';
import 'package:fujistudio_mobile/features/studio_editor/studio_editor_screen.dart';
import 'package:material_ui/material_ui.dart';

final List<int> _kTinyValidPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

final class _GeoWidgetStudioGateway implements StudioNativeGateway {
  final List<int> closedSurfaceIds = <int>[];
  int _nextId = 1;

  @override
  Future<int> openStudioSurface({
    required int width,
    required int height,
    required Uint8List sourceRgba,
  }) async {
    return _nextId++;
  }

  @override
  Future<StudioRenderResult> renderStudioSurface({
    required int surfaceId,
    required DnaRescueNativeParams params,
  }) async {
    final rgba = Uint8List(12 * 8 * 4)..fillRange(0, 12 * 8 * 4, 128);
    return StudioRenderResult(
      statusCode: FsStatusCode.FS_OK.value,
      renderTimeMicros: 1500,
      width: 12,
      height: 8,
      rgbaBytes: rgba,
    );
  }

  @override
  Future<DnaRescueSuggestionResult> analyzeStudioSurface({
    required int surfaceId,
  }) async {
    return DnaRescueSuggestionResult(
      statusCode: FsStatusCode.FS_OK.value,
      elapsedMicroseconds: 300,
      recommendedShadowLift: 0.40,
      p10Luma: 0.08,
      p50Luma: 0.42,
      p95Luma: 0.85,
      shadowPixelRatio: 0.30,
      recommendedMode: FsDnaRescueMode.FS_DNA_MODE_SOOC_SAFE.value,
    );
  }

  @override
  Future<GeometryProposalNative> analyzeGeometryOnSurface({
    required int surfaceId,
    required int targetAspectPreset,
    bool useRescuedBuffer = false,
  }) async {
    return GeometryProposalNative(
      statusCode: FsStatusCode.FS_OK.value,
      elapsedMicroseconds: 450,
      suggestedRotationDeg: -1.4,
      horizonConfidence: 0.91,
      suggestedCropBox: const NormCropBoxData(
        left: 0.1,
        top: 0.0,
        right: 0.9,
        bottom: 1.0,
      ),
      cropConfidence: 0.91,
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
  Future<void> closeStudioSurface(int surfaceId) async {
    closedSurfaceIds.add(surfaceId);
  }
}

final class _GeoStorageGateway implements StorageGateway {
  _GeoStorageGateway({
    required this.proxyDir,
    required this.sessionDir,
    required this.files,
  });

  final String proxyDir;
  final String sessionDir;
  final List<RawMediaFileDescriptor> files;

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
      width: 12,
      height: 8,
      byteSize: _kTinyValidPngBytes.length,
    );
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
  Future<OpenedNativeFd?> openReadOnlyFd(String uri) async => null;

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

Future<StudioDecodedFrame> _geoFrameLoader(PairedAsset asset) async {
  const w = 12;
  const h = 8;
  final rgba = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 180);
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    w,
    h,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final img = await completer.future;
  return StudioDecodedFrame(
    width: w,
    height: h,
    rgbaBytes: rgba,
    originalImage: img,
  );
}

final class _PopObserver extends NavigatorObserver {
  int popCount = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount++;
    super.didPop(route, previousRoute);
  }
}

void main() {
  group('StudioEditorScreen Geometry Tab Widget Tests', () {
    late Directory tempDir;
    late NativeWorker worker;
    late _GeoStorageGateway storageGateway;
    late SessionStore store;
    late ProxyCacheManager proxyManager;
    late SessionController sessionController;
    late _GeoWidgetStudioGateway studioGateway;

    setUpAll(() async {
      worker = await NativeWorker.spawn();
    });

    tearDownAll(() async {
      await worker.dispose();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fujistudio_geo_ui_');
      final proxyDir = Directory('${tempDir.path}${Platform.pathSeparator}proxy')
        ..createSync();
      final sessionDir = Directory('${tempDir.path}${Platform.pathSeparator}sess')
        ..createSync();

      const files = <RawMediaFileDescriptor>[
        RawMediaFileDescriptor(
          mediaId: '1',
          uri: 'content://media/external/images/media/1',
          displayName: 'DSCF2026.JPG',
          relativePath: 'DCIM/100_FUJI/',
          mimeType: 'image/jpeg',
          sizeBytes: 12000,
          dateTakenMs: 100000,
          dateModifiedSec: 100,
          width: 6240,
          height: 4160,
        ),
      ];
      storageGateway = _GeoStorageGateway(
        proxyDir: proxyDir.path,
        sessionDir: sessionDir.path,
        files: files,
      );
      store = SessionStore(
        explicitSessionRoot: sessionDir.path,
        debounceDuration: const Duration(seconds: 5),
      );
      proxyManager = ProxyCacheManager(
        storageGateway: storageGateway,
        nativeWorker: worker,
        lruSaveDebounce: const Duration(seconds: 10),
      );
      await proxyManager.initialize();

      sessionController = SessionController(
        storageGateway: storageGateway,
        sessionStore: store,
        proxyCacheManager: proxyManager,
        bindAppLifecycle: false,
      );
      await sessionController.openAlbum(
        const MediaAlbumDescriptor(albumId: 'album_g', name: '100_FUJI', count: 1),
      );
      studioGateway = _GeoWidgetStudioGateway();
    });

    tearDown(() async {
      await store.flushAll();
      await proxyManager.dispose();
      if (tempDir.existsSync()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    });

    testWidgets(
      'switches to [CÂN & CROP], drags HorizonDial, switches aspect 4:5/9:16, accepts Auto proposal, tests unified Undo/Redo, and guards double-pop',
      (WidgetTester tester) async {
        final itemId = sessionController.state.visibleItemIds.first;
        final observer = _PopObserver();

        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              storageGatewayProvider.overrideWithValue(storageGateway),
              nativeWorkerProvider.overrideWithValue(worker),
              sessionStoreProvider.overrideWithValue(store),
              proxyCacheManagerProvider.overrideWithValue(proxyManager),
              sessionControllerProvider.overrideWith((_) => sessionController),
              studioNativeGatewayProvider.overrideWithValue(studioGateway),
              studioFrameLoaderProvider.overrideWithValue(_geoFrameLoader),
            ],
            child: MaterialApp(
              theme: FujiTheme.dark(),
              navigatorObservers: <NavigatorObserver>[observer],
              home: QuickLoupeScreen(initialItemId: itemId),
            ),
          ),
        );

        await tester.pump();
        await tester.tap(find.byKey(const Key('loupe_develop_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();

        // First apply Auto Rescue on CỨU TỐI tab (step 1 in unified history)
        await tester.tap(find.byKey(const Key('studio_auto_button')));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
        expect(sessionController.editRecipeForItem(itemId)!.dnaRescue.shadowLift, equals(40.0));

        // Switch to [ CÂN & CROP ] tab
        await tester.tap(find.byKey(const Key('studio_tab_crop')));
        await tester.pump();
        expect(find.byKey(const Key('geometry_horizon_dial')), findsOneWidget);

        // Drag HorizonDial to change rotation_deg
        await tester.drag(
          find.byKey(const Key('geometry_horizon_dial')),
          const Offset(-60, 0),
        );
        await tester.pump();
        expect(
          sessionController.editRecipeForItem(itemId)!.geometry.rotationDeg,
          greaterThan(1.0),
        );

        // Switch aspect ratio 4:5 then 9:16
        await tester.tap(find.byKey(const Key('geometry_aspect_4_5')));
        await tester.pump();
        expect(
          sessionController.editRecipeForItem(itemId)!.geometry.aspectRatio,
          equals('4:5'),
        );

        await tester.tap(find.byKey(const Key('geometry_aspect_9_16')));
        await tester.pump();
        expect(
          sessionController.editRecipeForItem(itemId)!.geometry.aspectRatio,
          equals('9:16'),
        );

        // Tap [ ✦ TỰ ĐỘNG CÂN & CROP ] -> proposal banner appears -> tap [ ÁP DỤNG ]
        await tester.tap(find.byKey(const Key('geometry_auto_button')));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
        expect(find.byKey(const Key('geometry_proposal_banner')), findsOneWidget);

        await tester.tap(find.byKey(const Key('geometry_proposal_accept')));
        await tester.pump();
        expect(find.byKey(const Key('geometry_proposal_banner')), findsNothing);
        expect(
          sessionController.editRecipeForItem(itemId)!.geometry.rotationDeg,
          closeTo(-1.4, 1e-3),
        );
        expect(
          sessionController.editRecipeForItem(itemId)!.geometry.aspectRatio,
          equals('4:5'),
        );
        expect(sessionController.state.document!.actionProposals, hasLength(1));
        expect(
          sessionController.state.document!.actionProposals.first.accepted,
          isTrue,
        );

        // Unified Undo -> reverts proposal back to 9:16, then Redo -> restores 4:5
        await tester.tap(find.byKey(const Key('studio_undo_button')));
        await tester.pump();
        expect(
          sessionController.editRecipeForItem(itemId)!.geometry.aspectRatio,
          equals('9:16'),
        );
        await tester.tap(find.byKey(const Key('studio_redo_button')));
        await tester.pump();
        expect(
          sessionController.editRecipeForItem(itemId)!.geometry.aspectRatio,
          equals('4:5'),
        );

        // Tap Undo 5 times to walk back across Geometry into initial DNA Rescue (0.0)
        for (var i = 0; i < 5; i++) {
          await tester.tap(find.byKey(const Key('studio_undo_button')));
          await tester.pump();
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump();
        }
        expect(
          sessionController.editRecipeForItem(itemId)!.dnaRescue.shadowLift,
          equals(0.0),
        );

        // Flush pending disk writes in real async zone so FakeAsync does not stall
        // RandomAccessFile inside _handleBack(), then invoke Back twice before
        // the async flush resolves to verify the double-pop guard.
        await tester.runAsync(() => sessionController.flushPendingSave());
        final backButton = tester.widget<IconButton>(
          find.byKey(const Key('studio_back_button')),
        );
        backButton.onPressed!();
        backButton.onPressed!();
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pumpAndSettle();

        expect(observer.popCount, equals(1));
        expect(find.byType(StudioEditorScreen), findsNothing);
        expect(studioGateway.closedSurfaceIds, equals(<int>[1]));

        await tester.runAsync(() async {
          await store.flushAll();
          await proxyManager.dispose();
        });
        await tester.pump(const Duration(seconds: 15));
        await tester.pumpWidget(const SizedBox.shrink());
        PaintingBinding.instance.imageCache.clear();
        expect(tester.takeException(), isNull);
      },
    );
  });
}
