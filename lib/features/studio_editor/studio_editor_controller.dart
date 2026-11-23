import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../core/ffi/native_worker.dart';
import '../../core/schema/action_proposal.dart';
import '../../core/schema/edit_recipe.dart';
import '../../core/storage/asset_pairing_engine.dart';
import '../../core/storage/proxy_cache_manager.dart';
import '../session_picker/session_controller.dart';
import 'dna_rescue_mapper.dart';
import 'geometry_mapper.dart';

/// Active editing tool tab inside [StudioEditorScreen].
enum StudioToolTab { dnaRescue, geometry, export }

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

  Future<GeometryProposalNative> analyzeGeometryOnSurface({
    required int surfaceId,
    required int targetAspectPreset,
    bool useRescuedBuffer = false,
  });

  Future<StudioRenderResult> renderGeometryOnSurface({
    required int surfaceId,
    required GeometryNativeParams params,
    required int outWidth,
    required int outHeight,
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
  Future<GeometryProposalNative> analyzeGeometryOnSurface({
    required int surfaceId,
    required int targetAspectPreset,
    bool useRescuedBuffer = false,
  }) {
    return _worker.analyzeGeometryOnSurface(
      surfaceId: surfaceId,
      targetAspectPreset: targetAspectPreset,
      useRescuedBuffer: useRescuedBuffer,
    );
  }

  @override
  Future<StudioRenderResult> renderGeometryOnSurface({
    required int surfaceId,
    required GeometryNativeParams params,
    required int outWidth,
    required int outHeight,
  }) {
    return _worker.renderGeometryOnSurface(
      surfaceId: surfaceId,
      params: params,
      outWidth: outWidth,
      outHeight: outHeight,
    );
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
    required this.recipe,
    this.activeTool = StudioToolTab.dnaRescue,
    this.pendingProposal,
    this.isLoading = true,
    this.isAnalyzing = false,
    this.isAnalyzingGeometry = false,
    this.errorMessage,
    this.originalImage,
    this.editedImage,
    this.frameWidth = 0,
    this.frameHeight = 0,
    this.lastRenderTimeMs = 0.0,
    this.canUndo = false,
    this.canRedo = false,
    this.showingBefore = false,
  });

  final String itemId;
  final String fileName;
  final EditRecipe recipe;
  final StudioToolTab activeTool;
  final ActionProposal? pendingProposal;
  final bool isLoading;
  final bool isAnalyzing;
  final bool isAnalyzingGeometry;
  final String? errorMessage;
  final ui.Image? originalImage;
  final ui.Image? editedImage;
  final int frameWidth;
  final int frameHeight;
  final double lastRenderTimeMs;
  final bool canUndo;
  final bool canRedo;
  final bool showingBefore;

  DnaRescueSpec get spec => recipe.dnaRescue;
  GeometrySpec get geometry => recipe.geometry;
  ExportProfileSpec get exportProfile => recipe.exportProfile;

  bool get canReset =>
      DnaRescueMapper.isEdited(spec) || GeometryMapper.isEdited(geometry);

  StudioEditorState copyWith({
    EditRecipe? recipe,
    StudioToolTab? activeTool,
    Object? pendingProposal = _proposalUnset,
    bool? isLoading,
    bool? isAnalyzing,
    bool? isAnalyzingGeometry,
    String? errorMessage,
    bool clearError = false,
    ui.Image? originalImage,
    ui.Image? editedImage,
    int? frameWidth,
    int? frameHeight,
    double? lastRenderTimeMs,
    bool? canUndo,
    bool? canRedo,
    bool? showingBefore,
  }) {
    return StudioEditorState(
      itemId: itemId,
      fileName: fileName,
      recipe: recipe ?? this.recipe,
      activeTool: activeTool ?? this.activeTool,
      pendingProposal: identical(pendingProposal, _proposalUnset)
          ? this.pendingProposal
          : pendingProposal as ActionProposal?,
      isLoading: isLoading ?? this.isLoading,
      isAnalyzing: isAnalyzing ?? this.isAnalyzing,
      isAnalyzingGeometry: isAnalyzingGeometry ?? this.isAnalyzingGeometry,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      originalImage: originalImage ?? this.originalImage,
      editedImage: editedImage ?? this.editedImage,
      frameWidth: frameWidth ?? this.frameWidth,
      frameHeight: frameHeight ?? this.frameHeight,
      lastRenderTimeMs: lastRenderTimeMs ?? this.lastRenderTimeMs,
      canUndo: canUndo ?? this.canUndo,
      canRedo: canRedo ?? this.canRedo,
      showingBefore: showingBefore ?? this.showingBefore,
    );
  }
}

const Object _proposalUnset = Object();

/// Manages single-decode 1280px interactive editing, Resident Studio Surface
/// rendering with Latest-Value Coalescing, unified 30-step Undo/Redo across
/// `dna_rescue` and `geometry`, Auto Rescue, Auto Horizon & Crop proposals,
/// and persistence through [SessionController].
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
       _committedRecipe =
           sessionController.editRecipeForItem(itemId) ?? _fallbackRecipe() {
    _state = StudioEditorState(
      itemId: itemId,
      fileName: pairedAsset.displayName,
      recipe: _committedRecipe,
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

  late EditRecipe _committedRecipe;
  late StudioEditorState _state;

  final List<EditRecipe> _undoStack = <EditRecipe>[];
  final List<EditRecipe> _redoStack = <EditRecipe>[];

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
        frameWidth: frame.width,
        frameHeight: frame.height,
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

  void setActiveTool(StudioToolTab tool) {
    if (_disposed || _state.activeTool == tool) return;
    _state = _state.copyWith(activeTool: tool);
    notifyListeners();
  }

  /// Updates the non-visual [ExportProfileSpec] and persists it through
  /// [SessionController] without altering the visual Undo/Redo stack.
  void updateExportProfile(ExportProfileSpec nextProfile) {
    if (_disposed) return;
    final nextRecipe = _state.recipe.copyWith(exportProfile: nextProfile);
    _committedRecipe = _committedRecipe.copyWith(exportProfile: nextProfile);
    _state = _state.copyWith(recipe: nextRecipe);
    _persistRecipe(nextRecipe);
    notifyListeners();
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
    _state = _state.copyWith(recipe: _state.recipe.copyWith(dnaRescue: nextSpec));
    notifyListeners();
    _requestRender(nextSpec);
  }

  /// Commits slider release (`onChangeEnd`): pushes a single Undo entry and
  /// schedules persistence via [SessionController].
  void commitShadowLift(double value) {
    if (_disposed) return;
    final clamped = value.clamp(0.0, 100.0);
    final committedDna = _committedRecipe.dnaRescue;
    final autoEnable =
        !committedDna.enabled && committedDna.shadowLift == 0.0 && clamped > 0.0;
    final nextSpec = _state.spec.copyWith(
      enabled: autoEnable ? true : _state.spec.enabled,
      shadowLift: clamped,
    );
    _commitRecipe(
      _state.recipe.copyWith(dnaRescue: nextSpec),
      triggerDnaRender: true,
    );
  }

  void toggleEnabled() {
    if (_disposed) return;
    final nextSpec = _state.spec.copyWith(enabled: !_state.spec.enabled);
    _commitRecipe(
      _state.recipe.copyWith(dnaRescue: nextSpec),
      triggerDnaRender: true,
    );
  }

  void setMode(int mode) {
    if (_disposed) return;
    if (DnaRescueMapper.readMode(_state.spec) == mode) return;
    final nextSpec = DnaRescueMapper.withMode(_state.spec, mode);
    _commitRecipe(
      _state.recipe.copyWith(dnaRescue: nextSpec),
      triggerDnaRender: true,
    );
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
        _commitRecipe(
          _state.recipe.copyWith(dnaRescue: nextSpec),
          triggerDnaRender: true,
        );
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

  /// Live 120fps GPU preview of horizon rotation without pushing Undo or writing disk.
  void previewRotationDeg(double rotationDeg) {
    if (_disposed) return;
    final clampedDeg = rotationDeg.clamp(-15.0, 15.0);
    final preset = GeometryMapper.aspectPresetFromString(_state.geometry.aspectRatio);
    final currentBox = GeometryMapper.normBoxFromSpec(_state.geometry);
    final frameW = _effectiveFrameWidth();
    final frameH = _effectiveFrameHeight();
    final clamped = GeometryMath.clampCrop(
      srcWidth: frameW,
      srcHeight: frameH,
      rotationDeg: clampedDeg,
      aspectPreset: preset,
      requestedBox: currentBox,
    );

    final nextGeom = GeometryMapper.withNormalizedGeometry(
      _state.geometry,
      rotationDeg: clampedDeg,
      aspectPreset: preset,
      cropBox: clamped.clampedBox,
    );
    _state = _state.copyWith(
      recipe: _state.recipe.copyWith(geometry: nextGeom),
    );
    notifyListeners();
  }

  /// Live 120fps GPU preview of crop box dragging/resizing without pushing Undo.
  void previewCropBox(NormCropBoxData requestedBox) {
    if (_disposed) return;
    final rot = _state.geometry.rotationDeg.clamp(-15.0, 15.0);
    final preset = GeometryMapper.aspectPresetFromString(_state.geometry.aspectRatio);
    final frameW = _effectiveFrameWidth();
    final frameH = _effectiveFrameHeight();
    final clamped = GeometryMath.clampCrop(
      srcWidth: frameW,
      srcHeight: frameH,
      rotationDeg: rot,
      aspectPreset: preset,
      requestedBox: requestedBox,
    );

    final nextGeom = GeometryMapper.withNormalizedGeometry(
      _state.geometry,
      rotationDeg: rot,
      aspectPreset: preset,
      cropBox: clamped.clampedBox,
    );
    _state = _state.copyWith(
      recipe: _state.recipe.copyWith(geometry: nextGeom),
    );
    notifyListeners();
  }

  /// Commits live geometry drag/dial changes into unified Undo history & disk.
  void commitGeometryChange() {
    if (_disposed) return;
    _commitRecipe(_state.recipe, triggerDnaRender: false);
  }

  /// Selects a social aspect preset (`FS_ASPECT_*`), clamps max centered crop
  /// inside the inscribed space, and commits immediately.
  void selectAspectRatio(int aspectPreset) {
    if (_disposed) return;
    final rot = _state.geometry.rotationDeg.clamp(-15.0, 15.0);
    final frameW = _effectiveFrameWidth();
    final frameH = _effectiveFrameHeight();
    final clamped = GeometryMath.clampCrop(
      srcWidth: frameW,
      srcHeight: frameH,
      rotationDeg: rot,
      aspectPreset: aspectPreset,
      requestedBox: NormCropBoxData.full,
    );

    final nextGeom = GeometryMapper.withNormalizedGeometry(
      _state.geometry,
      rotationDeg: rot,
      aspectPreset: aspectPreset,
      cropBox: clamped.clampedBox,
    );
    _commitRecipe(
      _state.recipe.copyWith(geometry: nextGeom),
      triggerDnaRender: false,
    );
  }

  /// Runs C++20 Auto-Horizon + AI Saliency Crop directly on the resident surface
  /// and surfaces an [ActionProposal] banner for explicit user consent.
  Future<void> runAutoHorizonAndCrop() async {
    final surfaceId = _surfaceId;
    if (_disposed || surfaceId == null || _state.isAnalyzingGeometry) return;
    _state = _state.copyWith(isAnalyzingGeometry: true);
    notifyListeners();

    try {
      final currentPreset =
          GeometryMapper.aspectPresetFromString(_state.geometry.aspectRatio);
      final nativeProp = await _nativeGateway.analyzeGeometryOnSurface(
        surfaceId: surfaceId,
        targetAspectPreset: currentPreset,
        useRescuedBuffer: DnaRescueMapper.isEdited(_state.recipe.dnaRescue),
      );
      if (_disposed) return;

      if (nativeProp.isOk) {
        final proposal = GeometryMapper.buildActionProposal(
          itemId: itemId,
          nativeProposal: nativeProp,
        );
        _state = _state.copyWith(
          isAnalyzingGeometry: false,
          pendingProposal: proposal,
        );
      } else {
        _state = _state.copyWith(isAnalyzingGeometry: false);
      }
      notifyListeners();
    } catch (error) {
      if (_disposed) return;
      _state = _state.copyWith(
        isAnalyzingGeometry: false,
        errorMessage: error.toString(),
      );
      notifyListeners();
    }
  }

  void acceptPendingProposal() {
    final proposal = _state.pendingProposal;
    if (_disposed || proposal == null) return;

    final nextGeom = GeometryMapper.applyProposalToSpec(
      _state.geometry,
      proposal,
    );
    _sessionController.recordActionProposal(proposal.copyWith(accepted: true));
    _state = _state.copyWith(pendingProposal: null);
    _commitRecipe(
      _state.recipe.copyWith(geometry: nextGeom),
      triggerDnaRender: false,
    );
  }

  void rejectPendingProposal() {
    final proposal = _state.pendingProposal;
    if (_disposed || proposal == null) return;
    _sessionController.recordActionProposal(proposal.copyWith(accepted: false));
    _state = _state.copyWith(pendingProposal: null);
    notifyListeners();
  }

  void setShowingBefore(bool showingBefore) {
    if (_disposed || _state.showingBefore == showingBefore) return;
    _state = _state.copyWith(showingBefore: showingBefore);
    notifyListeners();
  }

  void undo() {
    if (_disposed || _undoStack.isEmpty) return;
    final previous = _undoStack.removeLast();
    _redoStack.add(_committedRecipe);
    final dnaChanged = !_dnaSpecsEqual(_committedRecipe.dnaRescue, previous.dnaRescue);
    _committedRecipe = previous;
    _persistRecipe(previous);
    _state = _state.copyWith(
      recipe: previous,
      canUndo: _undoStack.isNotEmpty,
      canRedo: _redoStack.isNotEmpty,
    );
    notifyListeners();
    if (dnaChanged) {
      _requestRender(previous.dnaRescue);
    }
  }

  void redo() {
    if (_disposed || _redoStack.isEmpty) return;
    final next = _redoStack.removeLast();
    _undoStack.add(_committedRecipe);
    if (_undoStack.length > maxUndoDepth) {
      _undoStack.removeAt(0);
    }
    final dnaChanged = !_dnaSpecsEqual(_committedRecipe.dnaRescue, next.dnaRescue);
    _committedRecipe = next;
    _persistRecipe(next);
    _state = _state.copyWith(
      recipe: next,
      canUndo: _undoStack.isNotEmpty,
      canRedo: _redoStack.isNotEmpty,
    );
    notifyListeners();
    if (dnaChanged) {
      _requestRender(next.dnaRescue);
    }
  }

  void resetToDefault() {
    if (_disposed) return;
    final resetDna = DnaRescueMapper.resetSpec(_state.spec);
    final resetGeom = GeometryMapper.resetSpec(_state.geometry);
    final nextRecipe = _state.recipe.copyWith(
      dnaRescue: resetDna,
      geometry: resetGeom,
    );
    _state = _state.copyWith(pendingProposal: null);
    _commitRecipe(nextRecipe, triggerDnaRender: true);
  }

  Future<void> flushPendingSave() async {
    await _sessionController.flushPendingSave();
  }

  int _effectiveFrameWidth() {
    if (_state.frameWidth > 0) return _state.frameWidth;
    return pairedAsset.width ?? 1280;
  }

  int _effectiveFrameHeight() {
    if (_state.frameHeight > 0) return _state.frameHeight;
    return pairedAsset.height ?? 853;
  }

  void _commitRecipe(
    EditRecipe nextRecipe, {
    required bool triggerDnaRender,
  }) {
    if (_recipesEqual(_committedRecipe, nextRecipe)) {
      _state = _state.copyWith(recipe: nextRecipe);
      notifyListeners();
      if (triggerDnaRender) _requestRender(nextRecipe.dnaRescue);
      return;
    }

    _undoStack.add(_committedRecipe);
    if (_undoStack.length > maxUndoDepth) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
    _committedRecipe = nextRecipe;
    _persistRecipe(nextRecipe);

    _state = _state.copyWith(
      recipe: nextRecipe,
      canUndo: _undoStack.isNotEmpty,
      canRedo: false,
    );
    notifyListeners();
    if (triggerDnaRender) {
      _requestRender(nextRecipe.dnaRescue);
    }
  }

  void _persistRecipe(EditRecipe nextRecipe) {
    _sessionController.updateItemEditRecipe(itemId, nextRecipe);
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

  static bool _dnaSpecsEqual(DnaRescueSpec a, DnaRescueSpec b) {
    return a.enabled == b.enabled &&
        a.shadowLift == b.shadowLift &&
        DnaRescueMapper.readMode(a) == DnaRescueMapper.readMode(b) &&
        DnaRescueMapper.readMidtoneAnchor(a) ==
            DnaRescueMapper.readMidtoneAnchor(b) &&
        DnaRescueMapper.readHighlightProtect(a) ==
            DnaRescueMapper.readHighlightProtect(b);
  }

  static bool _geometrySpecsEqual(GeometrySpec a, GeometrySpec b) {
    if ((a.rotationDeg - b.rotationDeg).abs() > 1e-4) return false;
    if (a.aspectRatio != b.aspectRatio) return false;
    if (a.flipHorizontal != b.flipHorizontal) return false;
    final ca = a.cropBox;
    final cb = b.cropBox;
    if (ca == null && cb == null) return true;
    if (ca == null || cb == null || ca.length != cb.length) return false;
    for (var i = 0; i < ca.length; i++) {
      if ((ca[i] - cb[i]).abs() > 1e-4) return false;
    }
    return true;
  }

  static bool _recipesEqual(EditRecipe a, EditRecipe b) {
    return _dnaSpecsEqual(a.dnaRescue, b.dnaRescue) &&
        _geometrySpecsEqual(a.geometry, b.geometry);
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
