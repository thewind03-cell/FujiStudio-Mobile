import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/ffi/bindings.g.dart';
import 'package:fujistudio_mobile/core/ffi/native_worker.dart';
import 'package:fujistudio_mobile/features/social_export/export_mapper.dart';

void main() {
  group('NativeWorker Social Export Pipeline Tests', () {
    late NativeWorker worker;
    late Directory tempDir;

    setUpAll(() async {
      worker = await NativeWorker.spawn();
    });

    tearDownAll(() async {
      await worker.dispose();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fujistudio_export_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'runExportPipelineOnRawFile runs DNA -> Crop -> Lanczos3 2048px -> USM cleanly without temp leftovers',
      () async {
        // 3000x2000 synthetic dark-shadow + sharp-edge image (24 MB RGBA)
        const srcW = 3000;
        const srcH = 2000;
        final rgba = Uint8List(srcW * srcH * 4);
        for (var y = 0; y < srcH; y++) {
          for (var x = 0; x < srcW; x++) {
            final off = (y * srcW + x) * 4;
            final val = x < srcW ~/ 2 ? 24 : 190;
            rgba[off + 0] = val;
            rgba[off + 1] = val;
            rgba[off + 2] = val;
            rgba[off + 3] = 255;
          }
        }

        final inPath = '${tempDir.path}${Platform.pathSeparator}input_3000.rgba';
        final outPath = '${tempDir.path}${Platform.pathSeparator}out_2048.rgba';
        File(inPath).writeAsBytesSync(rgba);

        final res = await worker.runExportPipelineOnRawFile(
          rawInputPath: inPath,
          srcWidth: srcW,
          srcHeight: srcH,
          rawOutputPath: outPath,
          dnaRescue: const DnaRescueNativeParams(
            shadowLift: 0.45,
            enabled: true,
          ),
          geometry: GeometryNativeParams(
            rotationDeg: 1.5,
            aspectPreset: FsAspectPreset.FS_ASPECT_3_2.value,
            cropBox: NormCropBoxData.full,
            highQuality: true,
          ),
          targetMaxLongEdge: 2048,
          outputUsm: SocialExportPreset.facebook2048.defaultSharpening
              .toNativeParams(),
        );

        expect(res.isOk, isTrue);
        expect(res.width, equals(2048));
        expect(res.height, equals(1365));
        expect(res.rawOutputPath, equals(outPath));

        final outFile = File(outPath);
        expect(outFile.existsSync(), isTrue);
        expect(outFile.lengthSync(), equals(2048 * 1365 * 4));
        expect(File('$outPath.tmp').existsSync(), isFalse);

        // Verify shadow side lifted (> 24) and alpha preserved (255).
        final outBytes = outFile.readAsBytesSync();
        expect(outBytes[0], greaterThan(26));
        expect(outBytes[3], equals(255));
      },
    );

    test(
      'runExportPipelineOnRawFile enforces No-Upscale when source <= targetMaxLongEdge',
      () async {
        const srcW = 1280;
        const srcH = 853;
        final rgba = Uint8List(srcW * srcH * 4);
        for (var i = 0; i < rgba.length; i += 4) {
          rgba[i + 0] = 110;
          rgba[i + 1] = 120;
          rgba[i + 2] = 130;
          rgba[i + 3] = 255;
        }

        final inPath = '${tempDir.path}${Platform.pathSeparator}small_1280.rgba';
        final outPath = '${tempDir.path}${Platform.pathSeparator}small_out.rgba';
        File(inPath).writeAsBytesSync(rgba);

        final res = await worker.runExportPipelineOnRawFile(
          rawInputPath: inPath,
          srcWidth: srcW,
          srcHeight: srcH,
          rawOutputPath: outPath,
          dnaRescue: null,
          geometry: null,
          targetMaxLongEdge: 2048,
          outputUsm: null,
        );

        expect(res.isOk, isTrue);
        expect(res.width, equals(srcW));
        expect(res.height, equals(srcH));
        expect(File(outPath).readAsBytesSync(), equals(rgba));
      },
    );

    test(
      'renderCollageToRawFile stitches 1152x2048 story collage with per-slot DNA Rescue & USM',
      () async {
        const slotW = 600;
        const slotH = 400;
        Uint8List solidSlot(int r, int g, int b) {
          final bytes = Uint8List(slotW * slotH * 4);
          for (var i = 0; i < bytes.length; i += 4) {
            bytes[i + 0] = r;
            bytes[i + 1] = g;
            bytes[i + 2] = b;
            bytes[i + 3] = 255;
          }
          return bytes;
        }

        final slot0Path = '${tempDir.path}${Platform.pathSeparator}slot0.rgba';
        final slot1Path = '${tempDir.path}${Platform.pathSeparator}slot1.rgba';
        final outPath = '${tempDir.path}${Platform.pathSeparator}collage_1152x2048.rgba';
        File(slot0Path).writeAsBytesSync(solidSlot(20, 20, 20));
        File(slot1Path).writeAsBytesSync(solidSlot(40, 120, 190));

        final res = await worker.renderCollageToRawFile(
          slots: <CollageRawFileSlot>[
            CollageRawFileSlot(
              rawInputPath: slot0Path,
              width: slotW,
              height: slotH,
              dnaRescue: const DnaRescueNativeParams(
                shadowLift: 0.5,
                enabled: true,
              ),
            ),
            CollageRawFileSlot(
              rawInputPath: slot1Path,
              width: slotW,
              height: slotH,
            ),
          ],
          config: CollageNativeConfig(
            templateId: FsCollageTemplate.FS_COLLAGE_SPLIT_2_V.value,
            canvasWidth: 1152,
            canvasHeight: 2048,
            gutterPx: 24,
            outerMarginPx: 32,
            bgR: 244,
            bgG: 241,
            bgB: 234,
          ),
          outputUsm: SocialExportPreset.instagram2048.defaultSharpening
              .toNativeParams(),
          rawOutputPath: outPath,
        );

        expect(res.isOk, isTrue);
        expect(res.width, equals(1152));
        expect(res.height, equals(2048));

        final outFile = File(outPath);
        expect(outFile.existsSync(), isTrue);
        expect(outFile.lengthSync(), equals(1152 * 2048 * 4));
        expect(File('$outPath.tmp').existsSync(), isFalse);

        final outBytes = outFile.readAsBytesSync();
        // Top-left margin pixel keeps paper background (244, 241, 234, 255)
        expect(outBytes[0], equals(244));
        expect(outBytes[1], equals(241));
        expect(outBytes[2], equals(234));
        expect(outBytes[3], equals(255));

        // Slot 0 interior pixel lifted by DNA Rescue (> 20)
        final slot0InteriorOff = (120 * 1152 + 200) * 4;
        expect(outBytes[slot0InteriorOff], greaterThan(22));
      },
    );

    test(
      'renderCollageToRawFile applies per-slot GeometryNativeParams (rotationDeg=8.0) via Host C++ DLL',
      () async {
        const slotW = 320;
        const slotH = 240;
        final patterned = Uint8List(slotW * slotH * 4);
        for (var y = 0; y < slotH; y++) {
          for (var x = 0; x < slotW; x++) {
            final off = (y * slotW + x) * 4;
            final leftHalf = x < slotW ~/ 2;
            patterned[off + 0] = leftHalf ? 20 : 230;
            patterned[off + 1] = y < slotH ~/ 2 ? 40 : 210;
            patterned[off + 2] = leftHalf ? 200 : 30;
            patterned[off + 3] = 255;
          }
        }

        final slot0Path = '${tempDir.path}${Platform.pathSeparator}geo_slot0.rgba';
        final slot1Path = '${tempDir.path}${Platform.pathSeparator}geo_slot1.rgba';
        final outNoRotPath = '${tempDir.path}${Platform.pathSeparator}col_no_rot.rgba';
        final outRotPath = '${tempDir.path}${Platform.pathSeparator}col_rot8.rgba';
        File(slot0Path).writeAsBytesSync(patterned);
        File(slot1Path).writeAsBytesSync(patterned);

        final cfg = CollageNativeConfig(
          templateId: FsCollageTemplate.FS_COLLAGE_SPLIT_2_V.value,
          canvasWidth: 540,
          canvasHeight: 960,
          gutterPx: 12,
          outerMarginPx: 16,
          bgR: 20,
          bgG: 20,
          bgB: 20,
        );

        final resNoRot = await worker.renderCollageToRawFile(
          slots: <CollageRawFileSlot>[
            CollageRawFileSlot(rawInputPath: slot0Path, width: slotW, height: slotH),
            CollageRawFileSlot(rawInputPath: slot1Path, width: slotW, height: slotH),
          ],
          config: cfg,
          outputUsm: null,
          rawOutputPath: outNoRotPath,
        );
        final resRot = await worker.renderCollageToRawFile(
          slots: <CollageRawFileSlot>[
            CollageRawFileSlot(
              rawInputPath: slot0Path,
              width: slotW,
              height: slotH,
              geometry: GeometryNativeParams(
                rotationDeg: 8.0,
                aspectPreset: FsAspectPreset.FS_ASPECT_ORIGINAL.value,
                cropBox: NormCropBoxData.full,
                highQuality: true,
              ),
            ),
            CollageRawFileSlot(rawInputPath: slot1Path, width: slotW, height: slotH),
          ],
          config: cfg,
          outputUsm: null,
          rawOutputPath: outRotPath,
        );

        expect(resNoRot.isOk, isTrue);
        expect(resRot.isOk, isTrue);

        final bytesNoRot = File(outNoRotPath).readAsBytesSync();
        final bytesRot = File(outRotPath).readAsBytesSync();
        var diffPixels = 0;
        for (var i = 0; i < bytesNoRot.length; i += 4) {
          if (bytesNoRot[i] != bytesRot[i] ||
              bytesNoRot[i + 1] != bytesRot[i + 1] ||
              bytesNoRot[i + 2] != bytesRot[i + 2]) {
            diffPixels++;
          }
        }
        expect(diffPixels, greaterThan(1000));
      },
    );

    test(
      'analyzeGeometryOnSurface(useRescuedBuffer: true) safely falls back to srcPtr before DNA render and uses dstPtr after DNA render',
      () async {
        const w = 160;
        const h = 120;
        // Dark tilted horizon edge in srcPtr (0..18) so before DNA rescue it's low contrast,
        // while uninitialized dstPtr is zeroed; after DNA rescue dstPtr has lifted contrast.
        final srcRgba = Uint8List(w * h * 4);
        for (var y = 0; y < h; y++) {
          final horizonY = (h * 0.5 + (y == 0 ? 0 : 0)) + 0.0;
          for (var x = 0; x < w; x++) {
            final off = (y * w + x) * 4;
            final slopeY = horizonY + (x - w / 2) * 0.08;
            final val = y < slopeY ? 18 : 4;
            srcRgba[off + 0] = val;
            srcRgba[off + 1] = val;
            srcRgba[off + 2] = val;
            srcRgba[off + 3] = 255;
          }
        }

        final surfaceId = await worker.openStudioSurface(
          width: w,
          height: h,
          sourceRgba: srcRgba,
        );
        try {
          // 1) Before renderStudioSurface: dstPtr is not valid yet -> must fall back to srcPtr
          final propSrc = await worker.analyzeGeometryOnSurface(
            surfaceId: surfaceId,
            targetAspectPreset: FsAspectPreset.FS_ASPECT_ORIGINAL.value,
          );
          final propFallback = await worker.analyzeGeometryOnSurface(
            surfaceId: surfaceId,
            targetAspectPreset: FsAspectPreset.FS_ASPECT_ORIGINAL.value,
            useRescuedBuffer: true,
          );
          expect(propFallback.isOk, isTrue);
          expect(
            propFallback.suggestedRotationDeg,
            closeTo(propSrc.suggestedRotationDeg, 1e-6),
          );
          expect(
            propFallback.horizonConfidence,
            closeTo(propSrc.horizonConfidence, 1e-6),
          );

          // 2) Render DNA Rescue into dstPtr, then re-analyze with useRescuedBuffer: true
          final renderRes = await worker.renderStudioSurface(
            surfaceId: surfaceId,
            params: const DnaRescueNativeParams(
              shadowLift: 0.90,
              midtoneAnchor: 0.65,
              mode: 1,
              enabled: true,
            ),
          );
          expect(renderRes.isOk, isTrue);

          final propRescued = await worker.analyzeGeometryOnSurface(
            surfaceId: surfaceId,
            targetAspectPreset: FsAspectPreset.FS_ASPECT_ORIGINAL.value,
            useRescuedBuffer: true,
          );
          expect(propRescued.isOk, isTrue);
          expect(propRescued.suggestedRotationDeg.isFinite, isTrue);
          expect(propRescued.cropConfidence.isFinite, isTrue);
        } finally {
          await worker.closeStudioSurface(surfaceId);
        }
      },
    );
  });
}
