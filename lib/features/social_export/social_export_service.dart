import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/ffi/native_worker.dart';
import '../../core/schema/collage_spec.dart';
import '../../core/schema/edit_recipe.dart';
import '../../core/schema/session_item.dart';
import '../../core/storage/asset_pairing_engine.dart';
import '../../core/storage/storage_gateway.dart';
import '../session_picker/session_controller.dart';
import '../story_collage/collage_mapper.dart';
import '../studio_editor/dna_rescue_mapper.dart';
import '../studio_editor/geometry_mapper.dart';
import 'export_mapper.dart';
import 'mobile_export_log_store.dart';

/// Abstraction over [NativeWorker] export calls for deterministic testing.
abstract interface class SocialExportNativePipeline {
  Future<RafExtractionResult> extractRafPreviewFromFd({
    required int fd,
    required String outJpegPath,
  });

  Future<RafExtractionResult> extractRafPreviewFromPath({
    required String rafPath,
    required String outJpegPath,
  });

  Future<ExportRgbaResult> runExportPipelineOnRawFile({
    required String rawInputPath,
    required int srcWidth,
    required int srcHeight,
    required String rawOutputPath,
    required DnaRescueNativeParams? dnaRescue,
    required GeometryNativeParams? geometry,
    required int targetMaxLongEdge,
    required OutputUsmNativeParams? outputUsm,
  });

  Future<ExportRgbaResult> renderCollageToRawFile({
    required List<CollageRawFileSlot> slots,
    required CollageNativeConfig config,
    required OutputUsmNativeParams? outputUsm,
    required String rawOutputPath,
  });
}

/// Production [SocialExportNativePipeline] backed by [NativeWorker].
final class NativeWorkerSocialExportPipeline
    implements SocialExportNativePipeline {
  const NativeWorkerSocialExportPipeline(this._worker);

  final NativeWorker _worker;

  @override
  Future<RafExtractionResult> extractRafPreviewFromFd({
    required int fd,
    required String outJpegPath,
  }) {
    return _worker.extractRafPreviewFromFd(fd: fd, outJpegPath: outJpegPath);
  }

  @override
  Future<RafExtractionResult> extractRafPreviewFromPath({
    required String rafPath,
    required String outJpegPath,
  }) {
    return _worker.extractRafPreviewFromPath(
      rafPath: rafPath,
      outJpegPath: outJpegPath,
    );
  }

  @override
  Future<ExportRgbaResult> runExportPipelineOnRawFile({
    required String rawInputPath,
    required int srcWidth,
    required int srcHeight,
    required String rawOutputPath,
    required DnaRescueNativeParams? dnaRescue,
    required GeometryNativeParams? geometry,
    required int targetMaxLongEdge,
    required OutputUsmNativeParams? outputUsm,
  }) {
    return _worker.runExportPipelineOnRawFile(
      rawInputPath: rawInputPath,
      srcWidth: srcWidth,
      srcHeight: srcHeight,
      rawOutputPath: rawOutputPath,
      dnaRescue: dnaRescue,
      geometry: geometry,
      targetMaxLongEdge: targetMaxLongEdge,
      outputUsm: outputUsm,
    );
  }

  @override
  Future<ExportRgbaResult> renderCollageToRawFile({
    required List<CollageRawFileSlot> slots,
    required CollageNativeConfig config,
    required OutputUsmNativeParams? outputUsm,
    required String rawOutputPath,
  }) {
    return _worker.renderCollageToRawFile(
      slots: slots,
      config: config,
      outputUsm: outputUsm,
      rawOutputPath: rawOutputPath,
    );
  }
}

/// Thrown before starting an export when free device storage falls below the
/// safety threshold (`max(150 MB, N * 60 MB)`).
final class ExportInsufficientSpaceException implements Exception {
  const ExportInsufficientSpaceException({
    required this.requiredBytes,
    required this.availableBytes,
    required this.message,
  });

  final int requiredBytes;
  final int availableBytes;
  final String message;

  @override
  String toString() => message;
}

/// Output summary returned after a successful single-item or collage export.
@immutable
final class SocialExportResult {
  const SocialExportResult({
    required this.itemIdOrCollageId,
    required this.contentUri,
    required this.displayName,
    required this.width,
    required this.height,
    required this.byteSize,
    required this.profileId,
    required this.exportedAtUtc,
  });

  final String itemIdOrCollageId;
  final String contentUri;
  final String displayName;
  final int width;
  final int height;
  final int byteSize;
  final String profileId;
  final String exportedAtUtc;

  String get galleryRelativePath => 'Pictures/FujiStudio/$displayName';

  String formatSummary() {
    return '$width × $height · ${formatByteSize(byteSize)} · $galleryRelativePath';
  }

  static String formatByteSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).round()} KB';
    }
    return '$bytes B';
  }
}

/// Coordinates full-resolution single-photo and Story Collage exports without
/// shuttling full-resolution RGBA buffers across the Dart/C++ Isolate boundary.
///
/// Guarantees:
/// - Crop-aware decode sizing (never falls back to the 1600px grid proxy)
/// - Proper `.RAF` embedded JPEG extraction via POSIX FD (`rafOnly`) vs direct
///   `.JPG` upright decode (`jpgOnly` / `jpgPlusRaf`)
/// - Strict cleanup of all temporary `.rgba` and `.jpg` files in `finally`,
///   plus orphan `export_tmp/` cleanup on session startup
/// - Updates `EditRecipe.exportProfile` in [SessionController] and writes
///   Android `content://` export records strictly to [MobileExportLogStore]
final class SocialExportService {
  SocialExportService({
    required this._storageGateway,
    NativeWorker? nativeWorker,
    SocialExportNativePipeline? nativePipeline,
    required this._exportLogStore,
    required this._sessionController,
  }) : assert(
         nativeWorker != null || nativePipeline != null,
         'Either nativeWorker or nativePipeline must be provided.',
       ),
       _nativePipeline =
           nativePipeline ?? NativeWorkerSocialExportPipeline(nativeWorker!);

  static const int minSingleExportFreeSpaceBytes = 150 * 1024 * 1024;
  static const int perBatchItemFreeSpaceBytes = 60 * 1024 * 1024;
  static const int lowRamThresholdBytes = 8 * 1024 * 1024 * 1024;
  static const int lowRamMaxDecodeLongEdge = 4608;
  static const int highRamMaxDecodeLongEdge = 7728;

  final StorageGateway _storageGateway;
  final SocialExportNativePipeline _nativePipeline;
  final MobileExportLogStore _exportLogStore;
  final SessionController _sessionController;

  int _tempSeq = 0;
  int _activeExports = 0;
  bool _orphansCleaned = false;
  int? _cachedTotalRamBytes;

  static int requiredFreeSpaceBytesForCount(int itemCount) {
    final safeCount = math.max(1, itemCount);
    return math.max(
      minSingleExportFreeSpaceBytes,
      safeCount * perBatchItemFreeSpaceBytes,
    );
  }

  /// Verifies free storage via [StorageGateway.getAvailableExportSpaceBytes]
  /// against `max(150 MB, itemCount * 60 MB)` before decoding or exporting.
  Future<void> ensureSufficientStorageSpace({int itemCount = 1}) async {
    final requiredBytes = requiredFreeSpaceBytesForCount(itemCount);
    final availableBytes = await _storageGateway.getAvailableExportSpaceBytes();
    if (availableBytes < requiredBytes) {
      final requiredMb = (requiredBytes / (1024 * 1024)).ceil();
      final availableMb = (availableBytes / (1024 * 1024)).floor();
      throw ExportInsufficientSpaceException(
        requiredBytes: requiredBytes,
        availableBytes: availableBytes,
        message:
            'Không đủ dung lượng trống để xuất ảnh (cần tối thiểu $requiredMb MB, hiện còn $availableMb MB).',
      );
    }
  }

  Future<int> _getDeviceTotalRamBytes() async {
    return _cachedTotalRamBytes ??=
        await _storageGateway.getDeviceTotalRamBytes();
  }

  /// Computes the required source decode long edge for [targetMaxLongEdge]
  /// (`0` means full native resolution) and [geometry] (`crop_box` / rotation).
  ///
  /// Ensures uncropped 2048px exports decode at least `2400px` and heavily
  /// cropped images decode up to `7728px` on `>= 8 GB` RAM devices, while
  /// clamping strictly to `<= 4608px` on `< 8 GB` RAM devices to avoid 40MP OOM.
  @visibleForTesting
  static int computeDecodeLongEdge({
    required int targetMaxLongEdge,
    required GeometrySpec geometry,
    int deviceTotalRamBytes = lowRamThresholdBytes,
  }) {
    final isLowRam =
        deviceTotalRamBytes > 0 && deviceTotalRamBytes < lowRamThresholdBytes;
    final maxAllowedEdge =
        isLowRam ? lowRamMaxDecodeLongEdge : highRamMaxDecodeLongEdge;

    if (targetMaxLongEdge <= 0) {
      return isLowRam ? lowRamMaxDecodeLongEdge : 0;
    }

    final box = GeometryMapper.normBoxFromSpec(geometry);
    final cropW = (box.right - box.left).clamp(0.05, 1.0);
    final cropH = (box.bottom - box.top).clamp(0.05, 1.0);
    final minCropSpan = math.min(cropW, cropH);
    final isRotated = geometry.rotationDeg.abs() > 0.1;
    final isCropped =
        !GeometryMapper.isFullBox(box) || geometry.aspectRatio != null;

    final int rawTarget;
    if (!isCropped && !isRotated) {
      rawTarget = math.max(targetMaxLongEdge, 2400);
    } else {
      final rotFactor = isRotated ? 0.85 : 1.0;
      rawTarget = (targetMaxLongEdge / (minCropSpan * rotFactor)).ceil();
    }
    final minEdge = math.min(math.max(targetMaxLongEdge, 2400), maxAllowedEdge);
    return rawTarget.clamp(minEdge, maxAllowedEdge);
  }

  /// Removes any leftover orphan files inside `export_tmp/` and expired
  /// pending (`IS_PENDING = 1`) MediaStore entries when no export is active.
  Future<void> cleanupOrphanTempFiles() async {
    if (_activeExports > 0) return;
    try {
      final tempDirPath = await _storageGateway.getExportTempDirectory();
      final dir = Directory(tempDirPath);
      if (dir.existsSync()) {
        for (final entity in dir.listSync(followLinks: false)) {
          if (entity is File) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {
      // Best-effort orphan cleanup.
    }
    try {
      await _storageGateway.cleanOrphanExportTempFiles(olderThanSeconds: 3600);
    } catch (_) {
      // Best-effort stale IS_PENDING cleanup.
    }
  }

  /// Exports a single [SessionItem] using its [EditRecipe] (with optional
  /// [exportProfileOverride]), saves it to `Pictures/FujiStudio/`, persists the
  /// updated `exportProfile`, and records the output URI in [MobileExportLogStore].
  Future<SocialExportResult> exportSingleItem({
    required String itemId,
    PairedAsset? pairedAsset,
    EditRecipe? recipe,
    ExportProfileSpec? exportProfileOverride,
    String? albumKey,
  }) async {
    await _prepareExportTempDir();
    await ensureSufficientStorageSpace(itemCount: 1);
    final deviceTotalRamBytes = await _getDeviceTotalRamBytes();
    _activeExports++;

    final tempDirPath = await _storageGateway.getExportTempDirectory();
    Directory(tempDirPath).createSync(recursive: true);

    final resolvedPair =
        pairedAsset ?? _sessionController.pairedAssetForItem(itemId);
    final resolvedItem = _sessionController.sessionItemById(itemId);
    final baseRecipe =
        recipe ?? resolvedItem?.editRecipe ?? _defaultNeutralRecipe();
    if (resolvedPair == null) {
      _activeExports = math.max(0, _activeExports - 1);
      throw StateError('Missing PairedAsset for item $itemId');
    }

    final effectiveProfile = exportProfileOverride ?? baseRecipe.exportProfile;
    final updatedRecipe = baseRecipe.copyWith(exportProfile: effectiveProfile);
    final nativeConfig = ExportMapper.toNativeConfig(effectiveProfile);

    final seq = ++_tempSeq;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final rawInputPath =
        '$tempDirPath${Platform.pathSeparator}raw_in_${seq}_$stamp.rgba';
    final rawOutputPath =
        '$tempDirPath${Platform.pathSeparator}raw_out_${seq}_$stamp.rgba';
    final rafTempJpegPath =
        '$tempDirPath${Platform.pathSeparator}raf_ext_${seq}_$stamp.jpg';

    final tempPathsToClean = <String>[rawInputPath, rawOutputPath];

    try {
      final maxDecodeLongEdge = computeDecodeLongEdge(
        targetMaxLongEdge: nativeConfig.maxLongEdgePx,
        geometry: updatedRecipe.geometry,
        deviceTotalRamBytes: deviceTotalRamBytes,
      );

      final decoded = await _decodeAssetToRawFile(
        pairedAsset: resolvedPair,
        outRawPath: rawInputPath,
        rafTempJpegPath: rafTempJpegPath,
        maxDecodeLongEdge: maxDecodeLongEdge,
        tempPathsToClean: tempPathsToClean,
      );

      final pipelineResult = await _nativePipeline.runExportPipelineOnRawFile(
        rawInputPath: decoded.rawPath,
        srcWidth: decoded.width,
        srcHeight: decoded.height,
        rawOutputPath: rawOutputPath,
        dnaRescue: DnaRescueMapper.isEdited(updatedRecipe.dnaRescue)
            ? DnaRescueMapper.toNativeParams(updatedRecipe.dnaRescue)
            : null,
        geometry: GeometryMapper.isEdited(updatedRecipe.geometry)
            ? GeometryMapper.toNativeParams(
                updatedRecipe.geometry,
                highQuality: true,
              )
            : null,
        targetMaxLongEdge: nativeConfig.maxLongEdgePx,
        outputUsm: nativeConfig.outputUsm.enabled
            ? nativeConfig.outputUsm
            : null,
      );

      if (!pipelineResult.isOk) {
        throw StateError(
          'Native export pipeline failed (${pipelineResult.statusCode}) for ${resolvedPair.displayName}',
        );
      }

      final suffix = nativeConfig.filenameSuffix.trim().isEmpty
          ? '_fuji2048'
          : nativeConfig.filenameSuffix.trim();
      var displayName = ExportMapper.buildOutputFileName(
        resolvedPair.displayName,
        suffix: suffix,
      );
      if (displayName.toLowerCase() == resolvedPair.displayName.toLowerCase()) {
        displayName = ExportMapper.buildOutputFileName(
          resolvedPair.displayName,
          suffix: '_fuji2048',
        );
      }

      final saved = await _storageGateway.encodeRgbaFileAndSaveExport(
        rawRgbaPath: pipelineResult.rawOutputPath,
        width: pipelineResult.width,
        height: pipelineResult.height,
        jpegQuality: nativeConfig.jpegQuality,
        displayName: displayName,
        exifSource: decoded.exifSource,
        exifSourceIsContentUri: decoded.exifSourceIsContentUri,
        preserveExif: nativeConfig.preserveExif,
        stripGps: nativeConfig.stripGps,
      );

      if (resolvedItem != null) {
        _sessionController.updateItemEditRecipe(itemId, updatedRecipe);
      }

      final exportedAtUtc = DateTime.now().toUtc().toIso8601String();
      final resolvedAlbumKey = albumKey ?? _sessionController.currentAlbumKey;
      if (resolvedAlbumKey != null && resolvedAlbumKey.isNotEmpty) {
        await _exportLogStore.recordExport(
          resolvedAlbumKey,
          MobileExportLogEntry(
            itemIdOrCollageId: itemId,
            displayName: saved.displayName,
            contentUri: saved.contentUri,
            width: saved.width,
            height: saved.height,
            byteSize: saved.byteSize,
            exportedAtUtc: exportedAtUtc,
            profileId: nativeConfig.preset.id,
          ),
        );
      }

      return SocialExportResult(
        itemIdOrCollageId: itemId,
        contentUri: saved.contentUri,
        displayName: saved.displayName,
        width: saved.width,
        height: saved.height,
        byteSize: saved.byteSize,
        profileId: nativeConfig.preset.id,
        exportedAtUtc: exportedAtUtc,
      );
    } finally {
      _activeExports = math.max(0, _activeExports - 1);
      await _deleteFiles(tempPathsToClean);
    }
  }

  /// Exports a 2–4 slot [CollageSpec] at full resolution (`1152x2048` for
  /// `9:16`, `1638x2048` for `4:5` when `maxLongEdgePx == 2048`), decoding each
  /// slot sequentially (`<= 1600px`) to prevent OOM spikes.
  Future<SocialExportResult> exportCollage({
    required CollageSpec spec,
    OutputSharpeningLevel sharpening = OutputSharpeningLevel.subtle,
    int maxLongEdgePx = 2048,
    int jpegQuality = 92,
    String? albumKey,
  }) async {
    if (spec.slots.length < 2 || spec.slots.length > 4) {
      throw ArgumentError('Collage must have 2-4 slots.');
    }

    await _prepareExportTempDir();
    await ensureSufficientStorageSpace(itemCount: 1);
    _activeExports++;

    final tempDirPath = await _storageGateway.getExportTempDirectory();
    Directory(tempDirPath).createSync(recursive: true);

    final seq = ++_tempSeq;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final rawOutputPath =
        '$tempDirPath${Platform.pathSeparator}collage_out_${seq}_$stamp.rgba';
    final tempPathsToClean = <String>[rawOutputPath];

    try {
      final config = CollageMapper.toExportNativeConfig(
        spec,
        maxLongEdgePx: maxLongEdgePx,
      );

      final rawSlots = <CollageRawFileSlot>[];
      for (var i = 0; i < spec.slots.length; i++) {
        final slot = spec.slots[i];
        final pair = _sessionController.pairedAssetForItem(slot.itemId);
        final item = _sessionController.sessionItemById(slot.itemId);
        if (pair == null || item == null) {
          throw StateError(
            'Missing session item or paired asset for collage slot ${slot.itemId}',
          );
        }

        final slotRawPath =
            '$tempDirPath${Platform.pathSeparator}collage_slot_${seq}_${i}_$stamp.rgba';
        final slotRafTemp =
            '$tempDirPath${Platform.pathSeparator}collage_raf_${seq}_${i}_$stamp.jpg';
        tempPathsToClean.add(slotRawPath);

        final slotMaxDecode = math.min(
          1600,
          math.max(1080, (maxLongEdgePx * 0.65 * slot.zoom).round()),
        );
        final decoded = await _decodeAssetToRawFile(
          pairedAsset: pair,
          outRawPath: slotRawPath,
          rafTempJpegPath: slotRafTemp,
          maxDecodeLongEdge: slotMaxDecode,
          tempPathsToClean: tempPathsToClean,
        );

        rawSlots.add(
          CollageRawFileSlot(
            rawInputPath: decoded.rawPath,
            width: decoded.width,
            height: decoded.height,
            panX: slot.panX,
            panY: slot.panY,
            zoom: slot.zoom,
            dnaRescue: DnaRescueMapper.isEdited(item.editRecipe.dnaRescue)
                ? DnaRescueMapper.toNativeParams(item.editRecipe.dnaRescue)
                : null,
          ),
        );
      }

      final renderResult = await _nativePipeline.renderCollageToRawFile(
        slots: rawSlots,
        config: config,
        outputUsm: sharpening.amount > 0 ? sharpening.toNativeParams() : null,
        rawOutputPath: rawOutputPath,
      );
      if (!renderResult.isOk) {
        throw StateError(
          'Native collage export failed (${renderResult.statusCode})',
        );
      }

      final displayName =
          'FujiCollage_${_formatFileTimestamp(DateTime.now().toUtc())}.jpg';
      final saved = await _storageGateway.encodeRgbaFileAndSaveExport(
        rawRgbaPath: renderResult.rawOutputPath,
        width: renderResult.width,
        height: renderResult.height,
        jpegQuality: jpegQuality.clamp(50, 100),
        displayName: displayName,
        exifSource: null,
        preserveExif: false,
        stripGps: true,
      );

      final exportedAtUtc = DateTime.now().toUtc().toIso8601String();
      final profileId = 'collage_${maxLongEdgePx}px';
      final resolvedAlbumKey = albumKey ?? _sessionController.currentAlbumKey;
      if (resolvedAlbumKey != null && resolvedAlbumKey.isNotEmpty) {
        await _exportLogStore.recordExport(
          resolvedAlbumKey,
          MobileExportLogEntry(
            itemIdOrCollageId: spec.collageId,
            displayName: saved.displayName,
            contentUri: saved.contentUri,
            width: saved.width,
            height: saved.height,
            byteSize: saved.byteSize,
            exportedAtUtc: exportedAtUtc,
            profileId: profileId,
          ),
        );
      }

      return SocialExportResult(
        itemIdOrCollageId: spec.collageId,
        contentUri: saved.contentUri,
        displayName: saved.displayName,
        width: saved.width,
        height: saved.height,
        byteSize: saved.byteSize,
        profileId: profileId,
        exportedAtUtc: exportedAtUtc,
      );
    } finally {
      _activeExports = math.max(0, _activeExports - 1);
      await _deleteFiles(tempPathsToClean);
    }
  }

  Future<void> _prepareExportTempDir() async {
    if (!_orphansCleaned) {
      _orphansCleaned = true;
      await cleanupOrphanTempFiles();
    }
  }

  Future<_DecodedSourceInfo> _decodeAssetToRawFile({
    required PairedAsset pairedAsset,
    required String outRawPath,
    required String rafTempJpegPath,
    required int maxDecodeLongEdge,
    required List<String> tempPathsToClean,
  }) async {
    if (pairedAsset.kind == AssetPairKind.rafOnly) {
      tempPathsToClean.add(rafTempJpegPath);
      final rafUri = pairedAsset.primaryAsset.uri;
      final openedFd = await _storageGateway.openReadOnlyFd(rafUri);
      final RafExtractionResult rafMeta;
      if (openedFd != null) {
        try {
          rafMeta = await _nativePipeline.extractRafPreviewFromFd(
            fd: openedFd.fd,
            outJpegPath: rafTempJpegPath,
          );
        } finally {
          await _storageGateway.closeFd(openedFd.handleId);
        }
      } else if (!rafUri.startsWith('content://') && File(rafUri).existsSync()) {
        rafMeta = await _nativePipeline.extractRafPreviewFromPath(
          rafPath: rafUri,
          outJpegPath: rafTempJpegPath,
        );
      } else {
        throw StateError(
          'Unable to open read-only FD for .RAF ${pairedAsset.displayName}',
        );
      }

      if (!rafMeta.isOk) {
        throw StateError(
          'Failed to extract embedded JPEG from .RAF ${pairedAsset.displayName} (${rafMeta.statusCode})',
        );
      }

      final decoded = await _storageGateway.decodeSourceForExportToRawFile(
        source: rafTempJpegPath,
        isContentUri: false,
        outRawPath: outRawPath,
        maxDecodeLongEdge: maxDecodeLongEdge,
        orientationOverride: rafMeta.exifOrientation,
      );
      return _DecodedSourceInfo(
        rawPath: decoded.rawPath,
        width: decoded.width,
        height: decoded.height,
        exifSource: rafTempJpegPath,
        exifSourceIsContentUri: false,
      );
    }

    final jpgUri = pairedAsset.primaryAsset.uri;
    final decoded = await _storageGateway.decodeSourceForExportToRawFile(
      source: jpgUri,
      isContentUri: true,
      outRawPath: outRawPath,
      maxDecodeLongEdge: maxDecodeLongEdge,
    );
    return _DecodedSourceInfo(
      rawPath: decoded.rawPath,
      width: decoded.width,
      height: decoded.height,
      exifSource: jpgUri,
      exifSourceIsContentUri: true,
    );
  }

  Future<void> _deleteFiles(List<String> paths) async {
    for (final path in paths) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  static String _formatFileTimestamp(DateTime utc) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}_'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}';
  }

  static EditRecipe _defaultNeutralRecipe() {
    return EditRecipe(
      dnaRescue: DnaRescueSpec(enabled: false, shadowLift: 0.0),
      geometry: GeometrySpec(rotationDeg: 0.0),
      lut: LutSpec(enabled: false, intensity: 0.0),
      exportProfile: ExportProfileSpec(
        format: 'jpeg',
        quality: 92,
        colorSpace: 'sRGB',
        maxLongEdgePx: 2048,
      ),
    );
  }
}

final class _DecodedSourceInfo {
  const _DecodedSourceInfo({
    required this.rawPath,
    required this.width,
    required this.height,
    required this.exifSource,
    required this.exifSourceIsContentUri,
  });

  final String rawPath;
  final int width;
  final int height;
  final String exifSource;
  final bool exifSourceIsContentUri;
}
