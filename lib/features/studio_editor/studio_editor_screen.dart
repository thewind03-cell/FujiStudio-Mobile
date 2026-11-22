import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/di/app_providers.dart';
import '../../core/ffi/bindings.g.dart';
import '../../core/storage/asset_pairing_engine.dart';
import '../../core/theme/fuji_theme.dart';
import 'dna_rescue_mapper.dart';
import 'studio_editor_controller.dart';

/// Mechanical Fujifilm darkroom studio screen for DNA-Aware Shadow Rescue.
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
                spec: spec,
                isDeepMode: isDeepMode,
                isAnalyzing: state.isAnalyzing,
                isDraggingSlider: _isDraggingSlider,
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildViewport(StudioEditorState state, dynamic displayImage) {
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

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        GestureDetector(
          key: const Key('studio_image_viewport'),
          onLongPressStart: (_) => _controller.setShowingBefore(true),
          onLongPressEnd: (_) => _controller.setShowingBefore(false),
          onLongPressCancel: () => _controller.setShowingBefore(false),
          child: InteractiveViewer(
            minScale: 1.0,
            maxScale: 3.0,
            child: Center(
              child: RawImage(
                image: displayImage,
                fit: BoxFit.contain,
              ),
            ),
          ),
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
    required this.spec,
    required this.isDeepMode,
    required this.isAnalyzing,
    required this.isDraggingSlider,
    required this.onToggleEnabled,
    required this.onAutoRescue,
    required this.onToggleMode,
    required this.onSliderStart,
    required this.onSliderChanged,
    required this.onSliderEnd,
  });

  final dynamic spec;
  final bool isDeepMode;
  final bool isAnalyzing;
  final bool isDraggingSlider;
  final VoidCallback onToggleEnabled;
  final VoidCallback onAutoRescue;
  final VoidCallback onToggleMode;
  final ValueChanged<double> onSliderStart;
  final ValueChanged<double> onSliderChanged;
  final ValueChanged<double> onSliderEnd;

  @override
  Widget build(BuildContext context) {
    final bool enabled = spec.enabled as bool;
    final double shadowLift = (spec.shadowLift as double).clamp(0.0, 100.0);

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
          // Row 1: 3 mechanical 1-tap switches
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
          // Row 2: Ticked SHADOW LIFT slider (0..100)
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
          const SizedBox(height: 6),
          // Row 3: Minimalist bottom tool selector (Slice 2 scope lock)
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
                    active: true,
                    onTap: () {},
                  ),
                ),
                Expanded(
                  child: _ToolTab(
                    key: const Key('studio_tab_crop'),
                    label: 'CÂN & CROP',
                    active: false,
                    onTap: () => _showPlaceholder(context, 'Sẵn sàng ở Lát cắt 3'),
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
