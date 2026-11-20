#ifndef FUJISTUDIO_C_API_H
#define FUJISTUDIO_C_API_H

#include <stddef.h>
#include <stdint.h>

/**
 * Safe upper bound for a single image axis (width or height).
 * Accommodates 26MP/40MP/100MP sensors while preventing multi-GB allocations
 * and signed 32-bit byte-length overflows.
 */
#define FS_MAX_IMAGE_DIMENSION 16384

#if defined(_WIN32) || defined(__CYGWIN__)
  #if defined(FUJISTUDIO_CORE_EXPORTS)
    #define FS_API __declspec(dllexport)
  #elif defined(FUJISTUDIO_CORE_STATIC)
    #define FS_API
  #else
    #define FS_API __declspec(dllimport)
  #endif
#else
  #define FS_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/** Standard status / error codes returned by FujiStudio C ABI functions. */
enum FsStatusCode {
  FS_OK = 0,
  FS_ERR_NULL_POINTER = -1,
  FS_ERR_INVALID_DIMENSIONS = -2,
  FS_ERR_OVERFLOW = -3,
  FS_ERR_ALLOC_FAILED = -4
};

/**
 * Returns the static null-terminated version string of the FujiStudio C++ core.
 * Returned pointer has static storage duration; caller must NOT free it.
 */
FS_API const char* fs_core_version(void);

/**
 * Smoke-test RGBA8888 pixel inverter: allocates an output buffer, inverts R/G/B
 * channels (255 - c) while preserving Alpha unchanged.
 *
 * Caller MUST pass the true byte length of `input_rgba` in `input_len`.
 * Caller owns `*out_rgba` on success (FS_OK) and MUST release it via
 * `fs_free_buffer(*out_rgba)`. On error, `*out_rgba` is set to NULL and
 * `*out_len` is set to 0 when those pointers are non-NULL.
 */
FS_API int32_t fs_invert_rgba_smoke(
    const uint8_t* input_rgba,
    size_t input_len,
    int32_t width,
    int32_t height,
    uint8_t** out_rgba,
    size_t* out_len);

/**
 * Releases a buffer previously allocated by the FujiStudio C++ core.
 * Passing NULL is a safe no-op.
 */
FS_API void fs_free_buffer(uint8_t* ptr);

#ifdef __cplusplus
}
#endif

#endif /* FUJISTUDIO_C_API_H */
