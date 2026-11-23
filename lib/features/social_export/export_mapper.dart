import 'package:flutter/foundation.dart';

import '../../core/ffi/native_worker.dart';
import '../../core/schema/edit_recipe.dart';

/// Supported mobile social export presets mapped onto Schema v2.4.2
/// [ExportProfileSpec].
enum SocialExportPreset {
  facebook2048(
    id: 'facebook_2048',
    label: 'Facebook 2048',
    defaultMaxLongEdgePx: 2048,
    defaultJpegQuality: 92,
    defaultSuffix: '_fb2048',
    defaultSharpening: OutputSharpeningLevel.subtle,
  ),
  instagram2048(
    id: 'instagram_2048',
    label: 'Instagram 2048',
    defaultMaxLongEdgePx: 2048,
    defaultJpegQuality: 92,
    defaultSuffix: '_ig2048',
    defaultSharpening: OutputSharpeningLevel.standard,
  ),
  originalMax(
    id: 'original_max',
    label: 'Gốc tối đa',
    defaultMaxLongEdgePx: null,
    defaultJpegQuality: 95,
    defaultSuffix: '_full',
    defaultSharpening: OutputSharpeningLevel.off,
  );

  const SocialExportPreset({
    required this.id,
    required this.label,
    required this.defaultMaxLongEdgePx,
    required this.defaultJpegQuality,
    required this.defaultSuffix,
    required this.defaultSharpening,
  });

  final String id;
  final String label;
  final int? defaultMaxLongEdgePx;
  final int defaultJpegQuality;
  final String defaultSuffix;
  final OutputSharpeningLevel defaultSharpening;

  static SocialExportPreset? tryParse(Object? raw) {
    if (raw is! String) return null;
    final normalized = raw.trim().toLowerCase();
    for (final preset in values) {
      if (preset.id == normalized) return preset;
    }
    return null;
  }
}

/// Output sharpening levels mapped to [OutputUsmNativeParams].
enum OutputSharpeningLevel {
  off(id: 'off', label: 'Tắt', amount: 0.0),
  subtle(id: 'subtle', label: 'Nhẹ', amount: 0.35),
  standard(id: 'standard', label: 'Chuẩn', amount: 0.50);

  const OutputSharpeningLevel({
    required this.id,
    required this.label,
    required this.amount,
  });

  final String id;
  final String label;
  final double amount;

  OutputUsmNativeParams toNativeParams() {
    return OutputUsmNativeParams(
      amount: amount,
      radius: 0.85,
      threshold: 3.0,
      haloClamp: 18.0,
      enabled: amount > 0.0,
    );
  }

  static OutputSharpeningLevel? tryParse(Object? raw) {
    if (raw is! String) return null;
    final normalized = raw.trim().toLowerCase();
    for (final level in values) {
      if (level.id == normalized) return level;
    }
    return null;
  }
}

/// Native execution parameters derived from a Schema v2.4.2 [ExportProfileSpec].
@immutable
final class SocialExportNativeConfig {
  const SocialExportNativeConfig({
    required this.preset,
    required this.maxLongEdgePx,
    required this.jpegQuality,
    required this.outputUsm,
    required this.preserveExif,
    required this.stripGps,
    required this.filenameSuffix,
  });

  final SocialExportPreset preset;

  /// Target maximum long edge in pixels (`0` disables downscaling).
  final int maxLongEdgePx;
  final int jpegQuality;
  final OutputUsmNativeParams outputUsm;
  final bool preserveExif;
  final bool stripGps;
  final String filenameSuffix;
}

/// Bidirectional mapper between Gate 0 Desktop v2.4.2 [ExportProfileSpec] and
/// [SocialExportNativeConfig].
///
/// Locked Gate 0 keys on [ExportProfileSpec]:
/// - `format`: `'jpeg'`
/// - `quality`: `int` (`1..100`)
/// - `color_space`: `'sRGB'`
/// - `max_long_edge_px`: `int?` (`null` means no downscale)
///
/// Mobile social-export metadata is stored in [ExportProfileSpec.unknownFields]
/// (`preset`, `output_sharpening`, `preserve_exif`, `strip_gps`,
/// `filename_suffix`) so existing Desktop `unknownFields` (e.g.
/// `desktop_exif_preserve_makernotes`) survive round-trips untouched.
abstract final class ExportMapper {
  static const String keyPreset = 'preset';
  static const String keyOutputSharpening = 'output_sharpening';
  static const String keyPreserveExif = 'preserve_exif';
  static const String keyStripGps = 'strip_gps';
  static const String keyFilenameSuffix = 'filename_suffix';

  static SocialExportPreset presetFromSpec(ExportProfileSpec spec) {
    final parsed = SocialExportPreset.tryParse(spec.unknownFields[keyPreset]);
    if (parsed != null) return parsed;
    if (spec.maxLongEdgePx == null) {
      return SocialExportPreset.originalMax;
    }
    return SocialExportPreset.facebook2048;
  }

  static OutputSharpeningLevel sharpeningFromSpec(
    ExportProfileSpec spec, {
    SocialExportPreset? fallbackPreset,
  }) {
    final parsed = OutputSharpeningLevel.tryParse(
      spec.unknownFields[keyOutputSharpening],
    );
    if (parsed != null) return parsed;
    return (fallbackPreset ?? presetFromSpec(spec)).defaultSharpening;
  }

  static bool preserveExifFromSpec(ExportProfileSpec spec) {
    final raw = spec.unknownFields[keyPreserveExif];
    return raw is bool ? raw : true;
  }

  static bool stripGpsFromSpec(ExportProfileSpec spec) {
    final raw = spec.unknownFields[keyStripGps];
    return raw is bool ? raw : true;
  }

  static String filenameSuffixFromSpec(
    ExportProfileSpec spec, {
    SocialExportPreset? fallbackPreset,
  }) {
    final raw = spec.unknownFields[keyFilenameSuffix];
    if (raw is String && raw.trim().isNotEmpty) {
      return raw.trim();
    }
    return (fallbackPreset ?? presetFromSpec(spec)).defaultSuffix;
  }

  static SocialExportNativeConfig toNativeConfig(ExportProfileSpec spec) {
    final preset = presetFromSpec(spec);
    final sharpening = sharpeningFromSpec(spec, fallbackPreset: preset);
    final maxEdge = spec.maxLongEdgePx ??
        (preset == SocialExportPreset.originalMax
            ? 0
            : (preset.defaultMaxLongEdgePx ?? 0));
    final quality = spec.quality.clamp(50, 100);

    return SocialExportNativeConfig(
      preset: preset,
      maxLongEdgePx: maxEdge < 0 ? 0 : maxEdge,
      jpegQuality: quality,
      outputUsm: sharpening.toNativeParams(),
      preserveExif: preserveExifFromSpec(spec),
      stripGps: stripGpsFromSpec(spec),
      filenameSuffix: filenameSuffixFromSpec(spec, fallbackPreset: preset),
    );
  }

  /// Applies [preset] onto [current], preserving unrelated Desktop
  /// `unknownFields` and locked Gate 0 types (`int` for `quality` and
  /// `max_long_edge_px`).
  static ExportProfileSpec applyPreset(
    ExportProfileSpec current,
    SocialExportPreset preset, {
    bool? preserveExif,
    bool? stripGps,
  }) {
    final updatedUnknown = Map<String, Object?>.of(current.unknownFields)
      ..[keyPreset] = preset.id
      ..[keyOutputSharpening] = preset.defaultSharpening.id
      ..[keyPreserveExif] = preserveExif ?? preserveExifFromSpec(current)
      ..[keyStripGps] = stripGps ?? stripGpsFromSpec(current)
      ..[keyFilenameSuffix] = preset.defaultSuffix;

    return current.copyWith(
      format: 'jpeg',
      quality: preset.defaultJpegQuality,
      colorSpace: 'sRGB',
      maxLongEdgePx: preset.defaultMaxLongEdgePx,
      unknownFields: updatedUnknown,
    );
  }

  /// Updates individual export options on [current] while keeping all unrelated
  /// Desktop `unknownFields` intact.
  static ExportProfileSpec withOptions(
    ExportProfileSpec current, {
    SocialExportPreset? preset,
    int? jpegQuality,
    int? maxLongEdgePx,
    bool clearMaxLongEdge = false,
    OutputSharpeningLevel? sharpening,
    bool? preserveExif,
    bool? stripGps,
    String? filenameSuffix,
  }) {
    final resolvedPreset = preset ?? presetFromSpec(current);
    final updatedUnknown = Map<String, Object?>.of(current.unknownFields)
      ..[keyPreset] = resolvedPreset.id
      ..[keyOutputSharpening] =
          (sharpening ?? sharpeningFromSpec(current, fallbackPreset: resolvedPreset)).id
      ..[keyPreserveExif] = preserveExif ?? preserveExifFromSpec(current)
      ..[keyStripGps] = stripGps ?? stripGpsFromSpec(current)
      ..[keyFilenameSuffix] = filenameSuffix ??
          filenameSuffixFromSpec(current, fallbackPreset: resolvedPreset);

    final Object? nextMaxEdge = clearMaxLongEdge
        ? null
        : (maxLongEdgePx ?? current.maxLongEdgePx);

    return current.copyWith(
      format: 'jpeg',
      quality: (jpegQuality ?? current.quality).clamp(1, 100),
      colorSpace: current.colorSpace,
      maxLongEdgePx: nextMaxEdge,
      unknownFields: updatedUnknown,
    );
  }

  /// Formats an exported JPEG display name such as `DSCF4012_fb2048.jpg`.
  static String buildOutputFileName(
    String sourceFileName, {
    required String suffix,
  }) {
    final trimmed = sourceFileName.trim();
    final dotIdx = trimmed.lastIndexOf('.');
    final stem = dotIdx > 0 ? trimmed.substring(0, dotIdx) : trimmed;
    final safeStem = stem.isEmpty ? 'fujistudio_export' : stem;
    return '$safeStem$suffix.jpg';
  }
}
