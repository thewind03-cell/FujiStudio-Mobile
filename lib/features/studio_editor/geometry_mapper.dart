import 'dart:math' as math;

import '../../core/ffi/bindings.g.dart';
import '../../core/ffi/native_worker.dart';
import '../../core/schema/action_proposal.dart';
import '../../core/schema/edit_recipe.dart';

/// Inscribed post-rotation rectangle dimensions in source-pixel units.
final class InscribedFrame {
  const InscribedFrame({
    required this.widthPx,
    required this.heightPx,
    required this.cosT,
    required this.sinT,
  });

  final double widthPx;
  final double heightPx;
  final double cosT;
  final double sinT;
}

/// Output of Dart-side [GeometryMath.clampCrop] mirroring `fs_geometry_clamp_crop`.
final class ClampedGeometryResult {
  const ClampedGeometryResult({
    required this.clampedBox,
    required this.pixelWidth,
    required this.pixelHeight,
  });

  final NormCropBoxData clampedBox;
  final int pixelWidth;
  final int pixelHeight;
}

/// Pure Dart closed-form inscribed-box math identical to C++20
/// `geometry_crop_engine.cpp` for 120fps GPU preview consistency.
abstract final class GeometryMath {
  static double aspectRatioForPreset(
    int preset,
    int srcWidth,
    int srcHeight,
  ) {
    if (preset == FsAspectPreset.FS_ASPECT_4_5.value) return 4.0 / 5.0;
    if (preset == FsAspectPreset.FS_ASPECT_1_1.value) return 1.0;
    if (preset == FsAspectPreset.FS_ASPECT_3_2.value) return 3.0 / 2.0;
    if (preset == FsAspectPreset.FS_ASPECT_9_16.value) return 9.0 / 16.0;
    return srcWidth / srcHeight;
  }

  static InscribedFrame computeInscribedFrame(
    int srcWidth,
    int srcHeight,
    double rotationDeg,
  ) {
    final clampedDeg = rotationDeg.clamp(-15.0, 15.0);
    final theta = clampedDeg * (math.pi / 180.0);
    final cosT = math.cos(theta);
    final sinT = math.sin(theta);
    final absC = cosT.abs();
    final absS = sinT.abs();

    final eps = (srcWidth >= 4 && srcHeight >= 4) ? 0.5 : 0.0;
    final availW = math.max(1.0, srcWidth - 2.0 * eps);
    final availH = math.max(1.0, srcHeight - 2.0 * eps);

    final r0 = srcWidth / srcHeight;
    final denomW = r0 * absC + absS;
    final denomH = r0 * absS + absC;
    final hInscr = math.min(availW / denomW, availH / denomH);
    final wInscr = r0 * hInscr;

    return InscribedFrame(
      widthPx: wInscr,
      heightPx: hInscr,
      cosT: cosT,
      sinT: sinT,
    );
  }

  static ClampedGeometryResult clampCrop({
    required int srcWidth,
    required int srcHeight,
    required double rotationDeg,
    required int aspectPreset,
    required NormCropBoxData requestedBox,
  }) {
    final inscr = computeInscribedFrame(srcWidth, srcHeight, rotationDeg);
    final r0 = srcWidth / srcHeight;
    final targetR = aspectRatioForPreset(aspectPreset, srcWidth, srcHeight);
    final k = targetR / r0;

    var reqL = requestedBox.left.clamp(0.0, 1.0);
    var reqR = requestedBox.right.clamp(0.0, 1.0);
    var reqT = requestedBox.top.clamp(0.0, 1.0);
    var reqB = requestedBox.bottom.clamp(0.0, 1.0);
    if (reqR < reqL) {
      final t = reqL;
      reqL = reqR;
      reqR = t;
    }
    if (reqB < reqT) {
      final t = reqT;
      reqT = reqB;
      reqB = t;
    }

    final maxNh = math.min(1.0, 1.0 / k);
    final minNh = math.min(maxNh, math.max(0.10, 0.10 / k));

    final reqW = reqR - reqL;
    final reqH = reqB - reqT;
    var nhCand = math.min(reqH, reqW / k);
    if (nhCand <= 0.0) {
      nhCand = minNh;
    }
    final nh = nhCand.clamp(minNh, maxNh);
    final nw = (k * nh).clamp(0.0, 1.0);

    final cx = 0.5 * (reqL + reqR);
    final cy = 0.5 * (reqT + reqB);
    final left = (cx - 0.5 * nw).clamp(0.0, 1.0 - nw);
    final top = (cy - 0.5 * nh).clamp(0.0, 1.0 - nh);
    final right = math.min(1.0, left + nw);
    final bottom = math.min(1.0, top + nh);

    final boxWPx = (right - left) * inscr.widthPx;
    final boxHPx = (bottom - top) * inscr.heightPx;
    int pxW;
    int pxH;
    if (targetR <= 1.0) {
      pxH = math.max(1, boxHPx.round());
      pxW = math.max(1, (pxH * targetR).round());
    } else {
      pxW = math.max(1, boxWPx.round());
      pxH = math.max(1, (pxW / targetR).round());
    }

    return ClampedGeometryResult(
      clampedBox: NormCropBoxData(
        left: left,
        top: top,
        right: right,
        bottom: bottom,
      ),
      pixelWidth: pxW.clamp(1, FS_MAX_IMAGE_DIMENSION),
      pixelHeight: pxH.clamp(1, FS_MAX_IMAGE_DIMENSION),
    );
  }
}

/// Bidirectional mapper between Schema v2.4.2 [GeometrySpec] / [ActionProposal]
/// and C++20 ABI [GeometryNativeParams] / [GeometryProposalNative].
///
/// Per `desktop_v2_4_2_sample.json` (`"crop_box": [0.02, 0.01, 0.96, 0.96]`),
/// `GeometrySpec.cropBox` stores `[x, y, width, height]` in `[0, 1]` inscribed
/// coordinates, while C++ `FsNormCropBox` uses `{left, top, right, bottom}`.
abstract final class GeometryMapper {
  static int aspectPresetFromString(String? aspectRatio) {
    return switch (aspectRatio) {
      '4:5' => FsAspectPreset.FS_ASPECT_4_5.value,
      '1:1' => FsAspectPreset.FS_ASPECT_1_1.value,
      '3:2' => FsAspectPreset.FS_ASPECT_3_2.value,
      '9:16' => FsAspectPreset.FS_ASPECT_9_16.value,
      _ => FsAspectPreset.FS_ASPECT_ORIGINAL.value,
    };
  }

  static String? aspectRatioToString(int preset) {
    if (preset == FsAspectPreset.FS_ASPECT_4_5.value) return '4:5';
    if (preset == FsAspectPreset.FS_ASPECT_1_1.value) return '1:1';
    if (preset == FsAspectPreset.FS_ASPECT_3_2.value) return '3:2';
    if (preset == FsAspectPreset.FS_ASPECT_9_16.value) return '9:16';
    return null;
  }

  static String aspectLabel(int preset) {
    if (preset == FsAspectPreset.FS_ASPECT_4_5.value) return '4:5';
    if (preset == FsAspectPreset.FS_ASPECT_1_1.value) return '1:1';
    if (preset == FsAspectPreset.FS_ASPECT_3_2.value) return '3:2';
    if (preset == FsAspectPreset.FS_ASPECT_9_16.value) return '9:16';
    return 'GỐC';
  }

  static NormCropBoxData normBoxFromSpec(GeometrySpec spec) {
    final raw = spec.cropBox;
    if (raw == null || raw.length != 4) {
      return NormCropBoxData.full;
    }
    final x = raw[0].clamp(0.0, 1.0);
    final y = raw[1].clamp(0.0, 1.0);
    final w = raw[2].clamp(0.0, 1.0);
    final h = raw[3].clamp(0.0, 1.0);
    final r = (x + w).clamp(x, 1.0);
    final b = (y + h).clamp(y, 1.0);
    if (r - x < 1e-4 || b - y < 1e-4) {
      return NormCropBoxData.full;
    }
    return NormCropBoxData(left: x, top: y, right: r, bottom: b);
  }

  static List<double> normBoxToSchemaList(NormCropBoxData box) {
    final l = box.left.clamp(0.0, 1.0);
    final t = box.top.clamp(0.0, 1.0);
    final w = (box.right - l).clamp(0.0, 1.0 - l);
    final h = (box.bottom - t).clamp(0.0, 1.0 - t);
    return <double>[
      _round4(l),
      _round4(t),
      _round4(w),
      _round4(h),
    ];
  }

  static bool isFullBox(NormCropBoxData box) {
    return box.left <= 1e-4 &&
        box.top <= 1e-4 &&
        box.right >= 1.0 - 1e-4 &&
        box.bottom >= 1.0 - 1e-4;
  }

  static GeometryNativeParams toNativeParams(
    GeometrySpec spec, {
    bool highQuality = true,
  }) {
    return GeometryNativeParams(
      rotationDeg: spec.rotationDeg.clamp(-15.0, 15.0),
      aspectPreset: aspectPresetFromString(spec.aspectRatio),
      cropBox: normBoxFromSpec(spec),
      highQuality: highQuality,
    );
  }

  static GeometrySpec withNormalizedGeometry(
    GeometrySpec current, {
    required double rotationDeg,
    required int aspectPreset,
    required NormCropBoxData cropBox,
  }) {
    final clampedRot = _round2(rotationDeg.clamp(-15.0, 15.0));
    final aspectStr = aspectRatioToString(aspectPreset);
    final List<double>? nextCrop =
        (aspectStr == null && isFullBox(cropBox))
            ? null
            : normBoxToSchemaList(cropBox);

    return current.copyWith(
      rotationDeg: clampedRot,
      aspectRatio: aspectStr,
      cropBox: nextCrop,
    );
  }

  static GeometrySpec resetSpec(GeometrySpec current) {
    return current.copyWith(
      rotationDeg: 0.0,
      aspectRatio: null,
      cropBox: null,
      flipHorizontal: false,
    );
  }

  static bool isEdited(GeometrySpec spec) {
    return spec.rotationDeg.abs() > 1e-4 ||
        spec.aspectRatio != null ||
        spec.cropBox != null ||
        spec.flipHorizontal;
  }

  static ActionProposal buildActionProposal({
    required String itemId,
    required GeometryProposalNative nativeProposal,
    String? proposalId,
  }) {
    final rot = _round2(nativeProposal.suggestedRotationDeg.clamp(-12.0, 12.0));
    final aspectStr = aspectRatioToString(nativeProposal.targetAspectPreset);
    final cropList = normBoxToSchemaList(nativeProposal.suggestedCropBox);

    final rotText = rot >= 0 ? '+${rot.toStringAsFixed(1)}°' : '${rot.toStringAsFixed(1)}°';
    final aspectText = aspectLabel(nativeProposal.targetAspectPreset);
    final conf = nativeProposal.hasHorizonLine
        ? math.max(nativeProposal.horizonConfidence, nativeProposal.cropConfidence)
        : nativeProposal.cropConfidence;
    final pct = (conf * 100.0).round().clamp(1, 99);

    final id = proposalId ??
        'prop_${itemId}_${DateTime.now().millisecondsSinceEpoch}';

    return ActionProposal(
      proposalId: id,
      targetItemId: itemId,
      actionType: 'horizon_and_crop',
      confidence: _round2(conf.clamp(0.0, 1.0)),
      summary: 'Đề xuất: $rotText · Khung $aspectText ($pct%)',
      accepted: false,
      patch: <String, Object?>{
        'geometry.rotation_deg': rot,
        'geometry.aspect_ratio': aspectStr,
        'geometry.crop_box': cropList,
      },
    );
  }

  static GeometrySpec applyProposalToSpec(
    GeometrySpec current,
    ActionProposal proposal,
  ) {
    final patch = proposal.patch;
    if (patch == null) return current;

    final rawRot = patch['geometry.rotation_deg'];
    final rot = rawRot is num ? rawRot.toDouble() : current.rotationDeg;

    final hasAspect = patch.containsKey('geometry.aspect_ratio');
    final rawAspect = patch['geometry.aspect_ratio'];
    final Object? nextAspect =
        hasAspect ? (rawAspect as String?) : current.aspectRatio;

    final hasCrop = patch.containsKey('geometry.crop_box');
    final rawCrop = patch['geometry.crop_box'];
    List<double>? nextCrop = current.cropBox;
    if (hasCrop) {
      if (rawCrop is List && rawCrop.length == 4) {
        nextCrop = rawCrop.map((e) => (e as num).toDouble()).toList();
      } else if (rawCrop == null) {
        nextCrop = null;
      }
    }

    return current.copyWith(
      rotationDeg: rot.clamp(-15.0, 15.0),
      aspectRatio: nextAspect,
      cropBox: nextCrop,
    );
  }

  static double _round2(double v) => (v * 100.0).roundToDouble() / 100.0;
  static double _round4(double v) => (v * 10000.0).roundToDouble() / 10000.0;
}
