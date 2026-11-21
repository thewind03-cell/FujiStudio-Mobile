import 'package:flutter/foundation.dart';

import 'storage_gateway.dart';

/// Pairing classification for a shot in a camera folder.
enum AssetPairKind { jpgPlusRaf, rafOnly, jpgOnly }

/// Represents a paired (or standalone) photo asset in an album.
@immutable
final class PairedAsset {
  const PairedAsset({
    required this.pairKey,
    required this.stem,
    required this.normalizedDir,
    required this.kind,
    required this.primaryAsset,
    this.rafCompanion,
    required this.capturedAtMs,
  });

  final String pairKey;
  final String stem;
  final String normalizedDir;
  final AssetPairKind kind;
  final RawMediaFileDescriptor primaryAsset;
  final RawMediaFileDescriptor? rafCompanion;
  final int capturedAtMs;

  String get displayName => primaryAsset.displayName;
  int? get width => primaryAsset.width;
  int? get height => primaryAsset.height;
  bool get hasRaw => kind != AssetPairKind.jpgOnly;
}

/// Pure Dart engine that pairs `.JPG`/`.JPEG` and `.RAF` files belonging to the
/// same shutter capture and sorts them deterministically.
final class AssetPairingEngine {
  const AssetPairingEngine();

  static const Set<String> _jpegExtensions = <String>{'jpg', 'jpeg'};
  static const String _rafExtension = 'raf';

  /// Normalizes a relative directory path into a canonical lowercase key.
  static String normalizeDir(String relativePath) {
    return relativePath
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '')
        .toLowerCase();
  }

  /// Pairs [files] into [PairedAsset] entries sorted by `capturedAtMs DESC`
  /// then `stem ASC`.
  List<PairedAsset> pairAssets(List<RawMediaFileDescriptor> files) {
    final buckets = <String, _PairBucket>{};

    for (final file in files) {
      final parsed = _splitName(file.displayName);
      if (parsed == null) continue;
      final (stem, ext) = parsed;

      final isJpeg = _jpegExtensions.contains(ext);
      final isRaf = ext == _rafExtension;
      if (!isJpeg && !isRaf) continue;

      final normalizedDir = normalizeDir(file.relativePath);
      final pairKey = '$normalizedDir|${stem.toLowerCase()}';
      final bucket = buckets.putIfAbsent(
        pairKey,
        () => _PairBucket(
          pairKey: pairKey,
          stem: stem,
          normalizedDir: normalizedDir,
        ),
      );

      if (isJpeg) {
        if (bucket.jpeg == null || _isPreferred(file, bucket.jpeg!)) {
          bucket.jpeg = file;
        }
      } else {
        if (bucket.raf == null || _isPreferred(file, bucket.raf!)) {
          bucket.raf = file;
        }
      }
    }

    final result = <PairedAsset>[];
    for (final bucket in buckets.values) {
      final jpeg = bucket.jpeg;
      final raf = bucket.raf;
      if (jpeg != null && raf != null) {
        result.add(
          PairedAsset(
            pairKey: bucket.pairKey,
            stem: bucket.stem,
            normalizedDir: bucket.normalizedDir,
            kind: AssetPairKind.jpgPlusRaf,
            primaryAsset: jpeg,
            rafCompanion: raf,
            capturedAtMs: _resolveCapturedAtMs(jpeg),
          ),
        );
      } else if (jpeg != null) {
        result.add(
          PairedAsset(
            pairKey: bucket.pairKey,
            stem: bucket.stem,
            normalizedDir: bucket.normalizedDir,
            kind: AssetPairKind.jpgOnly,
            primaryAsset: jpeg,
            rafCompanion: null,
            capturedAtMs: _resolveCapturedAtMs(jpeg),
          ),
        );
      } else if (raf != null) {
        result.add(
          PairedAsset(
            pairKey: bucket.pairKey,
            stem: bucket.stem,
            normalizedDir: bucket.normalizedDir,
            kind: AssetPairKind.rafOnly,
            primaryAsset: raf,
            rafCompanion: null,
            capturedAtMs: _resolveCapturedAtMs(raf),
          ),
        );
      }
    }

    result.sort((a, b) {
      final timeCmp = b.capturedAtMs.compareTo(a.capturedAtMs);
      if (timeCmp != 0) return timeCmp;
      final stemLowerCmp = a.stem.toLowerCase().compareTo(b.stem.toLowerCase());
      if (stemLowerCmp != 0) return stemLowerCmp;
      return a.stem.compareTo(b.stem);
    });

    return List<PairedAsset>.unmodifiable(result);
  }

  static (String, String)? _splitName(String displayName) {
    final trimmed = displayName.trim();
    final dot = trimmed.lastIndexOf('.');
    if (dot <= 0 || dot >= trimmed.length - 1) {
      return null;
    }
    return (
      trimmed.substring(0, dot),
      trimmed.substring(dot + 1).toLowerCase(),
    );
  }

  static bool _isPreferred(
    RawMediaFileDescriptor candidate,
    RawMediaFileDescriptor existing,
  ) {
    if (candidate.sizeBytes != existing.sizeBytes) {
      return candidate.sizeBytes > existing.sizeBytes;
    }
    return candidate.dateModifiedSec > existing.dateModifiedSec;
  }

  static int _resolveCapturedAtMs(RawMediaFileDescriptor asset) {
    return asset.dateTakenMs ?? (asset.dateModifiedSec * 1000);
  }
}

final class _PairBucket {
  _PairBucket({
    required this.pairKey,
    required this.stem,
    required this.normalizedDir,
  });

  final String pairKey;
  final String stem;
  final String normalizedDir;
  RawMediaFileDescriptor? jpeg;
  RawMediaFileDescriptor? raf;
}
