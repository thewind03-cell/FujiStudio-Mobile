import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/di/app_providers.dart';
import '../../core/ffi/bindings.g.dart';
import '../../core/ffi/native_worker.dart';
import '../../core/schema/action_proposal.dart';
import '../../core/schema/edit_recipe.dart';
import '../../core/storage/asset_pairing_engine.dart';
import '../../core/theme/fuji_theme.dart';
import 'dna_rescue_mapper.dart';
import 'geometry_mapper.dart';
import 'studio_editor_controller.dart';

/// Mechanical Fujifilm darkroom studio screen for DNA-Aware Shadow Rescue and
/// 120fps Horizon Leveling / Social Crop.
class StudioEditorScreen extends ConsumerStatefulWidget {
  const StudioEditorScreen({
    super.key,
    required this.itemId,
    required this.pairedAsset,
  });

  final String itemId;
  final PairedAsset pairedAsset;

  @override
  ConsumerState<StudioEditorScreen> createState() => _StudioEditorScreenState();
}

class _StudioEditorScreenState extends ConsumerState<StudioEditorScreen> {
  late final StudioEditorController _controller;
  bool _isDraggingSlider = false;
  int _lastHapticStep = -1;
  int _lastDialHapticStep = 0;
  bool _wasSnappedZero = true;
  bool _allowPop = false;
  bool _isPopping = false;

  @override
  void initState() {
    super.initState();
    _controller = StudioEditorController(
      itemId: widget.itemId,
      pairedAsset: widget.pairedAsset,
      sessionController: ref.read(sessionControllerProvider.notifier),
      proxyCacheManager: ref.read(proxyCacheManagerProvider),
      nativeGateway: ref.read(studioNativeGatewayProvider),
      frameLoader: ref.read(studioFrameLoaderProvider),
    )..addListener(_onControllerUpdate);
    unawaited(_controller.initialize());
  }

  void _onControllerUpdate() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerUpdate);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleBack() async {
    if (_isPopping) return;
    _isPopping = true;
    try {
      await _controller.flushPendingSave();
      if (!mounted) return;
      setState(() {
        _allowPop = true;
      });
      Navigator.of(context).pop();
    } finally {
      if (mounted && !_allowPop) {
        _isPopping = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final spec = state.spec;
    final geom = state.geometry;
    final mode = DnaRescueMapper.readMode(spec);
    final isDeepMode = mode == FsDnaRescueMode.FS_DNA_MODE_DEEP_RESCUE.value;
    final displayImage = state.showingBefore
        ? state.originalImage
        : (state.editedImage ?? state.originalImage);

    final telemetryText = state.lastRenderTimeMs > 0
        ? '${state.fileName} · ${state.lastRenderTimeMs.toStringAsFixed(1)}ms'
        : state.fileName;

    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleBack());
      },
      child: Scaffold(
        backgroundColor: FujiColors.canvas,
        body: SafeArea(
          child: Column(
            children: <Widget>[
              _StudioTopBar(
                telemetryText: telemetryText,
                canUndo: state.canUndo,
                canRedo: state.canRedo,
                canReset: state.canReset,
                onBack: () => unawaited(_handleBack()),
                onUndo: _controller.undo,
                onRedo: _controller.redo,
                onReset: _controller.resetToDefault,
              ),
              Expanded(
                child: _buildViewport(state, displayImage),
              ),
              _StudioControlDeck(
                activeTool: state.activeTool,
                spec: spec,
                geometry: geom,
                pendingProposal: state.pendingProposal,
                isDeepMode: isDeepMode,
                isAnalyzing: state.isAnalyzing,
                isAnalyzingGeometry: state.isAnalyzingGeometry,
                isDraggingSlider: _isDraggingSlider,
                onSelectTool: _controller.setActiveTool,
                onToggleEnabled: () {
                  unawaited(HapticFeedback.selectionClick());
                  _controller.toggleEnabled();
                },
                onAutoRescue: () {
                  unawaited(HapticFeedback.mediumImpact());
                  unawaited(_controller.applyAutoRescue());
                },
                onToggleMode: () {
                  unawaited(HapticFeedback.selectionClick());
                  final nextMode = isDeepMode
                      ? FsDnaRescueMode.FS_DNA_MODE_SOOC_SAFE.value
                      : FsDnaRescueMode.FS_DNA_MODE_DEEP_RESCUE.value;
                  _controller.setMode(nextMode);
                },
                onSliderStart: (v) {
                  _lastHapticStep = (v / 5.0).round();
                  setState(() {
                    _isDraggingSlider = true;
                  });
                },
                onSliderChanged: (v) {
                  final step = (v / 5.0).round();
                  if (step != _lastHapticStep) {
                    _lastHapticStep = step;
                    unawaited(HapticFeedback.selectionClick());
                  }
                  _controller.previewShadowLift(v);
                },
                onSliderEnd: (v) {
                  setState(() {
                    _isDraggingSlider = false;
                  });
                  _controller.commitShadowLift(v);
                },
                onAutoGeometry: () {
                  unawaited(HapticFeedback.mediumImpact());
                  unawaited(_controller.runAutoHorizonAndCrop());
                },
                onAcceptProposal: () {
                  unawaited(HapticFeedback.mediumImpact());
                  _controller.acceptPendingProposal();
                },
                onRejectProposal: () {
                  unawaited(HapticFeedback.selectionClick());
                  _controller.rejectPendingProposal();
                },
                onZeroAngle: () {
                  unawaited(HapticFeedback.mediumImpact());
                  _controller.previewRotationDeg(0.0);
                  _controller.commitGeometryChange();
                },
                onDialStart: (deg) {
                  _lastDialHapticStep = (deg / 0.5).round();
                  _wasSnappedZero = deg.abs() < 0.05;
                },
                onDialChanged: (deg) {
                  var next = deg.clamp(-15.0, 15.0);
                  if (next.abs() < 0.22) {
                    next = 0.0;
                    if (!_wasSnappedZero) {
                      _wasSnappedZero = true;
                      unawaited(HapticFeedback.mediumImpact());
                    }
                  } else {
                    _wasSnappedZero = false;
                    final step = (next / 0.5).round();
                    if (step != _lastDialHapticStep) {
                      _lastDialHapticStep = step;
                      unawaited(HapticFeedback.selectionClick());
                    }
                  }
                  _controller.previewRotationDeg(next);
                },
                onDialEnd: _controller.commitGeometryChange,
                onSelectAspect: (preset) {
                  unawaited(HapticFeedback.selectionClick());
                  _controller.selectAspectRatio(preset);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildViewport(StudioEditorState state, ui.Image? displayImage) {
    if (state.isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: FujiColors.accent),
      );
    }

    if (state.errorMessage != null && displayImage == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            state.errorMessage!,
            style: const TextStyle(color: FujiColors.textSecondary),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (displayImage == null) {
      return const Center(
        child: Icon(
          Icons.broken_image_outlined,
          size: 40,
          color: FujiColors.textSecondary,
        ),
      );
    }

    final isGeometryTab = state.activeTool == StudioToolTab.geometry;
    final hasGeomEdit = GeometryMapper.isEdited(state.geometry);

    Widget content;
    if (state.showingBefore) {
      content = InteractiveViewer(
        minScale: 1.0,
        maxScale: 3.0,
        child: Center(
          child: RawImage(
            image: displayImage,
            fit: BoxFit.contain,
          ),
        ),
      );
    } else if (isGeometryTab) {
      content = _GeometryCropViewport(
        image: displayImage,
        geometry: state.geometry,
        onPreviewCropBox: _controller.previewCropBox,
        onCommitCropBox: _controller.commitGeometryChange,
      );
    } else if (hasGeomEdit) {
      content = InteractiveViewer(
        minScale: 1.0,
        maxScale: 3.0,
        child: _GeometryCroppedPreview(
          image: displayImage,
          geometry: state.geometry,
        ),
      );
    } else {
      content = InteractiveViewer(
        minScale: 1.0,
        maxScale: 3.0,
        child: Center(
          child: RawImage(
            image: displayImage,
            fit: BoxFit.contain,
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        GestureDetector(
          key: const Key('studio_image_viewport'),
          onLongPressStart: (_) => _controller.setShowingBefore(true),
          onLongPressEnd: (_) => _controller.setShowingBefore(false),
          onLongPressCancel: () => _controller.setShowingBefore(false),
          child: content,
        ),
        if (state.showingBefore)
          Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                key: const Key('studio_before_badge'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xCC0E0F11),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: FujiColors.accent, width: 1),
                ),
                child: const Text(
                  'GỐC (SOOC)',
                  style: TextStyle(
                    color: FujiColors.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          top: 10,
          right: 10,
          child: InkWell(
            key: const Key('studio_compare_button'),
            onTap: () => _controller.setShowingBefore(!state.showingBefore),
            borderRadius: BorderRadius.circular(4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: state.showingBefore
                    ? FujiColors.accent.withValues(alpha: 0.2)
                    : const Color(0xB317191D),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: state.showingBefore
                      ? FujiColors.accent
                      : FujiColors.border,
                  width: 1,
                ),
              ),
              child: Text(
                'GỐC',
                style: TextStyle(
                  color: state.showingBefore
                      ? FujiColors.accent
                      : FujiColors.textPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

enum _CropDragHandle { none, move, topLeft, topRight, bottomLeft, bottomRight }

class _GeometryCropViewport extends StatefulWidget {
  const _GeometryCropViewport({
    required this.image,
    required this.geometry,
    required this.onPreviewCropBox,
    required this.onCommitCropBox,
  });

  final ui.Image image;
  final GeometrySpec geometry;
  final ValueChanged<NormCropBoxData> onPreviewCropBox;
  final VoidCallback onCommitCropBox;

  @override
  State<_GeometryCropViewport> createState() => _GeometryCropViewportState();
}

class _GeometryCropViewportState extends State<_GeometryCropViewport> {
  _CropDragHandle _activeHandle = _CropDragHandle.none;
  Rect _inscribedRect = Rect.zero;
  NormCropBoxData _dragStartBox = NormCropBoxData.full;
  Offset _dragStartPos = Offset.zero;

  Rect _computeInscribedRect(Size viewportSize) {
    const pad = 16.0;
    final availW = math.max(32.0, viewportSize.width - 2 * pad);
    final availH = math.max(32.0, viewportSize.height - 2 * pad);
    final inscr = GeometryMath.computeInscribedFrame(
      widget.image.width,
      widget.image.height,
      widget.geometry.rotationDeg,
    );
    final inscrAspect = inscr.widthPx / math.max(1e-6, inscr.heightPx);
    double rectW;
    double rectH;
    if (availW / availH > inscrAspect) {
      rectH = availH;
      rectW = rectH * inscrAspect;
    } else {
      rectW = availW;
      rectH = rectW / inscrAspect;
    }
    return Rect.fromCenter(
      center: Offset(viewportSize.width / 2, viewportSize.height / 2),
      width: rectW,
      height: rectH,
    );
  }

  Rect _cropRectFromBox(Rect inscrRect, NormCropBoxData box) {
    return Rect.fromLTRB(
      inscrRect.left + box.left * inscrRect.width,
      inscrRect.top + box.top * inscrRect.height,
      inscrRect.left + box.right * inscrRect.width,
      inscrRect.top + box.bottom * inscrRect.height,
    );
  }

  _CropDragHandle _hitTestHandle(Offset localPos, Rect cropRect) {
    const hitRadius = 28.0;
    if ((localPos - cropRect.topLeft).distance <= hitRadius) {
      return _CropDragHandle.topLeft;
    }
    if ((localPos - cropRect.topRight).distance <= hitRadius) {
      return _CropDragHandle.topRight;
    }
    if ((localPos - cropRect.bottomLeft).distance <= hitRadius) {
      return _CropDragHandle.bottomLeft;
    }
    if ((localPos - cropRect.bottomRight).distance <= hitRadius) {
      return _CropDragHandle.bottomRight;
    }
    if (cropRect.inflate(8.0).contains(localPos)) {
      return _CropDragHandle.move;
    }
    return _CropDragHandle.none;
  }

  void _onPanStart(DragStartDetails details) {
    if (_inscribedRect.width <= 0 || _inscribedRect.height <= 0) return;
    final box = GeometryMapper.normBoxFromSpec(widget.geometry);
    final cropRect = _cropRectFromBox(_inscribedRect, box);
    _activeHandle = _hitTestHandle(details.localPosition, cropRect);
    _dragStartBox = box;
    _dragStartPos = details.localPosition;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_activeHandle == _CropDragHandle.none ||
        _inscribedRect.width <= 0 ||
        _inscribedRect.height <= 0) {
      return;
    }
    final dxNorm =
        (details.localPosition.dx - _dragStartPos.dx) / _inscribedRect.width;
    final dyNorm =
        (details.localPosition.dy - _dragStartPos.dy) / _inscribedRect.height;

    if (_activeHandle == _CropDragHandle.move) {
      final nw = _dragStartBox.right - _dragStartBox.left;
      final nh = _dragStartBox.bottom - _dragStartBox.top;
      final nextL = (_dragStartBox.left + dxNorm).clamp(0.0, 1.0 - nw);
      final nextT = (_dragStartBox.top + dyNorm).clamp(0.0, 1.0 - nh);
      widget.onPreviewCropBox(
        NormCropBoxData(
          left: nextL,
          top: nextT,
          right: nextL + nw,
          bottom: nextT + nh,
        ),
      );
      return;
    }

    // Corner resize anchored at the opposite corner with locked aspect ratio.
    final preset =
        GeometryMapper.aspectPresetFromString(widget.geometry.aspectRatio);
    final r0 = widget.image.width / math.max(1, widget.image.height);
    final targetR = GeometryMath.aspectRatioForPreset(
      preset,
      widget.image.width,
      widget.image.height,
    );
    final k = targetR / r0; // nw = k * nh

    final anchorX = (_activeHandle == _CropDragHandle.topLeft ||
            _activeHandle == _CropDragHandle.bottomLeft)
        ? _dragStartBox.right
        : _dragStartBox.left;
    final anchorY = (_activeHandle == _CropDragHandle.topLeft ||
            _activeHandle == _CropDragHandle.topRight)
        ? _dragStartBox.bottom
        : _dragStartBox.top;

    final dragX = ((_activeHandle == _CropDragHandle.topLeft ||
                _activeHandle == _CropDragHandle.bottomLeft)
            ? _dragStartBox.left + dxNorm
            : _dragStartBox.right + dxNorm)
        .clamp(0.0, 1.0);
    final dragY = ((_activeHandle == _CropDragHandle.topLeft ||
                _activeHandle == _CropDragHandle.topRight)
            ? _dragStartBox.top + dyNorm
            : _dragStartBox.bottom + dyNorm)
        .clamp(0.0, 1.0);

    final isLeft = _activeHandle == _CropDragHandle.topLeft ||
        _activeHandle == _CropDragHandle.bottomLeft;
    final isTop = _activeHandle == _CropDragHandle.topLeft ||
        _activeHandle == _CropDragHandle.topRight;

    final maxSpanX = isLeft ? anchorX : (1.0 - anchorX);
    final maxSpanY = isTop ? anchorY : (1.0 - anchorY);
    final maxNh = math.min(maxSpanY, maxSpanX / k);
    final minNh = math.min(maxNh, math.max(0.10, 0.10 / k));

    final rawW = (isLeft ? (anchorX - dragX) : (dragX - anchorX)).clamp(0.0, maxSpanX);
    final rawH = (isTop ? (anchorY - dragY) : (dragY - anchorY)).clamp(0.0, maxSpanY);
    final nh = math.min(rawH, rawW / k).clamp(minNh, maxNh);
    final nw = k * nh;

    final l = isLeft ? (anchorX - nw) : anchorX;
    final r = isLeft ? anchorX : (anchorX + nw);
    final t = isTop ? (anchorY - nh) : anchorY;
    final b = isTop ? anchorY : (anchorY + nh);

    widget.onPreviewCropBox(
      NormCropBoxData(left: l, top: t, right: r, bottom: b),
    );
  }

  void _onPanEnd(DragEndDetails _) {
    if (_activeHandle != _CropDragHandle.none) {
      _activeHandle = _CropDragHandle.none;
      widget.onCommitCropBox();
    }
  }

  void _onPanCancel() {
    if (_activeHandle != _CropDragHandle.none) {
      _activeHandle = _CropDragHandle.none;
      widget.onCommitCropBox();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _inscribedRect = _computeInscribedRect(size);
        final box = GeometryMapper.normBoxFromSpec(widget.geometry);
        final cropRect = _cropRectFromBox(_inscribedRect, box);

        return GestureDetector(
          key: const Key('geometry_crop_overlay'),
          behavior: HitTestBehavior.opaque,
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onPanCancel: _onPanCancel,
          child: CustomPaint(
            size: size,
            painter: _GeometryCropOverlayPainter(
              image: widget.image,
              rotationDeg: widget.geometry.rotationDeg,
              inscribedRect: _inscribedRect,
              cropRect: cropRect,
            ),
          ),
        );
      },
    );
  }
}

class _GeometryCropOverlayPainter extends CustomPainter {
  const _GeometryCropOverlayPainter({
    required this.image,
    required this.rotationDeg,
    required this.inscribedRect,
    required this.cropRect,
  });

  final ui.Image image;
  final double rotationDeg;
  final Rect inscribedRect;
  final Rect cropRect;

  @override
  void paint(Canvas canvas, Size size) {
    if (inscribedRect.width <= 0 || inscribedRect.height <= 0) return;

    final inscr = GeometryMath.computeInscribedFrame(
      image.width,
      image.height,
      rotationDeg,
    );
    final scale = inscribedRect.width / math.max(1e-6, inscr.widthPx);
    final theta = rotationDeg.clamp(-15.0, 15.0) * (math.pi / 180.0);

    // 1. Draw rotated image clipped strictly to the zero-black-corners inscribed rect.
    canvas.save();
    canvas.clipRect(inscribedRect);
    canvas.translate(inscribedRect.center.dx, inscribedRect.center.dy);
    canvas.scale(scale, scale);
    canvas.rotate(theta);
    final imgRect = Rect.fromCenter(
      center: Offset.zero,
      width: image.width.toDouble(),
      height: image.height.toDouble(),
    );
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      imgRect,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();

    // 2. Dark translucent mask outside cropRect inside inscribedRect.
    final maskPaint = Paint()..color = const Color(0x990E0F11);
    canvas.drawRect(
      Rect.fromLTRB(
        inscribedRect.left,
        inscribedRect.top,
        inscribedRect.right,
        cropRect.top,
      ),
      maskPaint,
    );
    canvas.drawRect(
      Rect.fromLTRB(
        inscribedRect.left,
        cropRect.bottom,
        inscribedRect.right,
        inscribedRect.bottom,
      ),
      maskPaint,
    );
    canvas.drawRect(
      Rect.fromLTRB(
        inscribedRect.left,
        cropRect.top,
        cropRect.left,
        cropRect.bottom,
      ),
      maskPaint,
    );
    canvas.drawRect(
      Rect.fromLTRB(
        cropRect.right,
        cropRect.top,
        inscribedRect.right,
        cropRect.bottom,
      ),
      maskPaint,
    );

    // 3. Rule-of-Thirds 1px grid inside cropRect.
    final gridPaint = Paint()
      ..color = const Color(0x66F2F2F0)
      ..strokeWidth = 1.0;
    for (var i = 1; i <= 2; i++) {
      final gx = cropRect.left + cropRect.width * (i / 3.0);
      final gy = cropRect.top + cropRect.height * (i / 3.0);
      canvas.drawLine(
        Offset(gx, cropRect.top),
        Offset(gx, cropRect.bottom),
        gridPaint,
      );
      canvas.drawLine(
        Offset(cropRect.left, gy),
        Offset(cropRect.right, gy),
        gridPaint,
      );
    }

    // 4. Crisp border + 4 mechanical #E5A93C corner L-handles.
    final borderPaint = Paint()
      ..color = FujiColors.accent.withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRect(cropRect, borderPaint);

    final cornerPaint = Paint()
      ..color = FujiColors.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.square;
    final arm = math.min(
      18.0,
      math.min(cropRect.width, cropRect.height) * 0.3,
    );

    // Top-left
    canvas.drawLine(
      cropRect.topLeft,
      cropRect.topLeft + Offset(arm, 0),
      cornerPaint,
    );
    canvas.drawLine(
      cropRect.topLeft,
      cropRect.topLeft + Offset(0, arm),
      cornerPaint,
    );
    // Top-right
    canvas.drawLine(
      cropRect.topRight,
      cropRect.topRight + Offset(-arm, 0),
      cornerPaint,
    );
    canvas.drawLine(
      cropRect.topRight,
      cropRect.topRight + Offset(0, arm),
      cornerPaint,
    );
    // Bottom-left
    canvas.drawLine(
      cropRect.bottomLeft,
      cropRect.bottomLeft + Offset(arm, 0),
      cornerPaint,
    );
    canvas.drawLine(
      cropRect.bottomLeft,
      cropRect.bottomLeft + Offset(0, -arm),
      cornerPaint,
    );
    // Bottom-right
    canvas.drawLine(
      cropRect.bottomRight,
      cropRect.bottomRight + Offset(-arm, 0),
      cornerPaint,
    );
    canvas.drawLine(
      cropRect.bottomRight,
      cropRect.bottomRight + Offset(0, -arm),
      cornerPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _GeometryCropOverlayPainter oldDelegate) {
    return !identical(oldDelegate.image, image) ||
        oldDelegate.rotationDeg != rotationDeg ||
        oldDelegate.inscribedRect != inscribedRect ||
        oldDelegate.cropRect != cropRect;
  }
}

class _GeometryCroppedPreview extends StatelessWidget {
  const _GeometryCroppedPreview({
    required this.image,
    required this.geometry,
  });

  final ui.Image image;
  final GeometrySpec geometry;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return CustomPaint(
          size: size,
          painter: _GeometryCroppedPreviewPainter(
            image: image,
            geometry: geometry,
          ),
        );
      },
    );
  }
}

class _GeometryCroppedPreviewPainter extends CustomPainter {
  const _GeometryCroppedPreviewPainter({
    required this.image,
    required this.geometry,
  });

  final ui.Image image;
  final GeometrySpec geometry;

  @override
  void paint(Canvas canvas, Size size) {
    final rotDeg = geometry.rotationDeg.clamp(-15.0, 15.0);
    final preset = GeometryMapper.aspectPresetFromString(geometry.aspectRatio);
    final clamped = GeometryMath.clampCrop(
      srcWidth: image.width,
      srcHeight: image.height,
      rotationDeg: rotDeg,
      aspectPreset: preset,
      requestedBox: GeometryMapper.normBoxFromSpec(geometry),
    ).clampedBox;

    final inscr = GeometryMath.computeInscribedFrame(
      image.width,
      image.height,
      rotDeg,
    );
    final boxW = (clamped.right - clamped.left) * inscr.widthPx;
    final boxH = (clamped.bottom - clamped.top) * inscr.heightPx;
    final boxAspect = boxW / math.max(1e-6, boxH);

    double dstW;
    double dstH;
    if (size.width / math.max(1.0, size.height) > boxAspect) {
      dstH = size.height;
      dstW = dstH * boxAspect;
    } else {
      dstW = size.width;
      dstH = dstW / boxAspect;
    }
    final dstRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: dstW,
      height: dstH,
    );

    final scale = dstW / math.max(1e-6, boxW);
    final offsetX = ((clamped.left + clamped.right) * 0.5 - 0.5) * inscr.widthPx;
    final offsetY = ((clamped.top + clamped.bottom) * 0.5 - 0.5) * inscr.heightPx;
    final theta = rotDeg * (math.pi / 180.0);

    canvas.save();
    canvas.clipRect(dstRect);
    canvas.translate(dstRect.center.dx, dstRect.center.dy);
    canvas.scale(scale, scale);
    canvas.translate(-offsetX, -offsetY);
    canvas.rotate(theta);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(
        center: Offset.zero,
        width: image.width.toDouble(),
        height: image.height.toDouble(),
      ),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GeometryCroppedPreviewPainter oldDelegate) {
    return !identical(oldDelegate.image, image) ||
        oldDelegate.geometry.rotationDeg != geometry.rotationDeg ||
        oldDelegate.geometry.aspectRatio != geometry.aspectRatio ||
        oldDelegate.geometry.cropBox != geometry.cropBox;
  }
}

class _StudioTopBar extends StatelessWidget {
  const _StudioTopBar({
    required this.telemetryText,
    required this.canUndo,
    required this.canRedo,
    required this.canReset,
    required this.onBack,
    required this.onUndo,
    required this.onRedo,
    required this.onReset,
  });

  final String telemetryText;
  final bool canUndo;
  final bool canRedo;
  final bool canReset;
  final VoidCallback onBack;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(
        color: FujiColors.canvas,
        border: Border(
          bottom: BorderSide(color: FujiColors.border, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const Key('studio_back_button'),
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: onBack,
          ),
          Expanded(
            child: Text(
              telemetryText,
              key: const Key('studio_telemetry_text'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: FujiColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFeatures: FujiTheme.tabularFeatures,
              ),
            ),
          ),
          IconButton(
            key: const Key('studio_undo_button'),
            tooltip: 'Hoàn tác',
            icon: Icon(
              Icons.undo,
              size: 19,
              color: canUndo ? FujiColors.textPrimary : FujiColors.border,
            ),
            onPressed: canUndo ? onUndo : null,
          ),
          IconButton(
            key: const Key('studio_redo_button'),
            tooltip: 'Làm lại',
            icon: Icon(
              Icons.redo,
              size: 19,
              color: canRedo ? FujiColors.textPrimary : FujiColors.border,
            ),
            onPressed: canRedo ? onRedo : null,
          ),
          TextButton(
            key: const Key('studio_reset_button'),
            onPressed: canReset ? onReset : null,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: canReset
                  ? FujiColors.accent
                  : FujiColors.textSecondary,
            ),
            child: const Text(
              'ĐẶT LẠI',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StudioControlDeck extends StatelessWidget {
  const _StudioControlDeck({
    required this.activeTool,
    required this.spec,
    required this.geometry,
    required this.pendingProposal,
    required this.isDeepMode,
    required this.isAnalyzing,
    required this.isAnalyzingGeometry,
    required this.isDraggingSlider,
    required this.onSelectTool,
    required this.onToggleEnabled,
    required this.onAutoRescue,
    required this.onToggleMode,
    required this.onSliderStart,
    required this.onSliderChanged,
    required this.onSliderEnd,
    required this.onAutoGeometry,
    required this.onAcceptProposal,
    required this.onRejectProposal,
    required this.onZeroAngle,
    required this.onDialStart,
    required this.onDialChanged,
    required this.onDialEnd,
    required this.onSelectAspect,
  });

  final StudioToolTab activeTool;
  final DnaRescueSpec spec;
  final GeometrySpec geometry;
  final ActionProposal? pendingProposal;
  final bool isDeepMode;
  final bool isAnalyzing;
  final bool isAnalyzingGeometry;
  final bool isDraggingSlider;
  final ValueChanged<StudioToolTab> onSelectTool;
  final VoidCallback onToggleEnabled;
  final VoidCallback onAutoRescue;
  final VoidCallback onToggleMode;
  final ValueChanged<double> onSliderStart;
  final ValueChanged<double> onSliderChanged;
  final ValueChanged<double> onSliderEnd;
  final VoidCallback onAutoGeometry;
  final VoidCallback onAcceptProposal;
  final VoidCallback onRejectProposal;
  final VoidCallback onZeroAngle;
  final ValueChanged<double> onDialStart;
  final ValueChanged<double> onDialChanged;
  final VoidCallback onDialEnd;
  final ValueChanged<int> onSelectAspect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: FujiColors.surface,
        border: Border(
          top: BorderSide(color: FujiColors.border, width: 1),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (activeTool == StudioToolTab.dnaRescue)
            _buildDnaRescueDeck(context)
          else
            _buildGeometryDeck(),
          const SizedBox(height: 6),
          // Bottom tool selector
          Container(
            padding: const EdgeInsets.only(top: 6),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: FujiColors.border, width: 1),
              ),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _ToolTab(
                    key: const Key('studio_tab_rescue'),
                    label: 'CỨU TỐI',
                    active: activeTool == StudioToolTab.dnaRescue,
                    onTap: () => onSelectTool(StudioToolTab.dnaRescue),
                  ),
                ),
                Expanded(
                  child: _ToolTab(
                    key: const Key('studio_tab_crop'),
                    label: 'CÂN & CROP',
                    active: activeTool == StudioToolTab.geometry,
                    onTap: () => onSelectTool(StudioToolTab.geometry),
                  ),
                ),
                Expanded(
                  child: _ToolTab(
                    key: const Key('studio_tab_export'),
                    label: 'XUẤT 2048',
                    active: false,
                    onTap: () => _showPlaceholder(context, 'Sẵn sàng ở Lát cắt 4'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDnaRescueDeck(BuildContext context) {
    final bool enabled = spec.enabled;
    final double shadowLift = spec.shadowLift.clamp(0.0, 100.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: _MechanicalSwitchButton(
                key: const Key('studio_toggle_button'),
                label: enabled ? '● BẬT' : '○ TẮT',
                active: enabled,
                activeColor: FujiColors.keep,
                onPressed: onToggleEnabled,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MechanicalSwitchButton(
                key: const Key('studio_auto_button'),
                label: isAnalyzing ? 'ĐANG PHÂN TÍCH' : '✦ TỰ ĐỘNG',
                active: false,
                activeColor: FujiColors.accent,
                onPressed: isAnalyzing ? null : onAutoRescue,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MechanicalSwitchButton(
                key: const Key('studio_mode_button'),
                label: isDeepMode ? 'DEEP RESCUE' : 'SOOC SAFE',
                active: isDeepMode,
                activeColor: FujiColors.accent,
                onPressed: onToggleMode,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            const Text(
              'SHADOW LIFT',
              style: TextStyle(
                color: FujiColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
            Text(
              '${shadowLift.round()}',
              key: const Key('studio_shadow_value'),
              style: TextStyle(
                color: isDraggingSlider || enabled
                    ? FujiColors.accent
                    : FujiColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                fontFeatures: FujiTheme.tabularFeatures,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 36,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              const Positioned.fill(
                child: IgnorePointer(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20),
                    child: CustomPaint(
                      painter: _MechanicalTicksPainter(),
                    ),
                  ),
                ),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: FujiColors.accent,
                  inactiveTrackColor: FujiColors.border,
                  thumbColor: FujiColors.textPrimary,
                  overlayColor: FujiColors.accent.withValues(alpha: 0.16),
                  trackHeight: 2,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                ),
                child: Slider(
                  key: const Key('studio_shadow_slider'),
                  min: 0,
                  max: 100,
                  value: shadowLift,
                  onChangeStart: onSliderStart,
                  onChanged: onSliderChanged,
                  onChangeEnd: onSliderEnd,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGeometryDeck() {
    final angle = geometry.rotationDeg.clamp(-15.0, 15.0);
    final currentPreset =
        GeometryMapper.aspectPresetFromString(geometry.aspectRatio);
    final proposal = pendingProposal;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (proposal != null) ...<Widget>[
          Container(
            key: const Key('geometry_proposal_banner'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: FujiColors.surfaceElevated,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: FujiColors.accent, width: 1),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    proposal.summary ?? 'Đề xuất cân & crop',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: FujiColors.textPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      fontFeatures: FujiTheme.tabularFeatures,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  key: const Key('geometry_proposal_accept'),
                  onPressed: onAcceptProposal,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(52, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    backgroundColor: FujiColors.accent.withValues(alpha: 0.18),
                    foregroundColor: FujiColors.accent,
                  ),
                  child: const Text(
                    'ÁP DỤNG',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 4),
                TextButton(
                  key: const Key('geometry_proposal_reject'),
                  onPressed: onRejectProposal,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(36, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    foregroundColor: FujiColors.textSecondary,
                  ),
                  child: const Text(
                    'BỎ',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
        ],
        Row(
          children: <Widget>[
            Expanded(
              flex: 2,
              child: _MechanicalSwitchButton(
                key: const Key('geometry_auto_button'),
                label: isAnalyzingGeometry
                    ? 'ĐANG PHÂN TÍCH'
                    : '✦ TỰ ĐỘNG CÂN & CROP',
                active: false,
                activeColor: FujiColors.accent,
                onPressed: isAnalyzingGeometry ? null : onAutoGeometry,
              ),
            ),
            const SizedBox(width: 8),
            _MechanicalSwitchButton(
              key: const Key('geometry_zero_angle_button'),
              label: '0.0° ↺',
              active: angle.abs() < 0.05,
              activeColor: FujiColors.textSecondary,
              onPressed: angle.abs() < 0.05 ? null : onZeroAngle,
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 56,
              child: Text(
                '${angle >= 0 ? '+' : ''}${angle.toStringAsFixed(1)}°',
                key: const Key('geometry_angle_value'),
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: angle.abs() > 0.05
                      ? FujiColors.accent
                      : FujiColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFeatures: FujiTheme.tabularFeatures,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _HorizonDial(
          key: const Key('geometry_horizon_dial'),
          angleDeg: angle,
          onStart: onDialStart,
          onChanged: onDialChanged,
          onEnd: onDialEnd,
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            _aspectChip(
              'geometry_aspect_original',
              'GỐC',
              FsAspectPreset.FS_ASPECT_ORIGINAL.value,
              currentPreset,
            ),
            const SizedBox(width: 6),
            _aspectChip(
              'geometry_aspect_4_5',
              '4:5',
              FsAspectPreset.FS_ASPECT_4_5.value,
              currentPreset,
            ),
            const SizedBox(width: 6),
            _aspectChip(
              'geometry_aspect_1_1',
              '1:1',
              FsAspectPreset.FS_ASPECT_1_1.value,
              currentPreset,
            ),
            const SizedBox(width: 6),
            _aspectChip(
              'geometry_aspect_3_2',
              '3:2',
              FsAspectPreset.FS_ASPECT_3_2.value,
              currentPreset,
            ),
            const SizedBox(width: 6),
            _aspectChip(
              'geometry_aspect_9_16',
              '9:16',
              FsAspectPreset.FS_ASPECT_9_16.value,
              currentPreset,
            ),
          ],
        ),
      ],
    );
  }

  Widget _aspectChip(
    String keyName,
    String label,
    int preset,
    int currentPreset,
  ) {
    final active = preset == currentPreset;
    return Expanded(
      child: InkWell(
        key: Key(keyName),
        onTap: () => onSelectAspect(preset),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? FujiColors.accent.withValues(alpha: 0.18)
                : FujiColors.canvas,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: active ? FujiColors.accent : FujiColors.border,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? FujiColors.accent : FujiColors.textPrimary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              fontFeatures: FujiTheme.tabularFeatures,
            ),
          ),
        ),
      ),
    );
  }

  static void _showPlaceholder(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
        ),
      );
  }
}

class _HorizonDial extends StatefulWidget {
  const _HorizonDial({
    super.key,
    required this.angleDeg,
    required this.onStart,
    required this.onChanged,
    required this.onEnd,
  });

  final double angleDeg;
  final ValueChanged<double> onStart;
  final ValueChanged<double> onChanged;
  final VoidCallback onEnd;

  @override
  State<_HorizonDial> createState() => _HorizonDialState();
}

class _HorizonDialState extends State<_HorizonDial> {
  double _accumDeg = 0.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) {
        _accumDeg = widget.angleDeg;
        widget.onStart(_accumDeg);
      },
      onHorizontalDragUpdate: (details) {
        _accumDeg = (_accumDeg - details.delta.dx * 0.10).clamp(-15.0, 15.0);
        widget.onChanged(_accumDeg);
      },
      onHorizontalDragEnd: (_) => widget.onEnd(),
      onHorizontalDragCancel: widget.onEnd,
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: FujiColors.canvas,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: FujiColors.border, width: 1),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: CustomPaint(
            painter: _HorizonDialPainter(angleDeg: widget.angleDeg),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class _HorizonDialPainter extends CustomPainter {
  const _HorizonDialPainter({required this.angleDeg});

  final double angleDeg;

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    const pxPerDeg = 12.0;

    final minorPaint = Paint()
      ..color = FujiColors.border
      ..strokeWidth = 1.0;
    final majorPaint = Paint()
      ..color = FujiColors.textSecondary
      ..strokeWidth = 1.4;
    final zeroPaint = Paint()
      ..color = FujiColors.textPrimary
      ..strokeWidth = 1.6;

    for (var deg = -15; deg <= 15; deg++) {
      final x = centerX + (deg - angleDeg) * pxPerDeg;
      if (x < 0 || x > size.width) continue;
      final isZero = deg == 0;
      final isMajor = deg % 5 == 0;
      final h = isZero ? 18.0 : (isMajor ? 14.0 : 8.0);
      final paint = isZero ? zeroPaint : (isMajor ? majorPaint : minorPaint);
      canvas.drawLine(
        Offset(x, size.height - h - 2),
        Offset(x, size.height - 2),
        paint,
      );
    }

    // Fixed center amber needle
    final needlePaint = Paint()
      ..color = FujiColors.accent
      ..strokeWidth = 2.0;
    canvas.drawLine(
      Offset(centerX, 2),
      Offset(centerX, size.height - 2),
      needlePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _HorizonDialPainter oldDelegate) {
    return oldDelegate.angleDeg != angleDeg;
  }
}

class _MechanicalSwitchButton extends StatelessWidget {
  const _MechanicalSwitchButton({
    super.key,
    required this.label,
    required this.active,
    required this.activeColor,
    required this.onPressed,
  });

  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        backgroundColor: active
            ? activeColor.withValues(alpha: 0.16)
            : FujiColors.canvas,
        foregroundColor: active ? activeColor : FujiColors.textPrimary,
        side: BorderSide(
          color: active ? activeColor : FujiColors.border,
          width: 1,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _MechanicalTicksPainter extends CustomPainter {
  const _MechanicalTicksPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = FujiColors.border
      ..strokeWidth = 1;
    const tickCount = 10;
    for (var i = 0; i <= tickCount; i++) {
      final x = (size.width * i) / tickCount;
      final isMajor = i % 5 == 0;
      final halfH = isMajor ? 8.0 : 4.5;
      final cy = size.height / 2;
      canvas.drawLine(Offset(x, cy - halfH), Offset(x, cy + halfH), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ToolTab extends StatelessWidget {
  const _ToolTab({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? FujiColors.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: active ? FujiColors.textPrimary : FujiColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }
}
