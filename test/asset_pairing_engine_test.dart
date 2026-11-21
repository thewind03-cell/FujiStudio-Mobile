import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/storage/asset_pairing_engine.dart';
import 'package:fujistudio_mobile/core/storage/storage_gateway.dart';

RawMediaFileDescriptor _file({
  required String id,
  required String name,
  String relativePath = 'DCIM/100_FUJI/',
  int sizeBytes = 1000,
  int? dateTakenMs,
  int dateModifiedSec = 100,
}) {
  return RawMediaFileDescriptor(
    mediaId: id,
    uri: 'content://media/external/file/$id',
    displayName: name,
    relativePath: relativePath,
    mimeType: name.toLowerCase().endsWith('.raf') ? 'image/x-fuji-raf' : 'image/jpeg',
    sizeBytes: sizeBytes,
    dateTakenMs: dateTakenMs,
    dateModifiedSec: dateModifiedSec,
    width: 6240,
    height: 4160,
  );
}

void main() {
  const engine = AssetPairingEngine();

  group('AssetPairingEngine', () {
    test('pairs .jpg/.jpeg and .raf case-insensitively across normalized dirs', () {
      final paired = engine.pairAssets(<RawMediaFileDescriptor>[
        _file(id: '1', name: 'DSCF1001.jpg', relativePath: r'\DCIM\100_FUJI\'),
        _file(id: '2', name: 'dscf1001.RAF', relativePath: 'dcim/100_fuji'),
        _file(id: '3', name: 'DSCF1002.JPEG', relativePath: 'DCIM/100_FUJI/'),
        _file(id: '4', name: 'DSCF1003.RAF', relativePath: 'DCIM/100_FUJI/'),
        _file(id: '5', name: 'DSCF1004.MOV', relativePath: 'DCIM/100_FUJI/'),
      ]);

      expect(paired, hasLength(3));
      final byStem = <String, PairedAsset>{
        for (final p in paired) p.stem.toUpperCase(): p,
      };

      expect(byStem['DSCF1001']!.kind, equals(AssetPairKind.jpgPlusRaf));
      expect(byStem['DSCF1001']!.primaryAsset.mediaId, equals('1'));
      expect(byStem['DSCF1001']!.rafCompanion?.mediaId, equals('2'));

      expect(byStem['DSCF1002']!.kind, equals(AssetPairKind.jpgOnly));
      expect(byStem['DSCF1002']!.rafCompanion, isNull);

      expect(byStem['DSCF1003']!.kind, equals(AssetPairKind.rafOnly));
      expect(byStem['DSCF1003']!.primaryAsset.mediaId, equals('4'));
    });

    test('does not falsely pair DSCF1042 (1).JPG with DSCF1042.RAF', () {
      final paired = engine.pairAssets(<RawMediaFileDescriptor>[
        _file(id: '1', name: 'DSCF1042 (1).JPG', dateTakenMs: 2000),
        _file(id: '2', name: 'DSCF1042.RAF', dateTakenMs: 1000),
      ]);

      expect(paired, hasLength(2));
      expect(paired[0].stem, equals('DSCF1042 (1)'));
      expect(paired[0].kind, equals(AssetPairKind.jpgOnly));
      expect(paired[1].stem, equals('DSCF1042'));
      expect(paired[1].kind, equals(AssetPairKind.rafOnly));
    });

    test('resolves duplicate same-type files by larger sizeBytes then newer dateModifiedSec', () {
      final paired = engine.pairAssets(<RawMediaFileDescriptor>[
        _file(id: 'small', name: 'DSCF2000.JPG', sizeBytes: 500, dateModifiedSec: 900),
        _file(id: 'large_older', name: 'DSCF2000.JPG', sizeBytes: 2000, dateModifiedSec: 100),
        _file(id: 'large_newer', name: 'DSCF2000.JPG', sizeBytes: 2000, dateModifiedSec: 300),
      ]);

      expect(paired, hasLength(1));
      expect(paired.single.primaryAsset.mediaId, equals('large_newer'));
    });

    test('sorts deterministically by capturedAtMs DESC then stem ASC on burst ties', () {
      final paired = engine.pairAssets(<RawMediaFileDescriptor>[
        _file(id: '1', name: 'DSCF0003.JPG', dateTakenMs: 5000),
        _file(id: '2', name: 'DSCF0001.JPG', dateTakenMs: 5000),
        _file(id: '3', name: 'DSCF0002.JPG', dateTakenMs: 5000),
        _file(id: '4', name: 'DSCF0010.JPG', dateTakenMs: 9000),
        _file(id: '5', name: 'DSCF0000.JPG', dateTakenMs: null, dateModifiedSec: 2),
      ]);

      expect(
        paired.map((e) => e.stem).toList(),
        equals(<String>[
          'DSCF0010',
          'DSCF0001',
          'DSCF0002',
          'DSCF0003',
          'DSCF0000',
        ]),
      );
    });
  });
}
