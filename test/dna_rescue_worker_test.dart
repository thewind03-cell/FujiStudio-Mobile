import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fujistudio_mobile/core/ffi/bindings.g.dart';
import 'package:fujistudio_mobile/core/ffi/native_worker.dart';

void main() {
  group('NativeWorker DNA Rescue Studio Surface Tests', () {
    late NativeWorker worker;

    setUpAll(() async {
      worker = await NativeWorker.spawn();
    });

    tearDownAll(() async {
      await worker.dispose();
    });

    test(
      'openStudioSurface + 20 consecutive renderStudioSurface calls preserve midtones and bypass bit-exactly at 0.0',
      () async {
        const width = 16;
        const height = 16;
        const byteLen = width * height * 4;
        final src = Uint8List(byteLen);
        for (var i = 0; i < byteLen; i += 4) {
          final px = i ~/ 4;
          if (px < 128) {
            // Shadow pixels (20, 20, 20, 255)
            src[i + 0] = 20;
            src[i + 1] = 20;
            src[i + 2] = 20;
            src[i + 3] = 255;
          } else {
            // Midtone pixels (160, 160, 160, 200) -> Y ~= 0.627 >= 0.55
            src[i + 0] = 160;
            src[i + 1] = 160;
            src[i + 2] = 160;
            src[i + 3] = 200;
          }
        }

        final surfaceId = await worker.openStudioSurface(
          width: width,
          height: height,
          sourceRgba: src,
        );
        expect(surfaceId, greaterThan(0));

        try {
          // 1. Bypass at 0.0 must match input bit-for-bit.
          final bypass = await worker.renderStudioSurface(
            surfaceId: surfaceId,
            params: const DnaRescueNativeParams(
              shadowLift: 0.0,
              enabled: true,
            ),
          );
          expect(bypass.isOk, isTrue);
          expect(bypass.rgbaBytes, equals(src));

          // 2. Run 20 consecutive renders with varying shadowLift.
          StudioRenderResult? halfResult;
          for (var i = 1; i <= 20; i++) {
            final lift = i == 10 ? 0.5 : (i / 20.0);
            final res = await worker.renderStudioSurface(
              surfaceId: surfaceId,
              params: DnaRescueNativeParams(
                shadowLift: lift,
                midtoneAnchor: 0.55,
                highlightProtect: 0.90,
                mode: FsDnaRescueMode.FS_DNA_MODE_SOOC_SAFE.value,
                enabled: true,
              ),
            );
            expect(res.isOk, isTrue);
            expect(res.rgbaBytes?.length, equals(byteLen));
            if (i == 10) {
              halfResult = res;
            }
          }

          final out = halfResult!.rgbaBytes!;
          // Zero-Haze v2: shadow (20,20,20) lifts cleanly (~28) without gray haze,
          // while midtone (160,160,160) stays untouched (diff <= 1).
          expect(out[0], greaterThan(25));
          expect(out[3], equals(255));
          const midOff = 128 * 4;
          expect((out[midOff + 0] - 160).abs(), lessThanOrEqualTo(1));
          expect((out[midOff + 1] - 160).abs(), lessThanOrEqualTo(1));
          expect((out[midOff + 2] - 160).abs(), lessThanOrEqualTo(1));
          expect(out[midOff + 3], equals(200));
        } finally {
          await worker.closeStudioSurface(surfaceId);
        }
      },
    );

    test(
      'analyzeStudioSurface distinguishes backlit dark scene from well-lit scene',
      () async {
        const w = 64;
        const h = 64;
        const bytes = w * h * 4;

        final backlit = Uint8List(bytes);
        final bright = Uint8List(bytes);
        for (var p = 0; p < w * h; p++) {
          final i = p * 4;
          final v = p < (w * h * 0.4) ? 10 : 235;
          backlit[i + 0] = v;
          backlit[i + 1] = v;
          backlit[i + 2] = v;
          backlit[i + 3] = 255;

          bright[i + 0] = 185;
          bright[i + 1] = 190;
          bright[i + 2] = 195;
          bright[i + 3] = 255;
        }

        final idBacklit = await worker.openStudioSurface(
          width: w,
          height: h,
          sourceRgba: backlit,
        );
        final idBright = await worker.openStudioSurface(
          width: w,
          height: h,
          sourceRgba: bright,
        );

        final sugBacklit = await worker.analyzeStudioSurface(
          surfaceId: idBacklit,
        );
        final sugBright = await worker.analyzeStudioSurface(
          surfaceId: idBright,
        );

        expect(sugBacklit.isOk, isTrue);
        expect(sugBacklit.recommendedShadowLift, greaterThan(0.30));

        expect(sugBright.isOk, isTrue);
        expect(sugBright.recommendedShadowLift, lessThanOrEqualTo(0.15));

        await worker.closeStudioSurface(idBacklit);
        await worker.closeStudioSurface(idBright);
      },
    );

    test(
      'rejects render on closed surfaceId and rejects opening more than 2 concurrent surfaces',
      () async {
        final pixel = Uint8List.fromList(<int>[10, 20, 30, 255]);
        final s1 = await worker.openStudioSurface(
          width: 1,
          height: 1,
          sourceRgba: pixel,
        );
        final s2 = await worker.openStudioSurface(
          width: 1,
          height: 1,
          sourceRgba: pixel,
        );

        // 3rd concurrent surface must be rejected cleanly.
        await expectLater(
          worker.openStudioSurface(width: 1, height: 1, sourceRgba: pixel),
          throwsA(isA<StateError>()),
        );

        await worker.closeStudioSurface(s1);
        await expectLater(
          worker.renderStudioSurface(
            surfaceId: s1,
            params: const DnaRescueNativeParams(shadowLift: 0.5),
          ),
          throwsA(isA<StateError>()),
        );

        await worker.closeStudioSurface(s2);

        // Worker remains healthy after surface limit/closed errors.
        expect(await worker.coreVersion(), equals('0.1.0-day0'));
      },
    );
  });
}
