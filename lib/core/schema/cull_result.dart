import 'package:flutter/foundation.dart';

import 'schema_utils.dart';

/// AI/manual culling evaluation for a [SessionItem], compatible with Desktop v2.4.2.
@immutable
final class CullResult {
  CullResult({
    required String status,
    required double sharpnessScore,
    double? exposureScore,
    String? burstClusterId,
    bool isBurstAnchor = false,
    List<String> flags = const <String>[],
    Map<String, Object?> unknownFields = const <String, Object?>{},
  }) : this._internal(
         status: status,
         sharpnessScore: sharpnessScore,
         exposureScore: exposureScore,
         burstClusterId: burstClusterId,
         isBurstAnchor: isBurstAnchor,
         flags: flags,
         unknownFields: unknownFields,
         presentKeys: null,
         intValuedFields: const <String>{},
       );

  CullResult._internal({
    required this.status,
    required this.sharpnessScore,
    required this.exposureScore,
    required this.burstClusterId,
    required this.isBurstAnchor,
    required List<String> flags,
    required Map<String, Object?> unknownFields,
    required Set<String>? presentKeys,
    required Set<String> intValuedFields,
  }) : flags = List<String>.unmodifiable(flags),
       unknownFields = freezeUnknownFields(unknownFields),
       _presentKeys = freezePresentKeys(presentKeys),
       _intValuedFields = freezeIntValuedFields(intValuedFields);

  static const Set<String> _knownKeys = <String>{
    'status',
    'sharpness_score',
    'exposure_score',
    'burst_cluster_id',
    'is_burst_anchor',
    'flags',
  };

  static const Set<String> _doubleKeys = <String>{
    'sharpness_score',
    'exposure_score',
  };

  final String status;
  final double sharpnessScore;
  final double? exposureScore;
  final String? burstClusterId;
  final bool isBurstAnchor;
  final List<String> flags;
  final Map<String, Object?> unknownFields;
  final Set<String>? _presentKeys;
  final Set<String> _intValuedFields;

  factory CullResult.fromJson(Map<String, Object?> json) {
    final rawFlags = json['flags'];
    final parsedFlags = <String>[];
    if (rawFlags != null) {
      if (rawFlags is! List) {
        throw const FormatException('Invalid list "flags" in CullResult');
      }
      for (final item in rawFlags) {
        if (item is! String) {
          throw const FormatException('Invalid flag entry in CullResult');
        }
        parsedFlags.add(item);
      }
    }

    return CullResult._internal(
      status: requireString(json, 'status', 'CullResult'),
      sharpnessScore: requireDouble(json, 'sharpness_score', 'CullResult'),
      exposureScore: optionalDouble(json, 'exposure_score', 'CullResult'),
      burstClusterId: optionalString(json, 'burst_cluster_id', 'CullResult'),
      isBurstAnchor: optionalBool(
        json,
        'is_burst_anchor',
        'CullResult',
        defaultValue: false,
      ),
      flags: parsedFlags,
      unknownFields: extractUnknownFields(json, _knownKeys),
      presentKeys: json.keys.toSet(),
      intValuedFields: extractIntValuedFields(json, _doubleKeys),
    );
  }

  CullResult copyWith({
    String? status,
    double? sharpnessScore,
    Object? exposureScore = schemaUnset,
    Object? burstClusterId = schemaUnset,
    bool? isBurstAnchor,
    List<String>? flags,
    Map<String, Object?>? unknownFields,
  }) {
    final addedKeys = <String>[
      if (isBurstAnchor != null) 'is_burst_anchor',
      if (flags != null) 'flags',
      if (!identical(exposureScore, schemaUnset) && exposureScore != null)
        'exposure_score',
      if (!identical(burstClusterId, schemaUnset) && burstClusterId != null)
        'burst_cluster_id',
    ];
    final clearedInts = <String>[
      if (sharpnessScore != null) 'sharpness_score',
      if (!identical(exposureScore, schemaUnset)) 'exposure_score',
    ];

    return CullResult._internal(
      status: status ?? this.status,
      sharpnessScore: sharpnessScore ?? this.sharpnessScore,
      exposureScore: identical(exposureScore, schemaUnset)
          ? this.exposureScore
          : exposureScore as double?,
      burstClusterId: identical(burstClusterId, schemaUnset)
          ? this.burstClusterId
          : burstClusterId as String?,
      isBurstAnchor: isBurstAnchor ?? this.isBurstAnchor,
      flags: flags ?? this.flags,
      unknownFields: unknownFields ?? this.unknownFields,
      presentKeys: updatePresentKeys(_presentKeys, addedKeys),
      intValuedFields: clearIntValuedFields(_intValuedFields, clearedInts),
    );
  }

  Map<String, Object?> toJson() {
    final known = <String, Object?>{
      'status': status,
      'sharpness_score': encodePreservedNumber(
        'sharpness_score',
        sharpnessScore,
        _intValuedFields,
      ),
      if (shouldEmitNullableKey('exposure_score', exposureScore, _presentKeys))
        'exposure_score': exposureScore == null
            ? null
            : encodePreservedNumber(
                'exposure_score',
                exposureScore!,
                _intValuedFields,
              ),
      if (shouldEmitNullableKey('burst_cluster_id', burstClusterId, _presentKeys))
        'burst_cluster_id': burstClusterId,
      if (shouldEmitOptionalKey('is_burst_anchor', _presentKeys))
        'is_burst_anchor': isBurstAnchor,
      if (shouldEmitOptionalKey('flags', _presentKeys))
        'flags': List<String>.of(flags),
    };
    return mergeWithUnknownFields(known, unknownFields);
  }
}
