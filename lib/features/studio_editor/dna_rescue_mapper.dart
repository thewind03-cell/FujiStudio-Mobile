import '../../core/ffi/bindings.g.dart';
import '../../core/ffi/native_worker.dart';
import '../../core/schema/edit_recipe.dart';

/// Pure Dart bidirectional mapper between the locked Gate 0 Desktop v2.4.2
/// [DnaRescueSpec] (`shadow_lift` on `0..100` scale) and the normalized C++20
/// ABI [DnaRescueNativeParams] (`[0.0, 1.0]`).
abstract final class DnaRescueMapper {
  static const double defaultMidtoneAnchor = 0.55;
  static const double defaultHighlightProtect = 0.90;
  static const String modeSoocSafe = 'sooc_safe';
  static const String modeDeepRescue = 'deep_rescue';

  static int readMode(DnaRescueSpec spec) {
    final raw = spec.unknownFields['mode'];
    if (raw == modeDeepRescue || raw == FsDnaRescueMode.FS_DNA_MODE_DEEP_RESCUE.value) {
      return FsDnaRescueMode.FS_DNA_MODE_DEEP_RESCUE.value;
    }
    return FsDnaRescueMode.FS_DNA_MODE_SOOC_SAFE.value;
  }

  static String modeToString(int mode) {
    return mode == FsDnaRescueMode.FS_DNA_MODE_DEEP_RESCUE.value
        ? modeDeepRescue
        : modeSoocSafe;
  }

  static double readMidtoneAnchor(DnaRescueSpec spec) {
    final raw = spec.unknownFields['midtone_anchor'];
    if (raw is num && raw.isFinite) {
      final val = raw.toDouble();
      final normalized = val > 1.0 ? val / 100.0 : val;
      return normalized.clamp(0.35, 0.75);
    }
    return defaultMidtoneAnchor;
  }

  static double readHighlightProtect(DnaRescueSpec spec) {
    final raw = spec.unknownFields['highlight_protect'];
    if (raw is num && raw.isFinite) {
      final val = raw.toDouble();
      final normalized = val > 1.0 ? val / 100.0 : val;
      return normalized.clamp(0.75, 0.98);
    }
    return defaultHighlightProtect;
  }

  /// Normalizes [spec] (`shadow_lift` in `0..100`) to C++20 ABI `[0.0, 1.0]`.
  static DnaRescueNativeParams toNativeParams(DnaRescueSpec spec) {
    final normalizedLift = (spec.shadowLift / 100.0).clamp(0.0, 1.0);
    final skinProtect =
        spec.skinProtect.isFinite ? spec.skinProtect.clamp(0.0, 1.0) : 0.0;
    return DnaRescueNativeParams(
      shadowLift: normalizedLift,
      midtoneAnchor: readMidtoneAnchor(spec),
      highlightProtect: readHighlightProtect(spec),
      mode: readMode(spec),
      enabled: spec.enabled,
      skinProtect: skinProtect,
    );
  }

  /// Updates [spec] with a new [mode] (`FS_DNA_MODE_SOOC_SAFE` / `FS_DNA_MODE_DEEP_RESCUE`)
  /// while preserving all existing Desktop v2.4.2 `unknownFields`.
  static DnaRescueSpec withMode(DnaRescueSpec spec, int mode) {
    final updatedUnknown = Map<String, Object?>.of(spec.unknownFields);
    updatedUnknown['mode'] = modeToString(mode);
    return spec.copyWith(unknownFields: updatedUnknown);
  }

  /// Applies an auto-analysis [suggestion] (`recommendedShadowLift` in `[0.0, 0.65]`)
  /// onto [current], converting back to the `0..100` schema scale.
  static DnaRescueSpec applySuggestion(
    DnaRescueSpec current,
    DnaRescueSuggestionResult suggestion,
  ) {
    final scaledLift =
        (suggestion.recommendedShadowLift * 100.0).clamp(0.0, 100.0).roundToDouble();
    final updated = current.copyWith(
      enabled: scaledLift > 0.0,
      shadowLift: scaledLift,
    );
    return withMode(updated, suggestion.recommendedMode);
  }

  /// Returns a neutral reset [DnaRescueSpec] preserving unrelated Desktop `unknownFields`.
  static DnaRescueSpec resetSpec(DnaRescueSpec current) {
    final updatedUnknown = Map<String, Object?>.of(current.unknownFields)
      ..remove('mode')
      ..remove('midtone_anchor')
      ..remove('highlight_protect');
    return current.copyWith(
      enabled: false,
      shadowLift: 0.0,
      unknownFields: updatedUnknown,
    );
  }

  static bool isEdited(DnaRescueSpec spec) {
    return spec.enabled && spec.shadowLift > 0.0;
  }
}
