#include "fujistudio_c_api.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
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

bool ranges_overlap(
    const uint8_t* a,
    size_t a_len,
    const uint8_t* b,
    size_t b_len) noexcept {
  const auto a_addr = reinterpret_cast<std::uintptr_t>(a);
  const auto b_addr = reinterpret_cast<std::uintptr_t>(b);
  if (a_addr == b_addr) {
    return true;
  }
  if (a_addr < b_addr) {
    return (b_addr - a_addr) < static_cast<std::uintptr_t>(a_len);
  }
  return (a_addr - b_addr) < static_cast<std::uintptr_t>(b_len);
}

inline double sinc(double x) noexcept {
  const double ax = std::abs(x);
  if (ax < 1e-7) {
    return 1.0;
  }
  const double pix = kPi * x;
  return std::sin(pix) / pix;
}

inline double lanczos3_kernel(double x) noexcept {
  const double ax = std::abs(x);
  if (ax >= 3.0) {
    return 0.0;
  }
  return sinc(x) * sinc(x / 3.0);
}

struct AxisTap {
  int32_t start;
  int32_t count;
  size_t  weight_offset;
};

struct AxisKernelPlan {
  std::vector<AxisTap> taps;
  std::vector<float>   weights;
};

AxisKernelPlan build_lanczos3_axis_plan(int32_t src_len, int32_t dst_len) {
  AxisKernelPlan plan;
  plan.taps.resize(static_cast<size_t>(dst_len));

  const double ratio =
      static_cast<double>(src_len) / static_cast<double>(dst_len);
  const double scale = std::max(1.0, ratio);
  const double support = 3.0 * scale;

  std::vector<double> tmp_weights;
  tmp_weights.reserve(static_cast<size_t>(std::ceil(2.0 * support)) + 4u);

  for (int32_t d = 0; d < dst_len; ++d) {
    const double src_center = (static_cast<double>(d) + 0.5) * ratio - 0.5;
    int32_t start = static_cast<int32_t>(std::floor(src_center - support));
    int32_t end = static_cast<int32_t>(std::ceil(src_center + support));

    start = std::max<int32_t>(0, start);
    end = std::min<int32_t>(src_len - 1, end);

    tmp_weights.clear();
    double sum_w = 0.0;
    for (int32_t s = start; s <= end; ++s) {
      const double dist = (static_cast<double>(s) - src_center) / scale;
      const double w = lanczos3_kernel(dist);
      tmp_weights.push_back(w);
      sum_w += w;
    }

    const size_t offset = plan.weights.size();
    if (tmp_weights.empty() || std::abs(sum_w) <= 1e-12) {
      const int32_t nearest = std::clamp(
          static_cast<int32_t>(std::lround(src_center)),
          0,
          src_len - 1);
      plan.taps[static_cast<size_t>(d)] = AxisTap{nearest, 1, offset};
      plan.weights.push_back(1.0f);
    } else {
      const double inv_sum = 1.0 / sum_w;
      const int32_t count = static_cast<int32_t>(tmp_weights.size());
      plan.taps[static_cast<size_t>(d)] = AxisTap{start, count, offset};
      for (double w : tmp_weights) {
        plan.weights.push_back(static_cast<float>(w * inv_sum));
      }
      // Enforce exact float weight sum = 1.0f on the central tap to avoid
      // ULP drift on flat-color inputs.
      float float_sum = 0.0f;
      for (int32_t k = 0; k < count; ++k) {
        float_sum += plan.weights[offset + static_cast<size_t>(k)];
      }
      plan.weights[offset + static_cast<size_t>(count / 2)] += (1.0f - float_sum);
    }
  }

  return plan;
}

inline uint8_t clamp_float_to_u8(float val) noexcept {
  return static_cast<uint8_t>(std::clamp(val + 0.5f, 0.0f, 255.0f));
}

std::vector<float> build_gaussian_1d_kernel(float sigma) {
  const int32_t radius = std::max(1, static_cast<int32_t>(std::ceil(2.5f * sigma)));
  const int32_t size = 2 * radius + 1;
  std::vector<float> kernel(static_cast<size_t>(size));
  const double denom = 2.0 * static_cast<double>(sigma) * static_cast<double>(sigma);
  double sum = 0.0;
  for (int32_t i = -radius; i <= radius; ++i) {
    const double d = static_cast<double>(i);
    const double w = std::exp(-(d * d) / denom);
    kernel[static_cast<size_t>(i + radius)] = static_cast<float>(w);
    sum += w;
  }
  const float inv_sum = static_cast<float>(1.0 / sum);
  for (float& w : kernel) {
    w *= inv_sum;
  }
  return kernel;
}

}  // namespace

extern "C" {

FS_API int32_t fs_export_lanczos3_resize_rgba_into(
    const uint8_t* input_rgba,
    size_t input_len,
    int32_t src_width,
    int32_t src_height,
    uint8_t* out_rgba,
    size_t out_len,
    int32_t out_width,
    int32_t out_height) {
  try {
    if (input_rgba == nullptr || out_rgba == nullptr) {
      return FS_ERR_NULL_POINTER;
    }

    size_t expected_in_bytes = 0;
    const int32_t in_dim_rc =
        validate_rgba_dimensions(src_width, src_height, &expected_in_bytes);
    if (in_dim_rc != FS_OK) {
      return in_dim_rc;
    }

    size_t expected_out_bytes = 0;
    const int32_t out_dim_rc =
        validate_rgba_dimensions(out_width, out_height, &expected_out_bytes);
    if (out_dim_rc != FS_OK) {
      return out_dim_rc;
    }

    if (input_len < expected_in_bytes || out_len < expected_out_bytes) {
      return FS_ERR_INVALID_DIMENSIONS;
    }

    if (ranges_overlap(input_rgba, expected_in_bytes, out_rgba, expected_out_bytes)) {
      return FS_ERR_INVALID_PARAMS;
    }

    if (out_width == src_width && out_height == src_height) {
      std::memcpy(out_rgba, input_rgba, expected_in_bytes);
      return FS_OK;
    }

    const AxisKernelPlan x_plan = build_lanczos3_axis_plan(src_width, out_width);
    const AxisKernelPlan y_plan = build_lanczos3_axis_plan(src_height, out_height);

    // Intermediate float buffer: out_width x src_height x 4
    const size_t tmp_floats =
        static_cast<size_t>(out_width) * static_cast<size_t>(src_height) * 4u;
    std::vector<float> tmp(tmp_floats);

    // Pass 1: Horizontal filter (src_width x src_height -> out_width x src_height)
    for (int32_t y = 0; y < src_height; ++y) {
      const uint8_t* src_row =
          input_rgba + static_cast<size_t>(y) * static_cast<size_t>(src_width) * 4u;
      float* dst_row =
          tmp.data() + static_cast<size_t>(y) * static_cast<size_t>(out_width) * 4u;

      for (int32_t dx = 0; dx < out_width; ++dx) {
        const AxisTap& tap = x_plan.taps[static_cast<size_t>(dx)];
        const float* w_ptr = x_plan.weights.data() + tap.weight_offset;

        float acc_r = 0.0f;
        float acc_g = 0.0f;
        float acc_b = 0.0f;
        float acc_a = 0.0f;
        for (int32_t k = 0; k < tap.count; ++k) {
          const float w = w_ptr[k];
          const size_t s_off = static_cast<size_t>(tap.start + k) * 4u;
          acc_r += w * static_cast<float>(src_row[s_off + 0u]);
          acc_g += w * static_cast<float>(src_row[s_off + 1u]);
          acc_b += w * static_cast<float>(src_row[s_off + 2u]);
          acc_a += w * static_cast<float>(src_row[s_off + 3u]);
        }

        const size_t d_off = static_cast<size_t>(dx) * 4u;
        dst_row[d_off + 0u] = acc_r;
        dst_row[d_off + 1u] = acc_g;
        dst_row[d_off + 2u] = acc_b;
        dst_row[d_off + 3u] = acc_a;
      }
    }

    // Pass 2: Vertical filter (out_width x src_height -> out_width x out_height)
    const size_t row_stride = static_cast<size_t>(out_width) * 4u;
    for (int32_t dy = 0; dy < out_height; ++dy) {
      const AxisTap& tap = y_plan.taps[static_cast<size_t>(dy)];
      const float* w_ptr = y_plan.weights.data() + tap.weight_offset;
      uint8_t* dst_row = out_rgba + static_cast<size_t>(dy) * row_stride;

      for (int32_t dx = 0; dx < out_width; ++dx) {
        const size_t col_off = static_cast<size_t>(dx) * 4u;
        float acc_r = 0.0f;
        float acc_g = 0.0f;
        float acc_b = 0.0f;
        float acc_a = 0.0f;

        for (int32_t k = 0; k < tap.count; ++k) {
          const float w = w_ptr[k];
          const float* s_px =
              tmp.data() + static_cast<size_t>(tap.start + k) * row_stride + col_off;
          acc_r += w * s_px[0];
          acc_g += w * s_px[1];
          acc_b += w * s_px[2];
          acc_a += w * s_px[3];
        }

        dst_row[col_off + 0u] = clamp_float_to_u8(acc_r);
        dst_row[col_off + 1u] = clamp_float_to_u8(acc_g);
        dst_row[col_off + 2u] = clamp_float_to_u8(acc_b);
        dst_row[col_off + 3u] = clamp_float_to_u8(acc_a);
      }
    }

    return FS_OK;
  } catch (const std::bad_alloc&) {
    return FS_ERR_ALLOC_FAILED;
  } catch (...) {
    return FS_ERR_INVALID_PARAMS;
  }
}

FS_API int32_t fs_export_output_usm_rgba_into(
    const uint8_t* input_rgba,
    size_t input_len,
    int32_t width,
    int32_t height,
    const FsOutputUsmParams* params,
    uint8_t* out_rgba,
    size_t out_len) {
  try {
    if (input_rgba == nullptr || params == nullptr || out_rgba == nullptr) {
      return FS_ERR_NULL_POINTER;
    }

    size_t expected_bytes = 0;
    const int32_t dim_rc =
        validate_rgba_dimensions(width, height, &expected_bytes);
    if (dim_rc != FS_OK) {
      return dim_rc;
    }

    if (input_len < expected_bytes || out_len < expected_bytes) {
      return FS_ERR_INVALID_DIMENSIONS;
    }

    if (out_rgba != input_rgba &&
        ranges_overlap(input_rgba, expected_bytes, out_rgba, expected_bytes)) {
      return FS_ERR_INVALID_PARAMS;
    }

    if (!std::isfinite(params->amount) ||
        !std::isfinite(params->radius) ||
        !std::isfinite(params->threshold) ||
        !std::isfinite(params->halo_clamp)) {
      return FS_ERR_INVALID_PARAMS;
    }

    if (params->enabled == 0 || params->amount <= 0.0f) {
      if (out_rgba != input_rgba) {
        std::memcpy(out_rgba, input_rgba, expected_bytes);
      }
      return FS_OK;
    }

    const float amount = std::clamp(params->amount, 0.0f, 1.5f);
    const float radius = std::clamp(params->radius, 0.5f, 2.0f);
    const float threshold = std::clamp(params->threshold, 0.0f, 20.0f);
    const float halo_clamp = std::clamp(params->halo_clamp, 0.0f, 40.0f);

    const std::vector<float> kernel = build_gaussian_1d_kernel(radius);
    const int32_t k_rad = static_cast<int32_t>(kernel.size() - 1u) / 2;
    const int32_t win_rows = 2 * k_rad + 1;
    const size_t w_sz = static_cast<size_t>(width);

    // Rolling ring-buffer over horizontally-blurred luma rows:
    // allocates ~11 rows instead of 3 full-frame float planes (~637 MB at 40MP).
    std::vector<float> row_luma(w_sz);
    std::vector<float> ring_hblur(static_cast<size_t>(win_rows) * w_sz);

    auto fill_hblur_row = [&](int32_t r) {
      const uint8_t* src_row =
          input_rgba + static_cast<size_t>(r) * w_sz * 4u;
      for (int32_t x = 0; x < width; ++x) {
        const size_t i = static_cast<size_t>(x) * 4u;
        const float pr = static_cast<float>(src_row[i + 0u]);
        const float pg = static_cast<float>(src_row[i + 1u]);
        const float pb = static_cast<float>(src_row[i + 2u]);
        row_luma[static_cast<size_t>(x)] =
            0.2126f * pr + 0.7152f * pg + 0.0722f * pb;
      }

      float* dst_ring =
          ring_hblur.data() + static_cast<size_t>(r % win_rows) * w_sz;
      for (int32_t x = 0; x < width; ++x) {
        float acc = 0.0f;
        for (int32_t k = -k_rad; k <= k_rad; ++k) {
          const int32_t sx = std::clamp(x + k, 0, width - 1);
          acc += kernel[static_cast<size_t>(k + k_rad)] *
                 row_luma[static_cast<size_t>(sx)];
        }
        dst_ring[static_cast<size_t>(x)] = acc;
      }
    };

    // Pre-fill rows [0 .. min(height - 1, k_rad)] before writing any output.
    const int32_t prefill_end = std::min(height - 1, k_rad);
    for (int32_t r = 0; r <= prefill_end; ++r) {
      fill_hblur_row(r);
    }

    // Process row y: read-ahead row (y + k_rad) from unmodified input_rgba
    // BEFORE overwriting row y in-place.
    for (int32_t y = 0; y < height; ++y) {
      if (y > 0 && y + k_rad < height) {
        fill_hblur_row(y + k_rad);
      }

      const size_t row_byte_off = static_cast<size_t>(y) * w_sz * 4u;
      const uint8_t* in_row = input_rgba + row_byte_off;
      uint8_t* out_row = out_rgba + row_byte_off;

      for (int32_t x = 0; x < width; ++x) {
        float y_blur = 0.0f;
        for (int32_t dy = -k_rad; dy <= k_rad; ++dy) {
          const int32_t sy = std::clamp(y + dy, 0, height - 1);
          y_blur += kernel[static_cast<size_t>(dy + k_rad)] *
                    ring_hblur[static_cast<size_t>(sy % win_rows) * w_sz +
                               static_cast<size_t>(x)];
        }

        const size_t i = static_cast<size_t>(x) * 4u;
        const uint8_t in_r = in_row[i + 0u];
        const uint8_t in_g = in_row[i + 1u];
        const uint8_t in_b = in_row[i + 2u];
        const uint8_t in_a = in_row[i + 3u];

        const float y_orig =
            0.2126f * static_cast<float>(in_r) +
            0.7152f * static_cast<float>(in_g) +
            0.0722f * static_cast<float>(in_b);
        const float diff = y_orig - y_blur;
        const float abs_diff = std::abs(diff);

        float delta = 0.0f;
        if (abs_diff > threshold) {
          const float eff_diff = std::copysign(abs_diff - threshold, diff);
          const float raw_delta = amount * eff_diff;
          delta = std::clamp(raw_delta, -halo_clamp, halo_clamp);
        }

        const float taper = std::clamp(
            std::min(y_orig / 16.0f, (255.0f - y_orig) / 16.0f),
            0.0f,
            1.0f);
        const float final_delta = delta * taper;

        out_row[i + 0u] = clamp_float_to_u8(static_cast<float>(in_r) + final_delta);
        out_row[i + 1u] = clamp_float_to_u8(static_cast<float>(in_g) + final_delta);
        out_row[i + 2u] = clamp_float_to_u8(static_cast<float>(in_b) + final_delta);
        out_row[i + 3u] = in_a;
      }
    }

    return FS_OK;
  } catch (const std::bad_alloc&) {
    return FS_ERR_ALLOC_FAILED;
  } catch (...) {
    return FS_ERR_INVALID_PARAMS;
  }
}

}  // extern "C"
