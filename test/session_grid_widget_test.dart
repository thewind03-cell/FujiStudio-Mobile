import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/di/app_providers.dart';
import 'package:fujistudio_mobile/core/ffi/native_worker.dart';
import 'package:fujistudio_mobile/core/schema/edit_recipe.dart';
import 'package:fujistudio_mobile/core/schema/session_item.dart';
import 'package:fujistudio_mobile/core/session/session_store.dart';
import 'package:fujistudio_mobile/core/storage/asset_pairing_engine.dart';
import 'package:fujistudio_mobile/core/storage/proxy_cache_manager.dart';
import 'package:fujistudio_mobile/core/storage/storage_gateway.dart';
import 'package:fujistudio_mobile/core/theme/fuji_theme.dart';
import 'package:fujistudio_mobile/features/session_picker/session_controller.dart';
import 'package:fujistudio_mobile/features/session_picker/session_grid_screen.dart';
import 'package:material_ui/material_ui.dart';

// Valid 1x1 transparent PNG bytes so Image.file decodes cleanly in widget tests.
final List<int> _kTinyValidPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

final class _WidgetTestStorageGateway implements StorageGateway {
  _WidgetTestStorageGateway({
    required this.proxyDir,
    required this.sessionDir,
    required this.files,
  });

  final String proxyDir;
  final String sessionDir;
  final List<RawMediaFileDescriptor> files;
  final List<Completer<void>> pendingDecodes = <Completer<void>>[];
  bool holdDecodes = true;

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
    if (holdDecodes) {
      final gate = Completer<void>();
      pendingDecodes.add(gate);
      await gate.future;
    }
    final out = File(outJpegPath);
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(_kTinyValidPngBytes);
    return ProxyDecodeResult(
      width: 1,
      height: 1,
      byteSize: _kTinyValidPngBytes.length,
    );
  }

  void completeAllDecodes() {
    holdDecodes = false;
    for (final c in pendingDecodes) {
      if (!c.isCompleted) c.complete();
    }
    pendingDecodes.clear();
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
      const <MediaAlbumDescriptor>[
        MediaAlbumDescriptor(albumId: 'album_100', name: '100_FUJI', count: 100),
      ];

  @override
  Future<List<RawMediaFileDescriptor>> listMediaInAlbum({
    required String albumId,
    int limit = 200,
    int offset = 0,
  }) async {
    if (offset >= files.length) return const <RawMediaFileDescriptor>[];
    final end = (offset + limit).clamp(0, files.length);
    return files.sublist(offset, end);
  }

  @override
  Future<OpenedNativeFd?> openReadOnlyFd(String uri) async => null;

  @override
  Future<StoragePermissionState> requestReadPermission() async =>
      StoragePermissionState.granted;
}

void main() {
  group('SessionGridScreen Widget Tests', () {
    late Directory tempDir;
    late NativeWorker worker;
    late _WidgetTestStorageGateway gateway;
    late SessionStore store;
    late ProxyCacheManager proxyManager;
    late SessionController controller;
    late List<RawMediaFileDescriptor> files;

    setUpAll(() async {
      worker = await NativeWorker.spawn();
    });

    tearDownAll(() async {
      await worker.dispose();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fujistudio_grid_widget_');
      final proxyDir = Directory('${tempDir.path}${Platform.pathSeparator}proxy')
        ..createSync();
      final sessionDir = Directory('${tempDir.path}${Platform.pathSeparator}sess')
        ..createSync();

      files = List<RawMediaFileDescriptor>.generate(100, (index) {
        final numStr = (1000 + index).toString();
        return RawMediaFileDescriptor(
          mediaId: 'm_$index',
          uri: 'content://media/external/images/media/$index',
          displayName: 'DSCF$numStr.JPG',
          relativePath: 'DCIM/100_FUJI/',
          mimeType: 'image/jpeg',
          sizeBytes: 10000 + index,
          dateTakenMs: 1000000 - index,
          dateModifiedSec: 1000 - index,
          width: 6240,
          height: 4160,
        );
      });

      gateway = _WidgetTestStorageGateway(
        proxyDir: proxyDir.path,
        sessionDir: sessionDir.path,
        files: files,
      );
      store = SessionStore(
        explicitSessionRoot: sessionDir.path,
        debounceDuration: const Duration(seconds: 5),
      );
      proxyManager = ProxyCacheManager(
        storageGateway: gateway,
        nativeWorker: worker,
        maxConcurrent: 2,
        lruSaveDebounce: const Duration(seconds: 10),
      );
      controller = SessionController(
        storageGateway: gateway,
        sessionStore: store,
        proxyCacheManager: proxyManager,
        bindAppLifecycle: false,
      );

      await proxyManager.initialize();
      await controller.openAlbum(
        const MediaAlbumDescriptor(
          albumId: 'album_100',
          name: '100_FUJI',
          count: 100,
        ),
      );
    });

    tearDown(() async {
      await store.flushAll();
      await proxyManager.dispose();
      if (tempDir.existsSync()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {
          // Best-effort cleanup on Windows.
        }
      }
    });

    testWidgets(
      'rapidly scrolling 100-photo grid cancels scrolled-off queued tiles without setState-after-dispose and long-press toggles KEEP',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              storageGatewayProvider.overrideWithValue(gateway),
              nativeWorkerProvider.overrideWithValue(worker),
              sessionStoreProvider.overrideWithValue(store),
              proxyCacheManagerProvider.overrideWithValue(proxyManager),
              sessionControllerProvider.overrideWith((_) => controller),
            ],
            child: MaterialApp(
              theme: FujiTheme.dark(),
              home: const SessionGridScreen(),
            ),
          ),
        );

        await tester.pump();
        expect(find.text('0 / 100'), findsOneWidget);

        // Rapidly scroll down multiple times across the 100-item grid.
        final gridFinder = find.byKey(const Key('session_photo_grid'));
        for (var i = 0; i < 8; i++) {
          await tester.drag(gridFinder, const Offset(0, -600));
          await tester.pump(const Duration(milliseconds: 16));
        }

        // Tiles scrolled off viewport must have cancelled their queued ProxyCancelTokens.
        expect(
          proxyManager.cancelledQueuedCount + proxyManager.cancelledRunningCount,
          greaterThan(0),
        );

        // Long-press a tile squarely inside the visible viewport -> toggles KEEP immediately.
        final tileFinder = find.byType(PhotoGridTile);
        final gridRect = tester.getRect(gridFinder);
        Finder? targetTile;
        final count = tester.widgetList(tileFinder).length;
        for (var i = 0; i < count; i++) {
          final candidate = tileFinder.at(i);
          final center = tester.getCenter(candidate);
          if (center.dy > gridRect.top + 40 && center.dy < gridRect.bottom - 40) {
            targetTile = candidate;
            break;
          }
        }
        expect(targetTile, isNotNull);
        await tester.longPress(targetTile!);
        await tester.pump(kLongPressTimeout);

        expect(find.text('1 / 100'), findsOneWidget);
        expect(find.text('CHỌN 1'), findsOneWidget);

        gateway.completeAllDecodes();
        await tester.pump();
        await tester.runAsync(() async {
          await controller.flushPendingSave();
          await proxyManager.dispose();
        });
        await tester.pump(const Duration(seconds: 15));
        await tester.pumpWidget(const SizedBox.shrink());
        PaintingBinding.instance.imageCache.clear();

        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'PhotoGridTile cancels old ProxyCancelToken and reloads proxy when pairedAsset changes via didUpdateWidget',
      (WidgetTester tester) async {
        final pairA = PairedAsset(
          pairKey: 'dcim|dscf_a',
          stem: 'DSCF_A',
          normalizedDir: 'dcim',
          kind: AssetPairKind.jpgOnly,
          primaryAsset: files[0],
          capturedAtMs: 1000,
        );
        final pairB = PairedAsset(
          pairKey: 'dcim|dscf_b',
          stem: 'DSCF_B',
          normalizedDir: 'dcim',
          kind: AssetPairKind.jpgOnly,
          primaryAsset: files[1],
          capturedAtMs: 2000,
        );
        final item = SessionItem(
          id: 'tile_item_1',
          fileName: 'DSCF_A.JPG',
          editRecipe: EditRecipe(
            dnaRescue: DnaRescueSpec(enabled: false, shadowLift: 0.0),
            geometry: GeometrySpec(rotationDeg: 0.0),
            lut: LutSpec(enabled: false, intensity: 0.0),
            exportProfile: ExportProfileSpec(format: 'jpeg', quality: 92),
          ),
        );

        Widget buildHarness(PairedAsset pair) {
          return ProviderScope(
            overrides: <Override>[
              storageGatewayProvider.overrideWithValue(gateway),
              nativeWorkerProvider.overrideWithValue(worker),
              sessionStoreProvider.overrideWithValue(store),
              proxyCacheManagerProvider.overrideWithValue(proxyManager),
            ],
            child: MaterialApp(
              theme: FujiTheme.dark(),
              home: Scaffold(
                body: SizedBox(
                  width: 120,
                  height: 120,
                  child: PhotoGridTile(
                    key: const Key('reused_photo_tile'),
                    item: item,
                    pairedAsset: pair,
                    onTap: () {},
                    onLongPress: () {},
                  ),
                ),
              ),
            ),
          );
        }

        await tester.pumpWidget(buildHarness(pairA));
        await tester.pump();
        expect(gateway.pendingDecodes, hasLength(1));

        // Update the same StatefulElement with a new pairedAsset -> must cancel old token & load pairB.
        await tester.pumpWidget(buildHarness(pairB));
        await tester.pump();
        expect(
          proxyManager.cancelledQueuedCount + proxyManager.cancelledRunningCount,
          equals(1),
        );
        expect(gateway.pendingDecodes, hasLength(2));

        gateway.completeAllDecodes();
        await tester.pump();
        await tester.pump();

        final expectedFileB = File(
          '${gateway.proxyDir}${Platform.pathSeparator}${proxyManager.cacheKeyFor(pairB)}.jpg',
        );
        expect(expectedFileB.existsSync(), isTrue);
        final imageWidget = tester.widget<Image>(find.byType(Image));
        final resizeImage = imageWidget.image as ResizeImage;
        final fileImage = resizeImage.imageProvider as FileImage;
        expect(fileImage.file.path, equals(expectedFileB.path));

        await tester.runAsync(() async {
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
