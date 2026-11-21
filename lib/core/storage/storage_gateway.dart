import 'package:flutter/foundation.dart';

/// Platform-agnostic gallery read permission state.
enum StoragePermissionState { granted, limited, denied }

/// Represents an open read-only native file descriptor managed by the host
/// platform (e.g., Android [ParcelFileDescriptor]).
///
/// Callers MUST release [handleId] via [StorageGateway.closeFd] in a `finally`
/// block and MUST NOT close [fd] directly from C++.
@immutable
final class OpenedNativeFd {
  const OpenedNativeFd({
    required this.handleId,
    required this.fd,
    required this.sizeBytes,
  });

  final String handleId;
  final int fd;
  final int sizeBytes;
}

/// Result of platform-accelerated subsampled JPEG proxy decoding.
@immutable
final class ProxyDecodeResult {
  const ProxyDecodeResult({
    required this.width,
    required this.height,
    required this.byteSize,
  });

  final int width;
  final int height;
  final int byteSize;
}

/// Platform-agnostic album/bucket descriptor returned by [StorageGateway].
@immutable
final class MediaAlbumDescriptor {
  const MediaAlbumDescriptor({
    required this.albumId,
    required this.name,
    required this.count,
    this.coverUri,
  });

  final String albumId;
  final String name;
  final int count;
  final String? coverUri;
}

/// Platform-agnostic media file descriptor returned by [StorageGateway].
@immutable
final class RawMediaFileDescriptor {
  const RawMediaFileDescriptor({
    required this.mediaId,
    required this.uri,
    required this.displayName,
    required this.relativePath,
    required this.mimeType,
    required this.sizeBytes,
    required this.dateTakenMs,
    required this.dateModifiedSec,
    this.width,
    this.height,
  });

  final String mediaId;
  final String uri;
  final String displayName;
  final String relativePath;
  final String mimeType;
  final int sizeBytes;
  final int? dateTakenMs;
  final int dateModifiedSec;
  final int? width;
  final int? height;
}

/// Platform-neutral storage gateway decoupling FujiStudio Mobile's core
/// pipeline from Android Scoped Storage (MediaStore) and iOS PhotoKit.
abstract interface class StorageGateway {
  Future<StoragePermissionState> getPermissionState();

  Future<StoragePermissionState> requestReadPermission();

  Future<List<MediaAlbumDescriptor>> listAlbums();

  Future<List<RawMediaFileDescriptor>> listMediaInAlbum({
    required String albumId,
    int limit = 200,
    int offset = 0,
  });

  Future<OpenedNativeFd?> openReadOnlyFd(String uri);

  Future<void> closeFd(String handleId);

  Future<ProxyDecodeResult> decodeToProxyJpeg({
    required String source,
    required bool isContentUri,
    required String outJpegPath,
    int maxLongEdge = 1600,
    int? orientationOverride,
  });

  Future<String> getProxyCacheDirectory();

  Future<String> getSessionStorageDirectory();
}
