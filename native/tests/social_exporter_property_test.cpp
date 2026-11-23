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

std::vector<uint8_t> make_synthetic_rgba(int32_t w, int32_t h, uint64_t seed) {
  std::mt19937_64 rng(seed);
  std::uniform_int_distribution<int> byte_dist(0, 255);
  std::vector<uint8_t> buf(static_cast<size_t>(w) * static_cast<size_t>(h) * 4u);
  for (size_t i = 0; i < buf.size(); i += 4u) {
    buf[i + 0u] = static_cast<uint8_t>(byte_dist(rng));
    buf[i + 1u] = static_cast<uint8_t>(byte_dist(rng));
    buf[i + 2u] = static_cast<uint8_t>(byte_dist(rng));
    buf[i + 3u] = static_cast<uint8_t>(128 + (byte_dist(rng) % 128));
  }
  return buf;
}

void test_identity_bit_exact() {
  constexpr int32_t kW = 64;
  constexpr int32_t kH = 48;
  const std::vector<uint8_t> src = make_synthetic_rgba(kW, kH, 0x1D3A717BULL);
  std::vector<uint8_t> dst(src.size(), 0u);

  // 1. Lanczos3 resize with identical dimensions => bit-exact memcpy
  FS_CHECK(fs_export_lanczos3_resize_rgba_into(
               src.data(), src.size(), kW, kH, dst.data(), dst.size(), kW, kH) ==
           FS_OK);
  FS_CHECK(std::memcmp(src.data(), dst.data(), src.size()) == 0);

  // 2. Output USM with enabled == 0 => bit-exact bypass (separate + in-place)
  std::fill(dst.begin(), dst.end(), 0u);
  FsOutputUsmParams usm_disabled{0.60f, 0.85f, 3.0f, 18.0f, 0};
  FS_CHECK(fs_export_output_usm_rgba_into(
               src.data(), src.size(), kW, kH, &usm_disabled, dst.data(), dst.size()) ==
           FS_OK);
  FS_CHECK(std::memcmp(src.data(), dst.data(), src.size()) == 0);

  std::vector<uint8_t> inplace = src;
  FS_CHECK(fs_export_output_usm_rgba_into(
               inplace.data(), inplace.size(), kW, kH, &usm_disabled,
               inplace.data(), inplace.size()) == FS_OK);
  FS_CHECK(std::memcmp(src.data(), inplace.data(), src.size()) == 0);

  // 3. Output USM with enabled == 1, amount == 0.0 => bit-exact bypass
  std::fill(dst.begin(), dst.end(), 0u);
  FsOutputUsmParams usm_zero{0.0f, 0.85f, 3.0f, 18.0f, 1};
  FS_CHECK(fs_export_output_usm_rgba_into(
               src.data(), src.size(), kW, kH, &usm_zero, dst.data(), dst.size()) ==
           FS_OK);
  FS_CHECK(std::memcmp(src.data(), dst.data(), src.size()) == 0);

  std::printf("[PASS] Suite 1: Identity Bit-Exact\n");
}

void test_flat_color_weight_normalization() {
  std::mt19937_64 rng(0xF1A7C010ULL);
  std::uniform_int_distribution<int> byte_dist(0, 255);

  constexpr int32_t kSrcW = 97;
  constexpr int32_t kSrcH = 63;
  constexpr int32_t kDstW = 31;
  constexpr int32_t kDstH = 20;

  std::vector<uint8_t> src(static_cast<size_t>(kSrcW) * kSrcH * 4u);
  std::vector<uint8_t> dst(static_cast<size_t>(kDstW) * kDstH * 4u);

  for (int iter = 0; iter < 20; ++iter) {
    const uint8_t r = static_cast<uint8_t>(byte_dist(rng));
    const uint8_t g = static_cast<uint8_t>(byte_dist(rng));
    const uint8_t b = static_cast<uint8_t>(byte_dist(rng));
    const uint8_t a = static_cast<uint8_t>(byte_dist(rng));

    for (size_t i = 0; i < src.size(); i += 4u) {
      src[i + 0u] = r;
      src[i + 1u] = g;
      src[i + 2u] = b;
      src[i + 3u] = a;
    }

    FS_CHECK(fs_export_lanczos3_resize_rgba_into(
                 src.data(), src.size(), kSrcW, kSrcH,
                 dst.data(), dst.size(), kDstW, kDstH) == FS_OK);

    for (size_t i = 0; i < dst.size(); i += 4u) {
      FS_CHECK(std::abs(static_cast<int>(dst[i + 0u]) - static_cast<int>(r)) <= 1);
      FS_CHECK(std::abs(static_cast<int>(dst[i + 1u]) - static_cast<int>(g)) <= 1);
      FS_CHECK(std::abs(static_cast<int>(dst[i + 2u]) - static_cast<int>(b)) <= 1);
      FS_CHECK(std::abs(static_cast<int>(dst[i + 3u]) - static_cast<int>(a)) <= 1);
    }
  }

  std::printf("[PASS] Suite 2: Flat-Color Weight Normalization (20 samples)\n");
}

void test_ringing_and_wrap_around_guard() {
  // High-contrast 2x2-block checkerboard of (0,0,0,200) and (255,255,255,200).
  // Negative Lanczos lobes can overshoot below 0 or above 255; clamping MUST
  // prevent uint8 wrap-around (e.g. -1 -> 255 or 256 -> 0), preserve R==G==B,
  // and keep constant Alpha bit-exact.
  constexpr int32_t kSrcW = 64;
  constexpr int32_t kSrcH = 64;
  constexpr int32_t kDstW = 29;
  constexpr int32_t kDstH = 29;
  constexpr uint8_t kAlpha = 200u;

  std::vector<uint8_t> src(static_cast<size_t>(kSrcW) * kSrcH * 4u);
  for (int32_t y = 0; y < kSrcH; ++y) {
    for (int32_t x = 0; x < kSrcW; ++x) {
      const bool white = (((x / 4) + (y / 4)) % 2) == 0;
      const uint8_t v = white ? 255u : 0u;
      const size_t off = (static_cast<size_t>(y) * kSrcW + static_cast<size_t>(x)) * 4u;
      src[off + 0u] = v;
      src[off + 1u] = v;
      src[off + 2u] = v;
      src[off + 3u] = kAlpha;
    }
  }

  std::vector<uint8_t> dst(static_cast<size_t>(kDstW) * kDstH * 4u);
  FS_CHECK(fs_export_lanczos3_resize_rgba_into(
               src.data(), src.size(), kSrcW, kSrcH,
               dst.data(), dst.size(), kDstW, kDstH) == FS_OK);

  for (size_t i = 0; i < dst.size(); i += 4u) {
    FS_CHECK(dst[i + 0u] == dst[i + 1u]);
    FS_CHECK(dst[i + 1u] == dst[i + 2u]);
    FS_CHECK(dst[i + 3u] == kAlpha);
  }

  // Also test half-black / half-white step edge where pure black interior
  // (left side) must NOT wrap around to 255, and pure white interior (right side)
  // must NOT wrap around to 0.
  std::vector<uint8_t> step_src(static_cast<size_t>(kSrcW) * kSrcH * 4u);
  for (int32_t y = 0; y < kSrcH; ++y) {
    for (int32_t x = 0; x < kSrcW; ++x) {
      const uint8_t v = (x < kSrcW / 2) ? 0u : 255u;
      const size_t off = (static_cast<size_t>(y) * kSrcW + static_cast<size_t>(x)) * 4u;
      step_src[off + 0u] = v;
      step_src[off + 1u] = v;
      step_src[off + 2u] = v;
      step_src[off + 3u] = 255u;
    }
  }
  std::vector<uint8_t> step_dst(static_cast<size_t>(kDstW) * kDstH * 4u);
  FS_CHECK(fs_export_lanczos3_resize_rgba_into(
               step_src.data(), step_src.size(), kSrcW, kSrcH,
               step_dst.data(), step_dst.size(), kDstW, kDstH) == FS_OK);

  for (int32_t y = 0; y < kDstH; ++y) {
    for (int32_t x = 0; x < kDstW; ++x) {
      const size_t off = (static_cast<size_t>(y) * kDstW + static_cast<size_t>(x)) * 4u;
      FS_CHECK(step_dst[off + 3u] == 255u);
      if (x < kDstW / 2 - 2) {
        FS_CHECK(step_dst[off + 0u] < 20u);
      } else if (x > kDstW / 2 + 2) {
        FS_CHECK(step_dst[off + 0u] > 235u);
      }
    }
  }

  std::printf("[PASS] Suite 3: Ringing & Wrap-Around Guard\n");
}

void test_usm_threshold_halo_clamp_and_hue_safety() {
  constexpr int32_t kW = 48;
  constexpr int32_t kH = 48;
  constexpr size_t kBytes = static_cast<size_t>(kW) * kH * 4u;

  // 1. Sub-threshold fine noise (amplitude 2 < threshold 4.0) => 0 change
  std::vector<uint8_t> noise_src(kBytes);
  for (int32_t y = 0; y < kH; ++y) {
    for (int32_t x = 0; x < kW; ++x) {
      const uint8_t v = ((x + y) % 2 == 0) ? 120u : 122u;
      const size_t off = (static_cast<size_t>(y) * kW + static_cast<size_t>(x)) * 4u;
      noise_src[off + 0u] = v;
      noise_src[off + 1u] = static_cast<uint8_t>(v + 10u);
      noise_src[off + 2u] = static_cast<uint8_t>(v - 10u);
      noise_src[off + 3u] = 240u;
    }
  }
  std::vector<uint8_t> noise_dst(kBytes);
  FsOutputUsmParams usm_params{0.80f, 0.85f, 4.0f, 18.0f, 1};
  FS_CHECK(fs_export_output_usm_rgba_into(
               noise_src.data(), noise_src.size(), kW, kH, &usm_params,
               noise_dst.data(), noise_dst.size()) == FS_OK);
  FS_CHECK(std::memcmp(noise_src.data(), noise_dst.data(), kBytes) == 0);

  // 2. Hard step edge (20 -> 235) + pure black (0,0,0) check + halo_clamp + in-place equivalence
  std::vector<uint8_t> edge_src(kBytes);
  for (int32_t y = 0; y < kH; ++y) {
    for (int32_t x = 0; x < kW; ++x) {
      const size_t off = (static_cast<size_t>(y) * kW + static_cast<size_t>(x)) * 4u;
      uint8_t v = 20u;
      if (y < 6) {
        v = 0u;  // Pure black strip
      } else if (x >= kW / 2) {
        v = 235u;
      }
      edge_src[off + 0u] = v;
      edge_src[off + 1u] = v;
      edge_src[off + 2u] = v;
      edge_src[off + 3u] = 215u;
    }
  }

  constexpr float kHaloClamp = 12.0f;
  FsOutputUsmParams edge_params{1.5f, 1.2f, 2.0f, kHaloClamp, 1};
  std::vector<uint8_t> edge_sep(kBytes);
  std::vector<uint8_t> edge_inplace = edge_src;

  FS_CHECK(fs_export_output_usm_rgba_into(
               edge_src.data(), edge_src.size(), kW, kH, &edge_params,
               edge_sep.data(), edge_sep.size()) == FS_OK);
  FS_CHECK(fs_export_output_usm_rgba_into(
               edge_inplace.data(), edge_inplace.size(), kW, kH, &edge_params,
               edge_inplace.data(), edge_inplace.size()) == FS_OK);
  FS_CHECK(std::memcmp(edge_sep.data(), edge_inplace.data(), kBytes) == 0);

  for (int32_t y = 0; y < kH; ++y) {
    for (int32_t x = 0; x < kW; ++x) {
      const size_t off = (static_cast<size_t>(y) * kW + static_cast<size_t>(x)) * 4u;
      FS_CHECK(edge_sep[off + 3u] == 215u);
      if (y < 2) {
        // Pure black region stays 0
        FS_CHECK(edge_sep[off + 0u] == 0u);
        FS_CHECK(edge_sep[off + 1u] == 0u);
        FS_CHECK(edge_sep[off + 2u] == 0u);
      }
      const int diff = std::abs(
          static_cast<int>(edge_sep[off + 0u]) - static_cast<int>(edge_src[off + 0u]));
      FS_CHECK(diff <= static_cast<int>(std::ceil(kHaloClamp)));
    }
  }

  // 3. Hue safety: adding equal luma delta preserves channel spread (G - R) on unclipped colors
  std::vector<uint8_t> color_src(kBytes);
  for (int32_t y = 0; y < kH; ++y) {
    for (int32_t x = 0; x < kW; ++x) {
      const size_t off = (static_cast<size_t>(y) * kW + static_cast<size_t>(x)) * 4u;
      if (x < kW / 2) {
        color_src[off + 0u] = 60u;
        color_src[off + 1u] = 100u;
        color_src[off + 2u] = 140u;
      } else {
        color_src[off + 0u] = 90u;
        color_src[off + 1u] = 130u;
        color_src[off + 2u] = 170u;
      }
      color_src[off + 3u] = 255u;
    }
  }
  std::vector<uint8_t> color_dst(kBytes);
  FsOutputUsmParams color_params{0.50f, 0.85f, 3.0f, 18.0f, 1};
  FS_CHECK(fs_export_output_usm_rgba_into(
               color_src.data(), color_src.size(), kW, kH, &color_params,
               color_dst.data(), color_dst.size()) == FS_OK);
  for (size_t i = 0; i < kBytes; i += 4u) {
    const int d_gr = static_cast<int>(color_dst[i + 1u]) - static_cast<int>(color_dst[i + 0u]);
    const int d_bg = static_cast<int>(color_dst[i + 2u]) - static_cast<int>(color_dst[i + 1u]);
    FS_CHECK(d_gr == 40);
    FS_CHECK(d_bg == 40);
  }

  std::printf("[PASS] Suite 4: Luma-USM Threshold, Halo Clamp & Hue Safety\n");
}

void test_downscale_geometry_precision() {
  struct DimCase {
    int32_t sw, sh, dw, dh;
  };
  const std::array<DimCase, 4> cases = {{
      {1, 1, 1, 1},
      {3, 5, 1, 2},
      {13, 7, 5, 3},
      {240, 160, 80, 53},
  }};

  for (const auto& c : cases) {
    const std::vector<uint8_t> src = make_synthetic_rgba(c.sw, c.sh, 0x6E0A1234ULL);
    std::vector<uint8_t> dst(static_cast<size_t>(c.dw) * c.dh * 4u, 0u);
    FS_CHECK(fs_export_lanczos3_resize_rgba_into(
                 src.data(), src.size(), c.sw, c.sh,
                 dst.data(), dst.size(), c.dw, c.dh) == FS_OK);
  }

  std::printf("[PASS] Suite 5: Downscale Geometry Precision\n");
}

void test_chained_pipeline_smoke() {
  constexpr int32_t kSrcW = 160;
  constexpr int32_t kSrcH = 120;
  std::vector<uint8_t> buf = make_synthetic_rgba(kSrcW, kSrcH, 0xC4A19E00ULL);

  // 1. DNA Rescue in-place
  FsDnaRescueParams dna{0.40f, 0.55f, 0.90f, FS_DNA_MODE_SOOC_SAFE, 1, 0.75f};
  FS_CHECK(fs_dna_rescue_apply_rgba_into(
               buf.data(), buf.size(), kSrcW, kSrcH, &dna,
               buf.data(), buf.size()) == FS_OK);

  // 2. Geometry rotation + crop
  const FsNormCropBox req{0.0f, 0.0f, 1.0f, 1.0f};
  FsNormCropBox clamped{};
  int32_t crop_w = 0;
  int32_t crop_h = 0;
  FS_CHECK(fs_geometry_clamp_crop(
               kSrcW, kSrcH, 2.5f, FS_ASPECT_4_5, &req, &clamped, &crop_w, &crop_h) ==
           FS_OK);

  std::vector<uint8_t> cropped(static_cast<size_t>(crop_w) * crop_h * 4u);
  FsGeometryParams geom{2.5f, FS_ASPECT_4_5, clamped, 1};
  FS_CHECK(fs_geometry_render_rgba_into(
               buf.data(), buf.size(), kSrcW, kSrcH, &geom,
               cropped.data(), cropped.size(), crop_w, crop_h) == FS_OK);

  // 3. Lanczos3 downscale
  constexpr int32_t kExportW = 48;
  constexpr int32_t kExportH = 60;
  std::vector<uint8_t> resized(static_cast<size_t>(kExportW) * kExportH * 4u);
  FS_CHECK(fs_export_lanczos3_resize_rgba_into(
               cropped.data(), cropped.size(), crop_w, crop_h,
               resized.data(), resized.size(), kExportW, kExportH) == FS_OK);

  // 4. Output USM in-place
  FsOutputUsmParams usm{0.35f, 0.85f, 3.0f, 18.0f, 1};
  FS_CHECK(fs_export_output_usm_rgba_into(
               resized.data(), resized.size(), kExportW, kExportH, &usm,
               resized.data(), resized.size()) == FS_OK);

  std::printf("[PASS] Suite 6: Chained Pipeline Smoke (DNA -> Crop -> Lanczos3 -> USM)\n");
}

void test_adversarial_guard_suite() {
  std::vector<uint8_t> buf(64u * 64u * 4u, 128u);
  std::vector<uint8_t> out(32u * 32u * 4u, 0u);
  FsOutputUsmParams valid_usm{0.35f, 0.85f, 3.0f, 18.0f, 1};

  // Null pointers
  FS_CHECK(fs_export_lanczos3_resize_rgba_into(
               nullptr, buf.size(), 64, 64, out.data(), out.size(), 32, 32) ==
           FS_ERR_NULL_POINTER);
  FS_CHECK(fs_export_lanczos3_resize_rgba_into(
               buf.data(), buf.size(), 64, 64, nullptr, out.size(), 32, 32) ==
           FS_ERR_NULL_POINTER);
  FS_CHECK(fs_export_output_usm_rgba_into(
               nullptr, buf.size(), 64, 64, &valid_usm, buf.data(), buf.size()) ==
           FS_ERR_NULL_POINTER);
  FS_CHECK(fs_export_output_usm_rgba_into(
               buf.data(), buf.size(), 64, 64, nullptr, buf.data(), buf.size()) ==
           FS_ERR_NULL_POINTER);
  FS_CHECK(fs_export_output_usm_rgba_into(
               buf.data(), buf.size(), 64, 64, &valid_usm, nullptr, buf.size()) ==
           FS_ERR_NULL_POINTER);

  // In-place & overlapping memory on Lanczos3
  FS_CHECK(fs_export_lanczos3_resize_rgba_into(
               buf.data(), buf.size(), 64, 64, buf.data(), buf.size(), 32, 32) ==
           FS_ERR_INVALID_PARAMS);
  FS_CHECK(fs_export_lanczos3_resize_rgba_into(
               buf.data(), buf.size(), 64, 64, buf.data() + 128,
               buf.size() - 128u, 32, 32) == FS_ERR_INVALID_PARAMS);

  // Partial overlap on USM (out != in)
  FS_CHECK(fs_export_output_usm_rgba_into(
               buf.data(), 32u * 32u * 4u, 32, 32, &valid_usm,
               buf.data() + 4, 32u * 32u * 4u) == FS_ERR_INVALID_PARAMS);

  // NaN / Inf params on USM
  const float nan_val = std::numeric_limits<float>::quiet_NaN();
  const float inf_val = std::numeric_limits<float>::infinity();
  FsOutputUsmParams nan_usm{nan_val, 0.85f, 3.0f, 18.0f, 1};
  FsOutputUsmParams inf_usm{0.35f, inf_val, 3.0f, 18.0f, 1};
  FS_CHECK(fs_export_output_usm_rgba_into(
               buf.data(), buf.size(), 64, 64, &nan_usm,
               buf.data(), buf.size()) == FS_ERR_INVALID_PARAMS);
  FS_CHECK(fs_export_output_usm_rgba_into(
               buf.data(), buf.size(), 64, 64, &inf_usm,
               buf.data(), buf.size()) == FS_ERR_INVALID_PARAMS);

  // Dimensions <= 0 and > FS_MAX_IMAGE_DIMENSION
  FS_CHECK(fs_export_lanczos3_resize_rgba_into(
               buf.data(), buf.size(), 0, 64, out.data(), out.size(), 32, 32) ==
           FS_ERR_INVALID_DIMENSIONS);
  FS_CHECK(fs_export_lanczos3_resize_rgba_into(
               buf.data(), buf.size(), 64, 64, out.data(), out.size(), 32, 0) ==
           FS_ERR_INVALID_DIMENSIONS);
  FS_CHECK(fs_export_lanczos3_resize_rgba_into(
               buf.data(), buf.size(), FS_MAX_IMAGE_DIMENSION + 1, 1,
               out.data(), out.size(), 1, 1) == FS_ERR_OVERFLOW);
  FS_CHECK(fs_export_output_usm_rgba_into(
               buf.data(), buf.size(), FS_MAX_IMAGE_DIMENSION + 1, 1,
               &valid_usm, buf.data(), buf.size()) == FS_ERR_OVERFLOW);

  // Undersized input_len / out_len
  FS_CHECK(fs_export_lanczos3_resize_rgba_into(
               buf.data(), buf.size() - 1u, 64, 64,
               out.data(), out.size(), 32, 32) == FS_ERR_INVALID_DIMENSIONS);
  FS_CHECK(fs_export_lanczos3_resize_rgba_into(
               buf.data(), buf.size(), 64, 64,
               out.data(), out.size() - 1u, 32, 32) == FS_ERR_INVALID_DIMENSIONS);
  FS_CHECK(fs_export_output_usm_rgba_into(
               buf.data(), buf.size() - 1u, 64, 64, &valid_usm,
               buf.data(), buf.size()) == FS_ERR_INVALID_DIMENSIONS);
  FS_CHECK(fs_export_output_usm_rgba_into(
               buf.data(), buf.size(), 64, 64, &valid_usm,
               buf.data(), buf.size() - 1u) == FS_ERR_INVALID_DIMENSIONS);

  std::printf("[PASS] Suite 7: Adversarial Guard Suite\n");
}

void test_usm_inplace_bit_exact_edge_dimensions() {
  struct DimCase {
    int32_t w, h;
  };
  const std::array<DimCase, 4> dims = {{
      {1, 1},
      {3, 5},
      {7, 4},
      {48, 48},
  }};
  const std::array<float, 3> radii = {{0.5f, 0.85f, 2.0f}};

  for (const auto& d : dims) {
    const std::vector<uint8_t> src =
        make_synthetic_rgba(d.w, d.h, 0xB1D00001ULL ^ static_cast<uint64_t>(d.w * 31 + d.h));
    for (float radius : radii) {
      const FsOutputUsmParams params{0.85f, radius, 1.5f, 18.0f, 1};
      std::vector<uint8_t> out_of_place(src.size(), 0u);
      std::vector<uint8_t> in_place = src;

      FS_CHECK(fs_export_output_usm_rgba_into(
                   src.data(), src.size(), d.w, d.h, &params,
                   out_of_place.data(), out_of_place.size()) == FS_OK);
      FS_CHECK(fs_export_output_usm_rgba_into(
                   in_place.data(), in_place.size(), d.w, d.h, &params,
                   in_place.data(), in_place.size()) == FS_OK);
      FS_CHECK(std::memcmp(out_of_place.data(), in_place.data(), src.size()) == 0);
    }
  }

  std::printf("[PASS] Suite 8: USM In-Place Bit-Exact Edge Dimensions\n");
}

}  // namespace

int main() {
  test_identity_bit_exact();
  test_flat_color_weight_normalization();
  test_ringing_and_wrap_around_guard();
  test_usm_threshold_halo_clamp_and_hue_safety();
  test_downscale_geometry_precision();
  test_chained_pipeline_smoke();
  test_adversarial_guard_suite();
  test_usm_inplace_bit_exact_edge_dimensions();
  std::printf("ALL 8 SOCIAL EXPORTER PROPERTY SUITES PASSED.\n");
  return 0;
}
