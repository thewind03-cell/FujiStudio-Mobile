import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/ffi/native_worker.dart';
import 'package:fujistudio_mobile/core/schema/cull_result.dart';
import 'package:fujistudio_mobile/core/schema/edit_recipe.dart';
import 'package:fujistudio_mobile/core/schema/session_document.dart';
import 'package:fujistudio_mobile/core/schema/session_item.dart';
import 'package:fujistudio_mobile/core/session/session_store.dart';
import 'package:fujistudio_mobile/core/storage/proxy_cache_manager.dart';
import 'package:fujistudio_mobile/core/storage/storage_gateway.dart';
import 'package:fujistudio_mobile/features/session_picker/session_controller.dart';

final class _FakeStorageGateway implements StorageGateway {
  _FakeStorageGateway({
    required this.proxyDir,
    required this.sessionDir,
    required this.mediaFiles,
  });

  final String proxyDir;
  final String sessionDir;
  final List<RawMediaFileDescriptor> mediaFiles;

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
    return const ProxyDecodeResult(width: 100, height: 100, byteSize: 10);
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
  }) async {
    if (offset >= mediaFiles.length) return const <RawMediaFileDescriptor>[];
    final end = (offset + limit).clamp(0, mediaFiles.length);
    return mediaFiles.sublist(offset, end);
  }

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

void main() {
  group('SessionController', () {
    late Directory tempDir;
    late NativeWorker worker;

    setUpAll(() async {
      worker = await NativeWorker.spawn();
    });

    tearDownAll(() async {
      await worker.dispose();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fujistudio_ctrl_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'performs 3-way reconciliation preserving old metadata, adding new photos, and retaining hidden photos in JSON',
      () async {
        final proxyDir = Directory('${tempDir.path}${Platform.pathSeparator}proxy')
          ..createSync();
        final sessionDir = Directory('${tempDir.path}${Platform.pathSeparator}sess')
          ..createSync();

        const album = MediaAlbumDescriptor(
          albumId: 'album_100',
          name: '100_FUJI',
          count: 2,
        );
        final albumKey = SessionStore.albumKeyFor(album.albumId);

        final store = SessionStore(
          explicitSessionRoot: sessionDir.path,
          debounceDuration: const Duration(milliseconds: 500),
        );

        // Pre-populate session JSON with 1 existing matched photo and 1 hidden photo
        final existingDoc = SessionDocument(
          schemaVersion: '2.4.2',
          sessionId: 'sess_preexisting',
          createdAt: '2026-11-20T00:00:00Z',
          items: <SessionItem>[
            SessionItem(
              id: 'item_desktop_01',
              fileName: 'DSCF0001.JPG',
              mediaUri: 'content://old/1',
              cullResult: CullResult(
                status: 'keep',
                sharpnessScore: 0.92,
                unknownFields: const <String, Object?>{
                  'desktop_dhash': 'abcd',
                },
              ),
              editRecipe: EditRecipe(
                dnaRescue: DnaRescueSpec(enabled: true, shadowLift: 24.5),
                geometry: GeometrySpec(rotationDeg: -1.2),
                lut: LutSpec(enabled: true, lutId: 'cc_warm', intensity: 0.6),
                exportProfile: ExportProfileSpec(format: 'jpeg', quality: 92),
              ),
              unknownFields: const <String, Object?>{
                'xmp_sidecar_hash': 'hash_123',
              },
            ),
            SessionItem(
              id: 'item_hidden_limited',
              fileName: 'DSCF9999.JPG',
              mediaUri: 'content://hidden/9999',
              cullResult: CullResult(status: 'reject', sharpnessScore: 0.1),
              editRecipe: EditRecipe(
                dnaRescue: DnaRescueSpec(enabled: false, shadowLift: 0.0),
                geometry: GeometrySpec(rotationDeg: 0.0),
                lut: LutSpec(enabled: false, intensity: 0.0),
                exportProfile: ExportProfileSpec(format: 'jpeg', quality: 92),
              ),
              unknownFields: const <String, Object?>{'hidden_tag': true},
            ),
          ],
          unknownFields: const <String, Object?>{
            'desktop_window_state': <String, Object?>{'split': 0.7},
          },
        );
        await store.saveNow(albumKey, existingDoc);

        final gateway = _FakeStorageGateway(
          proxyDir: proxyDir.path,
          sessionDir: sessionDir.path,
          mediaFiles: const <RawMediaFileDescriptor>[
            RawMediaFileDescriptor(
              mediaId: '1',
              uri: 'content://new/1',
              displayName: 'DSCF0001.JPG',
              relativePath: 'DCIM/100_FUJI/',
              mimeType: 'image/jpeg',
              sizeBytes: 2048,
              dateTakenMs: 2000,
              dateModifiedSec: 2,
              width: 6240,
              height: 4160,
            ),
            RawMediaFileDescriptor(
              mediaId: '2',
              uri: 'content://new/2',
              displayName: 'DSCF0002.JPG',
              relativePath: 'DCIM/100_FUJI/',
              mimeType: 'image/jpeg',
              sizeBytes: 3000,
              dateTakenMs: 3000,
              dateModifiedSec: 3,
              width: 6240,
              height: 4160,
            ),
          ],
        );

        final proxyManager = ProxyCacheManager(
          storageGateway: gateway,
          nativeWorker: worker,
        );
        await proxyManager.initialize();

        final controller = SessionController(
          storageGateway: gateway,
          sessionStore: store,
          proxyCacheManager: proxyManager,
          bindAppLifecycle: false,
        );

        await controller.openAlbum(album);

        // Grid only renders the 2 gallery-visible photos; missing hidden item is counted & retained in document.
        expect(controller.state.totalCount, equals(2));
        expect(controller.state.missingFromGalleryCount, equals(1));
        expect(controller.state.document!.items, hasLength(3));
        expect(proxyManager.pinnedKeys, hasLength(2));

        // Matched item preserved cull_result, edit_recipe, unknownFields, and refreshed mediaUri.
        final matched = controller.state.itemById('item_desktop_01')!;
        expect(matched.mediaUri, equals('content://new/1'));
        expect(matched.cullResult?.status, equals('keep'));
        expect(matched.cullResult?.unknownFields['desktop_dhash'], equals('abcd'));
        expect(matched.editRecipe.dnaRescue.shadowLift, equals(24.5));
        expect(matched.unknownFields['xmp_sidecar_hash'], equals('hash_123'));

        // New photo initialized unmarked.
        final newItem = controller.state.document!.items.firstWhere(
          (i) => i.fileName == 'DSCF0002.JPG',
        );
        expect(newItem.cullResult, isNull);

        // Filter switching
        controller.setFilter(GridFilterMode.keep);
        expect(controller.state.visibleItemIds, equals(<String>['item_desktop_01']));
        controller.setFilter(GridFilterMode.unmarked);
        expect(controller.state.visibleItemIds, equals(<String>[newItem.id]));
        controller.setFilter(GridFilterMode.reject);
        expect(controller.state.visibleItemIds, isEmpty);
        controller.setFilter(GridFilterMode.all);
        expect(controller.state.visibleItemIds, hasLength(2));

        // Mutate + flushPendingSave writes immediately to disk and retains hidden item.
        controller.setCullStatus(newItem.id, 'reject');
        expect(controller.state.hasPendingChanges, isTrue);
        await controller.flushPendingSave();
        expect(controller.state.hasPendingChanges, isFalse);

        final savedFile = File(
          '${sessionDir.path}${Platform.pathSeparator}$albumKey${Platform.pathSeparator}${SessionStore.sessionFileName}',
        );
        final savedJson =
            jsonDecode(await savedFile.readAsString()) as Map<String, Object?>;
        final savedItems = savedJson['items'] as List<Object?>;
        expect(savedItems, hasLength(3));
        expect(
          savedItems.any(
            (e) => (e as Map<String, Object?>)['id'] == 'item_hidden_limited',
          ),
          isTrue,
        );

        controller.dispose();
        await proxyManager.dispose();
      },
    );
  });
}
