#include "fujistudio_c_api.h"

#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <vector>

namespace {

int g_failures = 0;

void expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "[FAIL] " << message << "\n";
    ++g_failures;
  }
}

void test_version() {
  const char* ver = fs_core_version();
  expect(ver != nullptr, "fs_core_version() must not return null");
  expect(std::strcmp(ver, "0.1.0-day0") == 0,
         "fs_core_version() must equal 0.1.0-day0");
}

void test_invert_rgba_basic() {
  const uint8_t input[8] = {
      0, 128, 255, 200,  // pixel 0
      10, 20, 30, 0      // pixel 1
  };
  uint8_t* out = nullptr;
  size_t out_len = 0;

  const int32_t rc =
      fs_invert_rgba_smoke(input, sizeof(input), 2, 1, &out, &out_len);
  expect(rc == FS_OK, "invert basic should return FS_OK");
  expect(out != nullptr, "invert basic output pointer must be non-null");
  expect(out_len == 8, "invert basic output length must be 8");

  if (out != nullptr && out_len == 8) {
    expect(out[0] == 255 && out[1] == 127 && out[2] == 0 && out[3] == 200,
           "pixel 0 RGB inverted and Alpha preserved");
    expect(out[4] == 245 && out[5] == 235 && out[6] == 225 && out[7] == 0,
           "pixel 1 RGB inverted and Alpha preserved");
  }

  // Round-trip double inversion must restore original input bit-for-bit.
  uint8_t* roundtrip = nullptr;
  size_t roundtrip_len = 0;
  const int32_t rc2 =
      fs_invert_rgba_smoke(out, out_len, 2, 1, &roundtrip, &roundtrip_len);
  expect(rc2 == FS_OK, "second inversion should return FS_OK");
  expect(roundtrip != nullptr && roundtrip_len == 8, "roundtrip length should be 8");
  if (roundtrip != nullptr && roundtrip_len == 8) {
    expect(std::memcmp(input, roundtrip, 8) == 0,
           "double inversion must match original bytes");
  }

  fs_free_buffer(roundtrip);
  fs_free_buffer(out);
}

void test_invert_rgba_64x64() {
  constexpr int32_t kWidth = 64;
  constexpr int32_t kHeight = 64;
  constexpr size_t kBytes = static_cast<size_t>(kWidth * kHeight * 4);
  std::vector<uint8_t> input(kBytes);
  for (size_t i = 0; i < kBytes; i += 4) {
    input[i + 0] = static_cast<uint8_t>((i / 4) & 0xFFU);
    input[i + 1] = static_cast<uint8_t>(((i / 4) * 3) & 0xFFU);
    input[i + 2] = static_cast<uint8_t>(((i / 4) * 7) & 0xFFU);
    input[i + 3] = static_cast<uint8_t>(255U - ((i / 4) & 0x3FU));
  }

  uint8_t* out = nullptr;
  size_t out_len = 0;
  const int32_t rc = fs_invert_rgba_smoke(
      input.data(), input.size(), kWidth, kHeight, &out, &out_len);
  expect(rc == FS_OK, "64x64 inversion should return FS_OK");
  expect(out != nullptr && out_len == kBytes, "64x64 output size mismatch");
  if (out != nullptr && out_len == kBytes) {
    bool all_match = true;
    for (size_t i = 0; i < kBytes; i += 4) {
      if (out[i + 0] != static_cast<uint8_t>(255U - input[i + 0]) ||
          out[i + 1] != static_cast<uint8_t>(255U - input[i + 1]) ||
          out[i + 2] != static_cast<uint8_t>(255U - input[i + 2]) ||
          out[i + 3] != input[i + 3]) {
        all_match = false;
        break;
      }
    }
    expect(all_match, "all 64x64 pixels must invert RGB and keep Alpha");
  }
  fs_free_buffer(out);
}

void test_invalid_inputs() {
  const uint8_t dummy[4] = {1, 2, 3, 255};
  uint8_t* out = reinterpret_cast<uint8_t*>(0x1);
  size_t out_len = 999;

  expect(fs_invert_rgba_smoke(nullptr, sizeof(dummy), 1, 1, &out, &out_len) ==
             FS_ERR_NULL_POINTER,
         "null input must return FS_ERR_NULL_POINTER");
  expect(out == nullptr && out_len == 0, "error path must reset outputs");

  expect(fs_invert_rgba_smoke(dummy, sizeof(dummy), 1, 1, nullptr, &out_len) ==
             FS_ERR_NULL_POINTER,
         "null out_rgba must return FS_ERR_NULL_POINTER");
  expect(fs_invert_rgba_smoke(dummy, sizeof(dummy), 1, 1, &out, nullptr) ==
             FS_ERR_NULL_POINTER,
         "null out_len must return FS_ERR_NULL_POINTER");

  expect(fs_invert_rgba_smoke(dummy, sizeof(dummy), 0, 1, &out, &out_len) ==
             FS_ERR_INVALID_DIMENSIONS,
         "zero width must return FS_ERR_INVALID_DIMENSIONS");
  expect(fs_invert_rgba_smoke(dummy, sizeof(dummy), 1, 0, &out, &out_len) ==
             FS_ERR_INVALID_DIMENSIONS,
         "zero height must return FS_ERR_INVALID_DIMENSIONS");
  expect(fs_invert_rgba_smoke(dummy, sizeof(dummy), -4, 4, &out, &out_len) ==
             FS_ERR_INVALID_DIMENSIONS,
         "negative width must return FS_ERR_INVALID_DIMENSIONS");
  expect(fs_invert_rgba_smoke(dummy, sizeof(dummy), 4, -4, &out, &out_len) ==
             FS_ERR_INVALID_DIMENSIONS,
         "negative height must return FS_ERR_INVALID_DIMENSIONS");

  // Null free must be safe.
  fs_free_buffer(nullptr);
}

void test_buffer_length_and_overflow_guards() {
  // 1. Undersized input buffer (4 bytes passed for 2x1 = 8 bytes required).
  const uint8_t one_pixel[4] = {10, 20, 30, 255};
  uint8_t* out = reinterpret_cast<uint8_t*>(0x1);
  size_t out_len = 123;

  const int32_t rc_short =
      fs_invert_rgba_smoke(one_pixel, sizeof(one_pixel), 2, 1, &out, &out_len);
  expect(rc_short == FS_ERR_INVALID_DIMENSIONS,
         "undersized input_len must return FS_ERR_INVALID_DIMENSIONS");
  expect(out == nullptr && out_len == 0,
         "undersized input_len error path must reset outputs");

  // 2. Dimensions exceeding FS_MAX_IMAGE_DIMENSION (20000x20000).
  out = reinterpret_cast<uint8_t*>(0x1);
  out_len = 456;
  const int32_t rc_20k = fs_invert_rgba_smoke(
      one_pixel, sizeof(one_pixel), 20000, 20000, &out, &out_len);
  expect(rc_20k == FS_ERR_OVERFLOW,
         "20000x20000 must return FS_ERR_OVERFLOW");
  expect(out == nullptr && out_len == 0,
         "overflow error path must reset outputs");

  // 3. Single axis exceeding FS_MAX_IMAGE_DIMENSION.
  expect(fs_invert_rgba_smoke(one_pixel, sizeof(one_pixel),
                              FS_MAX_IMAGE_DIMENSION + 1, 1, &out, &out_len) ==
             FS_ERR_OVERFLOW,
         "width > FS_MAX_IMAGE_DIMENSION must return FS_ERR_OVERFLOW");
  expect(fs_invert_rgba_smoke(one_pixel, sizeof(one_pixel), 1,
                              FS_MAX_IMAGE_DIMENSION + 1, &out, &out_len) ==
             FS_ERR_OVERFLOW,
         "height > FS_MAX_IMAGE_DIMENSION must return FS_ERR_OVERFLOW");

  // 4. Extreme INT32_MAX x INT32_MAX overflow guard.
  constexpr int32_t kMaxI32 = std::numeric_limits<int32_t>::max();
  expect(fs_invert_rgba_smoke(one_pixel, sizeof(one_pixel), kMaxI32, kMaxI32,
                              &out, &out_len) == FS_ERR_OVERFLOW,
         "INT32_MAX x INT32_MAX must return FS_ERR_OVERFLOW");
}

}  // namespace

int main() {
  test_version();
  test_invert_rgba_basic();
  test_invert_rgba_64x64();
  test_invalid_inputs();
  test_buffer_length_and_overflow_guards();

  if (g_failures > 0) {
    std::cerr << "core_abi_test FAILED with " << g_failures << " failure(s).\n";
    return 1;
  }
  std::cout << "core_abi_test PASSED (all assertions green).\n";
  return 0;
}
