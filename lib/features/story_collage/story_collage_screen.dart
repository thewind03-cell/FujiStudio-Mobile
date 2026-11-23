import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/di/app_providers.dart';
import '../../core/schema/collage_spec.dart';
import '../../core/schema/session_item.dart';
import '../../core/theme/fuji_theme.dart';
import '../session_picker/session_controller.dart';
import '../social_export/export_mapper.dart';
import 'collage_mapper.dart';
import 'story_collage_controller.dart';

/// Shows a Fujifilm darkroom bottom sheet to pick 2-4 photos for Story Collage,
/// sorting `KEEP` items first.
Future<List<String>?> showCollageImagePickerSheet({
  required BuildContext context,
  required SessionState sessionState,
  List<String> initialSelectedIds = const <String>[],
}) {
  final keepItems = <SessionItem>[];
  final otherItems = <SessionItem>[];
  for (final id in sessionState.galleryOrderedItemIds) {
    final item = sessionState.itemById(id);
    if (item == null) continue;
    if (item.cullResult?.status == 'keep') {
      keepItems.add(item);
    } else {
      otherItems.add(item);
    }
  }
  final sortedItems = <SessionItem>[...keepItems, ...otherItems];

  return showModalBottomSheet<List<String>>(
    context: context,
    backgroundColor: FujiColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      side: BorderSide(color: FujiColors.border, width: 1),
    ),
    builder: (sheetCtx) {
      final selected = List<String>.of(initialSelectedIds);
      return StatefulBuilder(
        builder: (ctx, setSheetState) {
          final canConfirm = selected.length >= 2 && selected.length <= 4;
          return SafeArea(
            child: SizedBox(
              key: const Key('collage_picker_sheet'),
              height: math.min(MediaQuery.of(ctx).size.height * 0.72, 520),
              child: Column(
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
                    decoration: const BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: FujiColors.border, width: 1),
                      ),
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            'CHỌN 2–4 ẢNH (${selected.length}/4)',
                            style: const TextStyle(
                              color: FujiColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                              fontFeatures: FujiTheme.tabularFeatures,
                            ),
                          ),
                        ),
                        TextButton(
                          key: const Key('collage_picker_confirm'),
                          onPressed: canConfirm
                              ? () => Navigator.of(sheetCtx).pop(selected)
                              : null,
                          style: TextButton.styleFrom(
                            foregroundColor: FujiColors.accent,
                          ),
                          child: const Text(
                            'TẠO COLLAGE',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: sortedItems.length,
                      itemBuilder: (_, index) {
                        final item = sortedItems[index];
                        final isSelected = selected.contains(item.id);
                        final isKeep = item.cullResult?.status == 'keep';
                        return ListTile(
                          key: Key('collage_picker_item_${item.id}'),
                          dense: true,
                          onTap: () {
                            setSheetState(() {
                              if (isSelected) {
                                selected.remove(item.id);
                              } else if (selected.length < 4) {
                                selected.add(item.id);
                              }
                            });
                          },
                          leading: Icon(
                            isSelected
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                            color: isSelected
                                ? FujiColors.accent
                                : FujiColors.textSecondary,
                          ),
                          title: Text(
                            item.fileName,
                            style: const TextStyle(
                              color: FujiColors.textPrimary,
                              fontSize: 13,
                            ),
                          ),
                          trailing: isKeep
                              ? Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: FujiColors.keep.withValues(alpha: 0.16),
                                    borderRadius: BorderRadius.circular(3),
                                    border: Border.all(
                                      color: FujiColors.keep,
                                      width: 0.8,
                                    ),
                                  ),
                                  child: const Text(
                                    'CHỌN',
                                    style: TextStyle(
                                      color: FujiColors.keep,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                )
                              : null,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

/// Interactive 2-4 slot Story Collage composer backed by C++20
/// `fs_collage_render_rgba_into`.
class StoryCollageScreen extends ConsumerStatefulWidget {
  const StoryCollageScreen({
    super.key,
    required this.initialItemIds,
  });

  final List<String> initialItemIds;

  @override
  ConsumerState<StoryCollageScreen> createState() => _StoryCollageScreenState();
}

class _StoryCollageScreenState extends ConsumerState<StoryCollageScreen> {
  late final StoryCollageController _controller;
  bool _allowPop = false;
  bool _isPopping = false;
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _controller = StoryCollageController(
      initialItemIds: widget.initialItemIds,
      sessionController: ref.read(sessionControllerProvider.notifier),
      proxyCacheManager: ref.read(proxyCacheManagerProvider),
      nativeGateway: ref.read(collageNativeGatewayProvider),
      slotLoader: ref.read(collageSlotLoaderProvider),
    )..addListener(_onUpdate);
    unawaited(_controller.initialize());
  }

  void _onUpdate() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onUpdate);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleBack() async {
    if (_isPopping || _isExporting) return;
    _isPopping = true;
    try {
      if (_controller.state.hasUnsavedChanges) {
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: FujiColors.surface,
            title: const Text(
              'Lưu Story Collage?',
              style: TextStyle(color: FujiColors.textPrimary, fontSize: 15),
            ),
            content: const Text(
              'Bạn có thay đổi collage chưa lưu vào phiên.',
              style: TextStyle(color: FujiColors.textSecondary, fontSize: 13),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('stay'),
                child: const Text('Ở LẠI'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('discard'),
                child: const Text(
                  'BỎ QUA',
                  style: TextStyle(color: FujiColors.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('save'),
                child: const Text(
                  'LƯU & THOÁT',
                  style: TextStyle(color: FujiColors.accent),
                ),
              ),
            ],
          ),
        );
        if (!mounted || choice == null || choice == 'stay') {
          return;
        }
        if (choice == 'save') {
          _controller.saveCollage();
        }
      }

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

  Future<void> _openCppPreview() async {
    final preview = await _controller.renderCppPreview();
    if (preview == null) return;
    try {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('collage_cpp_preview_dialog'),
          backgroundColor: FujiColors.surface,
          titlePadding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
          contentPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          title: Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  'BẢN GHÉP C++ (1:1)',
                  style: TextStyle(
                    color: FujiColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${preview.width}×${preview.height} · ${preview.renderTimeMs.toStringAsFixed(1)}ms',
                style: const TextStyle(
                  color: FujiColors.accent,
                  fontSize: 11,
                  fontFeatures: FujiTheme.tabularFeatures,
                ),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: AspectRatio(
              aspectRatio: preview.width / math.max(1, preview.height),
              child: RawImage(
                image: preview.image,
                fit: BoxFit.contain,
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              key: const Key('collage_cpp_preview_close'),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text(
                'ĐÓNG',
                style: TextStyle(color: FujiColors.accent),
              ),
            ),
          ],
        ),
      );
    } finally {
      preview.image.dispose();
    }
  }

  Future<void> _openImagePicker() async {
    final sessionState = ref.read(sessionControllerProvider);
    final currentIds =
        _controller.state.spec.slots.map((s) => s.itemId).toList();
    final picked = await showCollageImagePickerSheet(
      context: context,
      sessionState: sessionState,
      initialSelectedIds: currentIds,
    );
    if (picked != null && mounted) {
      await _controller.replaceSelectedItems(picked);
    }
  }

  Future<void> _exportCollage() async {
    if (_isExporting) return;
    unawaited(HapticFeedback.mediumImpact());
    setState(() {
      _isExporting = true;
    });
    try {
      final result = await ref.read(socialExportServiceProvider).exportCollage(
            spec: _controller.state.spec,
            sharpening: OutputSharpeningLevel.subtle,
            maxLongEdgePx: 2048,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Đã xuất Collage: ${result.formatSummary()}'),
            duration: const Duration(seconds: 3),
          ),
        );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Lỗi xuất Collage: $error'),
            duration: const Duration(seconds: 3),
          ),
        );
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final spec = state.spec;
    final availableTemplates =
        CollageMapper.templatesForSlotCount(spec.slots.length);

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
              _buildTopBar(state),
              Expanded(
                child: _buildCanvasArea(state),
              ),
              _buildActionStrip(state),
              _buildControlDeck(spec, availableTemplates),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(StoryCollageState state) {
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
            key: const Key('collage_back_button'),
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: () => unawaited(_handleBack()),
          ),
          Expanded(
            child: Text(
              'STORY COLLAGE · ${state.spec.slots.length} KHUNG',
              style: const TextStyle(
                color: FujiColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                fontFeatures: FujiTheme.tabularFeatures,
              ),
            ),
          ),
          TextButton(
            key: const Key('collage_save_button'),
            onPressed: () {
              unawaited(HapticFeedback.mediumImpact());
              _controller.saveCollage();
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  const SnackBar(
                    content: Text('Đã lưu Story Collage vào phiên'),
                    duration: Duration(seconds: 2),
                  ),
                );
            },
            style: TextButton.styleFrom(
              foregroundColor: state.hasUnsavedChanges
                  ? FujiColors.accent
                  : FujiColors.keep,
            ),
            child: Text(
              state.hasUnsavedChanges ? 'LƯU' : 'ĐÃ LƯU',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvasArea(StoryCollageState state) {
    if (state.isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: FujiColors.accent),
      );
    }

    if (state.errorMessage != null && state.slotFrames.isEmpty) {
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

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Center(
        child: _InteractiveCollageCanvas(
          key: const Key('collage_interactive_canvas'),
          spec: state.spec,
          slotFrames: state.slotFrames,
          selectedSlotIndex: state.selectedSlotIndex,
          swapSourceIndex: state.swapSourceIndex,
          onSelectSlot: _controller.selectSlot,
          onUpdateSlotPanZoom: (idx, panX, panY, zoom) {
            _controller.updateSlotPanZoom(
              idx,
              panX: panX,
              panY: panY,
              zoom: zoom,
            );
          },
        ),
      ),
    );
  }

  Widget _buildActionStrip(StoryCollageState state) {
    final isSwapping = state.swapSourceIndex != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: const BoxDecoration(
        color: FujiColors.surface,
        border: Border(
          top: BorderSide(color: FujiColors.border, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _CompactActionButton(
              key: const Key('collage_swap_button'),
              label: isSwapping ? 'CHỌN Ô ĐÍCH' : '⇄ ĐỔI Ô',
              active: isSwapping,
              onPressed: _controller.toggleSwapMode,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _CompactActionButton(
              key: const Key('collage_pick_images_button'),
              label: 'CHỌN ẢNH',
              active: false,
              onPressed: () => unawaited(_openImagePicker()),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 2,
            child: _CompactActionButton(
              key: const Key('collage_cpp_preview_button'),
              label: state.isRenderingCpp ? 'ĐANG GHÉP...' : '⚙ XEM BẢN GHÉP C++',
              active: false,
              onPressed: state.isRenderingCpp
                  ? null
                  : () => unawaited(_openCppPreview()),
            ),
          ),
          const SizedBox(width: 6),
          _CompactActionButton(
            key: const Key('collage_export_button'),
            label: _isExporting ? 'ĐANG XUẤT...' : 'XUẤT 2048',
            active: _isExporting,
            onPressed: (_isExporting || state.isLoading || state.isRenderingCpp)
                ? null
                : () => unawaited(_exportCollage()),
          ),
        ],
      ),
    );
  }

  Widget _buildControlDeck(CollageSpec spec, List<int> availableTemplates) {
    final activeTpl = CollageMapper.templateIdFromSchema(
      spec.templateId,
      slotCount: spec.slots.length,
    );

    return Container(
      color: FujiColors.surface,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Row 1: Filtered layout templates + 9:16 / 4:5 aspect toggle
          Row(
            children: <Widget>[
              Expanded(
                child: SizedBox(
                  height: 30,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: availableTemplates.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (_, index) {
                      final tplId = availableTemplates[index];
                      final schemaName = CollageMapper.templateIdToSchema(tplId);
                      final selected = tplId == activeTpl;
                      return InkWell(
                        key: Key('collage_template_$schemaName'),
                        onTap: () {
                          unawaited(HapticFeedback.selectionClick());
                          _controller.setTemplate(tplId);
                        },
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: selected
                                ? FujiColors.accent.withValues(alpha: 0.18)
                                : FujiColors.canvas,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: selected
                                  ? FujiColors.accent
                                  : FujiColors.border,
                              width: 1,
                            ),
                          ),
                          child: Text(
                            CollageMapper.templateLabel(tplId),
                            style: TextStyle(
                              color: selected
                                  ? FujiColors.accent
                                  : FujiColors.textPrimary,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _aspectToggleChip('9:16', spec.aspectRatio == '9:16'),
              const SizedBox(width: 4),
              _aspectToggleChip('4:5', spec.aspectRatio == '4:5'),
            ],
          ),
          const SizedBox(height: 8),
          // Row 2: Gutter thickness slider (0..32px) + 3 Fuji background swatches
          Row(
            children: <Widget>[
              Text(
                'VIỀN ${spec.spacingPx}px',
                style: const TextStyle(
                  color: FujiColors.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  fontFeatures: FujiTheme.tabularFeatures,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: FujiColors.accent,
                    inactiveTrackColor: FujiColors.border,
                    thumbColor: FujiColors.textPrimary,
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                  ),
                  child: Slider(
                    key: const Key('collage_gutter_slider'),
                    min: 0,
                    max: 32,
                    value: spec.spacingPx.clamp(0, 32).toDouble(),
                    onChanged: (v) => _controller.setGutterPx(v.round()),
                  ),
                ),
              ),
              for (final theme in CollagePaperTheme.values) ...<Widget>[
                const SizedBox(width: 6),
                _bgSwatch(theme, spec.backgroundHex == theme.hex),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _aspectToggleChip(String aspect, bool active) {
    final keyStr = aspect == '9:16'
        ? 'collage_aspect_9_16'
        : 'collage_aspect_4_5';
    return InkWell(
      key: Key(keyStr),
      onTap: () {
        unawaited(HapticFeedback.selectionClick());
        _controller.setAspectRatio(aspect);
      },
      borderRadius: BorderRadius.circular(4),
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
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
          aspect,
          style: TextStyle(
            color: active ? FujiColors.accent : FujiColors.textPrimary,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            fontFeatures: FujiTheme.tabularFeatures,
          ),
        ),
      ),
    );
  }

  Widget _bgSwatch(CollagePaperTheme theme, bool selected) {
    final parsed = CollageMapper.parseHexColor(theme.hex);
    final swatchColor = Color.fromARGB(parsed.a, parsed.r, parsed.g, parsed.b);
    final cleanKey = theme.hex.replaceFirst('#', '');
    return InkWell(
      key: Key('collage_bg_$cleanKey'),
      onTap: () {
        unawaited(HapticFeedback.selectionClick());
        _controller.setBackgroundHex(theme.hex);
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: swatchColor,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? FujiColors.accent : FujiColors.border,
            width: selected ? 2.5 : 1.0,
          ),
        ),
      ),
    );
  }
}

class _CompactActionButton extends StatelessWidget {
  const _CompactActionButton({
    super.key,
    required this.label,
    required this.active,
    required this.onPressed,
  });

  final String label;
  final bool active;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        backgroundColor: active
            ? FujiColors.accent.withValues(alpha: 0.18)
            : FujiColors.canvas,
        foregroundColor: active ? FujiColors.accent : FujiColors.textPrimary,
        side: BorderSide(
          color: active ? FujiColors.accent : FujiColors.border,
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
        ),
      ),
    );
  }
}

class _InteractiveCollageCanvas extends StatefulWidget {
  const _InteractiveCollageCanvas({
    super.key,
    required this.spec,
    required this.slotFrames,
    required this.selectedSlotIndex,
    required this.swapSourceIndex,
    required this.onSelectSlot,
    required this.onUpdateSlotPanZoom,
  });

  final CollageSpec spec;
  final Map<String, StoryCollageSlotFrame> slotFrames;
  final int selectedSlotIndex;
  final int? swapSourceIndex;
  final ValueChanged<int> onSelectSlot;
  final void Function(int slotIndex, double panX, double panY, double zoom)
      onUpdateSlotPanZoom;

  @override
  State<_InteractiveCollageCanvas> createState() =>
      _InteractiveCollageCanvasState();
}

class _InteractiveCollageCanvasState extends State<_InteractiveCollageCanvas> {
  List<Rect> _cellRects = const <Rect>[];
  int? _gestureSlotIdx;
  double _startPanX = 0.0;
  double _startPanY = 0.0;
  double _startZoom = 1.0;
  Offset _startFocal = Offset.zero;

  static List<Rect> computeCellRects({
    required int nativeTemplateId,
    required Size canvasSize,
    required double gutterPx,
    required double marginPx,
  }) {
    final scale = canvasSize.width / 540.0;
    final g = gutterPx * scale;
    final m = marginPx * scale;
    final availW = math.max(16.0, canvasSize.width - 2 * m);
    final availH = math.max(16.0, canvasSize.height - 2 * m);
    final xEnd = m + availW;
    final yEnd = m + availH;

    switch (nativeTemplateId) {
      case 0: // SPLIT_2_V
        final h0 = (availH - g) / 2.0;
        return <Rect>[
          Rect.fromLTRB(m, m, xEnd, m + h0),
          Rect.fromLTRB(m, m + h0 + g, xEnd, yEnd),
        ];
      case 1: // SPLIT_2_H
        final w0 = (availW - g) / 2.0;
        return <Rect>[
          Rect.fromLTRB(m, m, m + w0, yEnd),
          Rect.fromLTRB(m + w0 + g, m, xEnd, yEnd),
        ];
      case 2: // GRID_3_STRIP
        final netH = availH - 2 * g;
        final h = netH / 3.0;
        return <Rect>[
          Rect.fromLTRB(m, m, xEnd, m + h),
          Rect.fromLTRB(m, m + h + g, xEnd, m + 2 * h + g),
          Rect.fromLTRB(m, m + 2 * h + 2 * g, xEnd, yEnd),
        ];
      case 3: // GRID_3_TOP
        final netH = availH - g;
        final topH = netH * 0.58;
        final botW0 = (availW - g) / 2.0;
        final yBot = m + topH + g;
        return <Rect>[
          Rect.fromLTRB(m, m, xEnd, m + topH),
          Rect.fromLTRB(m, yBot, m + botW0, yEnd),
          Rect.fromLTRB(m + botW0 + g, yBot, xEnd, yEnd),
        ];
      case 4: // GRID_3_LEFT
        final netW = availW - g;
        final leftW = netW * 0.55;
        final rightH0 = (availH - g) / 2.0;
        final xRight = m + leftW + g;
        return <Rect>[
          Rect.fromLTRB(m, m, m + leftW, yEnd),
          Rect.fromLTRB(xRight, m, xEnd, m + rightH0),
          Rect.fromLTRB(xRight, m + rightH0 + g, xEnd, yEnd),
        ];
      case 5: // GRID_4_EVEN
      default:
        final w0 = (availW - g) / 2.0;
        final h0 = (availH - g) / 2.0;
        final xMid = m + w0;
        final yMid = m + h0;
        return <Rect>[
          Rect.fromLTRB(m, m, xMid, yMid),
          Rect.fromLTRB(xMid + g, m, xEnd, yMid),
          Rect.fromLTRB(m, yMid + g, xMid, yEnd),
          Rect.fromLTRB(xMid + g, yMid + g, xEnd, yEnd),
        ];
    }
  }

  int? _hitTestSlot(Offset pos) {
    for (var i = 0; i < _cellRects.length; i++) {
      if (_cellRects[i].contains(pos)) {
        return i;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final aspect = widget.spec.aspectRatio == '4:5' ? (4.0 / 5.0) : (9.0 / 16.0);
    final nativeTpl = CollageMapper.templateIdFromSchema(
      widget.spec.templateId,
      slotCount: widget.spec.slots.length,
    );
    final marginPx = CollageMapper.readOuterMarginPx(widget.spec).toDouble();

    return AspectRatio(
      aspectRatio: aspect,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          _cellRects = computeCellRects(
            nativeTemplateId: nativeTpl,
            canvasSize: size,
            gutterPx: widget.spec.spacingPx.toDouble(),
            marginPx: marginPx,
          );

          return GestureDetector(
            onTapUp: (details) {
              final hit = _hitTestSlot(details.localPosition);
              if (hit != null) {
                widget.onSelectSlot(hit);
              }
            },
            onScaleStart: (details) {
              final hit = _hitTestSlot(details.localFocalPoint);
              if (hit == null || hit >= widget.spec.slots.length) {
                _gestureSlotIdx = null;
                return;
              }
              _gestureSlotIdx = hit;
              if (widget.swapSourceIndex == null &&
                  hit != widget.selectedSlotIndex) {
                widget.onSelectSlot(hit);
              }
              final slot = widget.spec.slots[hit];
              _startPanX = slot.panX;
              _startPanY = slot.panY;
              _startZoom = slot.zoom;
              _startFocal = details.localFocalPoint;
            },
            onScaleUpdate: (details) {
              final idx = _gestureSlotIdx;
              if (idx == null ||
                  idx >= _cellRects.length ||
                  widget.swapSourceIndex != null) {
                return;
              }
              final cell = _cellRects[idx];
              final dx = details.localFocalPoint.dx - _startFocal.dx;
              final dy = details.localFocalPoint.dy - _startFocal.dy;
              final nextPanX =
                  (_startPanX + dx / math.max(24.0, cell.width * 0.5))
                      .clamp(-1.0, 1.0);
              final nextPanY =
                  (_startPanY + dy / math.max(24.0, cell.height * 0.5))
                      .clamp(-1.0, 1.0);
              final nextZoom =
                  (_startZoom * details.scale).clamp(1.0, 3.0);
              widget.onUpdateSlotPanZoom(idx, nextPanX, nextPanY, nextZoom);
            },
            onScaleEnd: (_) => _gestureSlotIdx = null,
            child: CustomPaint(
              size: size,
              painter: _CollageCanvasPainter(
                spec: widget.spec,
                slotFrames: widget.slotFrames,
                cellRects: _cellRects,
                selectedSlotIndex: widget.selectedSlotIndex,
                swapSourceIndex: widget.swapSourceIndex,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CollageCanvasPainter extends CustomPainter {
  const _CollageCanvasPainter({
    required this.spec,
    required this.slotFrames,
    required this.cellRects,
    required this.selectedSlotIndex,
    required this.swapSourceIndex,
  });

  final CollageSpec spec;
  final Map<String, StoryCollageSlotFrame> slotFrames;
  final List<Rect> cellRects;
  final int selectedSlotIndex;
  final int? swapSourceIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = CollageMapper.parseHexColor(spec.backgroundHex);
    final bgColor = Color.fromARGB(bg.a, bg.r, bg.g, bg.b);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = bgColor,
    );

    final count = math.min(spec.slots.length, cellRects.length);
    for (var i = 0; i < count; i++) {
      final slot = spec.slots[i];
      final cell = cellRects[i];
      final frame = slotFrames[slot.itemId];

      if (frame != null) {
        final sw = frame.width.toDouble();
        final sh = frame.height.toDouble();
        final srcAspect = sw / math.max(1.0, sh);
        final cellAspect = cell.width / math.max(1.0, cell.height);
        final double baseW = srcAspect > cellAspect ? sh * cellAspect : sw;
        final double baseH = srcAspect > cellAspect ? sh : sw / cellAspect;

        final zoom = slot.zoom.clamp(1.0, 3.0);
        final cropW = baseW / zoom;
        final cropH = baseH / zoom;
        final slackX = math.max(0.0, sw - cropW);
        final slackY = math.max(0.0, sh - cropH);
        final panX = slot.panX.clamp(-1.0, 1.0);
        final panY = slot.panY.clamp(-1.0, 1.0);
        final winX0 = 0.5 * slackX * (1.0 - panX);
        final winY0 = 0.5 * slackY * (1.0 - panY);

        canvas.save();
        canvas.clipRect(cell);
        canvas.drawImageRect(
          frame.image,
          Rect.fromLTWH(winX0, winY0, cropW, cropH),
          cell,
          Paint()..filterQuality = FilterQuality.medium,
        );
        canvas.restore();
      } else {
        canvas.drawRect(cell, Paint()..color = FujiColors.surfaceElevated);
      }

      final isSelected = i == selectedSlotIndex;
      final isSwapSource = i == swapSourceIndex;
      if (isSelected || isSwapSource) {
        canvas.drawRect(
          cell.deflate(1.0),
          Paint()
            ..color = isSwapSource ? FujiColors.keep : FujiColors.accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CollageCanvasPainter oldDelegate) {
    return oldDelegate.spec != spec ||
        oldDelegate.slotFrames != slotFrames ||
        oldDelegate.selectedSlotIndex != selectedSlotIndex ||
        oldDelegate.swapSourceIndex != swapSourceIndex;
  }
}
