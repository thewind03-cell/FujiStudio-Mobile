import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/schema/edit_recipe.dart';
import 'package:fujistudio_mobile/core/schema/session_document.dart';
import 'package:fujistudio_mobile/features/social_export/export_mapper.dart';

void main() {
  group('Slice 4 ExportProfile Schema v2.4.2 Round-Trip & Mapper Tests', () {
    test(
      'updating ExportProfileSpec on desktop_v2_4_2_sample.json preserves 100% of unknownFields and int types',
      () {
        final rawText = File(
          'schemas/fixtures/desktop_v2_4_2_sample.json',
        ).readAsStringSync();
        final rawJson = jsonDecode(rawText) as Map<String, Object?>;
        final doc = SessionDocument.fromJson(rawJson);

        final item = doc.items.first;
        final updatedProfile = ExportMapper.applyPreset(
          item.editRecipe.exportProfile,
          SocialExportPreset.facebook2048,
          preserveExif: true,
          stripGps: true,
        );

        final updatedItem = item.copyWith(
          editRecipe: item.editRecipe.copyWith(exportProfile: updatedProfile),
        );
        final updatedDoc = doc.copyWith(items: [updatedItem]);

        final reserialized =
            jsonDecode(jsonEncode(updatedDoc.toJson())) as Map<String, Object?>;
        final itemsOut = reserialized['items'] as List<Object?>;
        final firstItemOut = itemsOut.first as Map<String, Object?>;
        final recipeOut = firstItemOut['edit_recipe'] as Map<String, Object?>;
        final exportOut = recipeOut['export_profile'] as Map<String, Object?>;

        // Locked Gate 0 keys and integer types
        expect(exportOut['format'], equals('jpeg'));
        expect(exportOut['quality'], equals(92));
        expect(exportOut['quality'], isA<int>());
        expect(exportOut['color_space'], equals('sRGB'));
        expect(exportOut['max_long_edge_px'], equals(2048));
        expect(exportOut['max_long_edge_px'], isA<int>());

        // Social export extension fields & EXIF/GPS polarity
        expect(exportOut['preset'], equals('facebook_2048'));
        expect(exportOut['output_sharpening'], equals('subtle'));
        expect(exportOut['preserve_exif'], isTrue);
        expect(exportOut['strip_gps'], isTrue);
        expect(exportOut['filename_suffix'], equals('_fb2048'));

        // Desktop unknownFields must survive verbatim at every level
        expect(exportOut['desktop_exif_preserve_makernotes'], isTrue);
        expect(recipeOut['desktop_recipe_revision'], equals(7));
        expect(
          firstItemOut['raf_companion_path'],
          equals('D:\\Shoot_2026\\DSCF4012.RAF'),
        );
        expect(reserialized['desktop_lut_cache'], isNotNull);

        // Native config mapping checks
        final nativeCfg = ExportMapper.toNativeConfig(updatedProfile);
        expect(nativeCfg.preset, equals(SocialExportPreset.facebook2048));
        expect(nativeCfg.maxLongEdgePx, equals(2048));
        expect(nativeCfg.jpegQuality, equals(92));
        expect(nativeCfg.outputUsm.enabled, isTrue);
        expect(nativeCfg.outputUsm.amount, closeTo(0.35, 1e-6));
        expect(nativeCfg.preserveExif, isTrue);
        expect(nativeCfg.stripGps, isTrue);
        expect(nativeCfg.filenameSuffix, equals('_fb2048'));
      },
    );

    test(
      'minimal JSON without max_long_edge_px or color_space emits int fields after copyWith & SessionDocument.copyWith',
      () {
        final minimalRaw = <String, Object?>{
          'schema_version': '2.4.2',
          'session_id': 'sess_min_export_01',
          'created_at': '2026-11-23T00:00:00Z',
          'items': <Object?>[
            <String, Object?>{
              'id': 'item_01',
              'file_name': 'DSCF0001.JPG',
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
                  'quality': 90,
                },
              },
            },
          ],
        };

        final doc = SessionDocument.fromJson(minimalRaw);
        final item = doc.items.first;

        // Before update, minimal export_profile had only format & quality
        final beforeJson = item.editRecipe.exportProfile.toJson();
        expect(beforeJson.containsKey('max_long_edge_px'), isFalse);
        expect(beforeJson.containsKey('color_space'), isFalse);

        // Update via ExportMapper + EditRecipe.copyWith + SessionDocument.copyWith
        final nextProfile = ExportMapper.withOptions(
          item.editRecipe.exportProfile,
          preset: SocialExportPreset.instagram2048,
          jpegQuality: 90,
          maxLongEdgePx: 2048,
          sharpening: OutputSharpeningLevel.standard,
          preserveExif: false,
          stripGps: true,
        );

        final nextDoc = doc.copyWith(
          items: [
            item.copyWith(
              editRecipe: item.editRecipe.copyWith(exportProfile: nextProfile),
            ),
          ],
        );

        final outJson =
            jsonDecode(jsonEncode(nextDoc.toJson())) as Map<String, Object?>;
        final outExport = (((outJson['items'] as List<Object?>).first
                as Map<String, Object?>)['edit_recipe']
            as Map<String, Object?>)['export_profile'] as Map<String, Object?>;

        expect(outExport['format'], equals('jpeg'));
        expect(outExport['quality'], equals(90));
        expect(outExport['quality'], isA<int>());
        expect(outExport['max_long_edge_px'], equals(2048));
        expect(outExport['max_long_edge_px'], isA<int>());
        expect(outExport['preset'], equals('instagram_2048'));
        expect(outExport['output_sharpening'], equals('standard'));
        expect(outExport['preserve_exif'], isFalse);
        expect(outExport['strip_gps'], isTrue);

        // Reload and verify originalMax clears maxLongEdgePx to null (0 in native)
        final reloaded = SessionDocument.fromJson(outJson);
        final origProfile = ExportMapper.applyPreset(
          reloaded.items.first.editRecipe.exportProfile,
          SocialExportPreset.originalMax,
        );
        final origOut = origProfile.toJson();
        expect(origOut.containsKey('max_long_edge_px'), isTrue);
        expect(origOut['max_long_edge_px'], isNull);

        final origNative = ExportMapper.toNativeConfig(origProfile);
        expect(origNative.maxLongEdgePx, equals(0));
        expect(origNative.outputUsm.enabled, isFalse);
        expect(origNative.outputUsm.amount, equals(0.0));
        expect(origNative.filenameSuffix, equals('_full'));
      },
    );

    test(
      'ExportMapper.buildOutputFileName formats JPG/RAF stems cleanly and EditRecipe.copyWith works with fresh ExportProfileSpec',
      () {
        expect(
          ExportMapper.buildOutputFileName('DSCF4012.JPG', suffix: '_fb2048'),
          equals('DSCF4012_fb2048.jpg'),
        );
        expect(
          ExportMapper.buildOutputFileName('DSCF4012.RAF', suffix: '_ig2048'),
          equals('DSCF4012_ig2048.jpg'),
        );
        expect(
          ExportMapper.buildOutputFileName('portrait', suffix: '_full'),
          equals('portrait_full.jpg'),
        );

        final fresh = ExportProfileSpec(
          format: 'jpeg',
          quality: 90,
          maxLongEdgePx: 2048,
        );
        final json = fresh.toJson();
        expect(json['quality'], equals(90));
        expect(json['quality'], isA<int>());
        expect(json['max_long_edge_px'], equals(2048));
        expect(json['max_long_edge_px'], isA<int>());
        expect(json['color_space'], equals('sRGB'));
      },
    );
  });
}
