import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/ffi/bindings.g.dart';
import 'package:fujistudio_mobile/core/ffi/native_worker.dart';
import 'package:fujistudio_mobile/core/schema/edit_recipe.dart';
import 'package:fujistudio_mobile/core/schema/session_document.dart';
import 'package:fujistudio_mobile/core/session/session_store.dart';
import 'package:fujistudio_mobile/core/storage/asset_pairing_engine.dart';
import 'package:fujistudio_mobile/core/storage/proxy_cache_manager.dart';
import 'package:fujistudio_mobile/core/storage/storage_gateway.dart';
import 'package:fujistudio_mobile/features/session_picker/session_controller.dart';
import 'package:fujistudio_mobile/features/studio_editor/dna_rescue_mapper.dart';
import 'package:fujistudio_mobile/features/studio_editor/studio_editor_controller.dart';

final class _FakeStudioWorker implements StudioNativeGateway {
  final List<double> renderedShadowLifts = <double>[];
  final List<int> closedSurfaceIds = <int>[];
  Completer<void>? activeRenderGate;
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
    renderedShadowLifts.add(params.shadowLift);
    final gate = activeRenderGate;
    if (gate != null && !gate.isCompleted) {
      await gate.future;
    }
    final out = Uint8List(4 * 4 * 4);
    for (var i = 0; i < out.length; i += 4) {
      final v = (20 + (params.shadowLift * 100)).round().clamp(0, 255);
      out[i + 0] = v;
      out[i + 1] = v;
      out[i + 2] = v;
      out[i + 3] = 255;
    }
    return StudioRenderResult(
      statusCode: FsStatusCode.FS_OK.value,
      renderTimeMicros: 1200,
      width: 4,
      height: 4,
      rgbaBytes: out,
    );
  }

  @override
  Future<DnaRescueSuggestionResult> analyzeStudioSurface({
    required int surfaceId,
  }) async {
    return DnaRescueSuggestionResult(
      statusCode: FsStatusCode.FS_OK.value,
      elapsedMicroseconds: 400,
      recommendedShadowLift: 0.42,
      p10Luma: 0.06,
      p50Luma: 0.45,
      p95Luma: 0.88,
      shadowPixelRatio: 0.31,
      recommendedMode: FsDnaRescueMode.FS_DNA_MODE_DEEP_RESCUE.value,
    );
  }

  @override
  Future<GeometryProposalNative> analyzeGeometryOnSurface({
    required int surfaceId,
    required int targetAspectPreset,
  }) async {
    return GeometryProposalNative(
      statusCode: FsStatusCode.FS_OK.value,
      elapsedMicroseconds: 450,
      suggestedRotationDeg: -2.4,
      horizonConfidence: 0.91,
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

final class _DummyStorageGateway implements StorageGateway {
  _DummyStorageGateway({
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
  }) async => const ProxyDecodeResult(width: 4, height: 4, byteSize: 64);

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

Future<StudioDecodedFrame> _fakeFrameLoader(PairedAsset asset) async {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DnaRescueMapper & StudioEditorController', () {
    late Directory tempDir;
    late NativeWorker worker;

    setUpAll(() async {
      worker = await NativeWorker.spawn();
    });

    tearDownAll(() async {
      await worker.dispose();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fujistudio_editor_ctrl_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('DnaRescueMapper preserves Gate 0 0..100 schema scale and unknownFields', () {
      final spec = DnaRescueSpec(
        enabled: true,
        shadowLift: 35.0,
        unknownFields: const <String, Object?>{
          'desktop_bilateral_sigma_spatial': 4.25,
          'mode': 'deep_rescue',
        },
      );

      final nativeParams = DnaRescueMapper.toNativeParams(spec);
      expect(nativeParams.enabled, isTrue);
      expect(nativeParams.shadowLift, closeTo(0.35, 1e-6));
      expect(nativeParams.midtoneAnchor, closeTo(0.55, 1e-6));
      expect(nativeParams.highlightProtect, closeTo(0.90, 1e-6));
      expect(
        nativeParams.mode,
        equals(FsDnaRescueMode.FS_DNA_MODE_DEEP_RESCUE.value),
      );

      final reset = DnaRescueMapper.resetSpec(spec);
      expect(reset.enabled, isFalse);
      expect(reset.shadowLift, equals(0.0));
      expect(
        reset.unknownFields['desktop_bilateral_sigma_spatial'],
        equals(4.25),
      );
      expect(reset.unknownFields.containsKey('mode'), isFalse);
    });

    test(
      'Latest-Value Coalescing executes only first and latest frame across 30 rapid slider events',
      () async {
        final proxyDir = Directory('${tempDir.path}${Platform.pathSeparator}proxy')
          ..createSync();
        final sessionDir = Directory('${tempDir.path}${Platform.pathSeparator}sess')
          ..createSync();

        final store = SessionStore(explicitSessionRoot: sessionDir.path);
        final gateway = _DummyStorageGateway(
          proxyDir: proxyDir.path,
          sessionDir: sessionDir.path,
          files: const <RawMediaFileDescriptor>[
            RawMediaFileDescriptor(
              mediaId: '1',
              uri: 'content://media/1',
              displayName: 'DSCF4012.JPG',
              relativePath: 'DCIM/',
              mimeType: 'image/jpeg',
              sizeBytes: 1000,
              dateTakenMs: 1000,
              dateModifiedSec: 1,
            ),
          ],
        );
        final proxyManager = ProxyCacheManager(
          storageGateway: gateway,
          nativeWorker: worker,
        );
        await proxyManager.initialize();

        final sessionController = SessionController(
          storageGateway: gateway,
          sessionStore: store,
          proxyCacheManager: proxyManager,
          bindAppLifecycle: false,
        );
        await sessionController.openAlbum(
          const MediaAlbumDescriptor(albumId: 'a1', name: 'A1', count: 1),
        );

        final itemId = sessionController.state.visibleItemIds.first;
        final pair = sessionController.state.pairedAssetsById[itemId]!;
        final fakeWorker = _FakeStudioWorker();
        final editor = StudioEditorController(
          itemId: itemId,
          pairedAsset: pair,
          sessionController: sessionController,
          proxyCacheManager: proxyManager,
          nativeGateway: fakeWorker,
          frameLoader: _fakeFrameLoader,
        );
        await editor.initialize();

        // Hold the first render in-flight while firing 30 rapid slider updates.
        fakeWorker.activeRenderGate = Completer<void>();
        for (var i = 1; i <= 30; i++) {
          editor.previewShadowLift(i.toDouble());
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(fakeWorker.renderedShadowLifts, equals(<double>[0.01]));

        // Release gate -> coalescer must skip 2..29 and render only 30 (0.30).
        fakeWorker.activeRenderGate!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(
          fakeWorker.renderedShadowLifts,
          equals(<double>[0.01, 0.30]),
        );

        editor.dispose();
        expect(fakeWorker.closedSurfaceIds, equals(<int>[1]));
        await proxyManager.dispose();
        sessionController.dispose();
      },
    );

    test(
      'Undo, Redo, Reset, and persistence preserve Desktop v2.4.2 unknownFields and sibling specs',
      () async {
        final proxyDir = Directory('${tempDir.path}${Platform.pathSeparator}proxy')
          ..createSync();
        final sessionDir = Directory('${tempDir.path}${Platform.pathSeparator}sess')
          ..createSync();

        const album = MediaAlbumDescriptor(albumId: 'a_v242', name: 'V242', count: 1);
        final albumKey = SessionStore.albumKeyFor(album.albumId);

        final rawFixture = jsonDecode(
          File('schemas/fixtures/desktop_v2_4_2_sample.json').readAsStringSync(),
        ) as Map<String, Object?>;
        final fixtureDoc = SessionDocument.fromJson(rawFixture);

        final store = SessionStore(
          explicitSessionRoot: sessionDir.path,
          debounceDuration: const Duration(milliseconds: 20),
        );
        await store.saveNow(albumKey, fixtureDoc);

        final gateway = _DummyStorageGateway(
          proxyDir: proxyDir.path,
          sessionDir: sessionDir.path,
          files: const <RawMediaFileDescriptor>[
            RawMediaFileDescriptor(
              mediaId: '4012',
              uri: 'content://media/external/images/media/4012',
              displayName: 'DSCF4012.JPG',
              relativePath: 'DCIM/',
              mimeType: 'image/jpeg',
              sizeBytes: 5000,
              dateTakenMs: 5000,
              dateModifiedSec: 5,
            ),
          ],
        );
        final proxyManager = ProxyCacheManager(
          storageGateway: gateway,
          nativeWorker: worker,
        );
        await proxyManager.initialize();

        final sessionController = SessionController(
          storageGateway: gateway,
          sessionStore: store,
          proxyCacheManager: proxyManager,
          bindAppLifecycle: false,
        );
        await sessionController.openAlbum(album);

        const itemId = 'item_dscf4012';
        final pair = sessionController.state.pairedAssetsById[itemId]!;
        final fakeWorker = _FakeStudioWorker();
        final editor = StudioEditorController(
          itemId: itemId,
          pairedAsset: pair,
          sessionController: sessionController,
          proxyCacheManager: proxyManager,
          nativeGateway: fakeWorker,
          frameLoader: _fakeFrameLoader,
        );
        await editor.initialize();

        expect(editor.state.spec.shadowLift, equals(18.5));

        editor.commitShadowLift(55.0);
        expect(editor.state.spec.shadowLift, equals(55.0));
        expect(editor.state.canUndo, isTrue);

        editor.undo();
        expect(editor.state.spec.shadowLift, equals(18.5));
        expect(editor.state.canRedo, isTrue);

        editor.redo();
        expect(editor.state.spec.shadowLift, equals(55.0));

        await editor.applyAutoRescue();
        expect(editor.state.spec.shadowLift, equals(42.0));
        expect(
          DnaRescueMapper.readMode(editor.state.spec),
          equals(FsDnaRescueMode.FS_DNA_MODE_DEEP_RESCUE.value),
        );

        await editor.flushPendingSave();

        // Reload raw JSON from disk and verify 100% unknownFields + sibling recipe preservation.
        final reloaded = await store.loadSession(albumKey);
        expect(reloaded, isNotNull);
        final reloadedItem = reloaded!.items.first;
        expect(reloadedItem.editRecipe.dnaRescue.shadowLift, equals(42.0));
        expect(
          reloadedItem.editRecipe.dnaRescue.unknownFields['desktop_bilateral_sigma_spatial'],
          equals(4.25),
        );
        expect(reloadedItem.editRecipe.geometry.rotationDeg, equals(-0.65));
        expect(reloadedItem.editRecipe.lut.lutId, equals('classic_chrome_warm_65'));
        expect(
          reloadedItem.editRecipe.unknownFields['desktop_reinhard_lab_ref_id'],
          equals('item_dscf4001'),
        );
        expect(
          reloadedItem.cullResult?.unknownFields['desktop_dhash_hex'],
          equals('ff81c3a599007e3c'),
        );

        editor.resetToDefault();
        expect(editor.state.spec.enabled, isFalse);
        expect(editor.state.spec.shadowLift, equals(0.0));

        await editor.flushPendingSave();
        editor.dispose();
        await proxyManager.dispose();
        sessionController.dispose();
      },
    );
  });
}
