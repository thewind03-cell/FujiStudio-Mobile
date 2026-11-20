#include "fujistudio_c_api.h"

#include <cstdlib>
#include <limits>

namespace {

constexpr const char* kCoreVersion = "0.1.0-day0";

}  // namespace

extern "C" {

FS_API const char* fs_core_version(void) {
  return kCoreVersion;
}

FS_API int32_t fs_invert_rgba_smoke(
    const uint8_t* input_rgba,
    size_t input_len,
    int32_t width,
    int32_t height,
    uint8_t** out_rgba,
    size_t* out_len) {
  if (out_rgba != nullptr) {
    *out_rgba = nullptr;
  }
  if (out_len != nullptr) {
    *out_len = 0;
  }

  if (input_rgba == nullptr || out_rgba == nullptr || out_len == nullptr) {
    return FS_ERR_NULL_POINTER;
  }

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

  const size_t byte_len = static_cast<size_t>(pixel_count * 4ULL);
  if (input_len < byte_len) {
    return FS_ERR_INVALID_DIMENSIONS;
  }

  auto* buffer = static_cast<uint8_t*>(std::malloc(byte_len));
  if (buffer == nullptr) {
    return FS_ERR_ALLOC_FAILED;
  }

  for (size_t i = 0; i < byte_len; i += 4) {
    buffer[i + 0] = static_cast<uint8_t>(255U - input_rgba[i + 0]);
    buffer[i + 1] = static_cast<uint8_t>(255U - input_rgba[i + 1]);
    buffer[i + 2] = static_cast<uint8_t>(255U - input_rgba[i + 2]);
    buffer[i + 3] = input_rgba[i + 3];
  }

  *out_rgba = buffer;
  *out_len = byte_len;
  return FS_OK;
}

FS_API void fs_free_buffer(uint8_t* ptr) {
  std::free(ptr);
}

}  // extern "C"
