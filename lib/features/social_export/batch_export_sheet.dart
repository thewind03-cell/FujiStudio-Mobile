import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/di/app_providers.dart';
import '../../core/schema/edit_recipe.dart';
import '../../core/theme/fuji_theme.dart';
import 'batch_export_controller.dart';
import 'export_mapper.dart';
import 'export_options_deck.dart';

/// Opens the Fuji mechanical [BatchExportSheet] for the given `KEEP` [targets].
Future<void> showBatchExportSheet({
  required BuildContext context,
  required List<BatchExportTarget> targets,
  required String? albumKey,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: FujiColors.surface,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      side: BorderSide(color: FujiColors.border, width: 1),
    ),
    builder: (_) => BatchExportSheet(
      targets: targets,
      albumKey: albumKey,
    ),
  );
}

/// Compact Fuji darkroom bottom sheet for sequential (`maxConcurrent = 1`)
/// batch export of `KEEP` photos with live progress and cooperative cancel.
class BatchExportSheet extends ConsumerStatefulWidget {
  const BatchExportSheet({
    super.key,
    required this.targets,
    required this.albumKey,
  });

  final List<BatchExportTarget> targets;
  final String? albumKey;

  @override
  ConsumerState<BatchExportSheet> createState() => _BatchExportSheetState();
}

class _BatchExportSheetState extends ConsumerState<BatchExportSheet> {
  late final BatchExportController _controller;
  late ExportProfileSpec _selectedProfile;
  bool _isPopping = false;

  @override
  void initState() {
    super.initState();
    _selectedProfile = ExportMapper.applyPreset(
      ExportProfileSpec(
        format: 'jpeg',
        quality: 92,
        colorSpace: 'sRGB',
        maxLongEdgePx: 2048,
      ),
      SocialExportPreset.facebook2048,
      preserveExif: true,
      stripGps: true,
    );
    _controller = BatchExportController(
      exportService: ref.read(socialExportServiceProvider),
    )..addListener(_onUpdate);
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

  void _handleClose() {
    if (_isPopping || _controller.state.isRunning) return;
    _isPopping = true;
    Navigator.of(context).pop();
  }

  void _startExport() {
    if (_controller.state.isRunning) return;
    unawaited(HapticFeedback.mediumImpact());
    unawaited(
      _controller.startBatch(
        targets: widget.targets,
        exportProfileOverride: _selectedProfile,
        albumKey: widget.albumKey,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final count = widget.targets.length;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleClose();
      },
      child: SafeArea(
        child: Padding(
          key: const Key('batch_export_sheet'),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'XUẤT HÀNG LOẠT · $count ẢNH',
                      style: const TextStyle(
                        color: FujiColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        fontFeatures: FujiTheme.tabularFeatures,
                      ),
                    ),
                  ),
                  if (!state.isRunning)
                    IconButton(
                      key: const Key('batch_export_close_icon'),
                      icon: const Icon(Icons.close, size: 18),
                      color: FujiColors.textSecondary,
                      onPressed: _handleClose,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                ],
              ),
              const Divider(color: FujiColors.border, height: 14),
              if (!state.isRunning && !state.isDone) ...<Widget>[
                ExportOptionsDeck(
                  profile: _selectedProfile,
                  onChanged: (next) {
                    setState(() {
                      _selectedProfile = next;
                    });
                  },
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 38,
                  child: FilledButton(
                    key: const Key('batch_export_start_button'),
                    onPressed: _startExport,
                    style: FilledButton.styleFrom(
                      backgroundColor: FujiColors.accent,
                      foregroundColor: FujiColors.canvas,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    child: Text(
                      'BẮT ĐẦU XUẤT $count ẢNH',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ] else if (state.isRunning) ...<Widget>[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        state.currentFileName ?? 'Đang xử lý...',
                        key: const Key('batch_export_current_file'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: FujiColors.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${state.processedCount} / ${state.totalCount}',
                      key: const Key('batch_export_progress_counter'),
                      style: const TextStyle(
                        color: FujiColors.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        fontFeatures: FujiTheme.tabularFeatures,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  key: const Key('batch_export_progress_bar'),
                  value: state.progress,
                  backgroundColor: FujiColors.canvas,
                  color: FujiColors.accent,
                  minHeight: 4,
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 36,
                  child: OutlinedButton(
                    key: const Key('batch_export_cancel_button'),
                    onPressed: state.isCancelled ? null : _controller.cancel,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: FujiColors.reject,
                      side: const BorderSide(color: FujiColors.reject, width: 1),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    child: Text(
                      state.isCancelled ? 'ĐANG DỪNG...' : 'HỦY',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ] else ...<Widget>[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: FujiColors.canvas,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: state.completedCount > 0
                          ? FujiColors.keep
                          : FujiColors.border,
                      width: 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Đã xuất ${state.completedCount}/${state.totalCount} ảnh vào Pictures/FujiStudio/',
                        key: const Key('batch_export_summary_text'),
                        style: const TextStyle(
                          color: FujiColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          fontFeatures: FujiTheme.tabularFeatures,
                        ),
                      ),
                      if (state.cancelledCount > 0 ||
                          state.failedCount > 0) ...<Widget>[
                        const SizedBox(height: 6),
                        Text(
                          'Đã hủy: ${state.cancelledCount} · Lỗi: ${state.failedCount}',
                          key: const Key('batch_export_breakdown_text'),
                          style: const TextStyle(
                            color: FujiColors.textSecondary,
                            fontSize: 11,
                            fontFeatures: FujiTheme.tabularFeatures,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 36,
                  child: FilledButton(
                    key: const Key('batch_export_close_button'),
                    onPressed: _handleClose,
                    style: FilledButton.styleFrom(
                      backgroundColor: FujiColors.accent,
                      foregroundColor: FujiColors.canvas,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    child: const Text(
                      'ĐÓNG',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
