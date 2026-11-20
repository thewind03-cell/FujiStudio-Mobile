import 'package:flutter/foundation.dart';

import 'schema_utils.dart';

/// Automated edit or workflow recommendation targeting a [SessionItem].
@immutable
final class ActionProposal {
  ActionProposal({
    required String proposalId,
    required String targetItemId,
    required String actionType,
    required double confidence,
    String? summary,
    required bool accepted,
    Map<String, Object?>? patch,
    Map<String, Object?> unknownFields = const <String, Object?>{},
  }) : this._internal(
         proposalId: proposalId,
         targetItemId: targetItemId,
         actionType: actionType,
         confidence: confidence,
         summary: summary,
         accepted: accepted,
         patch: patch,
         unknownFields: unknownFields,
         presentKeys: null,
         intValuedFields: const <String>{},
       );

  ActionProposal._internal({
    required this.proposalId,
    required this.targetItemId,
    required this.actionType,
    required this.confidence,
    required this.summary,
    required this.accepted,
    required Map<String, Object?>? patch,
    required Map<String, Object?> unknownFields,
    required Set<String>? presentKeys,
    required Set<String> intValuedFields,
  }) : patch = patch == null ? null : freezeUnknownFields(patch),
       unknownFields = freezeUnknownFields(unknownFields),
       _presentKeys = freezePresentKeys(presentKeys),
       _intValuedFields = freezeIntValuedFields(intValuedFields);

  static const Set<String> _knownKeys = <String>{
    'proposal_id',
    'target_item_id',
    'action_type',
    'confidence',
    'summary',
    'accepted',
    'patch',
  };

  static const Set<String> _doubleKeys = <String>{
    'confidence',
  };

  final String proposalId;
  final String targetItemId;
  final String actionType;
  final double confidence;
  final String? summary;
  final bool accepted;
  final Map<String, Object?>? patch;
  final Map<String, Object?> unknownFields;
  final Set<String>? _presentKeys;
  final Set<String> _intValuedFields;

  factory ActionProposal.fromJson(Map<String, Object?> json) {
    final rawPatch = json['patch'];
    return ActionProposal._internal(
      proposalId: requireString(json, 'proposal_id', 'ActionProposal'),
      targetItemId: requireString(json, 'target_item_id', 'ActionProposal'),
      actionType: requireString(json, 'action_type', 'ActionProposal'),
      confidence: requireDouble(json, 'confidence', 'ActionProposal'),
      summary: optionalString(json, 'summary', 'ActionProposal'),
      accepted: requireBool(json, 'accepted', 'ActionProposal'),
      patch: rawPatch == null
          ? null
          : requireJsonObject(rawPatch, 'ActionProposal.patch'),
      unknownFields: extractUnknownFields(json, _knownKeys),
      presentKeys: json.keys.toSet(),
      intValuedFields: extractIntValuedFields(json, _doubleKeys),
    );
  }

  ActionProposal copyWith({
    String? proposalId,
    String? targetItemId,
    String? actionType,
    double? confidence,
    Object? summary = schemaUnset,
    bool? accepted,
    Object? patch = schemaUnset,
    Map<String, Object?>? unknownFields,
  }) {
    final addedKeys = <String>[
      if (!identical(summary, schemaUnset) && summary != null) 'summary',
      if (!identical(patch, schemaUnset) && patch != null) 'patch',
    ];
    final clearedInts = <String>[
      if (confidence != null) 'confidence',
    ];

    return ActionProposal._internal(
      proposalId: proposalId ?? this.proposalId,
      targetItemId: targetItemId ?? this.targetItemId,
      actionType: actionType ?? this.actionType,
      confidence: confidence ?? this.confidence,
      summary: identical(summary, schemaUnset)
          ? this.summary
          : summary as String?,
      accepted: accepted ?? this.accepted,
      patch: identical(patch, schemaUnset)
          ? this.patch
          : patch as Map<String, Object?>?,
      unknownFields: unknownFields ?? this.unknownFields,
      presentKeys: updatePresentKeys(_presentKeys, addedKeys),
      intValuedFields: clearIntValuedFields(_intValuedFields, clearedInts),
    );
  }

  Map<String, Object?> toJson() {
    final known = <String, Object?>{
      'proposal_id': proposalId,
      'target_item_id': targetItemId,
      'action_type': actionType,
      'confidence': encodePreservedNumber(
        'confidence',
        confidence,
        _intValuedFields,
      ),
      if (shouldEmitNullableKey('summary', summary, _presentKeys))
        'summary': summary,
      'accepted': accepted,
      if (shouldEmitNullableKey('patch', patch, _presentKeys))
        'patch': patch == null ? null : deepUnfreezeJsonValue(patch),
    };
    return mergeWithUnknownFields(known, unknownFields);
  }
}
