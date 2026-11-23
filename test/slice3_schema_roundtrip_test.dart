import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/ffi/native_worker.dart';
import 'package:fujistudio_mobile/core/schema/action_proposal.dart';
import 'package:fujistudio_mobile/core/schema/collage_spec.dart';
import 'package:fujistudio_mobile/core/schema/session_document.dart';
import 'package:fujistudio_mobile/core/session/session_store.dart';
import 'package:fujistudio_mobile/core/storage/proxy_cache_manager.dart';
import 'package:fujistudio_mobile/core/storage/storage_gateway.dart';
import 'package:fujistudio_mobile/features/session_picker/session_controller.dart';
import 'package:fujistudio_mobile/features/story_collage/collage_mapper.dart';
import 'package:fujistudio_mobile/features/studio_editor/geometry_mapper.dart';

final class _MinimalStorageGateway implements StorageGateway {
  _MinimalStorageGateway({
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
  }) async => const ProxyDecodeResult(width: 100, height: 100, byteSize: 10);

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

void main() {
  group('Slice 3 Schema v2.4.2 Round-Trip & _presentKeys Persistence', () {
    test(
      'mutating GeometrySpec, adding/accepting ActionProposal, and saving CollageSpec preserves 100% of unknownFields',
      () {
        final rawText = File(
          'schemas/fixtures/desktop_v2_4_2_sample.json',
        ).readAsStringSync();
        final rawJson = jsonDecode(rawText) as Map<String, Object?>;
        final doc = SessionDocument.fromJson(rawJson);

        final item = doc.items.first;
        final updatedGeometry = GeometryMapper.withNormalizedGeometry(
          item.editRecipe.geometry,
          rotationDeg: 2.35,
          aspectPreset: 1, // 4:5
          cropBox: const NormCropBoxData(
            left: 0.1,
            top: 0.05,
            right: 0.9,
            bottom: 0.95,
          ),
        );
        final updatedItem = item.copyWith(
          editRecipe: item.editRecipe.copyWith(geometry: updatedGeometry),
        );

        final acceptedProposal = doc.actionProposals.first.copyWith(
          accepted: true,
        );
        final newProposal = ActionProposal(
          proposalId: 'prop_mobile_002',
          targetItemId: item.id,
          actionType: 'horizon_and_crop',
          confidence: 0.91,
          summary: 'Đề xuất: -1.4° · Khung 4:5 (91%)',
          accepted: true,
          patch: const <String, Object?>{
            'geometry.rotation_deg': -1.4,
            'geometry.aspect_ratio': '4:5',
            'geometry.crop_box': <double>[0.1, 0.0, 0.8, 1.0],
          },
        );

        final savedCollage = CollageMapper.withOuterMarginPx(
          CollageSpec(
            collageId: 'col_mobile_02',
            templateId: 'grid_3_top',
            aspectRatio: '9:16',
            backgroundHex: '#F4F1EA',
            spacingPx: 14,
            slots: <CollageSlot>[
              CollageSlot(slotIndex: 0, itemId: item.id, panX: 0.1, zoom: 1.2),
              CollageSlot(slotIndex: 1, itemId: item.id),
              CollageSlot(slotIndex: 2, itemId: item.id),
            ],
          ),
          16,
        );

        final updatedDoc = doc.copyWith(
          items: <dynamic>[updatedItem].cast(),
          actionProposals: <ActionProposal>[acceptedProposal, newProposal],
          collages: <CollageSpec>[...doc.collages, savedCollage],
        );

        final wireJson =
            jsonDecode(jsonEncode(updatedDoc.toJson())) as Map<String, Object?>;

        // Root & nested unknownFields intact
        expect(
          (wireJson['desktop_lut_cache'] as Map<String, Object?>)['max_cube_size'],
          equals(65),
        );
        expect(
          wireJson['xmp_sidecar_hash'],
          equals('9f86d081884c7d659a2feaa0c55ad015'),
        );

        final outItem =
            (wireJson['items'] as List<Object?>).first as Map<String, Object?>;
        final outGeom =
            ((outItem['edit_recipe'] as Map<String, Object?>)['geometry']
                as Map<String, Object?>);
        expect(outGeom['rotation_deg'], equals(2.35));
        expect(outGeom['aspect_ratio'], equals('4:5'));
        expect(
          outGeom['desktop_warp_interpolation'],
          equals('LANCZOS4'),
        );

        final outProposals = wireJson['action_proposals'] as List<Object?>;
        expect(outProposals, hasLength(2));
        expect(
          (outProposals.first as Map<String, Object?>)['desktop_model_checkpoint'],
          equals('horizon_v2_4_onnx'),
        );

        final outCollages = wireJson['collages'] as List<Object?>;
        expect(outCollages, hasLength(2));
        expect(
          (outCollages.first as Map<String, Object?>)['desktop_print_dpi'],
          equals(300),
        );
        expect(
          (outCollages.last as Map<String, Object?>)['outer_margin_px'],
          equals(16),
        );
      },
    );

    test(
      'minimal SessionDocument without action_proposals/collages emits both keys onto disk after SessionController updates (_presentKeys fix)',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'fujistudio_slice3_minimal_',
        );
        final worker = await NativeWorker.spawn();
        try {
          final proxyDir = Directory('${tempDir.path}${Platform.pathSeparator}proxy')
            ..createSync();
          final sessionDir = Directory('${tempDir.path}${Platform.pathSeparator}sess')
            ..createSync();

          const album = MediaAlbumDescriptor(
            albumId: 'album_min',
            name: 'MIN_FUJI',
            count: 2,
          );
          final albumKey = SessionStore.albumKeyFor(album.albumId);

          // Pre-seed a minimal session JSON WITHOUT action_proposals or collages.
          final minimalRaw = <String, Object?>{
            'schema_version': '2.4.2',
            'session_id': 'sess_min_001',
            'created_at': '2026-11-22T00:00:00Z',
            'items': <Object?>[
              <String, Object?>{
                'id': 'item_min_1',
                'file_name': 'DSCF0001.JPG',
                'media_uri': 'content://media/1',
                'edit_recipe': <String, Object?>{
                  'dna_rescue': <String, Object?>{
                    'enabled': false,
                    'shadow_lift': 0,
                  },
                  'geometry': <String, Object?>{
                    'rotation_deg': 0,
                  },
                  'lut': <String, Object?>{
                    'enabled': false,
                    'intensity': 0,
                  },
                  'export_profile': <String, Object?>{
                    'format': 'jpeg',
                    'quality': 92,
                  },
                },
              },
              <String, Object?>{
                'id': 'item_min_2',
                'file_name': 'DSCF0002.JPG',
                'media_uri': 'content://media/2',
                'edit_recipe': <String, Object?>{
                  'dna_rescue': <String, Object?>{
                    'enabled': false,
                    'shadow_lift': 0,
                  },
                  'geometry': <String, Object?>{
                    'rotation_deg': 0,
                  },
                  'lut': <String, Object?>{
                    'enabled': false,
                    'intensity': 0,
                  },
                  'export_profile': <String, Object?>{
                    'format': 'jpeg',
                    'quality': 92,
                  },
                },
              },
            ],
          };

          final store = SessionStore(
            explicitSessionRoot: sessionDir.path,
            debounceDuration: const Duration(milliseconds: 10),
          );
          await store.saveNow(albumKey, SessionDocument.fromJson(minimalRaw));

          final gateway = _MinimalStorageGateway(
            proxyDir: proxyDir.path,
            sessionDir: sessionDir.path,
            files: const <RawMediaFileDescriptor>[
              RawMediaFileDescriptor(
                mediaId: '1',
                uri: 'content://media/1',
                displayName: 'DSCF0001.JPG',
                relativePath: 'DCIM/',
                mimeType: 'image/jpeg',
                sizeBytes: 1000,
                dateTakenMs: 1000,
                dateModifiedSec: 1,
              ),
              RawMediaFileDescriptor(
                mediaId: '2',
                uri: 'content://media/2',
                displayName: 'DSCF0002.JPG',
                relativePath: 'DCIM/',
                mimeType: 'image/jpeg',
                sizeBytes: 1000,
                dateTakenMs: 2000,
                dateModifiedSec: 2,
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

          controller.recordActionProposal(
            ActionProposal(
              proposalId: 'prop_min_1',
              targetItemId: 'item_min_1',
              actionType: 'horizon_and_crop',
              confidence: 0.88,
              summary: 'Đề xuất: -1.5° · Khung 4:5 (88%)',
              accepted: true,
              patch: const <String, Object?>{
                'geometry.rotation_deg': -1.5,
                'geometry.aspect_ratio': '4:5',
              },
            ),
          );
          controller.saveCollageSpec(
            CollageSpec(
              collageId: 'col_min_1',
              templateId: 'split_2_v',
              aspectRatio: '9:16',
              backgroundHex: '#FFFFFF',
              spacingPx: 12,
              slots: <CollageSlot>[
                CollageSlot(slotIndex: 0, itemId: 'item_min_1'),
                CollageSlot(slotIndex: 1, itemId: 'item_min_2'),
              ],
            ),
          );
          await controller.flushPendingSave();

          // Read raw JSON back from disk and verify both keys are present.
          final sessionFile = File(
            '${sessionDir.path}${Platform.pathSeparator}$albumKey${Platform.pathSeparator}.fujistudio_session.json',
          );
          expect(sessionFile.existsSync(), isTrue);
          final diskJson =
              jsonDecode(sessionFile.readAsStringSync()) as Map<String, Object?>;
          expect(diskJson.containsKey('action_proposals'), isTrue);
          expect(diskJson.containsKey('collages'), isTrue);

          final reloaded = await store.loadSession(albumKey);
          expect(reloaded, isNotNull);
          expect(reloaded!.actionProposals, hasLength(1));
          expect(
            reloaded.actionProposals.first.proposalId,
            equals('prop_min_1'),
          );
          expect(reloaded.collages, hasLength(1));
          expect(reloaded.collages.first.collageId, equals('col_min_1'));

          controller.dispose();
          await proxyManager.dispose();
        } finally {
          await worker.dispose();
          if (tempDir.existsSync()) {
            await tempDir.delete(recursive: true);
          }
        }
      },
    );
  });
}
