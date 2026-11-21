import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/ffi/bindings.g.dart';
import 'package:fujistudio_mobile/core/ffi/native_worker.dart';

void main() {
  group('NativeWorker FFI Host Tests', () {
    late NativeWorker worker;

    setUpAll(() async {
      worker = await NativeWorker.spawn();
    });

    tearDownAll(() async {
      await worker.dispose();
    });

    test('fs_core_version returns exact Day-0 version string', () async {
      final version = await worker.coreVersion();
      expect(version, equals('0.1.0-day0'));
    });

    test(
      '100 consecutive 64x64 RGBA inversions succeed without crash or corruption',
      () async {
        const width = 64;
        const height = 64;
        const byteLen = width * height * 4;

        final input = Uint8List(byteLen);
        for (var i = 0; i < byteLen; i += 4) {
          final px = i ~/ 4;
          input[i + 0] = px & 0xFF;
          input[i + 1] = (px * 5) & 0xFF;
          input[i + 2] = (px * 11) & 0xFF;
          input[i + 3] = 180;
        }

        for (var iteration = 0; iteration < 100; iteration++) {
          final res = await worker.invertRgbaSmoke(
            inputRgba: input,
            width: width,
            height: height,
          );
          expect(
            res.statusCode,
            equals(FsStatusCode.FS_OK.value),
            reason: 'Failed on iteration $iteration',
          );
          expect(res.rgbaBytes, isNotNull);
          expect(res.rgbaBytes!.length, equals(byteLen));

          final out = res.rgbaBytes!;
          if (iteration == 0 || iteration == 99) {
            for (var i = 0; i < byteLen; i += 4) {
              expect(out[i + 0], equals(255 - input[i + 0]));
              expect(out[i + 1], equals(255 - input[i + 1]));
              expect(out[i + 2], equals(255 - input[i + 2]));
              expect(out[i + 3], equals(input[i + 3]));
            }
          } else {
            expect(out[0], equals(255 - input[0]));
            expect(out[3], equals(180));
            expect(out[byteLen - 4], equals(255 - input[byteLen - 4]));
            expect(out[byteLen - 1], equals(180));
          }
        }
      },
    );

    test(
      'invalid inputs return clean negative ABI error codes without crashing',
      () async {
        final validPixel = Uint8List.fromList(<int>[10, 20, 30, 255]);

        final nullInput = await worker.invertRgbaSmoke(
          inputRgba: null,
          width: 1,
          height: 1,
        );
        expect(
          nullInput.statusCode,
          equals(FsStatusCode.FS_ERR_NULL_POINTER.value),
        );
        expect(nullInput.rgbaBytes, isNull);

        final zeroWidth = await worker.invertRgbaSmoke(
          inputRgba: validPixel,
          width: 0,
          height: 1,
        );
        expect(
          zeroWidth.statusCode,
          equals(FsStatusCode.FS_ERR_INVALID_DIMENSIONS.value),
        );
        expect(zeroWidth.rgbaBytes, isNull);

        final negativeHeight = await worker.invertRgbaSmoke(
          inputRgba: validPixel,
          width: 1,
          height: -8,
        );
        expect(
          negativeHeight.statusCode,
          equals(FsStatusCode.FS_ERR_INVALID_DIMENSIONS.value),
        );
        expect(negativeHeight.rgbaBytes, isNull);

        final undersizedBuffer = await worker.invertRgbaSmoke(
          inputRgba: validPixel,
          width: 4,
          height: 4,
        );
        expect(
          undersizedBuffer.statusCode,
          equals(FsStatusCode.FS_ERR_INVALID_DIMENSIONS.value),
        );
        expect(undersizedBuffer.rgbaBytes, isNull);

        // Worker Isolate must remain completely healthy after error calls.
        final recovery = await worker.invertRgbaSmoke(
          inputRgba: validPixel,
          width: 1,
          height: 1,
        );
        expect(recovery.isOk, isTrue);
        expect(
          recovery.rgbaBytes,
          equals(Uint8List.fromList(<int>[245, 235, 225, 255])),
        );
      },
    );

    test(
      'blocks int64 overflow and int64->int32 truncation dimension attacks',
      () async {
        final tinyBuf = Uint8List(4);

        final int64WrapAttack = await worker.invertRgbaSmoke(
          inputRgba: tinyBuf,
          width: 0x2000000000000100,
          height: 1,
        );
        expect(
          int64WrapAttack.statusCode,
          equals(FsStatusCode.FS_ERR_OVERFLOW.value),
        );
        expect(int64WrapAttack.rgbaBytes, isNull);

        final int32TruncAttack = await worker.invertRgbaSmoke(
          inputRgba: tinyBuf,
          width: 0x100000001,
          height: 1,
        );
        expect(
          int32TruncAttack.statusCode,
          equals(FsStatusCode.FS_ERR_OVERFLOW.value),
        );
        expect(int32TruncAttack.rgbaBytes, isNull);

        final oversizedGrid = await worker.invertRgbaSmoke(
          inputRgba: tinyBuf,
          width: 65536,
          height: 65536,
        );
        expect(
          oversizedGrid.statusCode,
          equals(FsStatusCode.FS_ERR_OVERFLOW.value),
        );
        expect(oversizedGrid.rgbaBytes, isNull);
      },
    );

    test(
      'dispose() is idempotent and subsequent requests throw StateError',
      () async {
        final tempWorker = await NativeWorker.spawn();
        expect(await tempWorker.coreVersion(), equals('0.1.0-day0'));

        await Future.wait<void>(<Future<void>>[
          tempWorker.dispose(),
          tempWorker.dispose(),
        ]);

        await expectLater(
          tempWorker.coreVersion(),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'extractRafPreviewFromPath and inspectJpegBytes succeed through NativeWorker on Host',
      () async {
        final jpeg = _buildSyntheticJpegWithExif(
          orientation: 6,
          width: 3200,
          height: 2133,
        );
        final raf = _buildSyntheticRaf(
          cameraModel: 'X-T4',
          jpegBytes: jpeg,
          trailingZeroPad: 4,
        );

        final tempDir = await Directory.systemTemp.createTemp(
          'fujistudio_ffi_raf_test_',
        );
        try {
          final rafFile = File('${tempDir.path}${Platform.pathSeparator}DSCF1234.RAF');
          final outJpegFile = File(
            '${tempDir.path}${Platform.pathSeparator}preview.jpg',
          );
          await rafFile.writeAsBytes(raf, flush: true);

          final extractRes = await worker.extractRafPreviewFromPath(
            rafPath: rafFile.path,
            outJpegPath: outJpegFile.path,
          );
          expect(extractRes.isOk, isTrue);
          expect(extractRes.exifOrientation, equals(6));
          expect(extractRes.hasExifTag, isTrue);
          expect(extractRes.jpegWidth, equals(3200));
          expect(extractRes.jpegHeight, equals(2133));
          expect(extractRes.cameraModel, equals('X-T4'));
          expect(extractRes.jpegLength, equals(jpeg.length));
          expect(await outJpegFile.readAsBytes(), equals(jpeg));

          final inspectRes = await worker.inspectJpegBytes(jpeg);
          expect(inspectRes.isOk, isTrue);
          expect(inspectRes.exifOrientation, equals(6));
          expect(inspectRes.hasExifTag, isTrue);
          expect(inspectRes.width, equals(3200));
          expect(inspectRes.height, equals(2133));

          final missingRes = await worker.extractRafPreviewFromPath(
            rafPath: '${tempDir.path}${Platform.pathSeparator}missing.RAF',
            outJpegPath: outJpegFile.path,
          );
          expect(
            missingRes.statusCode,
            equals(FsStatusCode.FS_ERR_IO_OPEN_FAILED.value),
          );
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
    );
  });
}

Uint8List _buildSyntheticJpegWithExif({
  required int orientation,
  required int width,
  required int height,
}) {
  final bytes = BytesBuilder();
  bytes.add(<int>[0xFF, 0xD8]); // SOI

  // Big-endian TIFF inside APP1
  final tiff = BytesBuilder();
  tiff.add(<int>[0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]);
  tiff.add(<int>[0x00, 0x01]); // 1 IFD0 entry
  // Tag 0x0112 (Orientation), type SHORT (3), count 1, value orientation
  tiff.add(<int>[
    0x01,
    0x12,
    0x00,
    0x03,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    orientation,
    0x00,
    0x00,
  ]);
  final tiffBytes = tiff.toBytes();
  final app1Len = 2 + 6 + tiffBytes.length;
  bytes.add(<int>[
    0xFF,
    0xE1,
    (app1Len >> 8) & 0xFF,
    app1Len & 0xFF,
    0x45,
    0x78,
    0x69,
    0x66,
    0x00,
    0x00,
  ]);
  bytes.add(tiffBytes);

  // SOF0
  bytes.add(<int>[
    0xFF,
    0xC0,
    0x00,
    0x0B,
    0x08,
    (height >> 8) & 0xFF,
    height & 0xFF,
    (width >> 8) & 0xFF,
    width & 0xFF,
    0x01,
    0x01,
    0x11,
    0x00,
  ]);

  // SOS + padding to >= 128 bytes
  bytes.add(<int>[0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]);
  while (bytes.length + 2 < 256) {
    bytes.addByte(0x5A);
  }
  bytes.add(<int>[0xFF, 0xD9]);
  return bytes.toBytes();
}

Uint8List _buildSyntheticRaf({
  required String cameraModel,
  required Uint8List jpegBytes,
  int trailingZeroPad = 0,
}) {
  const jpegOffset = 160;
  final jpegLength = jpegBytes.length + trailingZeroPad;
  final raf = Uint8List(jpegOffset + jpegLength + 64);
  const magic = 'FUJIFILMCCD-RAW ';
  for (var i = 0; i < magic.length; i++) {
    raf[i] = magic.codeUnitAt(i);
  }
  for (var i = 0; i < cameraModel.length && i < 32; i++) {
    raf[0x1C + i] = cameraModel.codeUnitAt(i);
  }
  final bd = ByteData.sublistView(raf);
  bd.setUint32(0x54, jpegOffset, Endian.big);
  bd.setUint32(0x58, jpegLength, Endian.big);
  raf.setRange(jpegOffset, jpegOffset + jpegBytes.length, jpegBytes);
  return raf;
}
