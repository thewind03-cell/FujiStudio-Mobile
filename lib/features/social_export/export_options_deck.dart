import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/schema/edit_recipe.dart';
import '../../core/theme/fuji_theme.dart';
import 'export_mapper.dart';

/// Shared mechanical Fujifilm export controls used by both
/// [StudioEditorScreen] (`[ XUẤT 2048 ]` tab) and [BatchExportSheet].
class ExportOptionsDeck extends StatelessWidget {
  const ExportOptionsDeck({
    super.key,
    required this.profile,
    required this.onChanged,
    this.enabled = true,
  });

  final ExportProfileSpec profile;
  final ValueChanged<ExportProfileSpec> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final preset = ExportMapper.presetFromSpec(profile);
    final isOriginalMax = preset == SocialExportPreset.originalMax;
    final sharpening = ExportMapper.sharpeningFromSpec(
      profile,
      fallbackPreset: preset,
    );
    final preserveExif = ExportMapper.preserveExifFromSpec(profile);
    final stripGps = ExportMapper.stripGpsFromSpec(profile);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            const SizedBox(
              width: 72,
              child: Text(
                'KÍCH THƯỚC',
                style: TextStyle(
                  color: FujiColors.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            Expanded(
              child: _OptionChip(
                key: const Key('export_preset_2048'),
                label: 'MXH 2048px',
                active: !isOriginalMax,
                onTap: enabled
                    ? () {
                        unawaited(HapticFeedback.selectionClick());
                        onChanged(
                          ExportMapper.applyPreset(
                            profile,
                            SocialExportPreset.facebook2048,
                            preserveExif: preserveExif,
                            stripGps: stripGps,
                          ),
                        );
                      }
                    : null,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _OptionChip(
                key: const Key('export_preset_original_max'),
                label: 'GỐC MAX',
                active: isOriginalMax,
                onTap: enabled
                    ? () {
                        unawaited(HapticFeedback.selectionClick());
                        onChanged(
                          ExportMapper.applyPreset(
                            profile,
                            SocialExportPreset.originalMax,
                            preserveExif: preserveExif,
                            stripGps: stripGps,
                          ),
                        );
                      }
                    : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            const SizedBox(
              width: 72,
              child: Text(
                'NÉT (USM)',
                style: TextStyle(
                  color: FujiColors.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            Expanded(
              child: _OptionChip(
                key: const Key('export_usm_off'),
                label: 'TẮT',
                active: sharpening == OutputSharpeningLevel.off,
                onTap: enabled
                    ? () {
                        unawaited(HapticFeedback.selectionClick());
                        onChanged(
                          ExportMapper.withOptions(
                            profile,
                            sharpening: OutputSharpeningLevel.off,
                          ),
                        );
                      }
                    : null,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _OptionChip(
                key: const Key('export_usm_subtle'),
                label: 'NHẸ',
                active: sharpening == OutputSharpeningLevel.subtle,
                onTap: enabled
                    ? () {
                        unawaited(HapticFeedback.selectionClick());
                        onChanged(
                          ExportMapper.withOptions(
                            profile,
                            sharpening: OutputSharpeningLevel.subtle,
                          ),
                        );
                      }
                    : null,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _OptionChip(
                key: const Key('export_usm_standard'),
                label: 'VỪA',
                active: sharpening == OutputSharpeningLevel.standard,
                onTap: enabled
                    ? () {
                        unawaited(HapticFeedback.selectionClick());
                        onChanged(
                          ExportMapper.withOptions(
                            profile,
                            sharpening: OutputSharpeningLevel.standard,
                          ),
                        );
                      }
                    : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Expanded(
              child: _OptionChip(
                key: const Key('export_toggle_exif'),
                label: preserveExif ? '● GIỮ EXIF' : '○ GIỮ EXIF',
                active: preserveExif,
                activeColor: FujiColors.keep,
                onTap: enabled
                    ? () {
                        unawaited(HapticFeedback.selectionClick());
                        onChanged(
                          ExportMapper.withOptions(
                            profile,
                            preserveExif: !preserveExif,
                          ),
                        );
                      }
                    : null,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _OptionChip(
                key: const Key('export_toggle_gps'),
                label: stripGps ? '● XÓA GPS' : '○ XÓA GPS',
                active: stripGps,
                activeColor: FujiColors.keep,
                onTap: enabled
                    ? () {
                        unawaited(HapticFeedback.selectionClick());
                        onChanged(
                          ExportMapper.withOptions(
                            profile,
                            stripGps: !stripGps,
                          ),
                        );
                      }
                    : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    this.activeColor = FujiColors.accent,
  });

  final String label;
  final bool active;
  final VoidCallback? onTap;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        height: 30,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: active
              ? activeColor.withValues(alpha: 0.16)
              : FujiColors.canvas,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: active ? activeColor : FujiColors.border,
            width: 1,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: active ? activeColor : FujiColors.textPrimary,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
            fontFeatures: FujiTheme.tabularFeatures,
          ),
        ),
      ),
    );
  }
}
