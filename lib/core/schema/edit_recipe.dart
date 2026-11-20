import 'package:flutter/foundation.dart';

import 'schema_utils.dart';

/// DNA-Aware shadow/highlight rescue parameters (`edit_recipe.dna_rescue`).
@immutable
final class DnaRescueSpec {
  DnaRescueSpec({
    required bool enabled,
    required double shadowLift,
    double highlightRolloff = 0.0,
    double microContrast = 0.0,
    double skinProtect = 0.0,
    Map<String, Object?> unknownFields = const <String, Object?>{},
  }) : this._internal(
         enabled: enabled,
         shadowLift: shadowLift,
         highlightRolloff: highlightRolloff,
         microContrast: microContrast,
         skinProtect: skinProtect,
         unknownFields: unknownFields,
         presentKeys: null,
         intValuedFields: const <String>{},
       );

  DnaRescueSpec._internal({
    required this.enabled,
    required this.shadowLift,
    required this.highlightRolloff,
    required this.microContrast,
    required this.skinProtect,
    required Map<String, Object?> unknownFields,
    required Set<String>? presentKeys,
    required Set<String> intValuedFields,
  }) : unknownFields = freezeUnknownFields(unknownFields),
       _presentKeys = freezePresentKeys(presentKeys),
       _intValuedFields = freezeIntValuedFields(intValuedFields);

  static const Set<String> _knownKeys = <String>{
    'enabled',
    'shadow_lift',
    'highlight_rolloff',
    'micro_contrast',
    'skin_protect',
  };

  static const Set<String> _doubleKeys = <String>{
    'shadow_lift',
    'highlight_rolloff',
    'micro_contrast',
    'skin_protect',
  };

  final bool enabled;
  final double shadowLift;
  final double highlightRolloff;
  final double microContrast;
  final double skinProtect;
  final Map<String, Object?> unknownFields;
  final Set<String>? _presentKeys;
  final Set<String> _intValuedFields;

  factory DnaRescueSpec.fromJson(Map<String, Object?> json) {
    return DnaRescueSpec._internal(
      enabled: requireBool(json, 'enabled', 'DnaRescueSpec'),
      shadowLift: requireDouble(json, 'shadow_lift', 'DnaRescueSpec'),
      highlightRolloff:
          optionalDouble(json, 'highlight_rolloff', 'DnaRescueSpec') ?? 0.0,
      microContrast:
          optionalDouble(json, 'micro_contrast', 'DnaRescueSpec') ?? 0.0,
      skinProtect: optionalDouble(json, 'skin_protect', 'DnaRescueSpec') ?? 0.0,
      unknownFields: extractUnknownFields(json, _knownKeys),
      presentKeys: json.keys.toSet(),
      intValuedFields: extractIntValuedFields(json, _doubleKeys),
    );
  }

  DnaRescueSpec copyWith({
    bool? enabled,
    double? shadowLift,
    double? highlightRolloff,
    double? microContrast,
    double? skinProtect,
    Map<String, Object?>? unknownFields,
  }) {
    final addedKeys = <String>[
      if (highlightRolloff != null) 'highlight_rolloff',
      if (microContrast != null) 'micro_contrast',
      if (skinProtect != null) 'skin_protect',
    ];
    final clearedInts = <String>[
      if (shadowLift != null) 'shadow_lift',
      if (highlightRolloff != null) 'highlight_rolloff',
      if (microContrast != null) 'micro_contrast',
      if (skinProtect != null) 'skin_protect',
    ];

    return DnaRescueSpec._internal(
      enabled: enabled ?? this.enabled,
      shadowLift: shadowLift ?? this.shadowLift,
      highlightRolloff: highlightRolloff ?? this.highlightRolloff,
      microContrast: microContrast ?? this.microContrast,
      skinProtect: skinProtect ?? this.skinProtect,
      unknownFields: unknownFields ?? this.unknownFields,
      presentKeys: updatePresentKeys(_presentKeys, addedKeys),
      intValuedFields: clearIntValuedFields(_intValuedFields, clearedInts),
    );
  }

  Map<String, Object?> toJson() {
    final known = <String, Object?>{
      'enabled': enabled,
      'shadow_lift': encodePreservedNumber(
        'shadow_lift',
        shadowLift,
        _intValuedFields,
      ),
      if (shouldEmitOptionalKey('highlight_rolloff', _presentKeys))
        'highlight_rolloff': encodePreservedNumber(
          'highlight_rolloff',
          highlightRolloff,
          _intValuedFields,
        ),
      if (shouldEmitOptionalKey('micro_contrast', _presentKeys))
        'micro_contrast': encodePreservedNumber(
          'micro_contrast',
          microContrast,
          _intValuedFields,
        ),
      if (shouldEmitOptionalKey('skin_protect', _presentKeys))
        'skin_protect': encodePreservedNumber(
          'skin_protect',
          skinProtect,
          _intValuedFields,
        ),
    };
    return mergeWithUnknownFields(known, unknownFields);
  }
}

/// Crop, rotation, and flip parameters (`edit_recipe.geometry`).
@immutable
final class GeometrySpec {
  GeometrySpec({
    required double rotationDeg,
    String? aspectRatio,
    List<double>? cropBox,
    bool flipHorizontal = false,
    Map<String, Object?> unknownFields = const <String, Object?>{},
  }) : this._internal(
         rotationDeg: rotationDeg,
         aspectRatio: aspectRatio,
         cropBox: cropBox,
         flipHorizontal: flipHorizontal,
         unknownFields: unknownFields,
         presentKeys: null,
         intValuedFields: const <String>{},
       );

  GeometrySpec._internal({
    required this.rotationDeg,
    required this.aspectRatio,
    required List<double>? cropBox,
    required this.flipHorizontal,
    required Map<String, Object?> unknownFields,
    required Set<String>? presentKeys,
    required Set<String> intValuedFields,
  }) : cropBox = cropBox == null ? null : List<double>.unmodifiable(cropBox),
       unknownFields = freezeUnknownFields(unknownFields),
       _presentKeys = freezePresentKeys(presentKeys),
       _intValuedFields = freezeIntValuedFields(intValuedFields);

  static const Set<String> _knownKeys = <String>{
    'rotation_deg',
    'aspect_ratio',
    'crop_box',
    'flip_horizontal',
  };

  static const Set<String> _doubleKeys = <String>{
    'rotation_deg',
  };

  final double rotationDeg;
  final String? aspectRatio;
  final List<double>? cropBox;
  final bool flipHorizontal;
  final Map<String, Object?> unknownFields;
  final Set<String>? _presentKeys;
  final Set<String> _intValuedFields;

  factory GeometrySpec.fromJson(Map<String, Object?> json) {
    final intFields = extractIntValuedFields(json, _doubleKeys).toSet();
    List<double>? parsedCrop;
    final rawCrop = json['crop_box'];
    if (rawCrop != null) {
      if (rawCrop is! List || rawCrop.length != 4) {
        throw const FormatException(
          'Invalid "crop_box" in GeometrySpec (expected 4 numbers)',
        );
      }
      parsedCrop = <double>[];
      for (var i = 0; i < rawCrop.length; i++) {
        final e = rawCrop[i];
        if (e is! num) {
          throw const FormatException('Invalid number in "crop_box"');
        }
        if (e is int) {
          intFields.add('crop_box[$i]');
        }
        parsedCrop.add(e.toDouble());
      }
    }

    return GeometrySpec._internal(
      rotationDeg: requireDouble(json, 'rotation_deg', 'GeometrySpec'),
      aspectRatio: optionalString(json, 'aspect_ratio', 'GeometrySpec'),
      cropBox: parsedCrop,
      flipHorizontal: optionalBool(
        json,
        'flip_horizontal',
        'GeometrySpec',
        defaultValue: false,
      ),
      unknownFields: extractUnknownFields(json, _knownKeys),
      presentKeys: json.keys.toSet(),
      intValuedFields: intFields,
    );
  }

  GeometrySpec copyWith({
    double? rotationDeg,
    Object? aspectRatio = schemaUnset,
    Object? cropBox = schemaUnset,
    bool? flipHorizontal,
    Map<String, Object?>? unknownFields,
  }) {
    final addedKeys = <String>[
      if (flipHorizontal != null) 'flip_horizontal',
      if (!identical(aspectRatio, schemaUnset) && aspectRatio != null)
        'aspect_ratio',
      if (!identical(cropBox, schemaUnset) && cropBox != null) 'crop_box',
    ];
    final clearedInts = <String>[
      if (rotationDeg != null) 'rotation_deg',
      if (!identical(cropBox, schemaUnset)) ...const <String>[
        'crop_box[0]',
        'crop_box[1]',
        'crop_box[2]',
        'crop_box[3]',
      ],
    ];

    return GeometrySpec._internal(
      rotationDeg: rotationDeg ?? this.rotationDeg,
      aspectRatio: identical(aspectRatio, schemaUnset)
          ? this.aspectRatio
          : aspectRatio as String?,
      cropBox: identical(cropBox, schemaUnset)
          ? this.cropBox
          : cropBox as List<double>?,
      flipHorizontal: flipHorizontal ?? this.flipHorizontal,
      unknownFields: unknownFields ?? this.unknownFields,
      presentKeys: updatePresentKeys(_presentKeys, addedKeys),
      intValuedFields: clearIntValuedFields(_intValuedFields, clearedInts),
    );
  }

  Map<String, Object?> toJson() {
    final known = <String, Object?>{
      'rotation_deg': encodePreservedNumber(
        'rotation_deg',
        rotationDeg,
        _intValuedFields,
      ),
      if (shouldEmitNullableKey('aspect_ratio', aspectRatio, _presentKeys))
        'aspect_ratio': aspectRatio,
      if (shouldEmitNullableKey('crop_box', cropBox, _presentKeys))
        'crop_box': cropBox == null
            ? null
            : <num>[
                for (var i = 0; i < cropBox!.length; i++)
                  encodePreservedNumber(
                    'crop_box[$i]',
                    cropBox![i],
                    _intValuedFields,
                  ),
              ],
      if (shouldEmitOptionalKey('flip_horizontal', _presentKeys))
        'flip_horizontal': flipHorizontal,
    };
    return mergeWithUnknownFields(known, unknownFields);
  }
}

/// 3D LUT application parameters (`edit_recipe.lut`).
@immutable
final class LutSpec {
  LutSpec({
    required bool enabled,
    String? lutId,
    required double intensity,
    Map<String, Object?> unknownFields = const <String, Object?>{},
  }) : this._internal(
         enabled: enabled,
         lutId: lutId,
         intensity: intensity,
         unknownFields: unknownFields,
         presentKeys: null,
         intValuedFields: const <String>{},
       );

  LutSpec._internal({
    required this.enabled,
    required this.lutId,
    required this.intensity,
    required Map<String, Object?> unknownFields,
    required Set<String>? presentKeys,
    required Set<String> intValuedFields,
  }) : unknownFields = freezeUnknownFields(unknownFields),
       _presentKeys = freezePresentKeys(presentKeys),
       _intValuedFields = freezeIntValuedFields(intValuedFields);

  static const Set<String> _knownKeys = <String>{
    'enabled',
    'lut_id',
    'intensity',
  };

  static const Set<String> _doubleKeys = <String>{
    'intensity',
  };

  final bool enabled;
  final String? lutId;
  final double intensity;
  final Map<String, Object?> unknownFields;
  final Set<String>? _presentKeys;
  final Set<String> _intValuedFields;

  factory LutSpec.fromJson(Map<String, Object?> json) {
    return LutSpec._internal(
      enabled: requireBool(json, 'enabled', 'LutSpec'),
      lutId: optionalString(json, 'lut_id', 'LutSpec'),
      intensity: requireDouble(json, 'intensity', 'LutSpec'),
      unknownFields: extractUnknownFields(json, _knownKeys),
      presentKeys: json.keys.toSet(),
      intValuedFields: extractIntValuedFields(json, _doubleKeys),
    );
  }

  LutSpec copyWith({
    bool? enabled,
    Object? lutId = schemaUnset,
    double? intensity,
    Map<String, Object?>? unknownFields,
  }) {
    final addedKeys = <String>[
      if (!identical(lutId, schemaUnset) && lutId != null) 'lut_id',
    ];
    final clearedInts = <String>[
      if (intensity != null) 'intensity',
    ];

    return LutSpec._internal(
      enabled: enabled ?? this.enabled,
      lutId: identical(lutId, schemaUnset) ? this.lutId : lutId as String?,
      intensity: intensity ?? this.intensity,
      unknownFields: unknownFields ?? this.unknownFields,
      presentKeys: updatePresentKeys(_presentKeys, addedKeys),
      intValuedFields: clearIntValuedFields(_intValuedFields, clearedInts),
    );
  }

  Map<String, Object?> toJson() {
    final known = <String, Object?>{
      'enabled': enabled,
      if (shouldEmitNullableKey('lut_id', lutId, _presentKeys)) 'lut_id': lutId,
      'intensity': encodePreservedNumber(
        'intensity',
        intensity,
        _intValuedFields,
      ),
    };
    return mergeWithUnknownFields(known, unknownFields);
  }
}

/// Export encoding parameters (`edit_recipe.export_profile`).
@immutable
final class ExportProfileSpec {
  ExportProfileSpec({
    required String format,
    required int quality,
    String colorSpace = 'sRGB',
    int? maxLongEdgePx,
    Map<String, Object?> unknownFields = const <String, Object?>{},
  }) : this._internal(
         format: format,
         quality: quality,
         colorSpace: colorSpace,
         maxLongEdgePx: maxLongEdgePx,
         unknownFields: unknownFields,
         presentKeys: null,
       );

  ExportProfileSpec._internal({
    required this.format,
    required this.quality,
    required this.colorSpace,
    required this.maxLongEdgePx,
    required Map<String, Object?> unknownFields,
    required Set<String>? presentKeys,
  }) : unknownFields = freezeUnknownFields(unknownFields),
       _presentKeys = freezePresentKeys(presentKeys);

  static const Set<String> _knownKeys = <String>{
    'format',
    'quality',
    'color_space',
    'max_long_edge_px',
  };

  final String format;
  final int quality;
  final String colorSpace;
  final int? maxLongEdgePx;
  final Map<String, Object?> unknownFields;
  final Set<String>? _presentKeys;

  factory ExportProfileSpec.fromJson(Map<String, Object?> json) {
    return ExportProfileSpec._internal(
      format: requireString(json, 'format', 'ExportProfileSpec'),
      quality: requireInt(json, 'quality', 'ExportProfileSpec'),
      colorSpace:
          optionalString(json, 'color_space', 'ExportProfileSpec') ?? 'sRGB',
      maxLongEdgePx:
          optionalInt(json, 'max_long_edge_px', 'ExportProfileSpec'),
      unknownFields: extractUnknownFields(json, _knownKeys),
      presentKeys: json.keys.toSet(),
    );
  }

  ExportProfileSpec copyWith({
    String? format,
    int? quality,
    String? colorSpace,
    Object? maxLongEdgePx = schemaUnset,
    Map<String, Object?>? unknownFields,
  }) {
    final addedKeys = <String>[
      if (colorSpace != null) 'color_space',
      if (!identical(maxLongEdgePx, schemaUnset) && maxLongEdgePx != null)
        'max_long_edge_px',
    ];

    return ExportProfileSpec._internal(
      format: format ?? this.format,
      quality: quality ?? this.quality,
      colorSpace: colorSpace ?? this.colorSpace,
      maxLongEdgePx: identical(maxLongEdgePx, schemaUnset)
          ? this.maxLongEdgePx
          : maxLongEdgePx as int?,
      unknownFields: unknownFields ?? this.unknownFields,
      presentKeys: updatePresentKeys(_presentKeys, addedKeys),
    );
  }

  Map<String, Object?> toJson() {
    final known = <String, Object?>{
      'format': format,
      'quality': quality,
      if (shouldEmitOptionalKey('color_space', _presentKeys))
        'color_space': colorSpace,
      if (shouldEmitNullableKey('max_long_edge_px', maxLongEdgePx, _presentKeys))
        'max_long_edge_px': maxLongEdgePx,
    };
    return mergeWithUnknownFields(known, unknownFields);
  }
}

/// Complete non-destructive editing recipe for a [SessionItem].
@immutable
final class EditRecipe {
  EditRecipe({
    required this.dnaRescue,
    required this.geometry,
    required this.lut,
    required this.exportProfile,
    Map<String, Object?> unknownFields = const <String, Object?>{},
  }) : unknownFields = freezeUnknownFields(unknownFields);

  static const Set<String> _knownKeys = <String>{
    'dna_rescue',
    'geometry',
    'lut',
    'export_profile',
  };

  final DnaRescueSpec dnaRescue;
  final GeometrySpec geometry;
  final LutSpec lut;
  final ExportProfileSpec exportProfile;
  final Map<String, Object?> unknownFields;

  factory EditRecipe.fromJson(Map<String, Object?> json) {
    return EditRecipe(
      dnaRescue: DnaRescueSpec.fromJson(
        requireJsonObject(json['dna_rescue'], 'EditRecipe.dna_rescue'),
      ),
      geometry: GeometrySpec.fromJson(
        requireJsonObject(json['geometry'], 'EditRecipe.geometry'),
      ),
      lut: LutSpec.fromJson(
        requireJsonObject(json['lut'], 'EditRecipe.lut'),
      ),
      exportProfile: ExportProfileSpec.fromJson(
        requireJsonObject(json['export_profile'], 'EditRecipe.export_profile'),
      ),
      unknownFields: extractUnknownFields(json, _knownKeys),
    );
  }

  EditRecipe copyWith({
    DnaRescueSpec? dnaRescue,
    GeometrySpec? geometry,
    LutSpec? lut,
    ExportProfileSpec? exportProfile,
    Map<String, Object?>? unknownFields,
  }) {
    return EditRecipe(
      dnaRescue: dnaRescue ?? this.dnaRescue,
      geometry: geometry ?? this.geometry,
      lut: lut ?? this.lut,
      exportProfile: exportProfile ?? this.exportProfile,
      unknownFields: unknownFields ?? this.unknownFields,
    );
  }

  Map<String, Object?> toJson() {
    final known = <String, Object?>{
      'dna_rescue': dnaRescue.toJson(),
      'geometry': geometry.toJson(),
      'lut': lut.toJson(),
      'export_profile': exportProfile.toJson(),
    };
    return mergeWithUnknownFields(known, unknownFields);
  }
}
