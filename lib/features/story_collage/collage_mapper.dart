import '../../core/ffi/bindings.g.dart';
import '../../core/ffi/native_worker.dart';
import '../../core/schema/collage_spec.dart';

/// Supported Story Collage background paper presets.
enum CollagePaperTheme {
  pureWhite('#FFFFFF', 'Trắng'),
  warmPaper('#F4F1EA', 'Giấy ấm'),
  darkroom('#0E0F11', 'Phòng tối');

  const CollagePaperTheme(this.hex, this.label);
  final String hex;
  final String label;
}

/// Bidirectional mapper between Schema v2.4.2 [CollageSpec] / [CollageSlot]
/// and C++20 ABI [CollageNativeConfig] / [FsCollageTemplate].
abstract final class CollageMapper {
  static const int defaultOuterMarginPx = 16;
  static const int defaultGutterPx = 12;

  static const List<int> templatesFor2Slots = <int>[
    0, // FS_COLLAGE_SPLIT_2_V
    1, // FS_COLLAGE_SPLIT_2_H
  ];

  static const List<int> templatesFor3Slots = <int>[
    2, // FS_COLLAGE_GRID_3_STRIP
    3, // FS_COLLAGE_GRID_3_TOP
    4, // FS_COLLAGE_GRID_3_LEFT
  ];

  static const List<int> templatesFor4Slots = <int>[
    5, // FS_COLLAGE_GRID_4_EVEN
  ];

  static List<int> templatesForSlotCount(int slotCount) {
    return switch (slotCount) {
      2 => templatesFor2Slots,
      3 => templatesFor3Slots,
      4 => templatesFor4Slots,
      _ => const <int>[],
    };
  }

  static int expectedSlotCount(int templateId) {
    if (templateId == FsCollageTemplate.FS_COLLAGE_SPLIT_2_V.value ||
        templateId == FsCollageTemplate.FS_COLLAGE_SPLIT_2_H.value) {
      return 2;
    }
    if (templateId == FsCollageTemplate.FS_COLLAGE_GRID_3_STRIP.value ||
        templateId == FsCollageTemplate.FS_COLLAGE_GRID_3_TOP.value ||
        templateId == FsCollageTemplate.FS_COLLAGE_GRID_3_LEFT.value) {
      return 3;
    }
    if (templateId == FsCollageTemplate.FS_COLLAGE_GRID_4_EVEN.value) {
      return 4;
    }
    return 2;
  }

  static String templateIdToSchema(int templateId) {
    if (templateId == FsCollageTemplate.FS_COLLAGE_SPLIT_2_V.value) {
      return 'split_2_v';
    }
    if (templateId == FsCollageTemplate.FS_COLLAGE_SPLIT_2_H.value) {
      return 'split_2_h';
    }
    if (templateId == FsCollageTemplate.FS_COLLAGE_GRID_3_STRIP.value) {
      return 'grid_3_strip';
    }
    if (templateId == FsCollageTemplate.FS_COLLAGE_GRID_3_TOP.value) {
      return 'grid_3_top';
    }
    if (templateId == FsCollageTemplate.FS_COLLAGE_GRID_3_LEFT.value) {
      return 'grid_3_left';
    }
    if (templateId == FsCollageTemplate.FS_COLLAGE_GRID_4_EVEN.value) {
      return 'grid_4_even';
    }
    return 'split_2_v';
  }

  static int templateIdFromSchema(String schemaTemplateId, {int? slotCount}) {
    switch (schemaTemplateId) {
      case 'split_2_v':
      case 'fuji_diptych_vertical':
        return FsCollageTemplate.FS_COLLAGE_SPLIT_2_V.value;
      case 'split_2_h':
      case 'fuji_diptych_horizontal':
        return FsCollageTemplate.FS_COLLAGE_SPLIT_2_H.value;
      case 'grid_3_strip':
        return FsCollageTemplate.FS_COLLAGE_GRID_3_STRIP.value;
      case 'grid_3_top':
        return FsCollageTemplate.FS_COLLAGE_GRID_3_TOP.value;
      case 'grid_3_left':
        return FsCollageTemplate.FS_COLLAGE_GRID_3_LEFT.value;
      case 'grid_4_even':
        return FsCollageTemplate.FS_COLLAGE_GRID_4_EVEN.value;
      default:
        if (slotCount == 3) {
          return FsCollageTemplate.FS_COLLAGE_GRID_3_TOP.value;
        }
        if (slotCount == 4) {
          return FsCollageTemplate.FS_COLLAGE_GRID_4_EVEN.value;
        }
        return FsCollageTemplate.FS_COLLAGE_SPLIT_2_V.value;
    }
  }

  static String templateLabel(int templateId) {
    if (templateId == FsCollageTemplate.FS_COLLAGE_SPLIT_2_V.value) {
      return '2 DỌC';
    }
    if (templateId == FsCollageTemplate.FS_COLLAGE_SPLIT_2_H.value) {
      return '2 NGANG';
    }
    if (templateId == FsCollageTemplate.FS_COLLAGE_GRID_3_STRIP.value) {
      return '3 DẢI PHIM';
    }
    if (templateId == FsCollageTemplate.FS_COLLAGE_GRID_3_TOP.value) {
      return '3 TRÊN LỚN';
    }
    if (templateId == FsCollageTemplate.FS_COLLAGE_GRID_3_LEFT.value) {
      return '3 TRÁI LỚN';
    }
    if (templateId == FsCollageTemplate.FS_COLLAGE_GRID_4_EVEN.value) {
      return 'LƯỚI 2×2';
    }
    return '2 DỌC';
  }

  static int readOuterMarginPx(CollageSpec spec) {
    final raw = spec.unknownFields['outer_margin_px'];
    if (raw is int) return raw.clamp(0, 64);
    if (raw is num) return raw.toInt().clamp(0, 64);
    return defaultOuterMarginPx;
  }

  static CollageSpec withOuterMarginPx(CollageSpec spec, int marginPx) {
    final updated = Map<String, Object?>.of(spec.unknownFields);
    updated['outer_margin_px'] = marginPx.clamp(0, 64);
    return spec.copyWith(unknownFields: updated);
  }

  static (int width, int height) canvasDimensionsForAspect(
    String aspectRatio, {
    int baseWidth = 540,
  }) {
    if (aspectRatio == '4:5') {
      final h = (baseWidth * 5 / 4).round();
      return (baseWidth, h);
    }
    // Default '9:16'
    final h = (baseWidth * 16 / 9).round();
    return (baseWidth, h);
  }

  static ({int r, int g, int b, int a}) parseHexColor(String hex) {
    var clean = hex.trim().replaceFirst('#', '');
    if (clean.length == 6) {
      final val = int.tryParse(clean, radix: 16);
      if (val != null) {
        return (
          r: (val >> 16) & 0xFF,
          g: (val >> 8) & 0xFF,
          b: val & 0xFF,
          a: 255,
        );
      }
    } else if (clean.length == 8) {
      final val = int.tryParse(clean, radix: 16);
      if (val != null) {
        return (
          a: (val >> 24) & 0xFF,
          r: (val >> 16) & 0xFF,
          g: (val >> 8) & 0xFF,
          b: val & 0xFF,
        );
      }
    }
    return (r: 14, g: 15, b: 17, a: 255);
  }

  static CollageNativeConfig toNativeConfig(
    CollageSpec spec, {
    int baseWidth = 540,
  }) {
    final tpl = templateIdFromSchema(
      spec.templateId,
      slotCount: spec.slots.length,
    );
    final dims = canvasDimensionsForAspect(
      spec.aspectRatio,
      baseWidth: baseWidth,
    );
    final color = parseHexColor(spec.backgroundHex);
    return CollageNativeConfig(
      templateId: tpl,
      canvasWidth: dims.$1,
      canvasHeight: dims.$2,
      gutterPx: spec.spacingPx.clamp(0, 48),
      outerMarginPx: readOuterMarginPx(spec),
      bgR: color.r,
      bgG: color.g,
      bgB: color.b,
      bgA: color.a,
    );
  }
}
