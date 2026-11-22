#include "fujistudio_c_api.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <random>
#include <vector>

namespace {

#define FS_CHECK(cond)                                                     \
  do {                                                                     \
    if (!(cond)) {                                                         \
      std::fprintf(stderr, "CHECK FAILED at %s:%d: %s\n", __FILE__,        \
                   __LINE__, #cond);                                       \
      std::abort();                                                        \
    }                                                                      \
  } while (0)

double preset_ratio(int32_t preset, int32_t src_w, int32_t src_h) {
  switch (preset) {
    case FS_ASPECT_4_5:
      return 4.0 / 5.0;
    case FS_ASPECT_1_1:
      return 1.0;
    case FS_ASPECT_3_2:
      return 3.0 / 2.0;
    case FS_ASPECT_9_16:
      return 9.0 / 16.0;
    default:
      return static_cast<double>(src_w) / static_cast<double>(src_h);
  }
}

void test_zero_black_corners_1000_samples() {
  std::mt19937_64 rng(0xF001570D10ULL);
  std::uniform_real_distribution<float> angle_dist(-15.0f, 15.0f);
  std::uniform_real_distribution<float> box_dist(-0.5f, 1.5f);
  std::uniform_int_distribution<int32_t> preset_dist(
      FS_ASPECT_ORIGINAL, FS_ASPECT_9_16);

  const std::array<std::pair<int32_t, int32_t>, 6> fixed_dims = {{
      {13, 7},
      {7, 13},
      {64, 64},
      {120, 80},
      {81, 144},
      {199, 133},
  }};
  std::uniform_int_distribution<int32_t> dim_dist(16, 160);

  for (int iter = 0; iter < 1000; ++iter) {
    int32_t w = 0;
    int32_t h = 0;
    if (iter < 120) {
      const auto p = fixed_dims[static_cast<size_t>(iter) % fixed_dims.size()];
      w = p.first;
      h = p.second;
    } else {
      w = dim_dist(rng);
      h = dim_dist(rng);
    }

    const float rot = angle_dist(rng);
    const int32_t preset = preset_dist(rng);
    const FsNormCropBox req{
        box_dist(rng),
        box_dist(rng),
        box_dist(rng),
        box_dist(rng),
    };

    FsNormCropBox clamped{};
    int32_t out_w = 0;
    int32_t out_h = 0;
    const int32_t rc = fs_geometry_clamp_crop(
        w, h, rot, preset, &req, &clamped, &out_w, &out_h);
    FS_CHECK(rc == FS_OK);
    FS_CHECK(out_w >= 1 && out_h >= 1);
    FS_CHECK(clamped.left >= 0.0f && clamped.left <= 1.0f);
    FS_CHECK(clamped.top >= 0.0f && clamped.top <= 1.0f);
    FS_CHECK(clamped.right >= clamped.left && clamped.right <= 1.0f);
    FS_CHECK(clamped.bottom >= clamped.top && clamped.bottom <= 1.0f);

    std::vector<uint8_t> src(static_cast<size_t>(w) * h * 4u, 255u);
    std::vector<uint8_t> dst(static_cast<size_t>(out_w) * out_h * 4u, 0u);

    FsGeometryParams params{};
    params.rotation_deg = rot;
    params.aspect_preset = preset;
    params.crop_box = clamped;
    params.high_quality = (iter % 2);

    const int32_t r_rc = fs_geometry_render_rgba_into(
        src.data(),
        src.size(),
        w,
        h,
        &params,
        dst.data(),
        dst.size(),
        out_w,
        out_h);
    FS_CHECK(r_rc == FS_OK);

    for (size_t i = 0; i < dst.size(); i += 4u) {
      FS_CHECK(dst[i + 0u] >= 254u);
      FS_CHECK(dst[i + 1u] >= 254u);
      FS_CHECK(dst[i + 2u] >= 254u);
      FS_CHECK(dst[i + 3u] >= 254u);
    }
  }
  std::printf("[PASS] Suite 1: Zero Black Corners (1000 random samples)\n");
}

void test_aspect_ratio_precision() {
  const std::array<int32_t, 4> presets = {
      FS_ASPECT_4_5, FS_ASPECT_1_1, FS_ASPECT_3_2, FS_ASPECT_9_16};
  const std::array<std::pair<int32_t, int32_t>, 4> sizes = {{
      {1280, 853},
      {853, 1280},
      {624, 416},
      {301, 203},
  }};
  const std::array<float, 5> angles = {-14.5f, -5.0f, 0.0f, 4.2f, 12.7f};

  const FsNormCropBox full{0.0f, 0.0f, 1.0f, 1.0f};
  for (auto sz : sizes) {
    for (float ang : angles) {
      for (int32_t preset : presets) {
        FsNormCropBox clamped{};
        int32_t ow = 0;
        int32_t oh = 0;
        FS_CHECK(fs_geometry_clamp_crop(
                     sz.first, sz.second, ang, preset, &full, &clamped, &ow, &oh) ==
                 FS_OK);
        const double r = preset_ratio(preset, sz.first, sz.second);
        if (r <= 1.0) {
          const double expected_w = static_cast<double>(oh) * r;
          FS_CHECK(std::abs(static_cast<double>(ow) - expected_w) <= 1.0);
        } else {
          const double expected_h = static_cast<double>(ow) / r;
          FS_CHECK(std::abs(static_cast<double>(oh) - expected_h) <= 1.0);
        }
      }
    }
  }
  std::printf("[PASS] Suite 2: Aspect Ratio Precision (<= 1px rounding)\n");
}

void test_identity_and_alpha_preservation() {
  constexpr int32_t w = 64;
  constexpr int32_t h = 48;
  std::vector<uint8_t> src(static_cast<size_t>(w) * h * 4u);
  std::mt19937_64 rng(42);
  for (size_t i = 0; i < src.size(); ++i) {
    src[i] = static_cast<uint8_t>(rng() & 0xFFu);
  }
  std::vector<uint8_t> dst(src.size(), 0u);

  FsGeometryParams params{};
  params.rotation_deg = 0.0f;
  params.aspect_preset = FS_ASPECT_ORIGINAL;
  params.crop_box = FsNormCropBox{0.0f, 0.0f, 1.0f, 1.0f};
  params.high_quality = 1;

  FS_CHECK(fs_geometry_render_rgba_into(
               src.data(), src.size(), w, h, &params, dst.data(), dst.size(), w, h) ==
           FS_OK);
  FS_CHECK(std::memcmp(src.data(), dst.data(), src.size()) == 0);
  std::printf("[PASS] Suite 3: Identity & Alpha Preservation\n");
}

void test_auto_horizon_accuracy() {
  constexpr int32_t w = 320;
  constexpr int32_t h = 240;

  // Render a synthetic level grid rotated by tilt_deg, then expect analyze to
  // suggest -tilt_deg within <= 0.6 deg.
  auto make_tilted_grid = [&](float tilt_deg) -> std::vector<uint8_t> {
    std::vector<uint8_t> buf(static_cast<size_t>(w) * h * 4u, 220u);
    const double rad = static_cast<double>(tilt_deg) * (3.141592653589793 / 180.0);
    const double c = std::cos(rad);
    const double s = std::sin(rad);
    const double cx = (w - 1) * 0.5;
    const double cy = (h - 1) * 0.5;

    for (int32_t y = 0; y < h; ++y) {
      for (int32_t x = 0; x < w; ++x) {
        const double dx = x - cx;
        const double dy = y - cy;
        // Inverse rotate to level grid coordinates
        const double lx = dx * c + dy * s;
        const double ly = -dx * s + dy * c;
        const double dh = std::abs(std::fmod(ly + 400.0, 40.0) - 20.0);
        const double dv = std::abs(std::fmod(lx + 400.0, 40.0) - 20.0);
        const double cov_h = std::clamp(2.0 - dh, 0.0, 1.0);
        const double cov_v = std::clamp(2.0 - dv, 0.0, 1.0);
        const double cov = std::max(cov_h, cov_v);
        const size_t idx = (static_cast<size_t>(y) * w + x) * 4u;
        const uint8_t val =
            static_cast<uint8_t>(std::lround(230.0 - cov * 210.0));
        buf[idx + 0u] = val;
        buf[idx + 1u] = val;
        buf[idx + 2u] = val;
        buf[idx + 3u] = 255u;
      }
    }
    return buf;
  };

  const std::array<float, 4> test_tilts = {-6.5f, -2.0f, 3.5f, 8.0f};
  for (float tilt : test_tilts) {
    auto img = make_tilted_grid(tilt);
    FsGeometryProposal prop{};
    FS_CHECK(fs_geometry_analyze_rgba(
                 img.data(), img.size(), w, h, FS_ASPECT_ORIGINAL, &prop) == FS_OK);
    if (prop.has_horizon_line != 1) {
      std::fprintf(
          stderr,
          "Horizon not detected for tilt=%.2f: has=%d angle=%.2f conf=%.3f\n",
          tilt,
          prop.has_horizon_line,
          prop.suggested_rotation_deg,
          prop.horizon_confidence);
    }
    FS_CHECK(prop.has_horizon_line == 1);
    const float expected_correction = -tilt;
    const float err = std::abs(prop.suggested_rotation_deg - expected_correction);
    if (err > 0.6f) {
      std::fprintf(
          stderr,
          "Horizon accuracy failed for tilt=%.2f: got=%.2f expected=%.2f err=%.2f conf=%.2f\n",
          tilt,
          prop.suggested_rotation_deg,
          expected_correction,
          err,
          prop.horizon_confidence);
    }
    FS_CHECK(err <= 0.6f);
  }

  // Uniform random noise -> must not hallucinate a horizon line.
  std::vector<uint8_t> noise(static_cast<size_t>(w) * h * 4u);
  std::mt19937_64 rng(999);
  for (int32_t p = 0; p < w * h; ++p) {
    const uint8_t v = static_cast<uint8_t>(110 + (rng() % 35));
    const size_t idx = static_cast<size_t>(p) * 4u;
    noise[idx + 0u] = v;
    noise[idx + 1u] = v;
    noise[idx + 2u] = v;
    noise[idx + 3u] = 255u;
  }
  FsGeometryProposal noise_prop{};
  FS_CHECK(fs_geometry_analyze_rgba(
               noise.data(), noise.size(), w, h, FS_ASPECT_ORIGINAL, &noise_prop) ==
           FS_OK);
  FS_CHECK(noise_prop.has_horizon_line == 0);
  FS_CHECK(std::abs(noise_prop.suggested_rotation_deg) < 1e-5f);
  std::printf("[PASS] Suite 4: Auto-Horizon Accuracy & Noise Rejection\n");
}

void test_ai_crop_subject_tracking() {
  constexpr int32_t w = 240;
  constexpr int32_t h = 160;

  for (int side = 0; side < 2; ++side) {
    std::vector<uint8_t> img(static_cast<size_t>(w) * h * 4u);
    for (int32_t y = 0; y < h; ++y) {
      for (int32_t x = 0; x < w; ++x) {
        const size_t idx = (static_cast<size_t>(y) * w + x) * 4u;
        // Flat dark cool background
        img[idx + 0u] = 30u;
        img[idx + 1u] = 40u;
        img[idx + 2u] = 55u;
        img[idx + 3u] = 255u;
      }
    }

    // Place a high-contrast textured warm subject on the left (x in [20..70])
    // or right (x in [170..220]), y in [40..120].
    const int32_t sx0 = side == 0 ? 20 : 170;
    const int32_t sx1 = sx0 + 50;
    const int32_t sy0 = 40;
    const int32_t sy1 = 120;
    for (int32_t y = sy0; y < sy1; ++y) {
      for (int32_t x = sx0; x < sx1; ++x) {
        const size_t idx = (static_cast<size_t>(y) * w + x) * 4u;
        const bool checker = ((x / 4) + (y / 4)) % 2 == 0;
        img[idx + 0u] = checker ? 235u : 195u;
        img[idx + 1u] = checker ? 180u : 140u;
        img[idx + 2u] = checker ? 145u : 110u;
        img[idx + 3u] = 255u;
      }
    }

    for (int32_t preset : {FS_ASPECT_4_5, FS_ASPECT_9_16}) {
      FsGeometryProposal prop{};
      FS_CHECK(fs_geometry_analyze_rgba(
                   img.data(), img.size(), w, h, preset, &prop) == FS_OK);

      // Verify crop captures >= 85% of subject area and doesn't slice top.
      const double box_x0 = prop.suggested_crop_box.left * w;
      const double box_x1 = prop.suggested_crop_box.right * w;
      const double box_y0 = prop.suggested_crop_box.top * h;
      const double box_y1 = prop.suggested_crop_box.bottom * h;

      const double inter_w =
          std::max(0.0, std::min<double>(box_x1, sx1) - std::max<double>(box_x0, sx0));
      const double inter_h =
          std::max(0.0, std::min<double>(box_y1, sy1) - std::max<double>(box_y0, sy0));
      const double subj_area = static_cast<double>(sx1 - sx0) * (sy1 - sy0);
      const double capture_ratio = (inter_w * inter_h) / subj_area;

      FS_CHECK(capture_ratio >= 0.85);
      FS_CHECK(box_y0 <= sy0 + 2.0);
    }
  }
  std::printf("[PASS] Suite 5: AI Crop Subject Tracking (>= 85%% capture)\n");
}

void test_collage_gutter_and_background_exactness() {
  struct SlotBuf {
    int32_t w;
    int32_t h;
    std::vector<uint8_t> rgba;
  };

  auto make_slot = [](int32_t w, int32_t h, uint8_t r, uint8_t g, uint8_t b) {
    SlotBuf s{w, h, std::vector<uint8_t>(static_cast<size_t>(w) * h * 4u)};
    for (size_t i = 0; i < s.rgba.size(); i += 4u) {
      s.rgba[i + 0u] = r;
      s.rgba[i + 1u] = g;
      s.rgba[i + 2u] = b;
      s.rgba[i + 3u] = 255u;
    }
    return s;
  };

  // Mix landscape & portrait slots
  std::array<SlotBuf, 4> bufs = {
      make_slot(180, 120, 200, 40, 40),
      make_slot(120, 180, 40, 200, 40),
      make_slot(160, 100, 40, 40, 200),
      make_slot(100, 160, 200, 200, 40),
  };

  const std::array<int32_t, 6> counts = {2, 2, 3, 3, 3, 4};
  constexpr int32_t cw = 270;
  constexpr int32_t ch = 480;
  constexpr int32_t gutter = 12;
  constexpr int32_t margin = 16;
  constexpr uint8_t bg_r = 244;
  constexpr uint8_t bg_g = 241;
  constexpr uint8_t bg_b = 234;
  constexpr uint8_t bg_a = 255;

  for (int32_t tpl = FS_COLLAGE_SPLIT_2_V; tpl <= FS_COLLAGE_GRID_4_EVEN; ++tpl) {
    const int32_t sc = counts[static_cast<size_t>(tpl)];
    std::array<FsCollageInputSlot, 4> slots{};
    for (int32_t i = 0; i < sc; ++i) {
      slots[static_cast<size_t>(i)] = FsCollageInputSlot{
          bufs[static_cast<size_t>(i)].rgba.data(),
          bufs[static_cast<size_t>(i)].rgba.size(),
          bufs[static_cast<size_t>(i)].w,
          bufs[static_cast<size_t>(i)].h,
          0.0f,
          0.0f,
          1.0f,
          0,
      };
    }

    FsCollageConfig cfg{
        tpl, cw, ch, gutter, margin, bg_r, bg_g, bg_b, bg_a};
    std::vector<uint8_t> canvas(static_cast<size_t>(cw) * ch * 4u, 0u);
    FS_CHECK(fs_collage_render_rgba_into(
                 slots.data(), sc, &cfg, canvas.data(), canvas.size()) == FS_OK);

    // Check every pixel in outer_margin matches exact background bytes.
    for (int32_t y = 0; y < ch; ++y) {
      for (int32_t x = 0; x < cw; ++x) {
        if (x < margin || x >= cw - margin || y < margin || y >= ch - margin) {
          const size_t idx = (static_cast<size_t>(y) * cw + x) * 4u;
          FS_CHECK(canvas[idx + 0u] == bg_r);
          FS_CHECK(canvas[idx + 1u] == bg_g);
          FS_CHECK(canvas[idx + 2u] == bg_b);
          FS_CHECK(canvas[idx + 3u] == bg_a);
        }
      }
    }

    // Check exact center gutter line for templates with horizontal/vertical center split.
    if (tpl == FS_COLLAGE_SPLIT_2_V || tpl == FS_COLLAGE_GRID_4_EVEN) {
      const int32_t avail_h = ch - 2 * margin;
      const int32_t h0 = (avail_h - gutter) / 2;
      const int32_t gy = margin + h0 + gutter / 2;
      for (int32_t x = 0; x < cw; ++x) {
        const size_t idx = (static_cast<size_t>(gy) * cw + x) * 4u;
        FS_CHECK(canvas[idx + 0u] == bg_r);
        FS_CHECK(canvas[idx + 1u] == bg_g);
        FS_CHECK(canvas[idx + 2u] == bg_b);
        FS_CHECK(canvas[idx + 3u] == bg_a);
      }
    }
    if (tpl == FS_COLLAGE_SPLIT_2_H || tpl == FS_COLLAGE_GRID_4_EVEN) {
      const int32_t avail_w = cw - 2 * margin;
      const int32_t w0 = (avail_w - gutter) / 2;
      const int32_t gx = margin + w0 + gutter / 2;
      for (int32_t y = 0; y < ch; ++y) {
        const size_t idx = (static_cast<size_t>(y) * cw + gx) * 4u;
        FS_CHECK(canvas[idx + 0u] == bg_r);
        FS_CHECK(canvas[idx + 1u] == bg_g);
        FS_CHECK(canvas[idx + 2u] == bg_b);
        FS_CHECK(canvas[idx + 3u] == bg_a);
      }
    }
  }
  std::printf("[PASS] Suite 6: Collage Gutter & Background Exactness (6 templates)\n");
}

void test_collage_pan_zoom_clamping() {
  constexpr int32_t sw = 80;
  constexpr int32_t sh = 60;
  // Solid green slots
  std::vector<uint8_t> s0(static_cast<size_t>(sw) * sh * 4u);
  for (size_t i = 0; i < s0.size(); i += 4u) {
    s0[i + 0u] = 20u;
    s0[i + 1u] = 180u;
    s0[i + 2u] = 90u;
    s0[i + 3u] = 255u;
  }

  std::array<FsCollageInputSlot, 2> slots = {{
      {s0.data(), s0.size(), sw, sh, -99.0f, 99.0f, 0.1f, 0},
      {s0.data(), s0.size(), sw, sh, 99.0f, -99.0f, 10.0f, 0},
  }};
  // Canvas with black background, margin=0, gutter=0 -> entire canvas must stay green!
  constexpr int32_t cw = 120;
  constexpr int32_t ch = 120;
  FsCollageConfig cfg{
      FS_COLLAGE_SPLIT_2_V, cw, ch, 0, 0, 0, 0, 0, 255};
  std::vector<uint8_t> canvas(static_cast<size_t>(cw) * ch * 4u, 0u);
  FS_CHECK(fs_collage_render_rgba_into(
               slots.data(), 2, &cfg, canvas.data(), canvas.size()) == FS_OK);

  for (size_t i = 0; i < canvas.size(); i += 4u) {
    FS_CHECK(canvas[i + 0u] == 20u);
    FS_CHECK(canvas[i + 1u] == 180u);
    FS_CHECK(canvas[i + 2u] == 90u);
    FS_CHECK(canvas[i + 3u] == 255u);
  }
  std::printf("[PASS] Suite 7: Collage Pan/Zoom Clamping\n");
}

void test_adversarial_guard_suite() {
  std::vector<uint8_t> buf(64 * 64 * 4u, 128u);
  std::vector<uint8_t> out(64 * 64 * 4u, 0u);
  FsNormCropBox box{0.0f, 0.0f, 1.0f, 1.0f};
  FsNormCropBox out_box{};
  int32_t ow = 0;
  int32_t oh = 0;

  // Null pointers
  FS_CHECK(fs_geometry_clamp_crop(64, 64, 0.0f, 0, nullptr, &out_box, &ow, &oh) ==
           FS_ERR_NULL_POINTER);
  FS_CHECK(fs_geometry_clamp_crop(64, 64, 0.0f, 0, &box, nullptr, &ow, &oh) ==
           FS_ERR_NULL_POINTER);
  FS_CHECK(fs_geometry_analyze_rgba(nullptr, 100, 64, 64, 0, nullptr) ==
           FS_ERR_NULL_POINTER);

  FsGeometryProposal prop{};
  FS_CHECK(fs_geometry_analyze_rgba(nullptr, buf.size(), 64, 64, 0, &prop) ==
           FS_ERR_NULL_POINTER);

  // NaN / Inf
  const float nan_v = std::numeric_limits<float>::quiet_NaN();
  const float inf_v = std::numeric_limits<float>::infinity();
  FS_CHECK(fs_geometry_clamp_crop(64, 64, nan_v, 0, &box, &out_box, &ow, &oh) ==
           FS_ERR_INVALID_PARAMS);
  FsNormCropBox inf_box{0.0f, 0.0f, inf_v, 1.0f};
  FS_CHECK(fs_geometry_clamp_crop(64, 64, 0.0f, 0, &inf_box, &out_box, &ow, &oh) ==
           FS_ERR_INVALID_PARAMS);

  // Dimension overflow
  FS_CHECK(fs_geometry_clamp_crop(
               FS_MAX_IMAGE_DIMENSION + 1, 64, 0.0f, 0, &box, &out_box, &ow, &oh) ==
           FS_ERR_OVERFLOW);

  // In-place aliasing rejected in render_rgba_into
  FsGeometryParams params{1.0f, FS_ASPECT_ORIGINAL, box, 0};
  FS_CHECK(fs_geometry_render_rgba_into(
               buf.data(), buf.size(), 64, 64, &params, buf.data(), buf.size(), 64, 64) ==
           FS_ERR_INVALID_PARAMS);

  // Undersized out_len
  FS_CHECK(fs_geometry_render_rgba_into(
               buf.data(), buf.size(), 64, 64, &params, out.data(), 16u, 64, 64) ==
           FS_ERR_INVALID_DIMENSIONS);

  // Collage wrong slot count -> FS_ERR_COLLAGE_INVALID_SLOTS
  std::array<FsCollageInputSlot, 2> slots = {{
      {buf.data(), buf.size(), 64, 64, 0.0f, 0.0f, 1.0f, 0},
      {buf.data(), buf.size(), 64, 64, 0.0f, 0.0f, 1.0f, 0},
  }};
  FsCollageConfig cfg{
      FS_COLLAGE_GRID_4_EVEN, 128, 128, 4, 4, 0, 0, 0, 255};
  std::vector<uint8_t> canvas(128 * 128 * 4u, 0u);
  FS_CHECK(fs_collage_render_rgba_into(
               slots.data(), 2, &cfg, canvas.data(), canvas.size()) ==
           FS_ERR_COLLAGE_INVALID_SLOTS);

  // Collage NaN pan / undersized canvas buffer / overflow dims
  slots[0].pan_x = nan_v;
  cfg.template_id = FS_COLLAGE_SPLIT_2_V;
  FS_CHECK(fs_collage_render_rgba_into(
               slots.data(), 2, &cfg, canvas.data(), canvas.size()) ==
           FS_ERR_INVALID_PARAMS);
  slots[0].pan_x = 0.0f;
  FS_CHECK(fs_collage_render_rgba_into(
               slots.data(), 2, &cfg, canvas.data(), 128u) ==
           FS_ERR_INVALID_DIMENSIONS);
  cfg.canvas_width = FS_MAX_IMAGE_DIMENSION + 1;
  FS_CHECK(fs_collage_render_rgba_into(
               slots.data(), 2, &cfg, canvas.data(), canvas.size()) ==
           FS_ERR_OVERFLOW);

  std::printf("[PASS] Suite 8: Adversarial Guard Suite\n");
}

}  // namespace

int main() {
  test_zero_black_corners_1000_samples();
  test_aspect_ratio_precision();
  test_identity_and_alpha_preservation();
  test_auto_horizon_accuracy();
  test_ai_crop_subject_tracking();
  test_collage_gutter_and_background_exactness();
  test_collage_pan_zoom_clamping();
  test_adversarial_guard_suite();
  std::printf("ALL 8 GEOMETRY + COLLAGE PROPERTY SUITES PASSED\n");
  return 0;
}
