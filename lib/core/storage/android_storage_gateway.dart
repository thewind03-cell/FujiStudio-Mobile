import 'package:flutter/services.dart';

import 'storage_gateway.dart';

/// Android Scoped Storage implementation of [StorageGateway] backed by
/// `MethodChannel('org.fujistudio.mobile/storage_gateway')`.
final class AndroidStorageGateway implements StorageGateway {
  AndroidStorageGateway({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'org.fujistudio.mobile/storage_gateway';

  final MethodChannel _channel;

  @override
  Future<StoragePermissionState> getPermissionState() async {
    final raw = await _channel.invokeMethod<String>('getPermissionState');
    return _parsePermissionState(raw);
  }

  @override
  Future<StoragePermissionState> requestReadPermission() async {
    final raw = await _channel.invokeMethod<String>('requestReadPermission');
    return _parsePermissionState(raw);
  }

  @override
  Future<List<MediaAlbumDescriptor>> listAlbums() async {
    final rawList = await _channel.invokeListMethod<Object?>('listAlbums');
    if (rawList == null) return const <MediaAlbumDescriptor>[];
    return rawList
        .whereType<Map<Object?, Object?>>()
        .map((m) {
          return MediaAlbumDescriptor(
            albumId: (m['albumId'] as String?) ?? '',
            name: (m['name'] as String?) ?? 'Album',
            count: (m['count'] as num?)?.toInt() ?? 0,
            coverUri: m['coverUri'] as String?,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<List<RawMediaFileDescriptor>> listMediaInAlbum({
    required String albumId,
    int limit = 200,
    int offset = 0,
  }) async {
    final rawList = await _channel.invokeListMethod<Object?>(
      'listMediaInAlbum',
      <String, Object?>{
        'albumId': albumId,
        'limit': limit,
        'offset': offset,
      },
    );
    if (rawList == null) return const <RawMediaFileDescriptor>[];
    return rawList
        .whereType<Map<Object?, Object?>>()
        .map((m) {
          return RawMediaFileDescriptor(
            mediaId: (m['mediaId'] as String?) ?? '',
            uri: (m['uri'] as String?) ?? '',
            displayName: (m['displayName'] as String?) ?? '',
            relativePath: (m['relativePath'] as String?) ?? '',
            mimeType: (m['mimeType'] as String?) ?? '',
            sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? 0,
            dateTakenMs: (m['dateTakenMs'] as num?)?.toInt(),
            dateModifiedSec: (m['dateModifiedSec'] as num?)?.toInt() ?? 0,
            width: (m['width'] as num?)?.toInt(),
            height: (m['height'] as num?)?.toInt(),
          );
        })
        .toList(growable: false);
  }

  @override
  Future<OpenedNativeFd?> openReadOnlyFd(String uri) async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'openReadOnlyFd',
      <String, Object?>{'uri': uri},
    );
    if (raw == null) return null;
    final handleId = raw['handleId'] as String?;
    final fd = (raw['fd'] as num?)?.toInt();
    final sizeBytes = (raw['sizeBytes'] as num?)?.toInt() ?? 0;
    if (handleId == null || fd == null || fd < 0) return null;
    return OpenedNativeFd(
      handleId: handleId,
      fd: fd,
      sizeBytes: sizeBytes,
    );
  }

  @override
  Future<void> closeFd(String handleId) async {
    await _channel.invokeMethod<void>(
      'closeFd',
      <String, Object?>{'handleId': handleId},
    );
  }

  @override
  Future<ProxyDecodeResult> decodeToProxyJpeg({
    required String source,
    required bool isContentUri,
    required String outJpegPath,
    int maxLongEdge = 1600,
    int? orientationOverride,
  }) async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'decodeToProxyJpeg',
      <String, Object?>{
        'source': source,
        'isContentUri': isContentUri,
        'outJpegPath': outJpegPath,
        'maxLongEdge': maxLongEdge,
        'orientationOverride': ?orientationOverride,
      },
    );
    if (raw == null) {
      throw StateError('decodeToProxyJpeg returned null for $source');
    }
    return ProxyDecodeResult(
      width: (raw['width'] as num?)?.toInt() ?? 0,
      height: (raw['height'] as num?)?.toInt() ?? 0,
      byteSize: (raw['byteSize'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<String> getProxyCacheDirectory() async {
    final dir = await _channel.invokeMethod<String>('getProxyCacheDirectory');
    if (dir == null || dir.isEmpty) {
      throw StateError('getProxyCacheDirectory returned empty path');
    }
    return dir;
  }

  @override
  Future<String> getSessionStorageDirectory() async {
    final dir = await _channel.invokeMethod<String>(
      'getSessionStorageDirectory',
    );
    if (dir == null || dir.isEmpty) {
      throw StateError('getSessionStorageDirectory returned empty path');
    }
    return dir;
  }

  static StoragePermissionState _parsePermissionState(String? raw) {
    return switch (raw) {
      'granted' => StoragePermissionState.granted,
      'limited' => StoragePermissionState.limited,
      _ => StoragePermissionState.denied,
    };
  }
}
