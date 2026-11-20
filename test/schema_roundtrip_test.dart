import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/schema/session_document.dart';

void _expectDeepTypeAndValueEquals(
  Object? actual,
  Object? expected,
  String path,
) {
  expect(
    actual.runtimeType,
    equals(expected.runtimeType),
    reason: 'Runtime type mismatch at $path',
  );

  if (expected is Map && actual is Map) {
    expect(
      actual.keys.toSet(),
      equals(expected.keys.toSet()),
      reason: 'Map keys mismatch at $path',
    );
    for (final key in expected.keys) {
      _expectDeepTypeAndValueEquals(actual[key], expected[key], '$path.$key');
    }
    return;
  }

  if (expected is List && actual is List) {
    expect(
      actual.length,
      equals(expected.length),
      reason: 'Length mismatch at $path',
    );
    for (var i = 0; i < expected.length; i++) {
      _expectDeepTypeAndValueEquals(actual[i], expected[i], '$path[$i]');
    }
    return;
  }

  expect(actual, equals(expected), reason: 'Value mismatch at $path');
}

void main() {
  group('Schema v2.4.2 Round-Trip & Unknown-Field Preservation', () {
    late String rawFixtureText;
    late Map<String, Object?> rawFixture;

    setUp(() {
      final file = File('schemas/fixtures/desktop_v2_4_2_sample.json');
      expect(file.existsSync(), isTrue, reason: 'Desktop v2.4.2 fixture missing');
      rawFixtureText = file.readAsStringSync();
      rawFixture = jsonDecode(rawFixtureText) as Map<String, Object?>;
    });

    test(
      'full root deep-equality: mutating dna_rescue.shadow_lift preserves 100% of entire JSON tree',
      () {
        final originalDoc = SessionDocument.fromJson(rawFixture);
        expect(originalDoc.schemaVersion, equals('2.4.2'));
        expect(originalDoc.items, hasLength(1));
        expect(
          originalDoc.items.first.editRecipe.dnaRescue.shadowLift,
          equals(18.5),
        );

        const updatedShadowLift = 33.75;
        final updatedItem = originalDoc.items.first.copyWith(
          editRecipe: originalDoc.items.first.editRecipe.copyWith(
            dnaRescue: originalDoc.items.first.editRecipe.dnaRescue.copyWith(
              shadowLift: updatedShadowLift,
            ),
          ),
        );
        final updatedDoc = originalDoc.copyWith(
          items: <dynamic>[updatedItem].cast(),
        );

        final reserializedJson =
            jsonDecode(jsonEncode(updatedDoc.toJson())) as Map<String, Object?>;

        // Deep-clone original fixture and mutate ONLY dna_rescue.shadow_lift.
        final expectedJson =
            jsonDecode(rawFixtureText) as Map<String, Object?>;
        final expectedItems = expectedJson['items'] as List<Object?>;
        final expectedFirstItem = expectedItems.first as Map<String, Object?>;
        final expectedRecipe =
            expectedFirstItem['edit_recipe'] as Map<String, Object?>;
        final expectedDna =
            expectedRecipe['dna_rescue'] as Map<String, Object?>;
        expectedDna['shadow_lift'] = updatedShadowLift;

        _expectDeepTypeAndValueEquals(reserializedJson, expectedJson, 'root');
      },
    );

    test(
      'minimal JSON preserves omitted optional lists, explicit nulls, int numeric types, version check, and nullable copyWith',
      () {
        final minimalRaw = <String, Object?>{
          'schema_version': '2.4.2',
          'session_id': 'sess_minimal_001',
          'created_at': '2026-11-20T12:00:00Z',
          'items': <Object?>[
            <String, Object?>{
              'id': 'item_001',
              'file_name': 'DSCF0001.JPG',
              'cull_result': null,
              'edit_recipe': <String, Object?>{
                'dna_rescue': <String, Object?>{
                  'enabled': false,
                  'shadow_lift': 0,
                },
                'geometry': <String, Object?>{
                  'rotation_deg': 0,
                  'crop_box': null,
                },
                'lut': <String, Object?>{
                  'enabled': false,
                  'intensity': 1,
                },
                'export_profile': <String, Object?>{
                  'format': 'jpeg',
                  'quality': 95,
                },
              },
            },
          ],
        };

        final parsed = SessionDocument.fromJson(minimalRaw);
        final roundTripped = parsed.toJson();

        // Omitted optional lists must NOT be fabricated as [].
        expect(roundTripped.containsKey('action_proposals'), isFalse);
        expect(roundTripped.containsKey('collages'), isFalse);

        // Explicit nulls and int numeric types must survive verbatim.
        final outItem =
            (roundTripped['items'] as List<Object?>).first as Map<String, Object?>;
        expect(outItem.containsKey('cull_result'), isTrue);
        expect(outItem['cull_result'], isNull);

        final outRecipe = outItem['edit_recipe'] as Map<String, Object?>;
        final outGeometry = outRecipe['geometry'] as Map<String, Object?>;
        expect(outGeometry.containsKey('crop_box'), isTrue);
        expect(outGeometry['crop_box'], isNull);
        expect(outGeometry['rotation_deg'], equals(0));
        expect(outGeometry['rotation_deg'], isA<int>());

        final wireRoundTripped =
            jsonDecode(jsonEncode(roundTripped)) as Map<String, Object?>;
        final wireMinimal =
            jsonDecode(jsonEncode(minimalRaw)) as Map<String, Object?>;
        _expectDeepTypeAndValueEquals(wireRoundTripped, wireMinimal, 'minimal');

        // Unsupported schema_version must throw FormatException.
        final wrongVersion = Map<String, Object?>.of(minimalRaw)
          ..['schema_version'] = '2.4.1';
        expect(
          () => SessionDocument.fromJson(wrongVersion),
          throwsA(isA<FormatException>()),
        );

        // Sentinel copyWith(cropBox: null) must clear a non-null cropBox back to null.
        final fullDoc = SessionDocument.fromJson(rawFixture);
        final originalGeometry = fullDoc.items.first.editRecipe.geometry;
        expect(originalGeometry.cropBox, isNotNull);

        final clearedGeometry = originalGeometry.copyWith(cropBox: null);
        expect(clearedGeometry.cropBox, isNull);
        expect(clearedGeometry.aspectRatio, equals(originalGeometry.aspectRatio));
        expect(clearedGeometry.toJson()['crop_box'], isNull);
      },
    );

    test('models and unknownFields maps are strictly immutable', () {
      final doc = SessionDocument.fromJson(rawFixture);
      expect(
        () => doc.unknownFields['injected'] = true,
        throwsUnsupportedError,
      );
      expect(
        () => doc.items.clear(),
        throwsUnsupportedError,
      );
      final lutCache =
          doc.unknownFields['desktop_lut_cache'] as Map<String, Object?>;
      expect(
        () => lutCache['max_cube_size'] = 33,
        throwsUnsupportedError,
      );
    });
  });
}
