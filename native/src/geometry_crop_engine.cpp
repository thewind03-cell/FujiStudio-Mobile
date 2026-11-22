#include "fujistudio_c_api.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;

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

bool is_valid_aspect_preset(int32_t preset) noexcept {
  return preset >= FS_ASPECT_ORIGINAL && preset <= FS_ASPECT_9_16;
}

double aspect_ratio_for_preset(
    int32_t preset,
    int32_t src_width,
    int32_t src_height) noexcept {
  switch (preset) {
    case FS_ASPECT_4_5:
      return 4.0 / 5.0;
    case FS_ASPECT_1_1:
      return 1.0;
    case FS_ASPECT_3_2:
      return 3.0 / 2.0;
    case FS_ASPECT_9_16:
      return 9.0 / 16.0;
    case FS_ASPECT_ORIGINAL:
    default:
      return static_cast<double>(src_width) / static_cast<double>(src_height);
  }
}

struct InscribedFrame {
  double width_px;
  double height_px;
  double cos_t;
  double sin_t;
};

InscribedFrame compute_inscribed_frame(
    int32_t src_width,
    int32_t src_height,
    float rotation_deg) noexcept {
  const double clamped_deg =
      std::clamp(static_cast<double>(rotation_deg), -15.0, 15.0);
  const double theta = clamped_deg * (kPi / 180.0);
  const double cos_t = std::cos(theta);
  const double sin_t = std::sin(theta);
  const double abs_c = std::abs(cos_t);
  const double abs_s = std::abs(sin_t);

  const double eps = (src_width >= 4 && src_height >= 4) ? 0.5 : 0.0;
  const double avail_w =
      std::max(1.0, static_cast<double>(src_width) - 2.0 * eps);
  const double avail_h =
      std::max(1.0, static_cast<double>(src_height) - 2.0 * eps);

  const double r0 =
      static_cast<double>(src_width) / static_cast<double>(src_height);
  const double denom_w = r0 * abs_c + abs_s;
  const double denom_h = r0 * abs_s + abs_c;
  const double h_inscr = std::min(avail_w / denom_w, avail_h / denom_h);
  const double w_inscr = r0 * h_inscr;

  return InscribedFrame{w_inscr, h_inscr, cos_t, sin_t};
}

int32_t clamp_crop_internal(
    int32_t src_width,
    int32_t src_height,
    float rotation_deg,
    int32_t aspect_preset,
    const FsNormCropBox& requested,
    FsNormCropBox* out_clamped,
    int32_t* out_pixel_width,
    int32_t* out_pixel_height) noexcept {
  if (src_width <= 0 || src_height <= 0) {
    return FS_ERR_INVALID_DIMENSIONS;
  }
  if (src_width > FS_MAX_IMAGE_DIMENSION ||
      src_height > FS_MAX_IMAGE_DIMENSION) {
    return FS_ERR_OVERFLOW;
  }
  if (!std::isfinite(rotation_deg) ||
      !std::isfinite(requested.left) ||
      !std::isfinite(requested.top) ||
      !std::isfinite(requested.right) ||
      !std::isfinite(requested.bottom) ||
      !is_valid_aspect_preset(aspect_preset)) {
    return FS_ERR_INVALID_PARAMS;
  }

  const InscribedFrame inscr =
      compute_inscribed_frame(src_width, src_height, rotation_deg);
  const double r0 =
      static_cast<double>(src_width) / static_cast<double>(src_height);
  const double target_r =
      aspect_ratio_for_preset(aspect_preset, src_width, src_height);
  // Ratio of normalized width to normalized height: nw / nh = target_r / r0.
  const double k = target_r / r0;

  double req_l = std::clamp(static_cast<double>(requested.left), 0.0, 1.0);
  double req_r = std::clamp(static_cast<double>(requested.right), 0.0, 1.0);
  double req_t = std::clamp(static_cast<double>(requested.top), 0.0, 1.0);
  double req_b = std::clamp(static_cast<double>(requested.bottom), 0.0, 1.0);
  if (req_r < req_l) std::swap(req_l, req_r);
  if (req_b < req_t) std::swap(req_t, req_b);

  const double max_nh = std::min(1.0, 1.0 / k);
  const double min_nh =
      std::min(max_nh, std::max(0.10, 0.10 / k));

  const double req_w = req_r - req_l;
  const double req_h = req_b - req_t;
  double nh_cand = std::min(req_h, req_w / k);
  if (nh_cand <= 0.0) {
    nh_cand = min_nh;
  }
  const double nh = std::clamp(nh_cand, min_nh, max_nh);
  const double nw = std::clamp(k * nh, 0.0, 1.0);

  const double cx = 0.5 * (req_l + req_r);
  const double cy = 0.5 * (req_t + req_b);
  const double left = std::clamp(cx - 0.5 * nw, 0.0, 1.0 - nw);
  const double top = std::clamp(cy - 0.5 * nh, 0.0, 1.0 - nh);
  const double right = std::min(1.0, left + nw);
  const double bottom = std::min(1.0, top + nh);

  out_clamped->left = static_cast<float>(left);
  out_clamped->top = static_cast<float>(top);
  out_clamped->right = static_cast<float>(right);
  out_clamped->bottom = static_cast<float>(bottom);

  const double box_w_px = (right - left) * inscr.width_px;
  const double box_h_px = (bottom - top) * inscr.height_px;
  int32_t px_w = 1;
  int32_t px_h = 1;
  if (target_r <= 1.0) {
    px_h = std::max<int32_t>(1, static_cast<int32_t>(std::lround(box_h_px)));
    px_w = std::max<int32_t>(
        1, static_cast<int32_t>(std::lround(static_cast<double>(px_h) * target_r)));
  } else {
    px_w = std::max<int32_t>(1, static_cast<int32_t>(std::lround(box_w_px)));
    px_h = std::max<int32_t>(
        1, static_cast<int32_t>(std::lround(static_cast<double>(px_w) / target_r)));
  }

  *out_pixel_width = std::clamp(px_w, 1, FS_MAX_IMAGE_DIMENSION);
  *out_pixel_height = std::clamp(px_h, 1, FS_MAX_IMAGE_DIMENSION);
  return FS_OK;
}

inline void sample_bilinear(
    const uint8_t* rgba,
    int32_t width,
    int32_t height,
    float sx,
    float sy,
    uint8_t* out_px) noexcept {
  const float cx = std::clamp(sx, 0.0f, static_cast<float>(width - 1));
  const float cy = std::clamp(sy, 0.0f, static_cast<float>(height - 1));

  const int32_t x0 = static_cast<int32_t>(std::floor(cx));
  const int32_t y0 = static_cast<int32_t>(std::floor(cy));
  const int32_t x1 = std::min(x0 + 1, width - 1);
  const int32_t y1 = std::min(y0 + 1, height - 1);

  const float fx = cx - static_cast<float>(x0);
  const float fy = cy - static_cast<float>(y0);
  const float w00 = (1.0f - fx) * (1.0f - fy);
  const float w10 = fx * (1.0f - fy);
  const float w01 = (1.0f - fx) * fy;
  const float w11 = fx * fy;

  const size_t idx00 = (static_cast<size_t>(y0) * width + x0) * 4u;
  const size_t idx10 = (static_cast<size_t>(y0) * width + x1) * 4u;
  const size_t idx01 = (static_cast<size_t>(y1) * width + x0) * 4u;
  const size_t idx11 = (static_cast<size_t>(y1) * width + x1) * 4u;

  for (int c = 0; c < 4; ++c) {
    const float v = w00 * rgba[idx00 + c] + w10 * rgba[idx10 + c] +
                    w01 * rgba[idx01 + c] + w11 * rgba[idx11 + c];
    out_px[c] = static_cast<uint8_t>(std::clamp(v + 0.5f, 0.0f, 255.0f));
  }
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

void downsample_luma_area(
    const uint8_t* rgba,
    int32_t src_w,
    int32_t src_h,
    int32_t dst_w,
    int32_t dst_h,
    std::vector<float>& out_luma) noexcept {
  out_luma.assign(static_cast<size_t>(dst_w) * dst_h, 0.0f);
  const float scale_x = static_cast<float>(src_w) / static_cast<float>(dst_w);
  const float scale_y = static_cast<float>(src_h) / static_cast<float>(dst_h);

  for (int32_t dy = 0; dy < dst_h; ++dy) {
    const int32_t sy0 =
        std::clamp(static_cast<int32_t>(dy * scale_y), 0, src_h - 1);
    const int32_t sy1 = std::clamp(
        std::max(sy0 + 1, static_cast<int32_t>((dy + 1) * scale_y)),
        1,
        src_h);
    for (int32_t dx = 0; dx < dst_w; ++dx) {
      const int32_t sx0 =
          std::clamp(static_cast<int32_t>(dx * scale_x), 0, src_w - 1);
      const int32_t sx1 = std::clamp(
          std::max(sx0 + 1, static_cast<int32_t>((dx + 1) * scale_x)),
          1,
          src_w);
      float sum = 0.0f;
      int32_t count = 0;
      for (int32_t sy = sy0; sy < sy1; ++sy) {
        const size_t row = static_cast<size_t>(sy) * src_w;
        for (int32_t sx = sx0; sx < sx1; ++sx) {
          const size_t idx = (row + static_cast<size_t>(sx)) * 4u;
          const float y = 0.2126f * rgba[idx + 0u] +
                          0.7152f * rgba[idx + 1u] +
                          0.0722f * rgba[idx + 2u];
          sum += y;
          ++count;
        }
      }
      out_luma[static_cast<size_t>(dy) * dst_w + dx] =
          count > 0 ? (sum / (255.0f * static_cast<float>(count))) : 0.0f;
    }
  }
}

void estimate_horizon(
    const uint8_t* rgba,
    int32_t src_w,
    int32_t src_h,
    float* out_angle_deg,
    float* out_confidence,
    int32_t* out_has_horizon) noexcept {
  *out_angle_deg = 0.0f;
  *out_confidence = 0.0f;
  *out_has_horizon = 0;

  if (src_w < 12 || src_h < 12) {
    return;
  }

  const int32_t max_dim = std::max(src_w, src_h);
  const float scale = max_dim > 320 ? (320.0f / static_cast<float>(max_dim)) : 1.0f;
  const int32_t dw = std::max(8, static_cast<int32_t>(std::lround(src_w * scale)));
  const int32_t dh = std::max(8, static_cast<int32_t>(std::lround(src_h * scale)));

  std::vector<float> luma;
  downsample_luma_area(rgba, src_w, src_h, dw, dh, luma);

  // Separable 5-tap Gaussian pre-smoothing [1, 4, 6, 4, 1] / 16 to suppress
  // single-pixel noise and quantization staircase artifacts before Sobel.
  std::vector<float> tmp_luma(luma.size(), 0.0f);
  std::vector<float> smooth_luma(luma.size(), 0.0f);
  constexpr std::array<float, 5> kGauss = {
      1.0f / 16.0f, 4.0f / 16.0f, 6.0f / 16.0f, 4.0f / 16.0f, 1.0f / 16.0f};
  for (int32_t y = 0; y < dh; ++y) {
    const size_t row = static_cast<size_t>(y) * dw;
    for (int32_t x = 0; x < dw; ++x) {
      float acc = 0.0f;
      for (int k = -2; k <= 2; ++k) {
        const int32_t sx = std::clamp(x + k, 0, dw - 1);
        acc += kGauss[static_cast<size_t>(k + 2)] * luma[row + sx];
      }
      tmp_luma[row + x] = acc;
    }
  }
  for (int32_t y = 0; y < dh; ++y) {
    for (int32_t x = 0; x < dw; ++x) {
      float acc = 0.0f;
      for (int k = -2; k <= 2; ++k) {
        const int32_t sy = std::clamp(y + k, 0, dh - 1);
        acc += kGauss[static_cast<size_t>(k + 2)] *
               tmp_luma[static_cast<size_t>(sy) * dw + x];
      }
      smooth_luma[static_cast<size_t>(y) * dw + x] = acc;
    }
  }
  luma.swap(smooth_luma);

  const int32_t bx = std::max(1, static_cast<int32_t>(std::floor(dw * 0.05)));
  const int32_t by = std::max(1, static_cast<int32_t>(std::floor(dh * 0.05)));
  if (dw - 2 * bx < 3 || dh - 2 * by < 3) {
    return;
  }

  struct EdgeSample {
    float mag;
    float gx;
    float gy;
  };
  std::vector<EdgeSample> samples;
  samples.reserve(static_cast<size_t>(dw - 2 * bx) * (dh - 2 * by));
  std::vector<float> mags;
  mags.reserve(samples.capacity());

  auto at = [&](int32_t x, int32_t y) -> float {
    return luma[static_cast<size_t>(y) * dw + x];
  };

  for (int32_t y = by; y < dh - by; ++y) {
    for (int32_t x = bx; x < dw - bx; ++x) {
      const float tl = at(x - 1, y - 1);
      const float tc = at(x, y - 1);
      const float tr = at(x + 1, y - 1);
      const float ml = at(x - 1, y);
      const float mr = at(x + 1, y);
      const float bl = at(x - 1, y + 1);
      const float bc = at(x, y + 1);
      const float br = at(x + 1, y + 1);

      const float gx = (-tl + tr) + 2.0f * (-ml + mr) + (-bl + br);
      const float gy = (-tl - 2.0f * tc - tr) + (bl + 2.0f * bc + br);
      const float mag = std::sqrt(gx * gx + gy * gy);
      mags.push_back(mag);
      samples.push_back(EdgeSample{mag, gx, gy});
    }
  }

  if (mags.empty()) {
    return;
  }

  const size_t p80_idx = (mags.size() * 80u) / 100u;
  std::nth_element(
      mags.begin(),
      mags.begin() + static_cast<ptrdiff_t>(std::min(p80_idx, mags.size() - 1)),
      mags.end());
  const float p80_thresh =
      std::max(1e-3f, mags[std::min(p80_idx, mags.size() - 1)]);

  // 97 bins spanning [-12.0 deg, +12.0 deg] in 0.25 deg increments.
  constexpr int kNumBins = 97;
  constexpr float kMinDeg = -12.0f;
  constexpr float kStepDeg = 0.25f;
  std::array<double, kNumBins> hist{};
  double total_weight = 0.0;

  for (const auto& s : samples) {
    if (s.mag < p80_thresh) continue;
    const float abs_gx = std::abs(s.gx);
    const float abs_gy = std::abs(s.gy);

    // Determine the tilt of the line in screen coordinates (X right, Y down).
    // A horizontal line tilted CW by +alpha has gradient (-sin(alpha), cos(alpha)).
    // A vertical line tilted CW by +alpha has gradient (cos(alpha), sin(alpha)).
    // The leveling correction is -alpha.
    float corr_deg = 0.0f;
    bool valid = false;
    if (abs_gy >= abs_gx && abs_gy > 1e-6f) {
      // Horizontal-ish edge: tilt = atan2(-gx, gy) folded to [-90, 90]
      const float nx = (s.gy >= 0.0f) ? s.gx : -s.gx;
      const float ny = std::abs(s.gy);
      const float tilt_deg =
          static_cast<float>(std::atan2(-nx, ny) * (180.0 / kPi));
      if (std::abs(tilt_deg) <= 12.0f) {
        corr_deg = -tilt_deg;
        valid = true;
      }
    } else if (abs_gx > abs_gy && abs_gx > 1e-6f) {
      // Vertical-ish edge: tilt = atan2(gy, gx) folded to [-90, 90]
      const float nx = std::abs(s.gx);
      const float ny = (s.gx >= 0.0f) ? s.gy : -s.gy;
      const float tilt_deg =
          static_cast<float>(std::atan2(ny, nx) * (180.0 / kPi));
      if (std::abs(tilt_deg) <= 12.0f) {
        corr_deg = -tilt_deg;
        valid = true;
      }
    }

    if (!valid) continue;

    const float pos = (corr_deg - kMinDeg) / kStepDeg;
    const int b0 = static_cast<int>(std::floor(pos));
    const float frac = pos - static_cast<float>(b0);
    if (b0 >= 0 && b0 < kNumBins) {
      hist[static_cast<size_t>(b0)] +=
          static_cast<double>(s.mag) * (1.0 - frac);
    }
    if (b0 + 1 >= 0 && b0 + 1 < kNumBins) {
      hist[static_cast<size_t>(b0 + 1)] += static_cast<double>(s.mag) * frac;
    }
    total_weight += static_cast<double>(s.mag);
  }

  if (total_weight <= 1e-6) {
    return;
  }

  std::array<double, kNumBins> smooth{};
  for (int i = 0; i < kNumBins; ++i) {
    const double left = (i > 0) ? hist[static_cast<size_t>(i - 1)] : hist[0];
    const double mid = hist[static_cast<size_t>(i)];
    const double right =
        (i + 1 < kNumBins) ? hist[static_cast<size_t>(i + 1)] : hist[kNumBins - 1];
    smooth[static_cast<size_t>(i)] = 0.25 * left + 0.50 * mid + 0.25 * right;
  }

  int best_bin = 48;
  double peak_val = -1.0;
  for (int i = 0; i < kNumBins; ++i) {
    if (smooth[static_cast<size_t>(i)] > peak_val) {
      peak_val = smooth[static_cast<size_t>(i)];
      best_bin = i;
    }
  }

  double refined_bin = static_cast<double>(best_bin);
  if (best_bin > 0 && best_bin < kNumBins - 1) {
    const double y0 = smooth[static_cast<size_t>(best_bin - 1)];
    const double y1 = smooth[static_cast<size_t>(best_bin)];
    const double y2 = smooth[static_cast<size_t>(best_bin + 1)];
    const double denom = 2.0 * (y0 - 2.0 * y1 + y2);
    if (std::abs(denom) > 1e-12) {
      const double delta = std::clamp((y0 - y2) / denom, -0.5, 0.5);
      refined_bin += delta;
    }
  }

  std::array<double, kNumBins> sorted_smooth = smooth;
  std::nth_element(
      sorted_smooth.begin(),
      sorted_smooth.begin() + (kNumBins / 2),
      sorted_smooth.end());
  const double median_val = sorted_smooth[kNumBins / 2];

  double peak3 = smooth[static_cast<size_t>(best_bin)];
  if (best_bin > 0) peak3 += smooth[static_cast<size_t>(best_bin - 1)];
  if (best_bin + 1 < kNumBins) peak3 += smooth[static_cast<size_t>(best_bin + 1)];

  const double ratio = peak_val / std::max(median_val, total_weight * 0.002);
  const double ratio_score = std::clamp((ratio - 2.2) / 8.0, 0.0, 1.0);
  const double conc_score =
      std::clamp((peak3 / total_weight - 0.12) / 0.35, 0.0, 1.0);
  const float confidence =
      static_cast<float>(std::clamp(0.5 * ratio_score + 0.5 * conc_score, 0.0, 1.0));

  const float angle = std::clamp(
      kMinDeg + static_cast<float>(refined_bin) * kStepDeg,
      -12.0f,
      12.0f);

  *out_confidence = confidence;
  if (confidence >= 0.35f && std::abs(angle) >= 0.3f) {
    *out_angle_deg = angle;
    *out_has_horizon = 1;
  } else {
    *out_angle_deg = 0.0f;
    *out_has_horizon = 0;
  }
}

void estimate_saliency_crop(
    const uint8_t* rgba,
    int32_t src_w,
    int32_t src_h,
    float rotation_deg,
    int32_t target_aspect_preset,
    FsNormCropBox* out_crop_box,
    float* out_crop_conf,
    float* out_sal_cx,
    float* out_sal_cy) noexcept {
  *out_sal_cx = 0.5f;
  *out_sal_cy = 0.5f;
  *out_crop_conf = 0.5f;

  // Compute maximum valid crop dimensions inside inscribed space for the preset.
  int32_t dummy_w = 0;
  int32_t dummy_h = 0;
  FsNormCropBox full_box{0.0f, 0.0f, 1.0f, 1.0f};
  FsNormCropBox max_aspect_box{0.0f, 0.0f, 1.0f, 1.0f};
  clamp_crop_internal(
      src_w,
      src_h,
      rotation_deg,
      target_aspect_preset,
      full_box,
      &max_aspect_box,
      &dummy_w,
      &dummy_h);

  if (src_w < 4 || src_h < 4) {
    *out_crop_box = max_aspect_box;
    return;
  }

  const int32_t max_dim = std::max(src_w, src_h);
  const float scale =
      max_dim > 160 ? (160.0f / static_cast<float>(max_dim)) : 1.0f;
  const int32_t sw = std::max(4, static_cast<int32_t>(std::lround(src_w * scale)));
  const int32_t sh = std::max(4, static_cast<int32_t>(std::lround(src_h * scale)));

  const size_t n_px = static_cast<size_t>(sw) * sh;
  std::vector<float> lum(n_px, 0.0f);
  std::vector<float> cb(n_px, 128.0f);
  std::vector<float> cr(n_px, 128.0f);
  std::vector<float> skin(n_px, 0.0f);

  const float sx_step = static_cast<float>(src_w) / static_cast<float>(sw);
  const float sy_step = static_cast<float>(src_h) / static_cast<float>(sh);

  double border_y = 0.0;
  double border_cb = 0.0;
  double border_cr = 0.0;
  int32_t border_count = 0;

  for (int32_t y = 0; y < sh; ++y) {
    const int32_t py = std::clamp(
        static_cast<int32_t>((y + 0.5f) * sy_step), 0, src_h - 1);
    for (int32_t x = 0; x < sw; ++x) {
      const int32_t px = std::clamp(
          static_cast<int32_t>((x + 0.5f) * sx_step), 0, src_w - 1);
      const size_t src_idx = (static_cast<size_t>(py) * src_w + px) * 4u;
      const float r = static_cast<float>(rgba[src_idx + 0u]);
      const float g = static_cast<float>(rgba[src_idx + 1u]);
      const float b = static_cast<float>(rgba[src_idx + 2u]);

      const float y_val = 0.299f * r + 0.587f * g + 0.114f * b;
      const float cb_val = 128.0f - 0.168736f * r - 0.331264f * g + 0.5f * b;
      const float cr_val = 128.0f + 0.5f * r - 0.418688f * g - 0.081312f * b;

      const size_t idx = static_cast<size_t>(y) * sw + x;
      lum[idx] = y_val / 255.0f;
      cb[idx] = cb_val;
      cr[idx] = cr_val;

      // Soft YCbCr skin detector (Cb in [77, 127], Cr in [133, 173], Y > 40).
      float sk = 0.0f;
      if (y_val > 40.0f &&
          cb_val >= 72.0f && cb_val <= 132.0f &&
          cr_val >= 128.0f && cr_val <= 178.0f) {
        const float cb_dist =
            std::max(0.0f, std::abs(cb_val - 102.0f) - 20.0f) / 10.0f;
        const float cr_dist =
            std::max(0.0f, std::abs(cr_val - 153.0f) - 15.0f) / 10.0f;
        sk = std::clamp(1.0f - std::max(cb_dist, cr_dist), 0.0f, 1.0f);
      }
      skin[idx] = sk;

      if (x == 0 || x == sw - 1 || y == 0 || y == sh - 1) {
        border_y += y_val;
        border_cb += cb_val;
        border_cr += cr_val;
        ++border_count;
      }
    }
  }

  const float mean_by =
      border_count > 0 ? static_cast<float>(border_y / border_count) : 128.0f;
  const float mean_bcb =
      border_count > 0 ? static_cast<float>(border_cb / border_count) : 128.0f;
  const float mean_bcr =
      border_count > 0 ? static_cast<float>(border_cr / border_count) : 128.0f;

  std::vector<float> sal(n_px, 0.0f);
  double total_sal = 0.0;
  double sum_sal_x = 0.0;
  double sum_sal_y = 0.0;

  for (int32_t y = 0; y < sh; ++y) {
    const int32_t ym = std::max(0, y - 1);
    const int32_t yp = std::min(sh - 1, y + 1);
    for (int32_t x = 0; x < sw; ++x) {
      const int32_t xm = std::max(0, x - 1);
      const int32_t xp = std::min(sw - 1, x + 1);
      const size_t idx = static_cast<size_t>(y) * sw + x;

      const float gx = lum[static_cast<size_t>(y) * sw + xp] -
                       lum[static_cast<size_t>(y) * sw + xm];
      const float gy = lum[static_cast<size_t>(yp) * sw + x] -
                       lum[static_cast<size_t>(ym) * sw + x];
      const float sharp = std::clamp(std::sqrt(gx * gx + gy * gy) * 2.0f, 0.0f, 1.0f);

      const float dy = lum[idx] * 255.0f - mean_by;
      const float dcb = cb[idx] - mean_bcb;
      const float dcr = cr[idx] - mean_bcr;
      const float contrast =
          std::clamp(std::sqrt(dy * dy + dcb * dcb + dcr * dcr) / 140.0f, 0.0f, 1.0f);

      const float s_val =
          0.50f * sharp + 0.25f * contrast + 0.25f * skin[idx];
      sal[idx] = s_val;
      total_sal += static_cast<double>(s_val);
      sum_sal_x += static_cast<double>(s_val) *
                   ((static_cast<double>(x) + 0.5) / sw);
      sum_sal_y += static_cast<double>(s_val) *
                   ((static_cast<double>(y) + 0.5) / sh);
    }
  }

  if (total_sal <= 1e-6) {
    *out_crop_box = max_aspect_box;
    *out_crop_conf = 0.4f;
    return;
  }

  const float sal_cx = static_cast<float>(sum_sal_x / total_sal);
  const float sal_cy = static_cast<float>(sum_sal_y / total_sal);
  *out_sal_cx = std::clamp(sal_cx, 0.0f, 1.0f);
  *out_sal_cy = std::clamp(sal_cy, 0.0f, 1.0f);

  // Build 2D Integral Images (stride = sw + 1).
  const int32_t iw = sw + 1;
  const int32_t ih = sh + 1;
  std::vector<double> int_sal(static_cast<size_t>(iw) * ih, 0.0);
  std::vector<double> int_skin(static_cast<size_t>(iw) * ih, 0.0);

  for (int32_t y = 0; y < sh; ++y) {
    double row_sal = 0.0;
    double row_skin = 0.0;
    for (int32_t x = 0; x < sw; ++x) {
      const size_t s_idx = static_cast<size_t>(y) * sw + x;
      row_sal += static_cast<double>(sal[s_idx]);
      row_skin += static_cast<double>(skin[s_idx]);
      const size_t curr = static_cast<size_t>(y + 1) * iw + (x + 1);
      const size_t above = static_cast<size_t>(y) * iw + (x + 1);
      int_sal[curr] = int_sal[above] + row_sal;
      int_skin[curr] = int_skin[above] + row_skin;
    }
  }

  auto query_rect = [&](const std::vector<double>& integral,
                        double nx0,
                        double ny0,
                        double nx1,
                        double ny1) -> double {
    const int32_t x0 = std::clamp(static_cast<int32_t>(std::floor(nx0 * sw)), 0, sw);
    const int32_t y0 = std::clamp(static_cast<int32_t>(std::floor(ny0 * sh)), 0, sh);
    const int32_t x1 = std::clamp(static_cast<int32_t>(std::ceil(nx1 * sw)), 0, sw);
    const int32_t y1 = std::clamp(static_cast<int32_t>(std::ceil(ny1 * sh)), 0, sh);
    if (x1 <= x0 || y1 <= y0) return 0.0;
    return integral[static_cast<size_t>(y1) * iw + x1] -
           integral[static_cast<size_t>(y0) * iw + x1] -
           integral[static_cast<size_t>(y1) * iw + x0] +
           integral[static_cast<size_t>(y0) * iw + x0];
  };

  const InscribedFrame inscr =
      compute_inscribed_frame(src_w, src_h, rotation_deg);
  const double max_nw = max_aspect_box.right - max_aspect_box.left;
  const double max_nh = max_aspect_box.bottom - max_aspect_box.top;

  FsNormCropBox best_box = max_aspect_box;
  double best_score = -1e9;
  double best_sal_ratio = 0.0;

  constexpr std::array<double, 2> kScales = {1.0, 0.85};
  for (double box_scale : kScales) {
    const double nw = std::max(0.10, max_nw * box_scale);
    const double nh = std::max(0.10, max_nh * box_scale);
    if (nw > 1.0 + 1e-6 || nh > 1.0 + 1e-6) continue;

    for (int gy = 0; gy < 15; ++gy) {
      const double fy = static_cast<double>(gy) / 14.0;
      const double ny0 = fy * (1.0 - nh);
      const double ny1 = ny0 + nh;
      for (int gx = 0; gx < 15; ++gx) {
        const double fx = static_cast<double>(gx) / 14.0;
        const double nx0 = fx * (1.0 - nw);
        const double nx1 = nx0 + nw;

        // Map inscribed normalized box to source normalized bounds [0..1] for O(1) integral query.
        const double half_w_norm = (0.5 * nw * inscr.width_px) / src_w;
        const double half_h_norm = (0.5 * nh * inscr.height_px) / src_h;
        const double cx_inscr = (0.5 * (nx0 + nx1) - 0.5) * inscr.width_px;
        const double cy_inscr = (0.5 * (ny0 + ny1) - 0.5) * inscr.height_px;
        const double sx_c =
            0.5 + (cx_inscr * inscr.cos_t + cy_inscr * inscr.sin_t) / src_w;
        const double sy_c =
            0.5 + (-cx_inscr * inscr.sin_t + cy_inscr * inscr.cos_t) / src_h;

        const double src_x0 = std::clamp(sx_c - half_w_norm, 0.0, 1.0);
        const double src_y0 = std::clamp(sy_c - half_h_norm, 0.0, 1.0);
        const double src_x1 = std::clamp(sx_c + half_w_norm, 0.0, 1.0);
        const double src_y1 = std::clamp(sy_c + half_h_norm, 0.0, 1.0);

        const double box_sal =
            query_rect(int_sal, src_x0, src_y0, src_x1, src_y1);
        const double sal_inside = std::clamp(box_sal / total_sal, 0.0, 1.0);

        // Rule of Thirds alignment inside the candidate box.
        const double box_w_src = std::max(1e-6, src_x1 - src_x0);
        const double box_h_src = std::max(1e-6, src_y1 - src_y0);
        const double u_sal = std::clamp((sal_cx - src_x0) / box_w_src, 0.0, 1.0);
        const double v_sal = std::clamp((sal_cy - src_y0) / box_h_src, 0.0, 1.0);
        const double dx3 = std::min(std::abs(u_sal - 1.0 / 3.0),
                                    std::abs(u_sal - 2.0 / 3.0));
        const double dy3 = std::min(std::abs(v_sal - 1.0 / 3.0),
                                    std::abs(v_sal - 2.0 / 3.0));
        const double thirds_dist = std::sqrt(dx3 * dx3 + dy3 * dy3);
        const double thirds_score = std::clamp(1.0 - thirds_dist * 2.0, 0.0, 1.0);

        // Top 8% border cut penalty (penalizes slicing high skin/saliency at top edge).
        const double top_strip_y1 = src_y0 + 0.08 * box_h_src;
        const double top_sal =
            query_rect(int_sal, src_x0, src_y0, src_x1, top_strip_y1);
        const double top_skin =
            query_rect(int_skin, src_x0, src_y0, src_x1, top_strip_y1);
        const double box_skin =
            query_rect(int_skin, src_x0, src_y0, src_x1, src_y1);
        const double top_sal_ratio =
            top_sal / std::max(1e-6, 0.08 * box_sal);
        const double top_skin_ratio =
            box_skin > 1e-4 ? (top_skin / std::max(1e-6, 0.08 * box_skin)) : 0.0;
        const double cut_penalty = std::clamp(
            0.5 * std::max(0.0, top_sal_ratio - 1.0) +
                0.5 * std::max(0.0, top_skin_ratio - 1.0),
            0.0,
            1.0);

        const double score = 0.60 * sal_inside + 0.20 * thirds_score -
                             0.20 * cut_penalty + 0.01 * (nw * nh);

        if (score > best_score) {
          best_score = score;
          best_sal_ratio = sal_inside;
          best_box = FsNormCropBox{
              static_cast<float>(nx0),
              static_cast<float>(ny0),
              static_cast<float>(nx1),
              static_cast<float>(ny1),
          };
        }
      }
    }
  }

  clamp_crop_internal(
      src_w,
      src_h,
      rotation_deg,
      target_aspect_preset,
      best_box,
      out_crop_box,
      &dummy_w,
      &dummy_h);

  *out_crop_conf = static_cast<float>(
      std::clamp(0.45 + 0.50 * best_sal_ratio, 0.45, 0.96));
}

}  // namespace

extern "C" {

FS_API int32_t fs_geometry_clamp_crop(
    int32_t src_width,
    int32_t src_height,
    float rotation_deg,
    int32_t aspect_preset,
    const FsNormCropBox* requested_box,
    FsNormCropBox* out_clamped_box,
    int32_t* out_pixel_width,
    int32_t* out_pixel_height) {
  try {
    if (requested_box == nullptr ||
        out_clamped_box == nullptr ||
        out_pixel_width == nullptr ||
        out_pixel_height == nullptr) {
      return FS_ERR_NULL_POINTER;
    }
    return clamp_crop_internal(
        src_width,
        src_height,
        rotation_deg,
        aspect_preset,
        *requested_box,
        out_clamped_box,
        out_pixel_width,
        out_pixel_height);
  } catch (...) {
    return FS_ERR_ALLOC_FAILED;
  }
}

FS_API int32_t fs_geometry_analyze_rgba(
    const uint8_t* input_rgba,
    size_t input_len,
    int32_t width,
    int32_t height,
    int32_t target_aspect_preset,
    FsGeometryProposal* out_proposal) {
  try {
    if (input_rgba == nullptr || out_proposal == nullptr) {
      return FS_ERR_NULL_POINTER;
    }
    std::memset(out_proposal, 0, sizeof(FsGeometryProposal));
    if (!is_valid_aspect_preset(target_aspect_preset)) {
      return FS_ERR_INVALID_PARAMS;
    }

    size_t byte_len = 0;
    const int32_t dim_rc = validate_rgba_dimensions(width, height, &byte_len);
    if (dim_rc != FS_OK) {
      return dim_rc;
    }
    if (input_len < byte_len) {
      return FS_ERR_INVALID_DIMENSIONS;
    }

    float angle_deg = 0.0f;
    float horizon_conf = 0.0f;
    int32_t has_horizon = 0;
    estimate_horizon(
        input_rgba, width, height, &angle_deg, &horizon_conf, &has_horizon);

    FsNormCropBox crop_box{0.0f, 0.0f, 1.0f, 1.0f};
    float crop_conf = 0.0f;
    float sal_cx = 0.5f;
    float sal_cy = 0.5f;
    estimate_saliency_crop(
        input_rgba,
        width,
        height,
        angle_deg,
        target_aspect_preset,
        &crop_box,
        &crop_conf,
        &sal_cx,
        &sal_cy);

    out_proposal->suggested_rotation_deg = angle_deg;
    out_proposal->horizon_confidence = horizon_conf;
    out_proposal->suggested_crop_box = crop_box;
    out_proposal->crop_confidence = crop_conf;
    out_proposal->saliency_cx = sal_cx;
    out_proposal->saliency_cy = sal_cy;
    out_proposal->has_horizon_line = has_horizon;
    out_proposal->target_aspect_preset = target_aspect_preset;
    return FS_OK;
  } catch (...) {
    return FS_ERR_ALLOC_FAILED;
  }
}

FS_API int32_t fs_geometry_render_rgba_into(
    const uint8_t* input_rgba,
    size_t input_len,
    int32_t src_width,
    int32_t src_height,
    const FsGeometryParams* params,
    uint8_t* out_rgba,
    size_t out_len,
    int32_t out_width,
    int32_t out_height) {
  try {
    if (input_rgba == nullptr || params == nullptr || out_rgba == nullptr) {
      return FS_ERR_NULL_POINTER;
    }
    if (out_rgba == input_rgba) {
      return FS_ERR_INVALID_PARAMS;
    }

    size_t src_byte_len = 0;
    const int32_t src_rc =
        validate_rgba_dimensions(src_width, src_height, &src_byte_len);
    if (src_rc != FS_OK) {
      return src_rc;
    }
    size_t out_byte_len = 0;
    const int32_t out_rc =
        validate_rgba_dimensions(out_width, out_height, &out_byte_len);
    if (out_rc != FS_OK) {
      return out_rc;
    }
    if (input_len < src_byte_len || out_len < out_byte_len) {
      return FS_ERR_INVALID_DIMENSIONS;
    }

    // Reject overlapping buffers that alias input/output memory ranges.
    const uintptr_t in_begin = reinterpret_cast<uintptr_t>(input_rgba);
    const uintptr_t in_end = in_begin + src_byte_len;
    const uintptr_t out_begin = reinterpret_cast<uintptr_t>(out_rgba);
    const uintptr_t out_end = out_begin + out_byte_len;
    if (in_begin < out_end && out_begin < in_end) {
      return FS_ERR_INVALID_PARAMS;
    }

    FsNormCropBox clamped_box{};
    int32_t dummy_w = 0;
    int32_t dummy_h = 0;
    const int32_t clamp_rc = clamp_crop_internal(
        src_width,
        src_height,
        params->rotation_deg,
        params->aspect_preset,
        params->crop_box,
        &clamped_box,
        &dummy_w,
        &dummy_h);
    if (clamp_rc != FS_OK) {
      return clamp_rc;
    }

    const bool is_identity =
        std::abs(params->rotation_deg) < 1e-4f &&
        params->aspect_preset == FS_ASPECT_ORIGINAL &&
        out_width == src_width &&
        out_height == src_height &&
        std::abs(clamped_box.left) < 1e-5f &&
        std::abs(clamped_box.top) < 1e-5f &&
        std::abs(clamped_box.right - 1.0f) < 1e-5f &&
        std::abs(clamped_box.bottom - 1.0f) < 1e-5f;
    if (is_identity) {
      std::memcpy(out_rgba, input_rgba, out_byte_len);
      return FS_OK;
    }

    const InscribedFrame inscr =
        compute_inscribed_frame(src_width, src_height, params->rotation_deg);
    const float cos_t = static_cast<float>(inscr.cos_t);
    const float sin_t = static_cast<float>(inscr.sin_t);
    const float w_inscr = static_cast<float>(inscr.width_px);
    const float h_inscr = static_cast<float>(inscr.height_px);

    const float box_l = clamped_box.left;
    const float box_t = clamped_box.top;
    const float box_w = clamped_box.right - clamped_box.left;
    const float box_h = clamped_box.bottom - clamped_box.top;

    const float src_cx = 0.5f * static_cast<float>(src_width - 1);
    const float src_cy = 0.5f * static_cast<float>(src_height - 1);
    const float inv_out_w = 1.0f / static_cast<float>(out_width);
    const float inv_out_h = 1.0f / static_cast<float>(out_height);
    const bool use_catmull = (params->high_quality != 0);

    for (int32_t oy = 0; oy < out_height; ++oy) {
      const float v = (static_cast<float>(oy) + 0.5f) * inv_out_h;
      const float ny = box_t + v * box_h;
      const float ry = (ny - 0.5f) * h_inscr;
      const size_t row_off = static_cast<size_t>(oy) * out_width;

      for (int32_t ox = 0; ox < out_width; ++ox) {
        const float u = (static_cast<float>(ox) + 0.5f) * inv_out_w;
        const float nx = box_l + u * box_w;
        const float rx = (nx - 0.5f) * w_inscr;

        const float sx = src_cx + (rx * cos_t + ry * sin_t);
        const float sy = src_cy + (-rx * sin_t + ry * cos_t);

        uint8_t* dst_px = out_rgba + (row_off + static_cast<size_t>(ox)) * 4u;
        if (use_catmull) {
          sample_catmull_rom(input_rgba, src_width, src_height, sx, sy, dst_px);
        } else {
          sample_bilinear(input_rgba, src_width, src_height, sx, sy, dst_px);
        }
      }
    }

    return FS_OK;
  } catch (...) {
    return FS_ERR_ALLOC_FAILED;
  }
}

}  // extern "C"
