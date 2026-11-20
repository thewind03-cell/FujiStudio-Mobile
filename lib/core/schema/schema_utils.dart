/// Internal immutability and JSON serialization utilities shared across
/// FujiStudio Mobile v2.4.2 schema models.
library;

/// Shared sentinel used by `copyWith` methods to distinguish an omitted
/// argument from an explicit `null` assignment on nullable fields.
const Object schemaUnset = Object();

/// Recursively clones and freezes any JSON-compatible value so that
/// [unknownFields] and nested maps/lists remain strictly immutable and
/// preserve their exact Dart runtime types (`int`, `double`, `bool`, `String`,
/// `null`, `List`, `Map`).
Object? deepFreezeJsonValue(Object? value) {
  if (value is Map) {
    final frozen = <String, Object?>{};
    for (final entry in value.entries) {
      frozen[entry.key.toString()] = deepFreezeJsonValue(entry.value);
    }
    return Map<String, Object?>.unmodifiable(frozen);
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(deepFreezeJsonValue));
  }
  return value;
}

/// Recursively clones frozen JSON structures back into plain mutable maps/lists
/// suitable for `jsonEncode` or downstream mutation without touching the model.
Object? deepUnfreezeJsonValue(Object? value) {
  if (value is Map) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      result[entry.key.toString()] = deepUnfreezeJsonValue(entry.value);
    }
    return result;
  }
  if (value is List) {
    return value.map(deepUnfreezeJsonValue).toList();
  }
  return value;
}

/// Extracts every key from [json] that is not in [knownKeys] and returns an
/// unmodifiable, deeply frozen map preserving exact values and types.
Map<String, Object?> extractUnknownFields(
  Map<String, Object?> json,
  Set<String> knownKeys,
) {
  final unknown = <String, Object?>{};
  for (final entry in json.entries) {
    if (!knownKeys.contains(entry.key)) {
      unknown[entry.key] = deepFreezeJsonValue(entry.value);
    }
  }
  return Map<String, Object?>.unmodifiable(unknown);
}

/// Freezes a caller-supplied [unknownFields] map.
Map<String, Object?> freezeUnknownFields(Map<String, Object?> unknownFields) {
  if (unknownFields.isEmpty) {
    return const <String, Object?>{};
  }
  final frozen = <String, Object?>{};
  for (final entry in unknownFields.entries) {
    frozen[entry.key] = deepFreezeJsonValue(entry.value);
  }
  return Map<String, Object?>.unmodifiable(frozen);
}

/// Freezes the set of JSON keys originally present on an object.
Set<String>? freezePresentKeys(Set<String>? keys) {
  if (keys == null) return null;
  return Set<String>.unmodifiable(keys);
}

/// Records which keys among [doubleKeys] had an `int` runtime value in [json]
/// so round-trip serialization preserves exact JSON integer types.
Set<String> extractIntValuedFields(
  Map<String, Object?> json,
  Set<String> doubleKeys,
) {
  final intKeys = <String>{};
  for (final key in doubleKeys) {
    if (json[key] is int) {
      intKeys.add(key);
    }
  }
  return intKeys.isEmpty
      ? const <String>{}
      : Set<String>.unmodifiable(intKeys);
}

/// Freezes a set of integer-valued double field keys.
Set<String> freezeIntValuedFields(Set<String> keys) {
  if (keys.isEmpty) return const <String>{};
  return Set<String>.unmodifiable(keys);
}

/// Returns an updated `_presentKeys` set after `copyWith` modifies [addedKeys].
/// Returns `null` when the model was created via Dart constructor (not JSON).
Set<String>? updatePresentKeys(
  Set<String>? current,
  Iterable<String> addedKeys,
) {
  if (current == null) return null;
  final next = Set<String>.of(current)..addAll(addedKeys);
  return Set<String>.unmodifiable(next);
}

/// Returns an updated `_intValuedFields` set with [clearedKeys] removed because
/// those fields were explicitly reassigned via `copyWith`.
Set<String> clearIntValuedFields(
  Set<String> current,
  Iterable<String> clearedKeys,
) {
  if (current.isEmpty) return const <String>{};
  final next = Set<String>.of(current)..removeAll(clearedKeys);
  return next.isEmpty ? const <String>{} : Set<String>.unmodifiable(next);
}

/// Encodes a Dart [double] field back to `int` when its original JSON type was
/// `int` and it has not been replaced by a fractional value.
num encodePreservedNumber(
  String key,
  double value,
  Set<String> intValuedFields,
) {
  if (intValuedFields.contains(key) && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return value;
}

/// Returns whether an optional field with a default value should be emitted in
/// `toJson()`. Models constructed in Dart (`presentKeys == null`) emit it;
/// models parsed from JSON emit it only if present originally or updated.
bool shouldEmitOptionalKey(String key, Set<String>? presentKeys) {
  return presentKeys == null || presentKeys.contains(key);
}

/// Returns whether a nullable field should be emitted in `toJson()`.
/// Non-null values are always emitted; `null` values are preserved when the
/// key was explicitly present in the source JSON.
bool shouldEmitNullableKey(
  String key,
  Object? value,
  Set<String>? presentKeys,
) {
  if (value != null) return true;
  return presentKeys != null && presentKeys.contains(key);
}

/// Merges [unknownFields] with [knownFields], ensuring unknown keys are
/// emitted verbatim alongside updated known fields.
Map<String, Object?> mergeWithUnknownFields(
  Map<String, Object?> knownFields,
  Map<String, Object?> unknownFields,
) {
  final out = <String, Object?>{};
  for (final entry in unknownFields.entries) {
    out[entry.key] = deepUnfreezeJsonValue(entry.value);
  }
  out.addAll(knownFields);
  return out;
}

/// Safely casts a dynamic JSON map to `Map<String, Object?>`.
Map<String, Object?> requireJsonObject(Object? raw, String contextName) {
  if (raw is Map<String, Object?>) {
    return raw;
  }
  if (raw is Map) {
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }
  throw FormatException('Expected JSON object for $contextName');
}

/// Safely reads a required non-null String field.
String requireString(Map<String, Object?> json, String key, String context) {
  final value = json[key];
  if (value is String) {
    return value;
  }
  throw FormatException('Missing or invalid string "$key" in $context');
}

/// Safely reads an optional String field.
String? optionalString(Map<String, Object?> json, String key, String context) {
  final value = json[key];
  if (value == null) return null;
  if (value is String) return value;
  throw FormatException('Invalid string "$key" in $context');
}

/// Safely reads a required num as double.
double requireDouble(Map<String, Object?> json, String key, String context) {
  final value = json[key];
  if (value is num) {
    return value.toDouble();
  }
  throw FormatException('Missing or invalid number "$key" in $context');
}

/// Safely reads an optional num as double.
double? optionalDouble(Map<String, Object?> json, String key, String context) {
  final value = json[key];
  if (value == null) return null;
  if (value is num) return value.toDouble();
  throw FormatException('Invalid number "$key" in $context');
}

/// Safely reads a required int.
int requireInt(Map<String, Object?> json, String key, String context) {
  final value = json[key];
  if (value is int) {
    return value;
  }
  throw FormatException('Missing or invalid integer "$key" in $context');
}

/// Safely reads an optional int.
int? optionalInt(Map<String, Object?> json, String key, String context) {
  final value = json[key];
  if (value == null) return null;
  if (value is int) return value;
  throw FormatException('Invalid integer "$key" in $context');
}

/// Safely reads a required bool.
bool requireBool(Map<String, Object?> json, String key, String context) {
  final value = json[key];
  if (value is bool) {
    return value;
  }
  throw FormatException('Missing or invalid bool "$key" in $context');
}

/// Safely reads an optional bool with a default fallback.
bool optionalBool(
  Map<String, Object?> json,
  String key,
  String context, {
  required bool defaultValue,
}) {
  final value = json[key];
  if (value == null) return defaultValue;
  if (value is bool) return value;
  throw FormatException('Invalid bool "$key" in $context');
}
