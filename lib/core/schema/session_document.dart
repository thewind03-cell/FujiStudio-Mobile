import 'package:flutter/foundation.dart';

import 'action_proposal.dart';
import 'collage_spec.dart';
import 'schema_utils.dart';
import 'session_item.dart';

/// Root FujiStudio session contract compatible with Desktop v2.4.2.
///
/// Every object level retains unrecognized keys in [unknownFields] and preserves
/// key presence, explicit `null` values, and numeric JSON types so that
/// Desktop-specific metadata survives Mobile round-trip edits without loss.
@immutable
final class SessionDocument {
  SessionDocument({
    required String schemaVersion,
    required String sessionId,
    required String createdAt,
    String? updatedAt,
    String? sourceApp,
    required List<SessionItem> items,
    List<ActionProposal> actionProposals = const <ActionProposal>[],
    List<CollageSpec> collages = const <CollageSpec>[],
    Map<String, Object?> unknownFields = const <String, Object?>{},
  }) : this._internal(
         schemaVersion: schemaVersion,
         sessionId: sessionId,
         createdAt: createdAt,
         updatedAt: updatedAt,
         sourceApp: sourceApp,
         items: items,
         actionProposals: actionProposals,
         collages: collages,
         unknownFields: unknownFields,
         presentKeys: null,
       );

  SessionDocument._internal({
    required this.schemaVersion,
    required this.sessionId,
    required this.createdAt,
    required this.updatedAt,
    required this.sourceApp,
    required List<SessionItem> items,
    required List<ActionProposal> actionProposals,
    required List<CollageSpec> collages,
    required Map<String, Object?> unknownFields,
    required Set<String>? presentKeys,
  }) : items = List<SessionItem>.unmodifiable(items),
       actionProposals = List<ActionProposal>.unmodifiable(actionProposals),
       collages = List<CollageSpec>.unmodifiable(collages),
       unknownFields = freezeUnknownFields(unknownFields),
       _presentKeys = freezePresentKeys(presentKeys);

  static const String expectedSchemaVersion = '2.4.2';

  static const Set<String> _knownKeys = <String>{
    'schema_version',
    'session_id',
    'created_at',
    'updated_at',
    'source_app',
    'items',
    'action_proposals',
    'collages',
  };

  final String schemaVersion;
  final String sessionId;
  final String createdAt;
  final String? updatedAt;
  final String? sourceApp;
  final List<SessionItem> items;
  final List<ActionProposal> actionProposals;
  final List<CollageSpec> collages;
  final Map<String, Object?> unknownFields;
  final Set<String>? _presentKeys;

  factory SessionDocument.fromJson(Map<String, Object?> json) {
    final schemaVersion = requireString(
      json,
      'schema_version',
      'SessionDocument',
    );
    if (schemaVersion != expectedSchemaVersion) {
      throw FormatException(
        'Unsupported schema_version "$schemaVersion" '
        '(expected $expectedSchemaVersion)',
      );
    }

    final rawItems = json['items'];
    if (rawItems is! List) {
      throw const FormatException(
        'Missing or invalid list "items" in SessionDocument',
      );
    }

    final rawProposals = json['action_proposals'];
    final parsedProposals = <ActionProposal>[];
    if (rawProposals != null) {
      if (rawProposals is! List) {
        throw const FormatException(
          'Invalid list "action_proposals" in SessionDocument',
        );
      }
      for (final entry in rawProposals) {
        parsedProposals.add(
          ActionProposal.fromJson(
            requireJsonObject(entry, 'SessionDocument.action_proposals'),
          ),
        );
      }
    }

    final rawCollages = json['collages'];
    final parsedCollages = <CollageSpec>[];
    if (rawCollages != null) {
      if (rawCollages is! List) {
        throw const FormatException(
          'Invalid list "collages" in SessionDocument',
        );
      }
      for (final entry in rawCollages) {
        parsedCollages.add(
          CollageSpec.fromJson(
            requireJsonObject(entry, 'SessionDocument.collages'),
          ),
        );
      }
    }

    return SessionDocument._internal(
      schemaVersion: schemaVersion,
      sessionId: requireString(json, 'session_id', 'SessionDocument'),
      createdAt: requireString(json, 'created_at', 'SessionDocument'),
      updatedAt: optionalString(json, 'updated_at', 'SessionDocument'),
      sourceApp: optionalString(json, 'source_app', 'SessionDocument'),
      items: rawItems
          .map(
            (e) => SessionItem.fromJson(
              requireJsonObject(e, 'SessionDocument.items'),
            ),
          )
          .toList(),
      actionProposals: parsedProposals,
      collages: parsedCollages,
      unknownFields: extractUnknownFields(json, _knownKeys),
      presentKeys: json.keys.toSet(),
    );
  }

  SessionDocument copyWith({
    String? schemaVersion,
    String? sessionId,
    String? createdAt,
    Object? updatedAt = schemaUnset,
    Object? sourceApp = schemaUnset,
    List<SessionItem>? items,
    List<ActionProposal>? actionProposals,
    List<CollageSpec>? collages,
    Map<String, Object?>? unknownFields,
  }) {
    final addedKeys = <String>[
      if (!identical(updatedAt, schemaUnset) && updatedAt != null) 'updated_at',
      if (!identical(sourceApp, schemaUnset) && sourceApp != null) 'source_app',
      if (actionProposals != null) 'action_proposals',
      if (collages != null) 'collages',
    ];

    return SessionDocument._internal(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      sessionId: sessionId ?? this.sessionId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: identical(updatedAt, schemaUnset)
          ? this.updatedAt
          : updatedAt as String?,
      sourceApp: identical(sourceApp, schemaUnset)
          ? this.sourceApp
          : sourceApp as String?,
      items: items ?? this.items,
      actionProposals: actionProposals ?? this.actionProposals,
      collages: collages ?? this.collages,
      unknownFields: unknownFields ?? this.unknownFields,
      presentKeys: updatePresentKeys(_presentKeys, addedKeys),
    );
  }

  Map<String, Object?> toJson() {
    final known = <String, Object?>{
      'schema_version': schemaVersion,
      'session_id': sessionId,
      'created_at': createdAt,
      if (shouldEmitNullableKey('updated_at', updatedAt, _presentKeys))
        'updated_at': updatedAt,
      if (shouldEmitNullableKey('source_app', sourceApp, _presentKeys))
        'source_app': sourceApp,
      'items': items.map((i) => i.toJson()).toList(),
      if (shouldEmitOptionalKey('action_proposals', _presentKeys) ||
          actionProposals.isNotEmpty)
        'action_proposals': actionProposals.map((p) => p.toJson()).toList(),
      if (shouldEmitOptionalKey('collages', _presentKeys) ||
          collages.isNotEmpty)
        'collages': collages.map((c) => c.toJson()).toList(),
    };
    return mergeWithUnknownFields(known, unknownFields);
  }
}
