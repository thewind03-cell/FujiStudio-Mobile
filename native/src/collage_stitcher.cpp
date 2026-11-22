#include "fujistudio_c_api.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>

namespace {

int32_t validate_rgba_dimensions(
    int32_t width,
    int32_t height,
    size_t* out_byte_len) noexcept {
  if (width <= 0 || height <= 0) {
    return FS_ERR_INVALID_DIMENSIONS;
  }
  if (width > FS_MAX_IMAGE_DIMENSION || height > FS_MAX_IMAGE_DIMENSION) {
    return FS_ERR_OVERFLOW;
  }
  const uint64_t pixel_count =
      static_cast<uint64_t>(width) * static_cast<uint64_t>(height);
  constexpr uint64_t kMaxSize =
      static_cast<uint64_t>(std::numeric_limits<size_t>::max());
  constexpr uint64_t kMaxInt32 =
      static_cast<uint64_t>(std::numeric_limits<int32_t>::max());
  if (pixel_count > (kMaxSize / 4ULL) || (pixel_count * 4ULL) > kMaxInt32) {
    return FS_ERR_OVERFLOW;
  }
  *out_byte_len = static_cast<size_t>(pixel_count * 4ULL);
  return FS_OK;
}

int32_t expected_slots_for_template(int32_t template_id) noexcept {
  switch (template_id) {
    case FS_COLLAGE_SPLIT_2_V:
    case FS_COLLAGE_SPLIT_2_H:
      return 2;
    case FS_COLLAGE_GRID_3_STRIP:
    case FS_COLLAGE_GRID_3_TOP:
    case FS_COLLAGE_GRID_3_LEFT:
      return 3;
    case FS_COLLAGE_GRID_4_EVEN:
      return 4;
    default:
      return -1;
  }
}

struct CellRect {
  int32_t x0;
  int32_t y0;
  int32_t x1;
  int32_t y1;
  int32_t width() const noexcept { return x1 - x0; }
  int32_t height() const noexcept { return y1 - y0; }
};

bool build_template_cells(
    int32_t template_id,
    int32_t canvas_w,
    int32_t canvas_h,
    int32_t gutter,
    int32_t margin,
    std::array<CellRect, 4>& out_cells,
    int32_t* out_count) noexcept {
  const int32_t avail_w = canvas_w - 2 * margin;
  const int32_t avail_h = canvas_h - 2 * margin;
  if (avail_w < 16 || avail_h < 16) {
    return false;
  }

  const int32_t x_end = margin + avail_w;
  const int32_t y_end = margin + avail_h;

  switch (template_id) {
    case FS_COLLAGE_SPLIT_2_V: {
      const int32_t h0 = (avail_h - gutter) / 2;
      out_cells[0] = CellRect{margin, margin, x_end, margin + h0};
      out_cells[1] = CellRect{margin, margin + h0 + gutter, x_end, y_end};
      *out_count = 2;
      break;
    }
    case FS_COLLAGE_SPLIT_2_H: {
      const int32_t w0 = (avail_w - gutter) / 2;
      out_cells[0] = CellRect{margin, margin, margin + w0, y_end};
      out_cells[1] = CellRect{margin + w0 + gutter, margin, x_end, y_end};
      *out_count = 2;
      break;
    }
    case FS_COLLAGE_GRID_3_STRIP: {
      const int32_t net_h = avail_h - 2 * gutter;
      const int32_t h0 = net_h / 3;
      const int32_t h1 = (net_h - h0) / 2;
      const int32_t y1 = margin + h0;
      const int32_t y2 = y1 + gutter;
      const int32_t y3 = y2 + h1;
      const int32_t y4 = y3 + gutter;
      out_cells[0] = CellRect{margin, margin, x_end, y1};
      out_cells[1] = CellRect{margin, y2, x_end, y3};
      out_cells[2] = CellRect{margin, y4, x_end, y_end};
      *out_count = 3;
      break;
    }
    case FS_COLLAGE_GRID_3_TOP: {
      const int32_t net_h = avail_h - gutter;
      const int32_t top_h = static_cast<int32_t>(std::lround(net_h * 0.58));
      const int32_t bot_w0 = (avail_w - gutter) / 2;
      const int32_t y_top_end = margin + top_h;
      const int32_t y_bot_start = y_top_end + gutter;
      out_cells[0] = CellRect{margin, margin, x_end, y_top_end};
      out_cells[1] = CellRect{margin, y_bot_start, margin + bot_w0, y_end};
      out_cells[2] =
          CellRect{margin + bot_w0 + gutter, y_bot_start, x_end, y_end};
      *out_count = 3;
      break;
    }
    case FS_COLLAGE_GRID_3_LEFT: {
      const int32_t net_w = avail_w - gutter;
      const int32_t left_w = static_cast<int32_t>(std::lround(net_w * 0.55));
      const int32_t right_h0 = (avail_h - gutter) / 2;
      const int32_t x_left_end = margin + left_w;
      const int32_t x_right_start = x_left_end + gutter;
      out_cells[0] = CellRect{margin, margin, x_left_end, y_end};
      out_cells[1] = CellRect{x_right_start, margin, x_end, margin + right_h0};
      out_cells[2] =
          CellRect{x_right_start, margin + right_h0 + gutter, x_end, y_end};
      *out_count = 3;
      break;
    }
    case FS_COLLAGE_GRID_4_EVEN: {
      const int32_t w0 = (avail_w - gutter) / 2;
      const int32_t h0 = (avail_h - gutter) / 2;
      const int32_t x_mid = margin + w0;
      const int32_t y_mid = margin + h0;
      out_cells[0] = CellRect{margin, margin, x_mid, y_mid};
      out_cells[1] = CellRect{x_mid + gutter, margin, x_end, y_mid};
      out_cells[2] = CellRect{margin, y_mid + gutter, x_mid, y_end};
      out_cells[3] = CellRect{x_mid + gutter, y_mid + gutter, x_end, y_end};
      *out_count = 4;
      break;
    }
    default:
      return false;
  }

  for (int32_t i = 0; i < *out_count; ++i) {
    if (out_cells[static_cast<size_t>(i)].width() < 16 ||
        out_cells[static_cast<size_t>(i)].height() < 16) {
      return false;
    }
  }
  return true;
}

inline void catmull_rom_weights(float t, float w[4]) noexcept {
  const float t2 = t * t;
  const float t3 = t2 * t;
  w[0] = -0.5f * t + t2 - 0.5f * t3;
  w[1] = 1.0f - 2.5f * t2 + 1.5f * t3;
  w[2] = 0.5f * t + 2.0f * t2 - 1.5f * t3;
  w[3] = -0.5f * t2 + 0.5f * t3;
}

inline void sample_catmull_rom(
    const uint8_t* rgba,
    int32_t width,
    int32_t height,
    float sx,
    float sy,
    uint8_t* out_px) noexcept {
  const float cx = std::clamp(sx, 0.0f, static_cast<float>(width - 1));
  const float cy = std::clamp(sy, 0.0f, static_cast<float>(height - 1));

  const int32_t ix = static_cast<int32_t>(std::floor(cx));
  const int32_t iy = static_cast<int32_t>(std::floor(cy));
  const float fx = cx - static_cast<float>(ix);
  const float fy = cy - static_cast<float>(iy);

  float wx[4];
  float wy[4];
  catmull_rom_weights(fx, wx);
  catmull_rom_weights(fy, wy);

  float acc[4] = {0.0f, 0.0f, 0.0f, 0.0f};
  for (int j = -1; j <= 2; ++j) {
    const int32_t py = std::clamp(iy + j, 0, height - 1);
    const float yw = wy[j + 1];
    const size_t row_off = static_cast<size_t>(py) * width;
    for (int i = -1; i <= 2; ++i) {
      const int32_t px = std::clamp(ix + i, 0, width - 1);
      const float w = yw * wx[i + 1];
      const size_t idx = (row_off + static_cast<size_t>(px)) * 4u;
      acc[0] += w * rgba[idx + 0u];
      acc[1] += w * rgba[idx + 1u];
      acc[2] += w * rgba[idx + 2u];
      acc[3] += w * rgba[idx + 3u];
    }
  }

  for (int c = 0; c < 4; ++c) {
    out_px[c] = static_cast<uint8_t>(std::clamp(acc[c] + 0.5f, 0.0f, 255.0f));
  }
}

}  // namespace

extern "C" {

FS_API int32_t fs_collage_render_rgba_into(
    const FsCollageInputSlot* slots,
    int32_t slot_count,
    const FsCollageConfig* config,
    uint8_t* out_canvas_rgba,
    size_t out_canvas_len) {
  try {
    if (slots == nullptr || config == nullptr || out_canvas_rgba == nullptr) {
      return FS_ERR_NULL_POINTER;
    }

    const int32_t expected_slots =
        expected_slots_for_template(config->template_id);
    if (expected_slots < 0) {
      return FS_ERR_INVALID_PARAMS;
    }
    if (slot_count != expected_slots) {
      return FS_ERR_COLLAGE_INVALID_SLOTS;
    }

    if (config->canvas_width > FS_MAX_IMAGE_DIMENSION ||
        config->canvas_height > FS_MAX_IMAGE_DIMENSION) {
      return FS_ERR_OVERFLOW;
    }
    if (config->canvas_width < 32 || config->canvas_height < 32) {
      return FS_ERR_INVALID_DIMENSIONS;
    }

    size_t canvas_byte_len = 0;
    const int32_t dim_rc = validate_rgba_dimensions(
        config->canvas_width, config->canvas_height, &canvas_byte_len);
    if (dim_rc != FS_OK) {
      return dim_rc;
    }
    if (out_canvas_len < canvas_byte_len) {
      return FS_ERR_INVALID_DIMENSIONS;
    }

    if (config->gutter_px < 0 || config->gutter_px > 48 ||
        config->outer_margin_px < 0 || config->outer_margin_px > 64) {
      return FS_ERR_INVALID_PARAMS;
    }

    std::array<CellRect, 4> cells{};
    int32_t cell_count = 0;
    if (!build_template_cells(
            config->template_id,
            config->canvas_width,
            config->canvas_height,
            config->gutter_px,
            config->outer_margin_px,
            cells,
            &cell_count)) {
      return FS_ERR_INVALID_DIMENSIONS;
    }

    const uintptr_t out_begin = reinterpret_cast<uintptr_t>(out_canvas_rgba);
    const uintptr_t out_end = out_begin + canvas_byte_len;

    for (int32_t i = 0; i < slot_count; ++i) {
      const FsCollageInputSlot& slot = slots[i];
      if (slot.rgba == nullptr) {
        return FS_ERR_NULL_POINTER;
      }
      size_t slot_byte_len = 0;
      const int32_t slot_rc =
          validate_rgba_dimensions(slot.width, slot.height, &slot_byte_len);
      if (slot_rc != FS_OK) {
        return slot_rc;
      }
      if (slot.rgba_len < slot_byte_len) {
        return FS_ERR_INVALID_DIMENSIONS;
      }
      if (!std::isfinite(slot.pan_x) ||
          !std::isfinite(slot.pan_y) ||
          !std::isfinite(slot.zoom)) {
        return FS_ERR_INVALID_PARAMS;
      }
      const uintptr_t s_begin = reinterpret_cast<uintptr_t>(slot.rgba);
      const uintptr_t s_end = s_begin + slot_byte_len;
      if (s_begin < out_end && out_begin < s_end) {
        return FS_ERR_INVALID_PARAMS;
      }
    }

    // Fill entire canvas with background color (guarantees exact margin & gutter bytes).
    const size_t total_pixels = canvas_byte_len / 4u;
    for (size_t p = 0; p < total_pixels; ++p) {
      const size_t off = p * 4u;
      out_canvas_rgba[off + 0u] = config->bg_r;
      out_canvas_rgba[off + 1u] = config->bg_g;
      out_canvas_rgba[off + 2u] = config->bg_b;
      out_canvas_rgba[off + 3u] = config->bg_a;
    }

    // Render each slot inside its exact cell bounds.
    for (int32_t i = 0; i < slot_count; ++i) {
      const FsCollageInputSlot& slot = slots[i];
      const CellRect& cell = cells[static_cast<size_t>(i)];
      const int32_t cw = cell.width();
      const int32_t ch = cell.height();
      const float sw = static_cast<float>(slot.width);
      const float sh = static_cast<float>(slot.height);

      const float pan_x = std::clamp(slot.pan_x, -1.0f, 1.0f);
      const float pan_y = std::clamp(slot.pan_y, -1.0f, 1.0f);
      const float zoom = std::clamp(slot.zoom, 1.0f, 3.0f);

      const float src_aspect = sw / sh;
      const float cell_aspect = static_cast<float>(cw) / static_cast<float>(ch);

      float base_w = sw;
      float base_h = sh;
      if (src_aspect > cell_aspect) {
        base_h = sh;
        base_w = sh * cell_aspect;
      } else {
        base_w = sw;
        base_h = sw / cell_aspect;
      }

      const float crop_w = base_w / zoom;
      const float crop_h = base_h / zoom;
      const float slack_x = std::max(0.0f, sw - crop_w);
      const float slack_y = std::max(0.0f, sh - crop_h);

      const float win_x0 = 0.5f * slack_x * (1.0f - pan_x);
      const float win_y0 = 0.5f * slack_y * (1.0f - pan_y);

      const float inv_cw = 1.0f / static_cast<float>(cw);
      const float inv_ch = 1.0f / static_cast<float>(ch);

      for (int32_t oy = cell.y0; oy < cell.y1; ++oy) {
        const float v = (static_cast<float>(oy - cell.y0) + 0.5f) * inv_ch;
        const float sy = win_y0 + v * crop_h - 0.5f;
        const size_t row_off = static_cast<size_t>(oy) * config->canvas_width;
        for (int32_t ox = cell.x0; ox < cell.x1; ++ox) {
          const float u = (static_cast<float>(ox - cell.x0) + 0.5f) * inv_cw;
          const float sx = win_x0 + u * crop_w - 0.5f;
          uint8_t* dst_px =
              out_canvas_rgba + (row_off + static_cast<size_t>(ox)) * 4u;
          sample_catmull_rom(slot.rgba, slot.width, slot.height, sx, sy, dst_px);
        }
      }
    }

    return FS_OK;
  } catch (...) {
    return FS_ERR_ALLOC_FAILED;
  }
}

}  // extern "C"
