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

final class _WidgetStudioGateway implements StudioNativeGateway {
  final List<int> closedSurfaceIds = <int>[];
  final List<double> renderedLifts = <double>[];
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
    renderedLifts.add(params.shadowLift);
    final rgba = Uint8List(4 * 4 * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      final v = (20 + params.shadowLift * 100).round().clamp(0, 255);
      rgba[i + 0] = v;
      rgba[i + 1] = v;
      rgba[i + 2] = v;
      rgba[i + 3] = 255;
    }
    return StudioRenderResult(
      statusCode: FsStatusCode.FS_OK.value,
      renderTimeMicros: 2300,
      width: 4,
      height: 4,
      rgbaBytes: rgba,
    );
  }

  @override
  Future<DnaRescueSuggestionResult> analyzeStudioSurface({
    required int surfaceId,
  }) async {
    return DnaRescueSuggestionResult(
      statusCode: FsStatusCode.FS_OK.value,
      elapsedMicroseconds: 350,
      recommendedShadowLift: 0.45,
      p10Luma: 0.05,
      p50Luma: 0.40,
      p95Luma: 0.85,
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
      suggestedRotationDeg: -1.4,
      horizonConfidence: 0.91,
      suggestedCropBox: const NormCropBoxData(
        left: 0.05,
        top: 0.05,
        right: 0.95,
        bottom: 0.95,
      ),
      cropConfidence: 0.89,
      saliencyCx: 0.5,
      saliencyCy: 0.5,
      hasHorizonLine: true,
      targetAspectPreset: targetAspectPreset,
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
      renderTimeMicros: 900,
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

final class _WidgetStorageGateway implements StorageGateway {
  _WidgetStorageGateway({
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
      width: 1,
      height: 1,
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

Future<StudioDecodedFrame> _widgetFrameLoader(PairedAsset asset) async {
  final rgba = Uint8List(4 * 4 * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i + 0] = 20;
    rgba[i + 1] = 20;
    rgba[i + 2] = 20;
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

final class _PopCountObserver extends NavigatorObserver {
  int popCount = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount++;
    super.didPop(route, previousRoute);
  }
}

void main() {
  group('StudioEditorScreen Widget Flow Tests', () {
    late Directory tempDir;
    late NativeWorker worker;
    late _WidgetStorageGateway storageGateway;
    late SessionStore store;
    late ProxyCacheManager proxyManager;
    late SessionController sessionController;
    late _WidgetStudioGateway studioGateway;

    setUpAll(() async {
      worker = await NativeWorker.spawn();
    });

    tearDownAll(() async {
      await worker.dispose();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fujistudio_studio_ui_');
      final proxyDir = Directory('${tempDir.path}${Platform.pathSeparator}proxy')
        ..createSync();
      final sessionDir = Directory('${tempDir.path}${Platform.pathSeparator}sess')
        ..createSync();

      const files = <RawMediaFileDescriptor>[
        RawMediaFileDescriptor(
          mediaId: '1',
          uri: 'content://media/external/images/media/1',
          displayName: 'DSCF1042.JPG',
          relativePath: 'DCIM/100_FUJI/',
          mimeType: 'image/jpeg',
          sizeBytes: 12000,
          dateTakenMs: 100000,
          dateModifiedSec: 100,
          width: 6240,
          height: 4160,
        ),
      ];
      storageGateway = _WidgetStorageGateway(
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
        const MediaAlbumDescriptor(albumId: 'album_1', name: '100_FUJI', count: 1),
      );
      studioGateway = _WidgetStudioGateway();
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
      'navigates from QuickLoupeScreen to StudioEditorScreen, supports slider, auto rescue, long-press Before/After, undo, reset, and clean dispose',
      (WidgetTester tester) async {
        final itemId = sessionController.state.visibleItemIds.first;

        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              storageGatewayProvider.overrideWithValue(storageGateway),
              nativeWorkerProvider.overrideWithValue(worker),
              sessionStoreProvider.overrideWithValue(store),
              proxyCacheManagerProvider.overrideWithValue(proxyManager),
              sessionControllerProvider.overrideWith((_) => sessionController),
              studioNativeGatewayProvider.overrideWithValue(studioGateway),
              studioFrameLoaderProvider.overrideWithValue(_widgetFrameLoader),
            ],
            child: MaterialApp(
              theme: FujiTheme.dark(),
              home: QuickLoupeScreen(initialItemId: itemId),
            ),
          ),
        );

        await tester.pump();
        await tester.pump();

        // Tap [ ⚙ HẬU KỲ ] on QuickLoupeScreen -> pushes StudioEditorScreen
        await tester.tap(find.byKey(const Key('loupe_develop_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();

        expect(find.byType(StudioEditorScreen), findsOneWidget);
        expect(find.byKey(const Key('studio_shadow_slider')), findsOneWidget);

        // Drag SHADOW LIFT slider toward right
        final sliderFinder = find.byKey(const Key('studio_shadow_slider'));
        await tester.drag(sliderFinder, const Offset(80, 0));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
        expect(studioGateway.renderedLifts, isNotEmpty);

        // Tap [ ✦ TỰ ĐỘNG ] -> sets recommended shadow lift 45
        await tester.tap(find.byKey(const Key('studio_auto_button')));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
        expect(find.text('45'), findsOneWidget);

        // Long-press viewport -> shows 'GỐC (SOOC)' badge while held
        final viewportFinder = find.byKey(const Key('studio_image_viewport'));
        final gesture = await tester.startGesture(tester.getCenter(viewportFinder));
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byKey(const Key('studio_before_badge')), findsOneWidget);
        await gesture.up();
        await tester.pump();
        expect(find.byKey(const Key('studio_before_badge')), findsNothing);

        // Tap UNDO -> reverts from 45 back to slider value
        await tester.tap(find.byKey(const Key('studio_undo_button')));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
        expect(find.text('45'), findsNothing);

        // Tap ĐẶT LẠI -> resets back to 0
        await tester.tap(find.byKey(const Key('studio_reset_button')));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
        expect(find.text('0'), findsOneWidget);

        // Flush pending disk writes in real async zone before tapping back button
        // so FakeAsync doesn't stall RandomAccessFile I/O inside Navigator pop handler.
        await tester.runAsync(() => sessionController.flushPendingSave());

        // Exit StudioEditorScreen -> must closeStudioSurface cleanly without errors
        await tester.tap(find.byKey(const Key('studio_back_button')));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pumpAndSettle();

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

    testWidgets(
      'tapping back twice while flushPendingSave is pending pops StudioEditorScreen only once',
      (WidgetTester tester) async {
        final itemId = sessionController.state.visibleItemIds.first;
        final observer = _PopCountObserver();

        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              storageGatewayProvider.overrideWithValue(storageGateway),
              nativeWorkerProvider.overrideWithValue(worker),
              sessionStoreProvider.overrideWithValue(store),
              proxyCacheManagerProvider.overrideWithValue(proxyManager),
              sessionControllerProvider.overrideWith((_) => sessionController),
              studioNativeGatewayProvider.overrideWithValue(studioGateway),
              studioFrameLoaderProvider.overrideWithValue(_widgetFrameLoader),
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
        expect(find.byType(StudioEditorScreen), findsOneWidget);

        // Trigger a pending change and flush disk I/O in real async zone so FakeAsync
        // does not stall RandomAccessFile during Navigator pop.
        await tester.tap(find.byKey(const Key('studio_auto_button')));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
        await tester.runAsync(() => sessionController.flushPendingSave());

        // Invoke back twice before the first async flushPendingSave() future resolves
        // to simulate a rapid double-tap while _handleBack() is in-flight.
        final backButton = tester.widget<IconButton>(
          find.byKey(const Key('studio_back_button')),
        );
        backButton.onPressed!();
        backButton.onPressed!();
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pumpAndSettle();

        expect(find.byType(StudioEditorScreen), findsNothing);
        expect(observer.popCount, equals(1));
        expect(find.byType(QuickLoupeScreen), findsOneWidget);

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
