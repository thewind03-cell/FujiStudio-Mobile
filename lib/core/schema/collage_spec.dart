import 'package:flutter/foundation.dart';

import 'schema_utils.dart';

/// Placement of a single [SessionItem] within a [CollageSpec].
@immutable
final class CollageSlot {
  CollageSlot({
    required int slotIndex,
    required String itemId,
    double panX = 0.0,
    double panY = 0.0,
    double zoom = 1.0,
    Map<String, Object?> unknownFields = const <String, Object?>{},
  }) : this._internal(
         slotIndex: slotIndex,
         itemId: itemId,
         panX: panX,
         panY: panY,
         zoom: zoom,
         unknownFields: unknownFields,
         presentKeys: null,
         intValuedFields: const <String>{},
       );

  CollageSlot._internal({
    required this.slotIndex,
    required this.itemId,
    required this.panX,
    required this.panY,
    required this.zoom,
    required Map<String, Object?> unknownFields,
    required Set<String>? presentKeys,
    required Set<String> intValuedFields,
  }) : unknownFields = freezeUnknownFields(unknownFields),
       _presentKeys = freezePresentKeys(presentKeys),
       _intValuedFields = freezeIntValuedFields(intValuedFields);

  static const Set<String> _knownKeys = <String>{
    'slot_index',
    'item_id',
    'pan_x',
    'pan_y',
    'zoom',
  };

  static const Set<String> _doubleKeys = <String>{
    'pan_x',
    'pan_y',
    'zoom',
  };

  final int slotIndex;
  final String itemId;
  final double panX;
  final double panY;
  final double zoom;
  final Map<String, Object?> unknownFields;
  final Set<String>? _presentKeys;
  final Set<String> _intValuedFields;

  factory CollageSlot.fromJson(Map<String, Object?> json) {
    return CollageSlot._internal(
      slotIndex: requireInt(json, 'slot_index', 'CollageSlot'),
      itemId: requireString(json, 'item_id', 'CollageSlot'),
      panX: optionalDouble(json, 'pan_x', 'CollageSlot') ?? 0.0,
      panY: optionalDouble(json, 'pan_y', 'CollageSlot') ?? 0.0,
      zoom: optionalDouble(json, 'zoom', 'CollageSlot') ?? 1.0,
      unknownFields: extractUnknownFields(json, _knownKeys),
      presentKeys: json.keys.toSet(),
      intValuedFields: extractIntValuedFields(json, _doubleKeys),
    );
  }

  CollageSlot copyWith({
    int? slotIndex,
    String? itemId,
    double? panX,
    double? panY,
    double? zoom,
    Map<String, Object?>? unknownFields,
  }) {
    final addedKeys = <String>[
      if (panX != null) 'pan_x',
      if (panY != null) 'pan_y',
      if (zoom != null) 'zoom',
    ];
    final clearedInts = <String>[
      if (panX != null) 'pan_x',
      if (panY != null) 'pan_y',
      if (zoom != null) 'zoom',
    ];

    return CollageSlot._internal(
      slotIndex: slotIndex ?? this.slotIndex,
      itemId: itemId ?? this.itemId,
      panX: panX ?? this.panX,
      panY: panY ?? this.panY,
      zoom: zoom ?? this.zoom,
      unknownFields: unknownFields ?? this.unknownFields,
      presentKeys: updatePresentKeys(_presentKeys, addedKeys),
      intValuedFields: clearIntValuedFields(_intValuedFields, clearedInts),
    );
  }

  Map<String, Object?> toJson() {
    final known = <String, Object?>{
      'slot_index': slotIndex,
      'item_id': itemId,
      if (shouldEmitOptionalKey('pan_x', _presentKeys))
        'pan_x': encodePreservedNumber('pan_x', panX, _intValuedFields),
      if (shouldEmitOptionalKey('pan_y', _presentKeys))
        'pan_y': encodePreservedNumber('pan_y', panY, _intValuedFields),
      if (shouldEmitOptionalKey('zoom', _presentKeys))
        'zoom': encodePreservedNumber('zoom', zoom, _intValuedFields),
    };
    return mergeWithUnknownFields(known, unknownFields);
  }
}

/// Story/Diptych collage layout specification compatible with Desktop v2.4.2.
@immutable
final class CollageSpec {
  CollageSpec({
    required String collageId,
    required String templateId,
    required String aspectRatio,
    String backgroundHex = '#000000',
    int spacingPx = 0,
    required List<CollageSlot> slots,
    Map<String, Object?> unknownFields = const <String, Object?>{},
  }) : this._internal(
         collageId: collageId,
         templateId: templateId,
         aspectRatio: aspectRatio,
         backgroundHex: backgroundHex,
         spacingPx: spacingPx,
         slots: slots,
         unknownFields: unknownFields,
         presentKeys: null,
       );

  CollageSpec._internal({
    required this.collageId,
    required this.templateId,
    required this.aspectRatio,
    required this.backgroundHex,
    required this.spacingPx,
    required List<CollageSlot> slots,
    required Map<String, Object?> unknownFields,
    required Set<String>? presentKeys,
  }) : slots = List<CollageSlot>.unmodifiable(slots),
       unknownFields = freezeUnknownFields(unknownFields),
       _presentKeys = freezePresentKeys(presentKeys);

  static const Set<String> _knownKeys = <String>{
    'collage_id',
    'template_id',
    'aspect_ratio',
    'background_hex',
    'spacing_px',
    'slots',
  };

  final String collageId;
  final String templateId;
  final String aspectRatio;
  final String backgroundHex;
  final int spacingPx;
  final List<CollageSlot> slots;
  final Map<String, Object?> unknownFields;
  final Set<String>? _presentKeys;

  factory CollageSpec.fromJson(Map<String, Object?> json) {
    final rawSlots = json['slots'];
    if (rawSlots is! List) {
      throw const FormatException(
        'Missing or invalid list "slots" in CollageSpec',
      );
    }
    final parsedSlots = rawSlots
        .map(
          (e) =>
              CollageSlot.fromJson(requireJsonObject(e, 'CollageSpec.slots')),
        )
        .toList();

    return CollageSpec._internal(
      collageId: requireString(json, 'collage_id', 'CollageSpec'),
      templateId: requireString(json, 'template_id', 'CollageSpec'),
      aspectRatio: requireString(json, 'aspect_ratio', 'CollageSpec'),
      backgroundHex:
          optionalString(json, 'background_hex', 'CollageSpec') ?? '#000000',
      spacingPx: optionalInt(json, 'spacing_px', 'CollageSpec') ?? 0,
      slots: parsedSlots,
      unknownFields: extractUnknownFields(json, _knownKeys),
      presentKeys: json.keys.toSet(),
    );
  }

  CollageSpec copyWith({
    String? collageId,
    String? templateId,
    String? aspectRatio,
    String? backgroundHex,
    int? spacingPx,
    List<CollageSlot>? slots,
    Map<String, Object?>? unknownFields,
  }) {
    final addedKeys = <String>[
      if (backgroundHex != null) 'background_hex',
      if (spacingPx != null) 'spacing_px',
    ];

    return CollageSpec._internal(
      collageId: collageId ?? this.collageId,
      templateId: templateId ?? this.templateId,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      backgroundHex: backgroundHex ?? this.backgroundHex,
      spacingPx: spacingPx ?? this.spacingPx,
      slots: slots ?? this.slots,
      unknownFields: unknownFields ?? this.unknownFields,
      presentKeys: updatePresentKeys(_presentKeys, addedKeys),
    );
  }

  Map<String, Object?> toJson() {
    final known = <String, Object?>{
      'collage_id': collageId,
      'template_id': templateId,
      'aspect_ratio': aspectRatio,
      if (shouldEmitOptionalKey('background_hex', _presentKeys))
        'background_hex': backgroundHex,
      if (shouldEmitOptionalKey('spacing_px', _presentKeys))
        'spacing_px': spacingPx,
      'slots': slots.map((s) => s.toJson()).toList(),
    };
    return mergeWithUnknownFields(known, unknownFields);
  }
}
