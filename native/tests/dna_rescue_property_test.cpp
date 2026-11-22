#include "fujistudio_c_api.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <random>
#include <vector>

namespace {

int g_failures = 0;
constexpr uint64_t kSeed = 0x20261121DAA20002ULL;

void expect(bool cond, const char* msg) {
  if (!cond) {
    std::cerr << "[FAIL] (seed=" << kSeed << ") " << msg << "\n";
    ++g_failures;
  }
}

float rec709_luma_u8(uint8_t r, uint8_t g, uint8_t b) {
  return (0.2126f * static_cast<float>(r) +
          0.7152f * static_cast<float>(g) +
          0.0722f * static_cast<float>(b)) /
         255.0f;
}

FsDnaRescueParams make_params(
    float shadow_lift,
    float midtone_anchor = 0.55f,
    float highlight_protect = 0.90f,
    int32_t mode = FS_DNA_MODE_SOOC_SAFE,
    int32_t enabled = 1) {
  FsDnaRescueParams p{};
  p.shadow_lift = shadow_lift;
  p.midtone_anchor = midtone_anchor;
  p.highlight_protect = highlight_protect;
  p.mode = mode;
  p.enabled = enabled;
  return p;
}

// 1. Identity Bit-Exact
void test_identity_bit_exact(std::mt19937_64& rng) {
  constexpr int32_t w = 32;
  constexpr int32_t h = 24;
  constexpr size_t bytes = static_cast<size_t>(w * h * 4);
  std::vector<uint8_t> in(bytes);
  std::vector<uint8_t> out(bytes);

  for (int iter = 0; iter < 100; ++iter) {
    for (size_t i = 0; i < bytes; ++i) {
      in[i] = static_cast<uint8_t>(rng() & 0xFFu);
    }
    const bool zero_lift = (iter % 2 == 0);
    const FsDnaRescueParams params = make_params(
        zero_lift ? 0.0f : 0.75f,
        0.55f,
        0.90f,
        iter % 3 == 0 ? FS_DNA_MODE_DEEP_RESCUE : FS_DNA_MODE_SOOC_SAFE,
        zero_lift ? 1 : 0);

    std::fill(out.begin(), out.end(), 0xAAu);
    const int32_t rc = fs_dna_rescue_apply_rgba_into(
        in.data(),
        in.size(),
        w,
        h,
        &params,
        out.data(),
        out.size());
    expect(rc == FS_OK, "identity bypass must return FS_OK");
    expect(std::memcmp(out.data(), in.data(), bytes) == 0,
           "identity bypass must match input bit-for-bit");
  }
}

// 2. Strict Monotonicity (Grayscale 0..255 + 200 color rays)
void test_strict_monotonicity(std::mt19937_64& rng) {
  std::uniform_real_distribution<float> dist_s(0.0f, 1.0f);
  std::uniform_real_distribution<float> dist_a(0.35f, 0.75f);
  std::uniform_real_distribution<float> dist_h(0.75f, 0.98f);

  std::vector<uint8_t> gray_in(256u * 4u);
  std::vector<uint8_t> gray_out(256u * 4u);
  for (size_t v = 0; v < 256u; ++v) {
    gray_in[v * 4u + 0u] = static_cast<uint8_t>(v);
    gray_in[v * 4u + 1u] = static_cast<uint8_t>(v);
    gray_in[v * 4u + 2u] = static_cast<uint8_t>(v);
    gray_in[v * 4u + 3u] = 255u;
  }

  for (int iter = 0; iter < 100; ++iter) {
    const FsDnaRescueParams params = make_params(
        dist_s(rng),
        dist_a(rng),
        dist_h(rng),
        (iter % 2 == 0) ? FS_DNA_MODE_SOOC_SAFE : FS_DNA_MODE_DEEP_RESCUE,
        1);
    const int32_t rc = fs_dna_rescue_apply_rgba_into(
        gray_in.data(),
        gray_in.size(),
        256,
        1,
        &params,
        gray_out.data(),
        gray_out.size());
    expect(rc == FS_OK, "grayscale monotonicity run must succeed");
    for (size_t v = 0; v < 255u; ++v) {
      const float y0 = rec709_luma_u8(
          gray_out[v * 4u + 0u], gray_out[v * 4u + 1u], gray_out[v * 4u + 2u]);
      const float y1 = rec709_luma_u8(
          gray_out[(v + 1u) * 4u + 0u],
          gray_out[(v + 1u) * 4u + 1u],
          gray_out[(v + 1u) * 4u + 2u]);
      expect(y1 + 1e-6f >= y0, "grayscale Y_out(v+1) must be >= Y_out(v)");
    }
  }

  // 200 color rays (k*R0, k*G0, k*B0)
  std::uniform_real_distribution<float> dist_c(0.1f, 1.0f);
  constexpr int kSteps = 64;
  std::vector<uint8_t> ray_in(kSteps * 4u);
  std::vector<uint8_t> ray_out(kSteps * 4u);

  for (int ray = 0; ray < 200; ++ray) {
    const float r0 = dist_c(rng);
    const float g0 = dist_c(rng);
    const float b0 = dist_c(rng);
    for (int step = 0; step < kSteps; ++step) {
      const float k = static_cast<float>(step) / static_cast<float>(kSteps - 1);
      ray_in[step * 4u + 0u] =
          static_cast<uint8_t>(std::clamp(r0 * k * 255.0f + 0.5f, 0.0f, 255.0f));
      ray_in[step * 4u + 1u] =
          static_cast<uint8_t>(std::clamp(g0 * k * 255.0f + 0.5f, 0.0f, 255.0f));
      ray_in[step * 4u + 2u] =
          static_cast<uint8_t>(std::clamp(b0 * k * 255.0f + 0.5f, 0.0f, 255.0f));
      ray_in[step * 4u + 3u] = 255u;
    }

    const FsDnaRescueParams params = make_params(
        dist_s(rng),
        dist_a(rng),
        dist_h(rng),
        (ray % 2 == 0) ? FS_DNA_MODE_SOOC_SAFE : FS_DNA_MODE_DEEP_RESCUE,
        1);
    const int32_t rc = fs_dna_rescue_apply_rgba_into(
        ray_in.data(),
        ray_in.size(),
        kSteps,
        1,
        &params,
        ray_out.data(),
        ray_out.size());
    expect(rc == FS_OK, "color ray monotonicity run must succeed");
    for (int step = 0; step < kSteps - 1; ++step) {
      const float y0 = rec709_luma_u8(
          ray_out[step * 4u + 0u],
          ray_out[step * 4u + 1u],
          ray_out[step * 4u + 2u]);
      const float y1 = rec709_luma_u8(
          ray_out[(step + 1) * 4u + 0u],
          ray_out[(step + 1) * 4u + 1u],
          ray_out[(step + 1) * 4u + 2u]);
      if (y1 + 1e-6f < y0) {
        const float dip = y0 - y1;
        if (dip > 0.004f) {
          std::cerr << "BIG RAY DIP ray=" << ray << " step=" << step
                    << " s=" << params.shadow_lift << " a=" << params.midtone_anchor
                    << " h=" << params.highlight_protect << " mode=" << params.mode
                    << " in0=(" << int(ray_in[step*4]) << "," << int(ray_in[step*4+1]) << "," << int(ray_in[step*4+2]) << ")"
                    << " in1=(" << int(ray_in[(step+1)*4]) << "," << int(ray_in[(step+1)*4+1]) << "," << int(ray_in[(step+1)*4+2]) << ")"
                    << " out0=(" << int(ray_out[step*4]) << "," << int(ray_out[step*4+1]) << "," << int(ray_out[step*4+2]) << ")"
                    << " out1=(" << int(ray_out[(step+1)*4]) << "," << int(ray_out[(step+1)*4+1]) << "," << int(ray_out[(step+1)*4+2]) << ")"
                    << " dip=" << dip << "\n";
        }
      }
      expect(y1 + (2.0f / 255.0f) >= y0, "color ray Y_out must be non-decreasing within u8 quantization");
    }
  }
}

// 3. Midtone & Highlight Anchor Protection (50,000 pixels x 50 parameter sets)
void test_midtone_highlight_anchor(std::mt19937_64& rng) {
  constexpr int32_t w = 250;
  constexpr int32_t h = 200;  // 50,000 pixels
  constexpr size_t pixels = static_cast<size_t>(w * h);
  std::vector<uint8_t> in(pixels * 4u);
  std::vector<uint8_t> out(pixels * 4u);
  for (size_t i = 0; i < in.size(); ++i) {
    in[i] = static_cast<uint8_t>(rng() & 0xFFu);
  }

  std::uniform_real_distribution<float> dist_s(0.05f, 1.0f);
  std::uniform_real_distribution<float> dist_a(0.35f, 0.75f);
  std::uniform_real_distribution<float> dist_hl(0.75f, 0.98f);

  for (int set_idx = 0; set_idx < 50; ++set_idx) {
    const float anchor = dist_a(rng);
    const FsDnaRescueParams params = make_params(
        dist_s(rng),
        anchor,
        dist_hl(rng),
        (set_idx % 2 == 0) ? FS_DNA_MODE_SOOC_SAFE : FS_DNA_MODE_DEEP_RESCUE,
        1);
    const int32_t rc = fs_dna_rescue_apply_rgba_into(
        in.data(),
        in.size(),
        w,
        h,
        &params,
        out.data(),
        out.size());
    expect(rc == FS_OK, "midtone anchor test run must succeed");

    for (size_t p = 0; p < pixels; ++p) {
      const size_t i = p * 4u;
      const float y_in = rec709_luma_u8(in[i + 0u], in[i + 1u], in[i + 2u]);
      if (y_in >= anchor) {
        const float y_out =
            rec709_luma_u8(out[i + 0u], out[i + 1u], out[i + 2u]);
        expect(
            std::fabs(y_out - y_in) <= 0.02f,
            "midtone/highlight pixel with Y_in >= midtone_anchor must stay protected");
      }
    }
  }
}

// 4. True Black Anchor & Alpha Preservation
void test_black_anchor_and_alpha(std::mt19937_64& rng) {
  constexpr size_t pixels = 256;
  std::vector<uint8_t> in(pixels * 4u);
  std::vector<uint8_t> out(pixels * 4u);
  for (size_t p = 0; p < pixels; ++p) {
    if (p < 64u) {
      in[p * 4u + 0u] = 0u;
      in[p * 4u + 1u] = 0u;
      in[p * 4u + 2u] = 0u;
      in[p * 4u + 3u] = static_cast<uint8_t>(p * 4u);
    } else {
      in[p * 4u + 0u] = static_cast<uint8_t>(rng() & 0xFFu);
      in[p * 4u + 1u] = static_cast<uint8_t>(rng() & 0xFFu);
      in[p * 4u + 2u] = static_cast<uint8_t>(rng() & 0xFFu);
      in[p * 4u + 3u] = static_cast<uint8_t>(rng() & 0xFFu);
    }
  }

  const FsDnaRescueParams params =
      make_params(1.0f, 0.75f, 0.98f, FS_DNA_MODE_DEEP_RESCUE, 1);
  const int32_t rc = fs_dna_rescue_apply_rgba_into(
      in.data(),
      in.size(),
      16,
      16,
      &params,
      out.data(),
      out.size());
  expect(rc == FS_OK, "black anchor & alpha test must return FS_OK");

  for (size_t p = 0; p < pixels; ++p) {
    const size_t i = p * 4u;
    if (p < 64u) {
      expect(out[i + 0u] == 0u && out[i + 1u] == 0u && out[i + 2u] == 0u,
             "(0,0,0,a) must remain (0,0,0,a)");
    }
    expect(out[i + 3u] == in[i + 3u], "alpha must be preserved bit-for-bit");
  }
}

// 5. Saturated Highlight Guard & In-Place Aliasing
void test_saturated_and_inplace() {
  const uint8_t saturated[16] = {
      0u, 0u, 255u, 200u,
      255u, 0u, 0u, 150u,
      0u, 255u, 0u, 100u,
      12u, 24u, 200u, 255u,
  };
  std::vector<uint8_t> out_sep(sizeof(saturated));
  std::vector<uint8_t> in_place(saturated, saturated + sizeof(saturated));

  const FsDnaRescueParams params =
      make_params(0.95f, 0.65f, 0.90f, FS_DNA_MODE_DEEP_RESCUE, 1);

  expect(fs_dna_rescue_apply_rgba_into(
             saturated,
             sizeof(saturated),
             4,
             1,
             &params,
             out_sep.data(),
             out_sep.size()) == FS_OK,
         "separate buffer saturated call must succeed");

  expect(fs_dna_rescue_apply_rgba_into(
             in_place.data(),
             in_place.size(),
             4,
             1,
             &params,
             in_place.data(),
             in_place.size()) == FS_OK,
         "in-place aliased call must succeed");

  expect(std::memcmp(out_sep.data(), in_place.data(), sizeof(saturated)) == 0,
         "in-place aliased result must match separate buffer bit-for-bit");

  // Pure saturated primaries with max channel 255 >= h (0.90*255) must not clip/shift hue.
  expect(out_sep[0] == 0u && out_sep[1] == 0u && out_sep[2] == 255u,
         "(0,0,255) must remain protected without overflow");
  expect(out_sep[4] == 255u && out_sep[5] == 0u && out_sep[6] == 0u,
         "(255,0,0) must remain protected without overflow");
  expect(out_sep[8] == 0u && out_sep[9] == 255u && out_sep[10] == 0u,
         "(0,255,0) must remain protected without overflow");
}

// 6. Odd Dimensions & Tail Loop Safety
void test_odd_dimensions_tail_safety(std::mt19937_64& rng) {
  const int dims[][2] = {
      {1, 1},
      {3, 1},
      {5, 3},
      {13, 7},
      {15, 17},
  };
  const FsDnaRescueParams params =
      make_params(0.60f, 0.55f, 0.90f, FS_DNA_MODE_SOOC_SAFE, 1);

  for (const auto& d : dims) {
    const int32_t w = d[0];
    const int32_t h = d[1];
    const size_t bytes = static_cast<size_t>(w * h * 4);
    std::vector<uint8_t> in(bytes);
    std::vector<uint8_t> out(bytes);
    for (size_t i = 0; i < bytes; ++i) {
      in[i] = static_cast<uint8_t>(rng() & 0xFFu);
    }
    const int32_t rc = fs_dna_rescue_apply_rgba_into(
        in.data(),
        in.size(),
        w,
        h,
        &params,
        out.data(),
        out.size());
    expect(rc == FS_OK, "odd dimension buffer must succeed without ASan OOB");
    for (size_t p = 0; p < bytes; p += 4u) {
      expect(out[p + 3u] == in[p + 3u], "odd dimension must preserve alpha");
    }
  }
}

// 7. Error & Fuzz Bounds
void test_error_and_fuzz_bounds() {
  uint8_t buf[16] = {10, 20, 30, 255, 0, 0, 0, 255, 1, 2, 3, 4, 5, 6, 7, 8};
  uint8_t out[16] = {};
  const FsDnaRescueParams valid = make_params(0.5f);

  expect(fs_dna_rescue_apply_rgba_into(
             nullptr, sizeof(buf), 2, 2, &valid, out, sizeof(out)) ==
             FS_ERR_NULL_POINTER,
         "null input must return FS_ERR_NULL_POINTER");
  expect(fs_dna_rescue_apply_rgba_into(
             buf, sizeof(buf), 2, 2, nullptr, out, sizeof(out)) ==
             FS_ERR_NULL_POINTER,
         "null params must return FS_ERR_NULL_POINTER");
  expect(fs_dna_rescue_apply_rgba_into(
             buf, sizeof(buf), 2, 2, &valid, nullptr, sizeof(out)) ==
             FS_ERR_NULL_POINTER,
         "null out must return FS_ERR_NULL_POINTER");

  FsDnaRescueParams nan_p = valid;
  nan_p.shadow_lift = std::numeric_limits<float>::quiet_NaN();
  expect(fs_dna_rescue_apply_rgba_into(
             buf, sizeof(buf), 2, 2, &nan_p, out, sizeof(out)) ==
             FS_ERR_INVALID_PARAMS,
         "NaN shadow_lift must return FS_ERR_INVALID_PARAMS");

  FsDnaRescueParams inf_p = valid;
  inf_p.midtone_anchor = std::numeric_limits<float>::infinity();
  expect(fs_dna_rescue_apply_rgba_into(
             buf, sizeof(buf), 2, 2, &inf_p, out, sizeof(out)) ==
             FS_ERR_INVALID_PARAMS,
         "Inf midtone_anchor must return FS_ERR_INVALID_PARAMS");

  FsDnaRescueParams bad_mode = valid;
  bad_mode.mode = 99;
  expect(fs_dna_rescue_apply_rgba_into(
             buf, sizeof(buf), 2, 2, &bad_mode, out, sizeof(out)) ==
             FS_ERR_INVALID_PARAMS,
         "mode=99 must return FS_ERR_INVALID_PARAMS");

  expect(fs_dna_rescue_apply_rgba_into(
             buf, 8, 2, 2, &valid, out, sizeof(out)) ==
             FS_ERR_INVALID_DIMENSIONS,
         "undersized input_len must return FS_ERR_INVALID_DIMENSIONS");
  expect(fs_dna_rescue_apply_rgba_into(
             buf, sizeof(buf), 2, 2, &valid, out, 8) ==
             FS_ERR_INVALID_DIMENSIONS,
         "undersized out_len must return FS_ERR_INVALID_DIMENSIONS");
  expect(fs_dna_rescue_apply_rgba_into(
             buf, sizeof(buf), 20000, 1, &valid, out, sizeof(out)) ==
             FS_ERR_OVERFLOW,
         "width=20000 must return FS_ERR_OVERFLOW");

  FsDnaRescueSuggestion sug{};
  expect(fs_dna_rescue_analyze_rgba(nullptr, 16, 2, 2, &sug) ==
             FS_ERR_NULL_POINTER,
         "analyze null input must return FS_ERR_NULL_POINTER");
  expect(fs_dna_rescue_analyze_rgba(buf, 16, 2, 2, nullptr) ==
             FS_ERR_NULL_POINTER,
         "analyze null out must return FS_ERR_NULL_POINTER");
  expect(fs_dna_rescue_analyze_rgba(buf, 4, 2, 2, &sug) ==
             FS_ERR_INVALID_DIMENSIONS,
         "analyze undersized input must return FS_ERR_INVALID_DIMENSIONS");
  expect(fs_dna_rescue_analyze_rgba(buf, 16, 20000, 1, &sug) ==
             FS_ERR_OVERFLOW,
         "analyze width=20000 must return FS_ERR_OVERFLOW");
}

// 8. Auto-Analyze Sanity & 1600x1067 Host Performance Log
void test_auto_analyze_and_perf(std::mt19937_64& rng) {
  // Backlit image: 40% dark shadows (10,10,10), 60% bright sky (235,235,235)
  constexpr int32_t aw = 100;
  constexpr int32_t ah = 100;
  std::vector<uint8_t> backlit(static_cast<size_t>(aw * ah * 4));
  std::vector<uint8_t> bright(static_cast<size_t>(aw * ah * 4));
  for (int32_t p = 0; p < aw * ah; ++p) {
    const size_t i = static_cast<size_t>(p) * 4u;
    const uint8_t v_backlit = (p < 4000) ? 10u : 235u;
    backlit[i + 0u] = v_backlit;
    backlit[i + 1u] = v_backlit;
    backlit[i + 2u] = v_backlit;
    backlit[i + 3u] = 255u;

    bright[i + 0u] = 180u;
    bright[i + 1u] = 185u;
    bright[i + 2u] = 190u;
    bright[i + 3u] = 255u;
  }

  FsDnaRescueSuggestion sug_backlit{};
  expect(fs_dna_rescue_analyze_rgba(
             backlit.data(), backlit.size(), aw, ah, &sug_backlit) == FS_OK,
         "backlit analyze must succeed");
  expect(sug_backlit.recommended_shadow_lift > 0.30f,
         "backlit image must suggest shadow_lift > 0.30");

  FsDnaRescueSuggestion sug_bright{};
  expect(fs_dna_rescue_analyze_rgba(
             bright.data(), bright.size(), aw, ah, &sug_bright) == FS_OK,
         "bright analyze must succeed");
  expect(sug_bright.recommended_shadow_lift <= 0.15f,
         "well-lit image must suggest shadow_lift <= 0.15");

  // 1600x1067 Host benchmark
  constexpr int32_t pw = 1600;
  constexpr int32_t ph = 1067;
  constexpr size_t pbytes = static_cast<size_t>(pw * ph * 4);
  std::vector<uint8_t> perf_in(pbytes);
  std::vector<uint8_t> perf_out(pbytes);
  for (size_t i = 0; i < pbytes; i += 4u) {
    perf_in[i + 0u] = static_cast<uint8_t>(rng() & 0x7Fu);
    perf_in[i + 1u] = static_cast<uint8_t>(rng() & 0x7Fu);
    perf_in[i + 2u] = static_cast<uint8_t>(rng() & 0x7Fu);
    perf_in[i + 3u] = 255u;
  }
  const FsDnaRescueParams params =
      make_params(0.45f, 0.55f, 0.90f, FS_DNA_MODE_SOOC_SAFE, 1);

  const auto t0 = std::chrono::steady_clock::now();
  const int32_t prc = fs_dna_rescue_apply_rgba_into(
      perf_in.data(),
      perf_in.size(),
      pw,
      ph,
      &params,
      perf_out.data(),
      perf_out.size());
  const auto t1 = std::chrono::steady_clock::now();
  expect(prc == FS_OK, "1600x1067 perf run must return FS_OK");

  const double ms =
      std::chrono::duration<double, std::milli>(t1 - t0).count();
  std::cout << "[PERF] 1600x1067 DNA Shadow Rescue (Host w/ sanitizers): "
            << ms << " ms\n";
}

// 9. Zero-Haze Black Floor Guard (Y in [0..8]/255 at shadow_lift=0.70, SOOC_SAFE)
void test_zero_haze_black_floor_guard() {
  constexpr int32_t w = 9;
  constexpr int32_t h = 1;
  std::vector<uint8_t> in(static_cast<size_t>(w * h * 4));
  std::vector<uint8_t> out(in.size());
  for (int32_t v = 0; v < w; ++v) {
    in[static_cast<size_t>(v) * 4u + 0u] = static_cast<uint8_t>(v);
    in[static_cast<size_t>(v) * 4u + 1u] = static_cast<uint8_t>(v);
    in[static_cast<size_t>(v) * 4u + 2u] = static_cast<uint8_t>(v);
    in[static_cast<size_t>(v) * 4u + 3u] = 255u;
  }

  const FsDnaRescueParams params =
      make_params(0.70f, 0.55f, 0.90f, FS_DNA_MODE_SOOC_SAFE, 1);
  const int32_t rc = fs_dna_rescue_apply_rgba_into(
      in.data(), in.size(), w, h, &params, out.data(), out.size());
  expect(rc == FS_OK, "Suite 9 black floor guard call must succeed");

  for (int32_t v = 0; v < w; ++v) {
    const size_t i = static_cast<size_t>(v) * 4u;
    const float y_in = rec709_luma_u8(in[i], in[i + 1u], in[i + 2u]) * 255.0f;
    const float y_out =
        rec709_luma_u8(out[i], out[i + 1u], out[i + 2u]) * 255.0f;
    expect(
        (y_out - y_in) <= 4.0f + 1e-4f,
        "Suite 9: near-black Y in [0..8]/255 must lift <= 4 levels (no gray haze)");
  }
}

// 10. Portrait Skin Midtone Isolation (Y in [102..140]/255 at shadow_lift=0.70, SOOC_SAFE)
void test_portrait_skin_midtone_isolation() {
  struct Rgb {
    uint8_t r, g, b;
  };
  std::vector<Rgb> samples;
  for (int v = 102; v <= 140; ++v) {
    samples.push_back(
        {static_cast<uint8_t>(v), static_cast<uint8_t>(v), static_cast<uint8_t>(v)});
  }
  samples.push_back({175u, 130u, 108u});
  samples.push_back({150u, 110u, 92u});
  samples.push_back({130u, 96u, 80u});
  samples.push_back({142u, 105u, 88u});
  samples.push_back({162u, 120u, 99u});

  const int32_t w = static_cast<int32_t>(samples.size());
  std::vector<uint8_t> in(samples.size() * 4u);
  std::vector<uint8_t> out(in.size());
  for (size_t idx = 0; idx < samples.size(); ++idx) {
    in[idx * 4u + 0u] = samples[idx].r;
    in[idx * 4u + 1u] = samples[idx].g;
    in[idx * 4u + 2u] = samples[idx].b;
    in[idx * 4u + 3u] = 255u;
  }

  const FsDnaRescueParams params =
      make_params(0.70f, 0.55f, 0.90f, FS_DNA_MODE_SOOC_SAFE, 1);
  const int32_t rc = fs_dna_rescue_apply_rgba_into(
      in.data(), in.size(), w, 1, &params, out.data(), out.size());
  expect(rc == FS_OK, "Suite 10 portrait skin isolation call must succeed");

  for (size_t idx = 0; idx < samples.size(); ++idx) {
    const size_t i = idx * 4u;
    const float y_in = rec709_luma_u8(in[i], in[i + 1u], in[i + 2u]) * 255.0f;
    const float y_out =
        rec709_luma_u8(out[i], out[i + 1u], out[i + 2u]) * 255.0f;
    expect(
        std::fabs(y_out - y_in) <= 2.0f + 1e-4f,
        "Suite 10: portrait skin midtone |out_luma - in_luma| must be <= 2 levels");
    expect(
        std::abs(static_cast<int>(out[i + 0u]) - static_cast<int>(in[i + 0u])) <= 3 &&
            std::abs(static_cast<int>(out[i + 1u]) - static_cast<int>(in[i + 1u])) <= 3 &&
            std::abs(static_cast<int>(out[i + 2u]) - static_cast<int>(in[i + 2u])) <= 3,
        "Suite 10: portrait skin midtone per-channel delta must be <= 3 levels");
  }
}

}  // namespace

int main() {
  std::mt19937_64 rng(kSeed);

  test_identity_bit_exact(rng);
  test_strict_monotonicity(rng);
  test_midtone_highlight_anchor(rng);
  test_black_anchor_and_alpha(rng);
  test_saturated_and_inplace();
  test_odd_dimensions_tail_safety(rng);
  test_error_and_fuzz_bounds();
  test_auto_analyze_and_perf(rng);
  test_zero_haze_black_floor_guard();
  test_portrait_skin_midtone_isolation();

  if (g_failures > 0) {
    std::cerr << "dna_rescue_property_test FAILED with " << g_failures
              << " failure(s).\n";
    return 1;
  }
  std::cout << "dna_rescue_property_test PASSED (all 10 property suites green).\n";
  return 0;
}
