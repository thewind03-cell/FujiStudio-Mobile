#include "fujistudio_c_api.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>

#if defined(__aarch64__) || defined(_M_ARM64)
  #include <arm_neon.h>
  #define FS_HAS_ARM64_NEON 1
#else
  #define FS_HAS_ARM64_NEON 0
#endif

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

inline uint8_t float_to_u8(float val) noexcept {
  const float clamped = std::clamp(val, 0.0f, 1.0f);
  return static_cast<uint8_t>(clamped * 255.0f + 0.5f);
}

void apply_dna_rescue_scalar_range(
    const uint8_t* input_rgba,
    uint8_t* out_rgba,
    size_t start_pixel,
    size_t pixel_count,
    float s,
    float a,
    float h,
    float c_max,
    float skin_protect) noexcept {
  constexpr float kInv255 = 1.0f / 255.0f;
  constexpr float kInvCbRadius = 1.0f / 0.11f;
  constexpr float kInvCrRadius = 1.0f / 0.09f;
  const float h_lo = std::max(a, h - 0.15f);
  const float h_span = h - h_lo;

  for (size_t idx = start_pixel; idx < start_pixel + pixel_count; ++idx) {
    const size_t i = idx * 4u;
    const uint8_t in_r = input_rgba[i + 0u];
    const uint8_t in_g = input_rgba[i + 1u];
    const uint8_t in_b = input_rgba[i + 2u];
    const uint8_t in_a = input_rgba[i + 3u];

    const float r = static_cast<float>(in_r) * kInv255;
    const float g = static_cast<float>(in_g) * kInv255;
    const float b = static_cast<float>(in_b) * kInv255;

    const float y = 0.2126f * r + 0.7152f * g + 0.0722f * b;
    const float v = std::max(r, std::max(g, b));
    const float y_eff = 0.65f * y + 0.35f * v;

    if (y_eff >= a || y_eff <= 0.0f) {
      if (out_rgba != input_rgba) {
        out_rgba[i + 0u] = in_r;
        out_rgba[i + 1u] = in_g;
        out_rgba[i + 2u] = in_b;
        out_rgba[i + 3u] = in_a;
      }
      continue;
    }

    const float t = y_eff / a;
    const float t2 = t * t;
    const float toe = t2 / (t2 + 0.06f);
    const float one_minus_t = 1.0f - t;
    const float one_minus_t2 = one_minus_t * one_minus_t;
    const float delta =
        a * c_max * s * toe * one_minus_t2 * one_minus_t2;

    float guard = 1.0f;
    if (v >= h) {
      guard = 0.0f;
    } else if (v > h_lo && h_span > 1e-6f) {
      const float u = (h - v) / h_span;
      guard = u * u * (3.0f - 2.0f * u);
    }

    const float delta_safe = delta * guard;
    const float raw_gain = (y_eff + delta_safe) / std::max(y_eff, 1e-6f);
    const float max_non_clip_gain = 1.0f / std::max(v, 1e-6f);
    const float gain = std::min(raw_gain, max_non_clip_gain);

    const float y_out = std::clamp(y * gain, 0.0f, 1.0f);
    const float gain_clamped = std::max(gain, 1.0f);
    const float damp_factor = std::clamp(1.0f - 1.0f / gain_clamped, 0.0f, 1.0f);

    // Smooth YCbCr skin-locus chroma protection modulated by skin_protect [0..1].
    const float cb = -0.168736f * r - 0.331264f * g + 0.500000f * b + 0.5f;
    const float cr =  0.500000f * r - 0.418688f * g - 0.081312f * b + 0.5f;
    const float d_cb = (cb - 0.43f) * kInvCbRadius;
    const float d_cr = (cr - 0.58f) * kInvCrRadius;
    const float dist2 = d_cb * d_cb + d_cr * d_cr;
    const float skin_t = std::clamp(1.0f - dist2, 0.0f, 1.0f);
    const float skin_weight = skin_t * skin_t * (3.0f - 2.0f * skin_t);
    const float chroma_damp =
        1.0f - (0.03f + 0.22f * skin_protect * skin_weight) * damp_factor;

    const float r_out =
        std::clamp(y_out + (r * gain - y_out) * chroma_damp, 0.0f, 1.0f);
    const float g_out =
        std::clamp(y_out + (g * gain - y_out) * chroma_damp, 0.0f, 1.0f);
    const float b_out =
        std::clamp(y_out + (b * gain - y_out) * chroma_damp, 0.0f, 1.0f);

    out_rgba[i + 0u] = float_to_u8(r_out);
    out_rgba[i + 1u] = float_to_u8(g_out);
    out_rgba[i + 2u] = float_to_u8(b_out);
    out_rgba[i + 3u] = in_a;
  }
}

#if FS_HAS_ARM64_NEON
inline void neon_process_4_pixels(
    uint16x4_t r16,
    uint16x4_t g16,
    uint16x4_t b16,
    float s,
    float a,
    float h,
    float c_max,
    float skin_protect,
    uint16x4_t* out_r16,
    uint16x4_t* out_g16,
    uint16x4_t* out_b16) noexcept {
  const float32x4_t v_zero = vdupq_n_f32(0.0f);
  const float32x4_t v_one = vdupq_n_f32(1.0f);
  const float32x4_t v_255 = vdupq_n_f32(255.0f);
  const float32x4_t v_inv255 = vdupq_n_f32(1.0f / 255.0f);
  const float32x4_t v_half = vdupq_n_f32(0.5f);
  const float32x4_t v_eps = vdupq_n_f32(1e-6f);

  const uint32x4_t r_u32_orig = vmovl_u16(r16);
  const uint32x4_t g_u32_orig = vmovl_u16(g16);
  const uint32x4_t b_u32_orig = vmovl_u16(b16);

  const float32x4_t r = vmulq_f32(vcvtq_f32_u32(r_u32_orig), v_inv255);
  const float32x4_t g = vmulq_f32(vcvtq_f32_u32(g_u32_orig), v_inv255);
  const float32x4_t b = vmulq_f32(vcvtq_f32_u32(b_u32_orig), v_inv255);

  const float32x4_t y = vfmaq_f32(
      vfmaq_f32(vmulq_f32(vdupq_n_f32(0.2126f), r), vdupq_n_f32(0.7152f), g),
      vdupq_n_f32(0.0722f),
      b);
  const float32x4_t v = vmaxq_f32(r, vmaxq_f32(g, b));
  const float32x4_t y_eff =
      vfmaq_f32(vmulq_f32(vdupq_n_f32(0.65f), y), vdupq_n_f32(0.35f), v);

  const float32x4_t v_a = vdupq_n_f32(a);
  const uint32x4_t active_mask =
      vandq_u32(vcgtq_f32(y_eff, v_zero), vcltq_f32(y_eff, v_a));

  const float32x4_t t = vdivq_f32(y_eff, v_a);
  const float32x4_t t2 = vmulq_f32(t, t);
  const float32x4_t toe = vdivq_f32(t2, vaddq_f32(t2, vdupq_n_f32(0.06f)));
  const float32x4_t one_minus_t = vsubq_f32(v_one, t);
  const float32x4_t omt2 = vmulq_f32(one_minus_t, one_minus_t);
  const float32x4_t omt4 = vmulq_f32(omt2, omt2);
  const float32x4_t delta =
      vmulq_f32(vdupq_n_f32(a * c_max * s), vmulq_f32(toe, omt4));

  const float h_lo = std::max(a, h - 0.15f);
  const float h_span = std::max(h - h_lo, 1e-6f);
  const float32x4_t v_h = vdupq_n_f32(h);
  const float32x4_t v_h_lo = vdupq_n_f32(h_lo);
  const float32x4_t u_raw =
      vdivq_f32(vsubq_f32(v_h, v), vdupq_n_f32(h_span));
  const float32x4_t u = vminq_f32(v_one, vmaxq_f32(v_zero, u_raw));
  const float32x4_t smooth = vmulq_f32(
      vmulq_f32(u, u),
      vsubq_f32(vdupq_n_f32(3.0f), vmulq_f32(vdupq_n_f32(2.0f), u)));
  const uint32x4_t le_lo = vcleq_f32(v, v_h_lo);
  const uint32x4_t ge_hi = vcgeq_f32(v, v_h);
  const float32x4_t guard = vbslq_f32(
      ge_hi,
      v_zero,
      vbslq_f32(le_lo, v_one, smooth));

  const float32x4_t delta_safe = vmulq_f32(delta, guard);
  const float32x4_t raw_gain =
      vdivq_f32(vaddq_f32(y_eff, delta_safe), vmaxq_f32(y_eff, v_eps));
  const float32x4_t max_non_clip = vdivq_f32(v_one, vmaxq_f32(v, v_eps));
  const float32x4_t gain = vminq_f32(raw_gain, max_non_clip);

  const float32x4_t y_out =
      vminq_f32(v_one, vmaxq_f32(v_zero, vmulq_f32(y, gain)));
  const float32x4_t gain_clamped = vmaxq_f32(gain, v_one);
  const float32x4_t damp_factor = vminq_f32(
      v_one,
      vmaxq_f32(v_zero, vsubq_f32(v_one, vdivq_f32(v_one, gain_clamped))));

  const float32x4_t cb = vfmaq_f32(
      vfmaq_f32(
          vfmaq_f32(v_half, vdupq_n_f32(-0.168736f), r),
          vdupq_n_f32(-0.331264f),
          g),
      vdupq_n_f32(0.500000f),
      b);
  const float32x4_t cr = vfmaq_f32(
      vfmaq_f32(
          vfmaq_f32(v_half, vdupq_n_f32(0.500000f), r),
          vdupq_n_f32(-0.418688f),
          g),
      vdupq_n_f32(-0.081312f),
      b);
  const float32x4_t d_cb =
      vmulq_f32(vsubq_f32(cb, vdupq_n_f32(0.43f)), vdupq_n_f32(1.0f / 0.11f));
  const float32x4_t d_cr =
      vmulq_f32(vsubq_f32(cr, vdupq_n_f32(0.58f)), vdupq_n_f32(1.0f / 0.09f));
  const float32x4_t dist2 = vfmaq_f32(vmulq_f32(d_cb, d_cb), d_cr, d_cr);
  const float32x4_t skin_t =
      vminq_f32(v_one, vmaxq_f32(v_zero, vsubq_f32(v_one, dist2)));
  const float32x4_t skin_weight = vmulq_f32(
      vmulq_f32(skin_t, skin_t),
      vsubq_f32(vdupq_n_f32(3.0f), vmulq_f32(vdupq_n_f32(2.0f), skin_t)));
  const float32x4_t total_damp_coeff = vfmaq_f32(
      vdupq_n_f32(0.03f),
      vdupq_n_f32(0.22f * skin_protect),
      skin_weight);
  const float32x4_t chroma_damp =
      vsubq_f32(v_one, vmulq_f32(total_damp_coeff, damp_factor));

  auto finish_chan = [&](float32x4_t c, uint32x4_t orig_u32) -> uint16x4_t {
    const float32x4_t lifted = vmulq_f32(c, gain);
    const float32x4_t damped =
        vfmaq_f32(y_out, vsubq_f32(lifted, y_out), chroma_damp);
    const float32x4_t clamped = vminq_f32(v_one, vmaxq_f32(v_zero, damped));
    const uint32x4_t proc_u32 =
        vcvtq_u32_f32(vfmaq_f32(v_half, clamped, v_255));
    const uint32x4_t selected = vbslq_u32(active_mask, proc_u32, orig_u32);
    return vqmovn_u32(selected);
  };

  *out_r16 = finish_chan(r, r_u32_orig);
  *out_g16 = finish_chan(g, g_u32_orig);
  *out_b16 = finish_chan(b, b_u32_orig);
}

void apply_dna_rescue_neon(
    const uint8_t* input_rgba,
    uint8_t* out_rgba,
    size_t pixel_count,
    float s,
    float a,
    float h,
    float c_max,
    float skin_protect) noexcept {
  const size_t vec_pixels = (pixel_count / 8u) * 8u;
  for (size_t idx = 0; idx < vec_pixels; idx += 8u) {
    const size_t byte_off = idx * 4u;
    const uint8x8x4_t px = vld4_u8(input_rgba + byte_off);

    const uint16x8_t r16 = vmovl_u8(px.val[0]);
    const uint16x8_t g16 = vmovl_u8(px.val[1]);
    const uint16x8_t b16 = vmovl_u8(px.val[2]);

    uint16x4_t r_lo, g_lo, b_lo;
    uint16x4_t r_hi, g_hi, b_hi;

    neon_process_4_pixels(
        vget_low_u16(r16),
        vget_low_u16(g16),
        vget_low_u16(b16),
        s,
        a,
        h,
        c_max,
        skin_protect,
        &r_lo,
        &g_lo,
        &b_lo);
    neon_process_4_pixels(
        vget_high_u16(r16),
        vget_high_u16(g16),
        vget_high_u16(b16),
        s,
        a,
        h,
        c_max,
        skin_protect,
        &r_hi,
        &g_hi,
        &b_hi);

    uint8x8x4_t out_px;
    out_px.val[0] = vqmovn_u16(vcombine_u16(r_lo, r_hi));
    out_px.val[1] = vqmovn_u16(vcombine_u16(g_lo, g_hi));
    out_px.val[2] = vqmovn_u16(vcombine_u16(b_lo, b_hi));
    out_px.val[3] = px.val[3];
    vst4_u8(out_rgba + byte_off, out_px);
  }

  if (vec_pixels < pixel_count) {
    apply_dna_rescue_scalar_range(
        input_rgba,
        out_rgba,
        vec_pixels,
        pixel_count - vec_pixels,
        s,
        a,
        h,
        c_max,
        skin_protect);
  }
}
#endif

}  // namespace

extern "C" {

FS_API int32_t fs_dna_rescue_apply_rgba_into(
    const uint8_t* input_rgba,
    size_t input_len,
    int32_t width,
    int32_t height,
    const FsDnaRescueParams* params,
    uint8_t* out_rgba,
    size_t out_len) {
  try {
    if (input_rgba == nullptr || params == nullptr || out_rgba == nullptr) {
      return FS_ERR_NULL_POINTER;
    }

    size_t byte_len = 0;
    const int32_t dim_rc = validate_rgba_dimensions(width, height, &byte_len);
    if (dim_rc != FS_OK) {
      return dim_rc;
    }
    if (input_len < byte_len || out_len < byte_len) {
      return FS_ERR_INVALID_DIMENSIONS;
    }

    if (!std::isfinite(params->shadow_lift) ||
        !std::isfinite(params->midtone_anchor) ||
        !std::isfinite(params->highlight_protect) ||
        !std::isfinite(params->skin_protect)) {
      return FS_ERR_INVALID_PARAMS;
    }
    if (params->mode != FS_DNA_MODE_SOOC_SAFE &&
        params->mode != FS_DNA_MODE_DEEP_RESCUE) {
      return FS_ERR_INVALID_PARAMS;
    }

    const float s = std::clamp(params->shadow_lift, 0.0f, 1.0f);
    const float a = std::clamp(params->midtone_anchor, 0.35f, 0.75f);
    const float h = std::clamp(params->highlight_protect, 0.75f, 0.98f);
    const float skin_protect = std::clamp(params->skin_protect, 0.0f, 1.0f);

    if (params->enabled == 0 || s <= 0.0f) {
      if (out_rgba != input_rgba) {
        std::memcpy(out_rgba, input_rgba, byte_len);
      }
      return FS_OK;
    }

    const float c_max =
        (params->mode == FS_DNA_MODE_DEEP_RESCUE) ? 1.05f : 0.85f;
    const size_t pixel_count = byte_len / 4u;

#if FS_HAS_ARM64_NEON
    apply_dna_rescue_neon(
        input_rgba, out_rgba, pixel_count, s, a, h, c_max, skin_protect);
#else
    apply_dna_rescue_scalar_range(
        input_rgba,
        out_rgba,
        0u,
        pixel_count,
        s,
        a,
        h,
        c_max,
        skin_protect);
#endif
    return FS_OK;
  } catch (...) {
    return FS_ERR_ALLOC_FAILED;
  }
}

FS_API int32_t fs_dna_rescue_analyze_rgba(
    const uint8_t* input_rgba,
    size_t input_len,
    int32_t width,
    int32_t height,
    FsDnaRescueSuggestion* out_suggestion) {
  try {
    if (input_rgba == nullptr || out_suggestion == nullptr) {
      return FS_ERR_NULL_POINTER;
    }
    std::memset(out_suggestion, 0, sizeof(FsDnaRescueSuggestion));
    out_suggestion->recommended_mode = FS_DNA_MODE_SOOC_SAFE;

    size_t byte_len = 0;
    const int32_t dim_rc = validate_rgba_dimensions(width, height, &byte_len);
    if (dim_rc != FS_OK) {
      return dim_rc;
    }
    if (input_len < byte_len) {
      return FS_ERR_INVALID_DIMENSIONS;
    }

    const size_t pixel_count = byte_len / 4u;
    const size_t stride = (pixel_count > 262144u) ? 2u : 1u;

    std::array<uint32_t, 256> hist{};
    uint64_t sampled_count = 0;
    uint64_t shadow_count = 0;

    for (size_t idx = 0; idx < pixel_count; idx += stride) {
      const size_t i = idx * 4u;
      const uint32_t r = input_rgba[i + 0u];
      const uint32_t g = input_rgba[i + 1u];
      const uint32_t b = input_rgba[i + 2u];
      // Fast integer Rec.709 luma quantized to 0..255 (54 + 183 + 19 = 256).
      const uint32_t y_bin =
          std::min<uint32_t>((54u * r + 183u * g + 19u * b + 128u) >> 8u, 255u);
      hist[y_bin] += 1u;
      sampled_count += 1u;
      if (y_bin < 56u) {  // 56 / 255 ~= 0.2196 (< 0.22)
        shadow_count += 1u;
      }
    }

    auto quantile_luma = [&](double q) -> float {
      if (sampled_count == 0u) return 0.0f;
      const uint64_t target =
          std::max<uint64_t>(1u, static_cast<uint64_t>(q * sampled_count + 0.5));
      uint64_t acc = 0u;
      for (size_t bin = 0; bin < 256u; ++bin) {
        acc += hist[bin];
        if (acc >= target) {
          return static_cast<float>(bin) / 255.0f;
        }
      }
      return 1.0f;
    };

    const float p10 = quantile_luma(0.10);
    const float p50 = quantile_luma(0.50);
    const float p95 = quantile_luma(0.95);
    const float shadow_ratio = sampled_count == 0u
        ? 0.0f
        : static_cast<float>(static_cast<double>(shadow_count) /
                             static_cast<double>(sampled_count));

    float recommended_lift = 0.0f;
    int32_t recommended_mode = FS_DNA_MODE_SOOC_SAFE;

    if (p95 < 0.45f) {
      // Intentional low-key / night scene: gentle rescue in [0.15, 0.30].
      recommended_lift =
          std::clamp(0.15f + (0.20f - p10) * 0.75f, 0.15f, 0.30f);
      recommended_mode = FS_DNA_MODE_SOOC_SAFE;
    } else if (p95 >= 0.72f && p10 < 0.14f && shadow_ratio >= 0.18f) {
      // High-contrast backlit scene: stronger rescue in [0.40, 0.70].
      const float deficit = std::clamp((0.14f - p10) / 0.14f, 0.0f, 1.0f);
      const float ratio_boost =
          std::clamp((shadow_ratio - 0.18f) / 0.42f, 0.0f, 1.0f);
      recommended_lift = std::clamp(
          0.40f + 0.30f * (0.65f * deficit + 0.35f * ratio_boost),
          0.40f,
          0.70f);
      recommended_mode = (p10 < 0.07f && p95 >= 0.85f)
          ? FS_DNA_MODE_DEEP_RESCUE
          : FS_DNA_MODE_SOOC_SAFE;
    } else if (p10 >= 0.20f || shadow_ratio < 0.10f) {
      // Already well-exposed: minimal lift in [0.0, 0.12].
      recommended_lift = (p10 >= 0.25f && shadow_ratio < 0.05f)
          ? 0.0f
          : std::clamp((0.22f - p10) * 0.50f, 0.0f, 0.12f);
      recommended_mode = FS_DNA_MODE_SOOC_SAFE;
    } else {
      // Moderate shadows.
      recommended_lift =
          std::clamp(0.12f + (0.20f - p10) * 1.10f, 0.12f, 0.34f);
      recommended_mode = FS_DNA_MODE_SOOC_SAFE;
    }

    out_suggestion->recommended_shadow_lift = recommended_lift;
    out_suggestion->p10_luma = p10;
    out_suggestion->p50_luma = p50;
    out_suggestion->p95_luma = p95;
    out_suggestion->shadow_pixel_ratio = shadow_ratio;
    out_suggestion->recommended_mode = recommended_mode;
    return FS_OK;
  } catch (...) {
    return FS_ERR_ALLOC_FAILED;
  }
}

}  // extern "C"
