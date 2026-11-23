import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/di/app_providers.dart';
import 'package:fujistudio_mobile/core/ffi/native_worker.dart';
import 'package:fujistudio_mobile/core/schema/edit_recipe.dart';
import 'package:fujistudio_mobile/core/session/session_store.dart';
import 'package:fujistudio_mobile/core/storage/asset_pairing_engine.dart';
import 'package:fujistudio_mobile/core/storage/proxy_cache_manager.dart';
import 'package:fujistudio_mobile/core/storage/storage_gateway.dart';
import 'package:fujistudio_mobile/core/theme/fuji_theme.dart';
import 'package:fujistudio_mobile/features/session_picker/session_controller.dart';
import 'package:fujistudio_mobile/features/session_picker/session_grid_screen.dart';
import 'package:fujistudio_mobile/features/story_collage/story_collage_controller.dart';
import 'package:fujistudio_mobile/features/story_collage/story_collage_screen.dart';
import 'package:material_ui/material_ui.dart';

final List<int> _kTinyValidPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

final class _CollageTestStorageGateway implements StorageGateway {
  _CollageTestStorageGateway({
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
      width: 64,
      height: 48,
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

Future<StoryCollageSlotFrame> _fakeSlotLoader(
  String itemId,
  PairedAsset asset,
  DnaRescueSpec dnaRescue,
) async {
  const w = 48;
  const h = 36;
  final rgba = Uint8List(w * h * 4);
  final tint = (itemId.hashCode & 0x7F) + 80;
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i + 0] = tint;
    rgba[i + 1] = 140;
    rgba[i + 2] = 190;
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

void main() {
  group('StoryCollageScreen Widget Flow Tests', () {
    late Directory tempDir;
    late NativeWorker worker;
    late _CollageTestStorageGateway storageGateway;
    late SessionStore store;
    late ProxyCacheManager proxyManager;
    late SessionController sessionController;

    setUpAll(() async {
      worker = await NativeWorker.spawn();
    });

    tearDownAll(() async {
      await worker.dispose();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fujistudio_collage_ui_');
      final proxyDir = Directory('${tempDir.path}${Platform.pathSeparator}proxy')
        ..createSync();
      final sessionDir = Directory('${tempDir.path}${Platform.pathSeparator}sess')
        ..createSync();

      final files = <RawMediaFileDescriptor>[
        for (var i = 1; i <= 3; i++)
          RawMediaFileDescriptor(
            mediaId: '$i',
            uri: 'content://media/external/images/media/$i',
            displayName: 'DSCF300$i.JPG',
            relativePath: 'DCIM/100_FUJI/',
            mimeType: 'image/jpeg',
            sizeBytes: 12000,
            dateTakenMs: 100000 + i,
            dateModifiedSec: 100 + i,
            width: 6240,
            height: 4160,
          ),
      ];
      storageGateway = _CollageTestStorageGateway(
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
        const MediaAlbumDescriptor(albumId: 'album_c', name: '100_FUJI', count: 3),
      );

      // Mark all 3 photos KEEP so tapping [⊞ COLLAGE] launches directly.
      for (final id in sessionController.state.galleryOrderedItemIds) {
        sessionController.setCullStatus(id, 'keep');
      }
      await sessionController.flushPendingSave();
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
      'launches StoryCollageScreen from SessionGridScreen with 3 KEEP photos, switches templates & aspect, swaps slots, previews real C++ stitch, saves CollageSpec, and pops cleanly',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              storageGatewayProvider.overrideWithValue(storageGateway),
              nativeWorkerProvider.overrideWithValue(worker),
              sessionStoreProvider.overrideWithValue(store),
              proxyCacheManagerProvider.overrideWithValue(proxyManager),
              sessionControllerProvider.overrideWith((_) => sessionController),
              collageSlotLoaderProvider.overrideWithValue(_fakeSlotLoader),
            ],
            child: MaterialApp(
              theme: FujiTheme.dark(),
              home: const SessionGridScreen(),
            ),
          ),
        );

        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();

        // Tap [⊞ COLLAGE] on SessionGridScreen
        await tester.tap(find.byKey(const Key('grid_collage_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        for (var i = 0; i < 10; i++) {
          if (find.byKey(const Key('collage_interactive_canvas')).evaluate().isNotEmpty) {
            break;
          }
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
          await tester.pump();
        }

        expect(find.byType(StoryCollageScreen), findsOneWidget);
        expect(find.byKey(const Key('collage_interactive_canvas')), findsOneWidget);

        // Switch between the 3 templates for 3 slots
        await tester.tap(find.byKey(const Key('collage_template_grid_3_strip')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('collage_template_grid_3_left')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('collage_template_grid_3_top')));
        await tester.pump();

        // Switch aspect 9:16 -> 4:5 -> 9:16
        await tester.tap(find.byKey(const Key('collage_aspect_4_5')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('collage_aspect_9_16')));
        await tester.pump();

        // Swap slot 0 and slot 1
        await tester.tap(find.byKey(const Key('collage_swap_button')));
        await tester.pump();
        final canvasBox = tester.getRect(
          find.byKey(const Key('collage_interactive_canvas')),
        );
        // Bottom-left region corresponds to slot 1 in grid_3_top
        await tester.tapAt(
          Offset(canvasBox.left + canvasBox.width * 0.25, canvasBox.bottom - 30),
        );
        await tester.pump();

        // Trigger real C++20 stitch preview [⚙ XEM BẢN GHÉP C++]
        await tester.tap(find.byKey(const Key('collage_cpp_preview_button')));
        await tester.pump();
        for (var i = 0; i < 10; i++) {
          if (find.byKey(const Key('collage_cpp_preview_dialog')).evaluate().isNotEmpty) {
            break;
          }
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
          await tester.pump();
        }

        expect(find.byKey(const Key('collage_cpp_preview_dialog')), findsOneWidget);
        await tester.tap(find.byKey(const Key('collage_cpp_preview_close')));
        await tester.pump();

        // Save CollageSpec into SessionController
        await tester.tap(find.byKey(const Key('collage_save_button')));
        await tester.pump();
        await tester.runAsync(() => sessionController.flushPendingSave());

        final savedCollages = sessionController.state.document!.collages;
        expect(savedCollages, hasLength(1));
        expect(savedCollages.first.templateId, equals('grid_3_top'));
        expect(savedCollages.first.aspectRatio, equals('9:16'));
        expect(savedCollages.first.slots, hasLength(3));
        // Slot 0 and 1 were swapped from initial gallery order
        final initialIds = sessionController.state.galleryOrderedItemIds;
        expect(savedCollages.first.slots[0].itemId, equals(initialIds[1]));
        expect(savedCollages.first.slots[1].itemId, equals(initialIds[0]));

        // Exit StoryCollageScreen cleanly
        await tester.tap(find.byKey(const Key('collage_back_button')));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pumpAndSettle();

        expect(find.byType(StoryCollageScreen), findsNothing);
        expect(find.byType(SessionGridScreen), findsOneWidget);

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
