import 'package:flutter/foundation.dart';

/// Platform-agnostic descriptor for a photo asset accessible through
/// Android Scoped Storage (MediaStore) or iOS PhotoKit.
@immutable
final class MediaAssetDescriptor {
  const MediaAssetDescriptor({
    required this.uri,
    required this.displayName,
    required this.mimeType,
    this.width,
    this.height,
    this.capturedAt,
  });

  /// Platform URI (`content://...` on Android MediaStore, `ph://...` on iOS).
  final String uri;
  final String displayName;
  final String mimeType;
  final int? width;
  final int? height;
  final DateTime? capturedAt;
}

/// Abstract storage contract decoupling FujiStudio Mobile's core pipeline from
/// platform media APIs (Android MediaStore Scoped Storage / iOS PhotoKit).
///
/// Slice 0 locks the interface only; concrete platform implementations belong
/// to subsequent slices.
abstract interface class StorageGateway {
  /// Returns `true` if read permission for user images is currently granted.
  Future<bool> hasReadPermission();

  /// Requests platform-appropriate scoped read permission for images.
  Future<bool> requestReadPermission();

  /// Lists readable image asset descriptors from the platform gallery.
  Future<List<MediaAssetDescriptor>> listImageAssets({
    int limit = 100,
    int offset = 0,
  });

  /// Reads raw encoded bytes for the given platform asset [uri].
  Future<Uint8List> readAssetBytes(String uri);

  /// Persists an exported image into the platform gallery via Scoped Storage
  /// / PhotoKit and returns the newly created asset URI.
  Future<String> saveExportedImage({
    required Uint8List bytes,
    required String displayName,
    required String mimeType,
    String? relativeAlbum,
  });
}
