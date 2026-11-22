import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/ffi/bindings.g.dart';
import 'package:fujistudio_mobile/core/ffi/native_worker.dart';
import 'package:fujistudio_mobile/features/studio_editor/geometry_mapper.dart';

void main() {
  group('NativeWorker Geometry & Collage Tests', () {
    late NativeWorker worker;

    setUpAll(() async {
      worker = await NativeWorker.spawn();
    });

    tearDownAll(() async {
      await worker.dispose();
    });

    test(
      '50 combinations of GeometryMath (Dart) vs NativeWorker.clampCrop (C++ ABI) agree within < 1e-4',
      () async {
        final rng = math.Random(20261122);
        const presets = <int>[0, 1, 2, 3, 4];

        for (var i = 0; i < 50; i++) {
          final w = 100 + rng.nextInt(3900);
          final h = 100 + rng.nextInt(3900);
          final rot = -15.0 + rng.nextDouble() * 30.0;
          final preset = presets[i % presets.length];
          final req = NormCropBoxData(
            left: -0.2 + rng.nextDouble() * 0.6,
            top: -0.2 + rng.nextDouble() * 0.6,
            right: 0.4 + rng.nextDouble() * 0.8,
            bottom: 0.4 + rng.nextDouble() * 0.8,
          );

          final dartRes = GeometryMath.clampCrop(
            srcWidth: w,
            srcHeight: h,
            rotationDeg: rot,
            aspectPreset: preset,
            requestedBox: req,
          );
          final cppRes = await worker.clampCrop(
            srcWidth: w,
            srcHeight: h,
            rotationDeg: rot,
            aspectPreset: preset,
            requestedBox: req,
          );

          expect(cppRes.isOk, isTrue);
          expect(
            (dartRes.clampedBox.left - cppRes.clampedBox.left).abs(),
            lessThan(1e-4),
          );
          expect(
            (dartRes.clampedBox.top - cppRes.clampedBox.top).abs(),
            lessThan(1e-4),
          );
          expect(
            (dartRes.clampedBox.right - cppRes.clampedBox.right).abs(),
            lessThan(1e-4),
          );
          expect(
            (dartRes.clampedBox.bottom - cppRes.clampedBox.bottom).abs(),
            lessThan(1e-4),
          );
          expect(dartRes.pixelWidth, equals(cppRes.pixelWidth));
          expect(dartRes.pixelHeight, equals(cppRes.pixelHeight));
        }
      },
    );

    test(
      'analyzeGeometryOnSurface and renderGeometryOnSurface produce zero black corners on 12 deg 4:5 white image',
      () async {
        const w = 160;
        const h = 120;
        final white = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);

        final surfaceId = await worker.openStudioSurface(
          width: w,
          height: h,
          sourceRgba: white,
        );
        try {
          final proposal = await worker.analyzeGeometryOnSurface(
            surfaceId: surfaceId,
            targetAspectPreset: FsAspectPreset.FS_ASPECT_4_5.value,
          );
          expect(proposal.isOk, isTrue);
          expect(
            proposal.targetAspectPreset,
            equals(FsAspectPreset.FS_ASPECT_4_5.value),
          );

          final clamped = await worker.clampCrop(
            srcWidth: w,
            srcHeight: h,
            rotationDeg: 12.0,
            aspectPreset: FsAspectPreset.FS_ASPECT_4_5.value,
            requestedBox: NormCropBoxData.full,
          );
          expect(clamped.isOk, isTrue);

          final rendered = await worker.renderGeometryOnSurface(
            surfaceId: surfaceId,
            params: GeometryNativeParams(
              rotationDeg: 12.0,
              aspectPreset: FsAspectPreset.FS_ASPECT_4_5.value,
              cropBox: clamped.clampedBox,
              highQuality: true,
            ),
            outWidth: clamped.pixelWidth,
            outHeight: clamped.pixelHeight,
          );
          expect(rendered.isOk, isTrue);
          expect(rendered.rgbaBytes, isNotNull);
          expect(
            rendered.rgbaBytes!.length,
            equals(clamped.pixelWidth * clamped.pixelHeight * 4),
          );
          for (final byte in rendered.rgbaBytes!) {
            expect(byte, greaterThanOrEqualTo(254));
          }
        } finally {
          await worker.closeStudioSurface(surfaceId);
        }
      },
    );

    test(
      'renderCollage stitches 2, 3, and 4 slots with exact gutter bytes and rejects invalid slot counts or overflow',
      () async {
        Uint8List solidSlot(int w, int h, int r, int g, int b) {
          final out = Uint8List(w * h * 4);
          for (var i = 0; i < out.length; i += 4) {
            out[i + 0] = r;
            out[i + 1] = g;
            out[i + 2] = b;
            out[i + 3] = 255;
          }
          return out;
        }

        final s0 = CollageSlotInputData(
          rgbaBytes: solidSlot(120, 90, 200, 30, 30),
          width: 120,
          height: 90,
        );
        final s1 = CollageSlotInputData(
          rgbaBytes: solidSlot(90, 120, 30, 200, 30),
          width: 90,
          height: 120,
        );
        final s2 = CollageSlotInputData(
          rgbaBytes: solidSlot(100, 100, 30, 30, 200),
          width: 100,
          height: 100,
        );
        final s3 = CollageSlotInputData(
          rgbaBytes: solidSlot(100, 80, 200, 200, 30),
          width: 100,
          height: 80,
        );

        const cw = 270;
        const ch = 480;
        const gutter = 12;
        const margin = 16;

        final configs = <(int tpl, List<CollageSlotInputData> slots)>[
          (FsCollageTemplate.FS_COLLAGE_SPLIT_2_V.value, [s0, s1]),
          (FsCollageTemplate.FS_COLLAGE_GRID_3_TOP.value, [s0, s1, s2]),
          (FsCollageTemplate.FS_COLLAGE_GRID_4_EVEN.value, [s0, s1, s2, s3]),
        ];

        for (final entry in configs) {
          final res = await worker.renderCollage(
            slots: entry.$2,
            config: CollageNativeConfig(
              templateId: entry.$1,
              canvasWidth: cw,
              canvasHeight: ch,
              gutterPx: gutter,
              outerMarginPx: margin,
              bgR: 244,
              bgG: 241,
              bgB: 234,
            ),
          );
          expect(res.isOk, isTrue);
          expect(res.width, equals(cw));
          expect(res.height, equals(ch));
          final bytes = res.rgbaBytes!;
          expect(bytes.length, equals(cw * ch * 4));

          // Verify top-left outer margin pixel matches background exactly.
          expect(bytes[0], equals(244));
          expect(bytes[1], equals(241));
          expect(bytes[2], equals(234));
          expect(bytes[3], equals(255));

          // Verify center gutter pixel on 2-slot V / 4-slot even.
          if (entry.$1 != FsCollageTemplate.FS_COLLAGE_GRID_3_TOP.value) {
            final gy = margin + ((ch - 2 * margin - gutter) ~/ 2) + (gutter ~/ 2);
            final gOff = (gy * cw + (cw ~/ 2)) * 4;
            expect(bytes[gOff + 0], equals(244));
            expect(bytes[gOff + 1], equals(241));
            expect(bytes[gOff + 2], equals(234));
            expect(bytes[gOff + 3], equals(255));
          }
        }

        // Wrong slot count for GRID_4_EVEN -> FS_ERR_COLLAGE_INVALID_SLOTS
        final badCount = await worker.renderCollage(
          slots: [s0, s1],
          config: CollageNativeConfig(
            templateId: FsCollageTemplate.FS_COLLAGE_GRID_4_EVEN.value,
            canvasWidth: cw,
            canvasHeight: ch,
            gutterPx: gutter,
            outerMarginPx: margin,
            bgR: 0,
            bgG: 0,
            bgB: 0,
          ),
        );
        expect(
          badCount.statusCode,
          equals(FsStatusCode.FS_ERR_COLLAGE_INVALID_SLOTS.value),
        );

        // Dimension overflow -> FS_ERR_OVERFLOW
        final overflow = await worker.renderCollage(
          slots: [s0, s1],
          config: CollageNativeConfig(
            templateId: FsCollageTemplate.FS_COLLAGE_SPLIT_2_V.value,
            canvasWidth: FS_MAX_IMAGE_DIMENSION + 1,
            canvasHeight: 480,
            gutterPx: 8,
            outerMarginPx: 8,
            bgR: 0,
            bgG: 0,
            bgB: 0,
          ),
        );
        expect(overflow.statusCode, equals(FsStatusCode.FS_ERR_OVERFLOW.value));
      },
    );
  });
}
