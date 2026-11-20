import 'package:flutter/foundation.dart';

import 'cull_result.dart';
import 'edit_recipe.dart';
import 'schema_utils.dart';

/// A single photo entry inside a [SessionDocument], preserving all unknown
/// Desktop v2.4.2 metadata (e.g. `histogram_bins`, `xmp_sidecar_hash`).
@immutable
final class SessionItem {
  SessionItem({
    required String id,
    required String fileName,
    String? mediaUri,
    String? filmSimulation,
    String? capturedAt,
    int? width,
    int? height,
    bool isRawPaired = false,
    int rating = 0,
    CullResult? cullResult,
    required EditRecipe editRecipe,
    Map<String, Object?> unknownFields = const <String, Object?>{},
  }) : this._internal(
         id: id,
         fileName: fileName,
         mediaUri: mediaUri,
         filmSimulation: filmSimulation,
         capturedAt: capturedAt,
         width: width,
         height: height,
         isRawPaired: isRawPaired,
         rating: rating,
         cullResult: cullResult,
         editRecipe: editRecipe,
         unknownFields: unknownFields,
         presentKeys: null,
       );

  SessionItem._internal({
    required this.id,
    required this.fileName,
    required this.mediaUri,
    required this.filmSimulation,
    required this.capturedAt,
    required this.width,
    required this.height,
    required this.isRawPaired,
    required this.rating,
    required this.cullResult,
    required this.editRecipe,
    required Map<String, Object?> unknownFields,
    required Set<String>? presentKeys,
  }) : unknownFields = freezeUnknownFields(unknownFields),
       _presentKeys = freezePresentKeys(presentKeys);

  static const Set<String> _knownKeys = <String>{
    'id',
    'file_name',
    'media_uri',
    'film_simulation',
    'captured_at',
    'width',
    'height',
    'is_raw_paired',
    'rating',
    'cull_result',
    'edit_recipe',
  };

  final String id;
  final String fileName;
  final String? mediaUri;
  final String? filmSimulation;
  final String? capturedAt;
  final int? width;
  final int? height;
  final bool isRawPaired;
  final int rating;
  final CullResult? cullResult;
  final EditRecipe editRecipe;
  final Map<String, Object?> unknownFields;
  final Set<String>? _presentKeys;

  factory SessionItem.fromJson(Map<String, Object?> json) {
    final rawCull = json['cull_result'];
    return SessionItem._internal(
      id: requireString(json, 'id', 'SessionItem'),
      fileName: requireString(json, 'file_name', 'SessionItem'),
      mediaUri: optionalString(json, 'media_uri', 'SessionItem'),
      filmSimulation: optionalString(json, 'film_simulation', 'SessionItem'),
      capturedAt: optionalString(json, 'captured_at', 'SessionItem'),
      width: optionalInt(json, 'width', 'SessionItem'),
      height: optionalInt(json, 'height', 'SessionItem'),
      isRawPaired: optionalBool(
        json,
        'is_raw_paired',
        'SessionItem',
        defaultValue: false,
      ),
      rating: optionalInt(json, 'rating', 'SessionItem') ?? 0,
      cullResult: rawCull == null
          ? null
          : CullResult.fromJson(
              requireJsonObject(rawCull, 'SessionItem.cull_result'),
            ),
      editRecipe: EditRecipe.fromJson(
        requireJsonObject(json['edit_recipe'], 'SessionItem.edit_recipe'),
      ),
      unknownFields: extractUnknownFields(json, _knownKeys),
      presentKeys: json.keys.toSet(),
    );
  }

  SessionItem copyWith({
    String? id,
    String? fileName,
    Object? mediaUri = schemaUnset,
    Object? filmSimulation = schemaUnset,
    Object? capturedAt = schemaUnset,
    Object? width = schemaUnset,
    Object? height = schemaUnset,
    bool? isRawPaired,
    int? rating,
    Object? cullResult = schemaUnset,
    EditRecipe? editRecipe,
    Map<String, Object?>? unknownFields,
  }) {
    final addedKeys = <String>[
      if (!identical(mediaUri, schemaUnset) && mediaUri != null) 'media_uri',
      if (!identical(filmSimulation, schemaUnset) && filmSimulation != null)
        'film_simulation',
      if (!identical(capturedAt, schemaUnset) && capturedAt != null)
        'captured_at',
      if (!identical(width, schemaUnset) && width != null) 'width',
      if (!identical(height, schemaUnset) && height != null) 'height',
      if (isRawPaired != null) 'is_raw_paired',
      if (rating != null) 'rating',
      if (!identical(cullResult, schemaUnset) && cullResult != null)
        'cull_result',
    ];

    return SessionItem._internal(
      id: id ?? this.id,
      fileName: fileName ?? this.fileName,
      mediaUri: identical(mediaUri, schemaUnset)
          ? this.mediaUri
          : mediaUri as String?,
      filmSimulation: identical(filmSimulation, schemaUnset)
          ? this.filmSimulation
          : filmSimulation as String?,
      capturedAt: identical(capturedAt, schemaUnset)
          ? this.capturedAt
          : capturedAt as String?,
      width: identical(width, schemaUnset) ? this.width : width as int?,
      height: identical(height, schemaUnset) ? this.height : height as int?,
      isRawPaired: isRawPaired ?? this.isRawPaired,
      rating: rating ?? this.rating,
      cullResult: identical(cullResult, schemaUnset)
          ? this.cullResult
          : cullResult as CullResult?,
      editRecipe: editRecipe ?? this.editRecipe,
      unknownFields: unknownFields ?? this.unknownFields,
      presentKeys: updatePresentKeys(_presentKeys, addedKeys),
    );
  }

  Map<String, Object?> toJson() {
    final known = <String, Object?>{
      'id': id,
      'file_name': fileName,
      if (shouldEmitNullableKey('media_uri', mediaUri, _presentKeys))
        'media_uri': mediaUri,
      if (shouldEmitNullableKey('film_simulation', filmSimulation, _presentKeys))
        'film_simulation': filmSimulation,
      if (shouldEmitNullableKey('captured_at', capturedAt, _presentKeys))
        'captured_at': capturedAt,
      if (shouldEmitNullableKey('width', width, _presentKeys)) 'width': width,
      if (shouldEmitNullableKey('height', height, _presentKeys))
        'height': height,
      if (shouldEmitOptionalKey('is_raw_paired', _presentKeys))
        'is_raw_paired': isRawPaired,
      if (shouldEmitOptionalKey('rating', _presentKeys)) 'rating': rating,
      if (shouldEmitNullableKey('cull_result', cullResult, _presentKeys))
        'cull_result': cullResult?.toJson(),
      'edit_recipe': editRecipe.toJson(),
    };
    return mergeWithUnknownFields(known, unknownFields);
  }
}
