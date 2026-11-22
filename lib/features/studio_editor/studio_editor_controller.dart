import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../core/ffi/native_worker.dart';
import '../../core/schema/edit_recipe.dart';
import '../../core/storage/asset_pairing_engine.dart';
import '../../core/storage/proxy_cache_manager.dart';
import '../session_picker/session_controller.dart';
import 'dna_rescue_mapper.dart';

/// Abstraction over [NativeWorker]'s Resident Studio Surface APIs so
/// [StudioEditorController] can be deterministic and unit-tested with fakes.
abstract interface class StudioNativeGateway {
  Future<int> openStudioSurface({
    required int width,
    required int height,
    required Uint8List sourceRgba,
  });

  Future<StudioRenderResult> renderStudioSurface({
    required int surfaceId,
    required DnaRescueNativeParams params,
  });

  Future<DnaRescueSuggestionResult> analyzeStudioSurface({
    required int surfaceId,
  });

  Future<void> closeStudioSurface(int surfaceId);
}

/// Production [StudioNativeGateway] backed by [NativeWorker].
final class NativeWorkerStudioGateway implements StudioNativeGateway {
  const NativeWorkerStudioGateway(this._worker);

  final NativeWorker _worker;

  @override
  Future<int> openStudioSurface({
    required int width,
    required int height,
    required Uint8List sourceRgba,
  }) {
    return _worker.openStudioSurface(
      width: width,
      height: height,
      sourceRgba: sourceRgba,
    );
  }

  @override
  Future<StudioRenderResult> renderStudioSurface({
    required int surfaceId,
    required DnaRescueNativeParams params,
  }) {
    return _worker.renderStudioSurface(surfaceId: surfaceId, params: params);
  }

  @override
  Future<DnaRescueSuggestionResult> analyzeStudioSurface({
    required int surfaceId,
  }) {
    return _worker.analyzeStudioSurface(surfaceId: surfaceId);
  }

  @override
  Future<void> closeStudioSurface(int surfaceId) {
    return _worker.closeStudioSurface(surfaceId);
  }
}

/// Decoded interactive `1280px` RGBA frame + original [ui.Image] for 0ms Before/After.
final class StudioDecodedFrame {
  const StudioDecodedFrame({
    required this.width,
    required this.height,
    required this.rgbaBytes,
    required this.originalImage,
  });

  final int width;
  final int height;
  final Uint8List rgbaBytes;
  final ui.Image originalImage;
}

typedef StudioFrameLoader = Future<StudioDecodedFrame> Function(PairedAsset asset);

/// Interactive state exposed by [StudioEditorController].
@immutable
final class StudioEditorState {
  const StudioEditorState({
    required this.itemId,
    required this.fileName,
    required this.spec,
    this.isLoading = true,
    this.isAnalyzing = false,
    this.errorMessage,
    this.originalImage,
    this.editedImage,
    this.lastRenderTimeMs = 0.0,
    this.canUndo = false,
    this.canRedo = false,
    this.showingBefore = false,
  });

  final String itemId;
  final String fileName;
  final DnaRescueSpec spec;
  final bool isLoading;
  final bool isAnalyzing;
  final String? errorMessage;
  final ui.Image? originalImage;
  final ui.Image? editedImage;
  final double lastRenderTimeMs;
  final bool canUndo;
  final bool canRedo;
  final bool showingBefore;

  bool get canReset => spec.enabled || spec.shadowLift > 0.0;

  StudioEditorState copyWith({
    DnaRescueSpec? spec,
    bool? isLoading,
    bool? isAnalyzing,
    String? errorMessage,
    bool clearError = false,
    ui.Image? originalImage,
    ui.Image? editedImage,
    double? lastRenderTimeMs,
    bool? canUndo,
    bool? canRedo,
    bool? showingBefore,
  }) {
    return StudioEditorState(
      itemId: itemId,
      fileName: fileName,
      spec: spec ?? this.spec,
      isLoading: isLoading ?? this.isLoading,
      isAnalyzing: isAnalyzing ?? this.isAnalyzing,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      originalImage: originalImage ?? this.originalImage,
      editedImage: editedImage ?? this.editedImage,
      lastRenderTimeMs: lastRenderTimeMs ?? this.lastRenderTimeMs,
      canUndo: canUndo ?? this.canUndo,
      canRedo: canRedo ?? this.canRedo,
      showingBefore: showingBefore ?? this.showingBefore,
    );
  }
}

/// Manages single-decode 1280px interactive editing, Resident Studio Surface
/// rendering with Latest-Value Coalescing, 30-step Undo/Redo, Auto Rescue, and
/// persistence through [SessionController].
final class StudioEditorController extends ChangeNotifier {
  StudioEditorController({
    required this.itemId,
    required this.pairedAsset,
    required SessionController sessionController,
    required this._proxyCacheManager,
    required this._nativeGateway,
    this._frameLoader,
    this.maxInteractiveLongEdge = 1280,
  }) : _sessionController = sessionController,
       _baseRecipe =
           sessionController.editRecipeForItem(itemId) ?? _fallbackRecipe() {
    _committedSpec = _baseRecipe.dnaRescue;
    _state = StudioEditorState(
      itemId: itemId,
      fileName: pairedAsset.displayName,
      spec: _committedSpec,
    );
  }

  static const int maxUndoDepth = 30;

  final String itemId;
  final PairedAsset pairedAsset;
  final SessionController _sessionController;
  final ProxyCacheManager _proxyCacheManager;
  final StudioNativeGateway _nativeGateway;
  final StudioFrameLoader? _frameLoader;
  final int maxInteractiveLongEdge;

  late EditRecipe _baseRecipe;
  late DnaRescueSpec _committedSpec;
  late StudioEditorState _state;

  final List<DnaRescueSpec> _undoStack = <DnaRescueSpec>[];
  final List<DnaRescueSpec> _redoStack = <DnaRescueSpec>[];

  int? _surfaceId;
  bool _disposed = false;
  bool _isRendering = false;
  DnaRescueSpec? _queuedSpec;
  ProxyCancelToken? _loadToken;

  StudioEditorState get state => _state;
  int? get surfaceId => _surfaceId;

  /// Loads the 1600px proxy once, downscales to `1280px` interactive RGBA,
  /// opens the Resident Studio Surface, and renders initial state if active.
  Future<void> initialize() async {
    try {
      final frame = await (_frameLoader ?? _defaultFrameLoader)(pairedAsset);
      if (_disposed) {
        frame.originalImage.dispose();
        return;
      }

      final surfaceId = await _nativeGateway.openStudioSurface(
        width: frame.width,
        height: frame.height,
        sourceRgba: frame.rgbaBytes,
      );
      if (_disposed) {
        frame.originalImage.dispose();
        await _nativeGateway.closeStudioSurface(surfaceId);
        return;
      }

      _surfaceId = surfaceId;
      _state = _state.copyWith(
        isLoading: false,
        originalImage: frame.originalImage,
        editedImage: frame.originalImage,
        clearError: true,
      );
      notifyListeners();

      if (_state.spec.enabled && _state.spec.shadowLift > 0.0) {
        _requestRender(_state.spec);
      }
    } catch (error) {
      if (_disposed) return;
      _state = _state.copyWith(
        isLoading: false,
        errorMessage: error.toString(),
      );
      notifyListeners();
    }
  }

  Future<StudioDecodedFrame> _defaultFrameLoader(PairedAsset asset) async {
    final token = ProxyCancelToken();
    _loadToken = token;
    final file = await _proxyCacheManager.requestProxy(
      asset,
      priority: ProxyPriority.activeViewer,
      cancelToken: token,
    );
    if (file == null || !file.existsSync()) {
      throw StateError('Proxy image unavailable for ${asset.displayName}');
    }
    final bytes = await file.readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final naturalW = descriptor.width;
      final naturalH = descriptor.height;
      int? targetWidth;
      int? targetHeight;
      if (math.max(naturalW, naturalH) > maxInteractiveLongEdge) {
        if (naturalW >= naturalH) {
          targetWidth = maxInteractiveLongEdge;
        } else {
          targetHeight = maxInteractiveLongEdge;
        }
      }
      codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      final frameInfo = await codec.getNextFrame();
      final image = frameInfo.image;
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) {
        image.dispose();
        throw StateError('Failed to extract RGBA bytes from ${asset.displayName}');
      }
      return StudioDecodedFrame(
        width: image.width,
        height: image.height,
        rgbaBytes: byteData.buffer.asUint8List(),
        originalImage: image,
      );
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  /// Live preview during slider drag — uses Latest-Value Coalescing without
  /// pushing intermediate Undo states or writing to disk.
  void previewShadowLift(double value) {
    if (_disposed) return;
    final clamped = value.clamp(0.0, 100.0);
    final autoEnable =
        !_state.spec.enabled && _state.spec.shadowLift == 0.0 && clamped > 0.0;
    final nextSpec = _state.spec.copyWith(
      enabled: autoEnable ? true : _state.spec.enabled,
      shadowLift: clamped,
    );
    _state = _state.copyWith(spec: nextSpec);
    notifyListeners();
    _requestRender(nextSpec);
  }

  /// Commits slider release (`onChangeEnd`): pushes a single Undo entry and
  /// schedules persistence via [SessionController].
  void commitShadowLift(double value) {
    if (_disposed) return;
    final clamped = value.clamp(0.0, 100.0);
    final autoEnable =
        !_committedSpec.enabled && _committedSpec.shadowLift == 0.0 && clamped > 0.0;
    final nextSpec = _state.spec.copyWith(
      enabled: autoEnable ? true : _state.spec.enabled,
      shadowLift: clamped,
    );
    _commitSpec(nextSpec, triggerRender: true);
  }

  void toggleEnabled() {
    if (_disposed) return;
    final nextSpec = _state.spec.copyWith(enabled: !_state.spec.enabled);
    _commitSpec(nextSpec, triggerRender: true);
  }

  void setMode(int mode) {
    if (_disposed) return;
    if (DnaRescueMapper.readMode(_state.spec) == mode) return;
    final nextSpec = DnaRescueMapper.withMode(_state.spec, mode);
    _commitSpec(nextSpec, triggerRender: true);
  }

  Future<void> applyAutoRescue() async {
    final surfaceId = _surfaceId;
    if (_disposed || surfaceId == null || _state.isAnalyzing) return;
    _state = _state.copyWith(isAnalyzing: true);
    notifyListeners();
    try {
      final suggestion = await _nativeGateway.analyzeStudioSurface(
        surfaceId: surfaceId,
      );
      if (_disposed) return;
      _state = _state.copyWith(isAnalyzing: false);
      if (suggestion.isOk) {
        final nextSpec = DnaRescueMapper.applySuggestion(
          _state.spec,
          suggestion,
        );
        _commitSpec(nextSpec, triggerRender: true);
      } else {
        notifyListeners();
      }
    } catch (error) {
      if (_disposed) return;
      _state = _state.copyWith(
        isAnalyzing: false,
        errorMessage: error.toString(),
      );
      notifyListeners();
    }
  }

  void setShowingBefore(bool showingBefore) {
    if (_disposed || _state.showingBefore == showingBefore) return;
    _state = _state.copyWith(showingBefore: showingBefore);
    notifyListeners();
  }

  void undo() {
    if (_disposed || _undoStack.isEmpty) return;
    final previous = _undoStack.removeLast();
    _redoStack.add(_committedSpec);
    _committedSpec = previous;
    _persistSpec(previous);
    _state = _state.copyWith(
      spec: previous,
      canUndo: _undoStack.isNotEmpty,
      canRedo: _redoStack.isNotEmpty,
    );
    notifyListeners();
    _requestRender(previous);
  }

  void redo() {
    if (_disposed || _redoStack.isEmpty) return;
    final next = _redoStack.removeLast();
    _undoStack.add(_committedSpec);
    if (_undoStack.length > maxUndoDepth) {
      _undoStack.removeAt(0);
    }
    _committedSpec = next;
    _persistSpec(next);
    _state = _state.copyWith(
      spec: next,
      canUndo: _undoStack.isNotEmpty,
      canRedo: _redoStack.isNotEmpty,
    );
    notifyListeners();
    _requestRender(next);
  }

  void resetToDefault() {
    if (_disposed) return;
    final reset = DnaRescueMapper.resetSpec(_state.spec);
    _commitSpec(reset, triggerRender: true);
  }

  Future<void> flushPendingSave() async {
    await _sessionController.flushPendingSave();
  }

  void _commitSpec(DnaRescueSpec nextSpec, {required bool triggerRender}) {
    if (_specsEqual(_committedSpec, nextSpec)) {
      _state = _state.copyWith(spec: nextSpec);
      notifyListeners();
      if (triggerRender) _requestRender(nextSpec);
      return;
    }

    _undoStack.add(_committedSpec);
    if (_undoStack.length > maxUndoDepth) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
    _committedSpec = nextSpec;
    _persistSpec(nextSpec);

    _state = _state.copyWith(
      spec: nextSpec,
      canUndo: _undoStack.isNotEmpty,
      canRedo: false,
    );
    notifyListeners();
    if (triggerRender) {
      _requestRender(nextSpec);
    }
  }

  void _persistSpec(DnaRescueSpec nextSpec) {
    _baseRecipe = _baseRecipe.copyWith(dnaRescue: nextSpec);
    _sessionController.updateItemEditRecipe(itemId, _baseRecipe);
  }

  void _requestRender(DnaRescueSpec spec) {
    if (_disposed || _surfaceId == null) return;
    _queuedSpec = spec;
    if (!spec.enabled || spec.shadowLift <= 0.0) {
      _applyBypassImage();
    }
    if (_isRendering) return;
    unawaited(_drainRenderQueue());
  }

  Future<void> _drainRenderQueue() async {
    _isRendering = true;
    try {
      while (_queuedSpec != null && !_disposed && _surfaceId != null) {
        final targetSpec = _queuedSpec!;
        _queuedSpec = null;

        if (!targetSpec.enabled || targetSpec.shadowLift <= 0.0) {
          _applyBypassImage();
          continue;
        }

        final result = await _nativeGateway.renderStudioSurface(
          surfaceId: _surfaceId!,
          params: DnaRescueMapper.toNativeParams(targetSpec),
        );
        if (_disposed) break;
        if (_queuedSpec != null) {
          // A newer slider value arrived while native render ran; skip stale GPU upload.
          continue;
        }
        if (!result.isOk || result.rgbaBytes == null) {
          continue;
        }

        final nextImage = await _rgbaToUiImage(
          result.rgbaBytes!,
          result.width,
          result.height,
        );
        if (_disposed || _queuedSpec != null) {
          nextImage.dispose();
          continue;
        }
        _replaceEditedImage(nextImage, renderTimeMs: result.renderTimeMs);
      }
    } catch (error) {
      if (!_disposed) {
        _state = _state.copyWith(errorMessage: error.toString());
        notifyListeners();
      }
    } finally {
      _isRendering = false;
    }
  }

  void _applyBypassImage() {
    final original = _state.originalImage;
    if (original == null) return;
    final prev = _state.editedImage;
    if (!identical(prev, original)) {
      _state = _state.copyWith(
        editedImage: original,
        lastRenderTimeMs: 0.0,
      );
      notifyListeners();
      prev?.dispose();
    }
  }

  void _replaceEditedImage(
    ui.Image nextImage, {
    required double renderTimeMs,
  }) {
    final original = _state.originalImage;
    final prev = _state.editedImage;
    _state = _state.copyWith(
      editedImage: nextImage,
      lastRenderTimeMs: renderTimeMs,
    );
    notifyListeners();
    if (prev != null && !identical(prev, original) && !identical(prev, nextImage)) {
      prev.dispose();
    }
  }

  Future<ui.Image> _rgbaToUiImage(
    Uint8List rgba,
    int width,
    int height,
  ) {
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

  static bool _specsEqual(DnaRescueSpec a, DnaRescueSpec b) {
    return a.enabled == b.enabled &&
        a.shadowLift == b.shadowLift &&
        DnaRescueMapper.readMode(a) == DnaRescueMapper.readMode(b) &&
        DnaRescueMapper.readMidtoneAnchor(a) ==
            DnaRescueMapper.readMidtoneAnchor(b) &&
        DnaRescueMapper.readHighlightProtect(a) ==
            DnaRescueMapper.readHighlightProtect(b);
  }

  static EditRecipe _fallbackRecipe() {
    return EditRecipe(
      dnaRescue: DnaRescueSpec(enabled: false, shadowLift: 0.0),
      geometry: GeometrySpec(rotationDeg: 0.0),
      lut: LutSpec(enabled: false, intensity: 0.0),
      exportProfile: ExportProfileSpec(format: 'jpeg', quality: 92),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _queuedSpec = null;
    _loadToken?.cancel();

    final surfaceId = _surfaceId;
    _surfaceId = null;
    if (surfaceId != null) {
      unawaited(
        _nativeGateway.closeStudioSurface(surfaceId).catchError((_) {}),
      );
    }

    final original = _state.originalImage;
    final edited = _state.editedImage;
    if (edited != null && !identical(edited, original)) {
      edited.dispose();
    }
    original?.dispose();
    super.dispose();
  }
}
