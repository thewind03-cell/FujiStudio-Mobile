import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../core/ffi/native_worker.dart';
import '../../core/schema/collage_spec.dart';
import '../../core/schema/edit_recipe.dart';
import '../../core/storage/asset_pairing_engine.dart';
import '../../core/storage/proxy_cache_manager.dart';
import '../session_picker/session_controller.dart';
import '../studio_editor/dna_rescue_mapper.dart';
import '../studio_editor/geometry_mapper.dart';
import 'collage_mapper.dart';

/// Native gateway for [StoryCollageController] so widget/unit tests can run
/// against either real C++ [NativeWorker] or deterministic fakes.
abstract interface class StoryCollageNativeGateway {
  Future<CollageRenderResult> renderCollage({
    required List<CollageSlotInputData> slots,
    required CollageNativeConfig config,
  });

  Future<Uint8List?> applyDnaRescuePreview({
    required int width,
    required int height,
    required Uint8List sourceRgba,
    required DnaRescueNativeParams params,
  });

  Future<({Uint8List rgbaBytes, int width, int height})?> applyGeometryPreview({
    required int width,
    required int height,
    required Uint8List sourceRgba,
    required GeometryNativeParams params,
  });
}

/// Production [StoryCollageNativeGateway] backed by [NativeWorker].
final class NativeWorkerCollageGateway implements StoryCollageNativeGateway {
  const NativeWorkerCollageGateway(this._worker);

  final NativeWorker _worker;

  @override
  Future<CollageRenderResult> renderCollage({
    required List<CollageSlotInputData> slots,
    required CollageNativeConfig config,
  }) {
    return _worker.renderCollage(slots: slots, config: config);
  }

  @override
  Future<Uint8List?> applyDnaRescuePreview({
    required int width,
    required int height,
    required Uint8List sourceRgba,
    required DnaRescueNativeParams params,
  }) async {
    final surfaceId = await _worker.openStudioSurface(
      width: width,
      height: height,
      sourceRgba: sourceRgba,
    );
    try {
      final result = await _worker.renderStudioSurface(
        surfaceId: surfaceId,
        params: params,
      );
      if (!result.isOk) return null;
      return result.rgbaBytes;
    } finally {
      await _worker.closeStudioSurface(surfaceId);
    }
  }

  @override
  Future<({Uint8List rgbaBytes, int width, int height})?> applyGeometryPreview({
    required int width,
    required int height,
    required Uint8List sourceRgba,
    required GeometryNativeParams params,
  }) async {
    final clamped = await _worker.clampCrop(
      srcWidth: width,
      srcHeight: height,
      rotationDeg: params.rotationDeg,
      aspectPreset: params.aspectPreset,
      requestedBox: params.cropBox,
    );
    if (!clamped.isOk || clamped.pixelWidth <= 0 || clamped.pixelHeight <= 0) {
      return null;
    }

    final surfaceId = await _worker.openStudioSurface(
      width: width,
      height: height,
      sourceRgba: sourceRgba,
    );
    try {
      final result = await _worker.renderGeometryOnSurface(
        surfaceId: surfaceId,
        params: GeometryNativeParams(
          rotationDeg: params.rotationDeg,
          aspectPreset: params.aspectPreset,
          cropBox: clamped.clampedBox,
          highQuality: params.highQuality,
        ),
        outWidth: clamped.pixelWidth,
        outHeight: clamped.pixelHeight,
      );
      if (!result.isOk || result.rgbaBytes == null) return null;
      return (
        rgbaBytes: result.rgbaBytes!,
        width: result.width,
        height: result.height,
      );
    } finally {
      await _worker.closeStudioSurface(surfaceId);
    }
  }
}

/// Decoded `<= 1080px` collage slot RGBA buffer and GPU [ui.Image].
final class StoryCollageSlotFrame {
  const StoryCollageSlotFrame({
    required this.itemId,
    required this.width,
    required this.height,
    required this.rgbaBytes,
    required this.image,
  });

  final String itemId;
  final int width;
  final int height;
  final Uint8List rgbaBytes;
  final ui.Image image;
}

typedef StoryCollageSlotLoader =
    Future<StoryCollageSlotFrame> Function(
      String itemId,
      PairedAsset asset,
      DnaRescueSpec dnaRescue,
    );

/// Result of calling C++ `fs_collage_render_rgba_into` for 1:1 preview inspection.
final class CppCollagePreviewResult {
  const CppCollagePreviewResult({
    required this.image,
    required this.width,
    required this.height,
    required this.renderTimeMs,
  });

  final ui.Image image;
  final int width;
  final int height;
  final double renderTimeMs;
}

/// Immutable state exposed by [StoryCollageController].
@immutable
final class StoryCollageState {
  StoryCollageState({
    required this.spec,
    Map<String, StoryCollageSlotFrame> slotFrames =
        const <String, StoryCollageSlotFrame>{},
    this.selectedSlotIndex = 0,
    this.swapSourceIndex,
    this.isLoading = true,
    this.isRenderingCpp = false,
    this.hasUnsavedChanges = true,
    this.errorMessage,
  }) : slotFrames = Map<String, StoryCollageSlotFrame>.unmodifiable(slotFrames);

  final CollageSpec spec;
  final Map<String, StoryCollageSlotFrame> slotFrames;
  final int selectedSlotIndex;
  final int? swapSourceIndex;
  final bool isLoading;
  final bool isRenderingCpp;
  final bool hasUnsavedChanges;
  final String? errorMessage;

  int get activeTemplateNativeId => CollageMapper.templateIdFromSchema(
    spec.templateId,
    slotCount: spec.slots.length,
  );

  int get outerMarginPx => CollageMapper.readOuterMarginPx(spec);

  StoryCollageState copyWith({
    CollageSpec? spec,
    Map<String, StoryCollageSlotFrame>? slotFrames,
    int? selectedSlotIndex,
    Object? swapSourceIndex = _swapUnset,
    bool? isLoading,
    bool? isRenderingCpp,
    bool? hasUnsavedChanges,
    String? errorMessage,
    bool clearError = false,
  }) {
    return StoryCollageState(
      spec: spec ?? this.spec,
      slotFrames: slotFrames ?? this.slotFrames,
      selectedSlotIndex: selectedSlotIndex ?? this.selectedSlotIndex,
      swapSourceIndex: identical(swapSourceIndex, _swapUnset)
          ? this.swapSourceIndex
          : swapSourceIndex as int?,
      isLoading: isLoading ?? this.isLoading,
      isRenderingCpp: isRenderingCpp ?? this.isRenderingCpp,
      hasUnsavedChanges: hasUnsavedChanges ?? this.hasUnsavedChanges,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

const Object _swapUnset = Object();

/// Manages 2-4 slot collage composition, `<= 1080px` memory-bounded decoding,
/// DNA rescue preview integration, slot swapping, C++ stitch verification, and
/// Schema v2.4.2 persistence via [SessionController].
final class StoryCollageController extends ChangeNotifier {
  StoryCollageController({
    required List<String> initialItemIds,
    required this.sessionController,
    required this._proxyCacheManager,
    required this._nativeGateway,
    this._slotLoader,
    CollageSpec? initialSpec,
    this.maxSlotLongEdge = 1080,
  }) : assert(initialItemIds.length >= 2 && initialItemIds.length <= 4) {
    final defaultTpl = _defaultTemplateForCount(initialItemIds.length);
    final resolvedSpec = initialSpec ??
        CollageMapper.withOuterMarginPx(
          CollageSpec(
            collageId: 'col_${DateTime.now().millisecondsSinceEpoch}',
            templateId: CollageMapper.templateIdToSchema(defaultTpl),
            aspectRatio: '9:16',
            backgroundHex: CollagePaperTheme.darkroom.hex,
            spacingPx: CollageMapper.defaultGutterPx,
            slots: <CollageSlot>[
              for (var i = 0; i < initialItemIds.length; i++)
                CollageSlot(slotIndex: i, itemId: initialItemIds[i]),
            ],
          ),
          CollageMapper.defaultOuterMarginPx,
        );
    _state = StoryCollageState(spec: resolvedSpec);
  }

  final SessionController sessionController;
  final ProxyCacheManager _proxyCacheManager;
  final StoryCollageNativeGateway _nativeGateway;
  final StoryCollageSlotLoader? _slotLoader;
  final int maxSlotLongEdge;

  late StoryCollageState _state;
  final Map<String, StoryCollageSlotFrame> _loadedFrames =
      <String, StoryCollageSlotFrame>{};
  final List<ProxyCancelToken> _activeTokens = <ProxyCancelToken>[];
  bool _disposed = false;

  StoryCollageState get state => _state;

  Future<void> initialize() async {
    await _loadSlotsForIds(_state.spec.slots.map((s) => s.itemId).toList());
  }

  Future<void> _loadSlotsForIds(List<String> itemIds) async {
    if (_disposed) return;
    _state = _state.copyWith(isLoading: true, clearError: true);
    notifyListeners();

    try {
      final neededIds = itemIds.toSet();

      // Dispose frames no longer referenced.
      final removedIds =
          _loadedFrames.keys.where((id) => !neededIds.contains(id)).toList();
      for (final oldId in removedIds) {
        final removed = _loadedFrames.remove(oldId);
        removed?.image.dispose();
      }

      for (final id in itemIds) {
        if (_disposed) return;
        if (_loadedFrames.containsKey(id)) continue;

        final pair = sessionController.pairedAssetForItem(id);
        final item = sessionController.sessionItemById(id);
        if (pair == null || item == null) {
          throw StateError('Missing session item or asset for $id');
        }

        final frame = await (_slotLoader ?? _defaultSlotLoader)(
          id,
          pair,
          item.editRecipe.dnaRescue,
        );
        if (_disposed) {
          frame.image.dispose();
          return;
        }
        _loadedFrames[id] = frame;
      }

      _state = _state.copyWith(
        slotFrames: Map<String, StoryCollageSlotFrame>.of(_loadedFrames),
        isLoading: false,
      );
      notifyListeners();
    } catch (error) {
      if (_disposed) return;
      _state = _state.copyWith(
        isLoading: false,
        errorMessage: error.toString(),
      );
      notifyListeners();
    }
  }

  Future<StoryCollageSlotFrame> _defaultSlotLoader(
    String itemId,
    PairedAsset asset,
    DnaRescueSpec dnaRescue,
  ) async {
    final token = ProxyCancelToken();
    _activeTokens.add(token);
    final file = await _proxyCacheManager.requestProxy(
      asset,
      priority: ProxyPriority.activeViewer,
      cancelToken: token,
    );
    _activeTokens.remove(token);
    if (file == null || !file.existsSync()) {
      throw StateError('Proxy unavailable for ${asset.displayName}');
    }

    final bytes = await file.readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? currentImage;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final naturalW = descriptor.width;
      final naturalH = descriptor.height;
      int? targetWidth;
      int? targetHeight;
      if (math.max(naturalW, naturalH) > maxSlotLongEdge) {
        if (naturalW >= naturalH) {
          targetWidth = maxSlotLongEdge;
        } else {
          targetHeight = maxSlotLongEdge;
        }
      }
      codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      final frameInfo = await codec.getNextFrame();
      currentImage = frameInfo.image;
      final byteData = await currentImage.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) {
        throw StateError('Failed to extract RGBA bytes for ${asset.displayName}');
      }
      var rgba = byteData.buffer.asUint8List();

      if (DnaRescueMapper.isEdited(dnaRescue)) {
        final rescued = await _nativeGateway.applyDnaRescuePreview(
          width: currentImage.width,
          height: currentImage.height,
          sourceRgba: rgba,
          params: DnaRescueMapper.toNativeParams(dnaRescue),
        );
        if (_disposed) {
          throw StateError('Controller disposed during slot load.');
        }
        if (rescued != null && rescued.length == rgba.length) {
          final rescuedImg = await _decodeRgba(
            rescued,
            currentImage.width,
            currentImage.height,
          );
          currentImage.dispose();
          currentImage = rescuedImg;
          if (_disposed) {
            throw StateError('Controller disposed during slot decode.');
          }
          rgba = rescued;
        }
      }

      final geometry =
          sessionController.sessionItemById(itemId)?.editRecipe.geometry;
      if (geometry != null && GeometryMapper.isEdited(geometry)) {
        final geomRes = await _nativeGateway.applyGeometryPreview(
          width: currentImage.width,
          height: currentImage.height,
          sourceRgba: rgba,
          params: GeometryMapper.toNativeParams(geometry, highQuality: true),
        );
        if (_disposed) {
          throw StateError('Controller disposed during geometry slot load.');
        }
        if (geomRes != null) {
          final geomImg = await _decodeRgba(
            geomRes.rgbaBytes,
            geomRes.width,
            geomRes.height,
          );
          currentImage.dispose();
          currentImage = geomImg;
          if (_disposed) {
            throw StateError('Controller disposed during geometry slot decode.');
          }
          rgba = geomRes.rgbaBytes;
        }
      }

      final frame = StoryCollageSlotFrame(
        itemId: itemId,
        width: currentImage.width,
        height: currentImage.height,
        rgbaBytes: rgba,
        image: currentImage,
      );
      currentImage = null;
      return frame;
    } catch (_) {
      currentImage?.dispose();
      rethrow;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<ui.Image> _decodeRgba(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  void selectSlot(int index) {
    if (_disposed || index < 0 || index >= _state.spec.slots.length) return;
    final swapSrc = _state.swapSourceIndex;
    if (swapSrc != null) {
      if (swapSrc != index) {
        _swapSlots(swapSrc, index);
      } else {
        _state = _state.copyWith(swapSourceIndex: null);
        notifyListeners();
      }
      return;
    }
    _state = _state.copyWith(selectedSlotIndex: index);
    notifyListeners();
  }

  void toggleSwapMode() {
    if (_disposed) return;
    if (_state.swapSourceIndex != null) {
      _state = _state.copyWith(swapSourceIndex: null);
    } else {
      _state = _state.copyWith(swapSourceIndex: _state.selectedSlotIndex);
    }
    notifyListeners();
  }

  void _swapSlots(int indexA, int indexB) {
    final slots = List<CollageSlot>.of(_state.spec.slots);
    final slotA = slots[indexA];
    final slotB = slots[indexB];
    slots[indexA] = slotB.copyWith(slotIndex: indexA);
    slots[indexB] = slotA.copyWith(slotIndex: indexB);
    _state = _state.copyWith(
      spec: _state.spec.copyWith(slots: slots),
      selectedSlotIndex: indexB,
      swapSourceIndex: null,
      hasUnsavedChanges: true,
    );
    notifyListeners();
  }

  void setTemplate(int nativeTemplateId) {
    if (_disposed) return;
    final expected = CollageMapper.expectedSlotCount(nativeTemplateId);
    if (expected != _state.spec.slots.length) return;
    _state = _state.copyWith(
      spec: _state.spec.copyWith(
        templateId: CollageMapper.templateIdToSchema(nativeTemplateId),
      ),
      swapSourceIndex: null,
      hasUnsavedChanges: true,
    );
    notifyListeners();
  }

  void setAspectRatio(String aspectRatio) {
    if (_disposed || (aspectRatio != '9:16' && aspectRatio != '4:5')) return;
    _state = _state.copyWith(
      spec: _state.spec.copyWith(aspectRatio: aspectRatio),
      hasUnsavedChanges: true,
    );
    notifyListeners();
  }

  void setGutterPx(int gutterPx) {
    if (_disposed) return;
    final clamped = gutterPx.clamp(0, 32);
    _state = _state.copyWith(
      spec: _state.spec.copyWith(spacingPx: clamped),
      hasUnsavedChanges: true,
    );
    notifyListeners();
  }

  void setBackgroundHex(String hex) {
    if (_disposed) return;
    _state = _state.copyWith(
      spec: _state.spec.copyWith(backgroundHex: hex),
      hasUnsavedChanges: true,
    );
    notifyListeners();
  }

  void updateSlotPanZoom(
    int slotIndex, {
    double? panX,
    double? panY,
    double? zoom,
  }) {
    if (_disposed || slotIndex < 0 || slotIndex >= _state.spec.slots.length) {
      return;
    }
    final slots = List<CollageSlot>.of(_state.spec.slots);
    final curr = slots[slotIndex];
    slots[slotIndex] = curr.copyWith(
      panX: (panX ?? curr.panX).clamp(-1.0, 1.0),
      panY: (panY ?? curr.panY).clamp(-1.0, 1.0),
      zoom: (zoom ?? curr.zoom).clamp(1.0, 3.0),
    );
    _state = _state.copyWith(
      spec: _state.spec.copyWith(slots: slots),
      hasUnsavedChanges: true,
    );
    notifyListeners();
  }

  Future<void> replaceSelectedItems(List<String> newItemIds) async {
    if (_disposed || newItemIds.length < 2 || newItemIds.length > 4) return;
    final currentCount = _state.spec.slots.length;
    var nextTemplate = _state.spec.templateId;
    if (newItemIds.length != currentCount) {
      nextTemplate = CollageMapper.templateIdToSchema(
        _defaultTemplateForCount(newItemIds.length),
      );
    }

    final nextSlots = <CollageSlot>[
      for (var i = 0; i < newItemIds.length; i++)
        CollageSlot(slotIndex: i, itemId: newItemIds[i]),
    ];

    _state = _state.copyWith(
      spec: _state.spec.copyWith(
        templateId: nextTemplate,
        slots: nextSlots,
      ),
      selectedSlotIndex: 0,
      swapSourceIndex: null,
      hasUnsavedChanges: true,
    );
    notifyListeners();
    await _loadSlotsForIds(newItemIds);
  }

  /// Calls the real C++20 `fs_collage_render_rgba_into` core and returns a
  /// decoded [ui.Image] for 1:1 inspection. Caller must dispose `result.image`
  /// when closing the preview dialog.
  Future<CppCollagePreviewResult?> renderCppPreview() async {
    if (_disposed || _state.isRenderingCpp) return null;

    final slotInputs = <CollageSlotInputData>[];
    for (final slot in _state.spec.slots) {
      final frame = _loadedFrames[slot.itemId];
      if (frame == null) return null;
      slotInputs.add(
        CollageSlotInputData(
          rgbaBytes: frame.rgbaBytes,
          width: frame.width,
          height: frame.height,
          panX: slot.panX,
          panY: slot.panY,
          zoom: slot.zoom,
        ),
      );
    }

    _state = _state.copyWith(isRenderingCpp: true, clearError: true);
    notifyListeners();

    try {
      final config = CollageMapper.toNativeConfig(_state.spec, baseWidth: 540);
      final renderResult = await _nativeGateway.renderCollage(
        slots: slotInputs,
        config: config,
      );
      if (_disposed) return null;
      if (!renderResult.isOk || renderResult.rgbaBytes == null) {
        _state = _state.copyWith(
          isRenderingCpp: false,
          errorMessage: 'C++ collage stitch error (${renderResult.statusCode})',
        );
        notifyListeners();
        return null;
      }

      final image = await _decodeRgba(
        renderResult.rgbaBytes!,
        renderResult.width,
        renderResult.height,
      );
      if (_disposed) {
        image.dispose();
        return null;
      }
      _state = _state.copyWith(isRenderingCpp: false);
      notifyListeners();
      return CppCollagePreviewResult(
        image: image,
        width: renderResult.width,
        height: renderResult.height,
        renderTimeMs: renderResult.renderTimeMs,
      );
    } catch (error) {
      if (_disposed) return null;
      _state = _state.copyWith(
        isRenderingCpp: false,
        errorMessage: error.toString(),
      );
      notifyListeners();
      return null;
    }
  }

  void saveCollage() {
    if (_disposed) return;
    sessionController.saveCollageSpec(_state.spec);
    _state = _state.copyWith(hasUnsavedChanges: false);
    notifyListeners();
  }

  Future<void> flushPendingSave() async {
    await sessionController.flushPendingSave();
  }

  static int _defaultTemplateForCount(int count) {
    if (count == 2) return CollageMapper.templatesFor2Slots.first;
    if (count == 3) return CollageMapper.templatesFor3Slots[1]; // grid_3_top
    return CollageMapper.templatesFor4Slots.first; // grid_4_even
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final token in _activeTokens) {
      token.cancel();
    }
    _activeTokens.clear();
    for (final frame in _loadedFrames.values) {
      frame.image.dispose();
    }
    _loadedFrames.clear();
    super.dispose();
  }
}
