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

#define FS_RAF_MIN_HEADER_BYTES   92u
#define FS_RAF_MIN_JPEG_BYTES     128u
#define FS_RAF_MAX_JPEG_BYTES     (32u * 1024u * 1024u)
#define FS_RAF_CAMERA_MODEL_MAX   33u

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
  FS_ERR_ALLOC_FAILED = -4,

  FS_ERR_IO_OPEN_FAILED       = -10,
  FS_ERR_IO_READ_FAILED       = -11,
  FS_ERR_IO_WRITE_FAILED      = -12,
  FS_ERR_RAF_INVALID_MAGIC    = -13,
  FS_ERR_RAF_TRUNCATED        = -14,
  FS_ERR_RAF_INVALID_RANGE    = -15,
  FS_ERR_RAF_JPEG_TOO_LARGE   = -16,
  FS_ERR_JPEG_INVALID_SOI     = -17,
  FS_ERR_JPEG_INVALID_EOI     = -18,
  FS_ERR_UNSUPPORTED_PLATFORM = -19
};

typedef enum FsExifOrientation {
  FS_ORIENTATION_NORMAL     = 1,
  FS_ORIENTATION_FLIP_H     = 2,
  FS_ORIENTATION_ROTATE_180 = 3,
  FS_ORIENTATION_FLIP_V     = 4,
  FS_ORIENTATION_TRANSPOSE  = 5,
  FS_ORIENTATION_ROTATE_90  = 6,
  FS_ORIENTATION_TRANSVERSE = 7,
  FS_ORIENTATION_ROTATE_270 = 8
} FsExifOrientation;

/** Explicit 56-byte POD layout for Dart ffigen compatibility. */
typedef struct FsRafMetadata {
  uint32_t jpeg_offset;
  uint32_t jpeg_length;
  uint32_t jpeg_width;
  uint32_t jpeg_height;
  uint8_t  exif_orientation;
  uint8_t  has_exif_tag;
  uint8_t  reserved[2];
  char     camera_model[FS_RAF_CAMERA_MODEL_MAX];
  uint8_t  pad[3];
} FsRafMetadata;

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

/**
 * Extracts the embedded JPEG preview from an in-memory .RAF byte slice.
 * On success (FS_OK), caller owns `*out_jpeg` and MUST free it via
 * `fs_free_buffer(*out_jpeg)`. On error, `*out_jpeg` is set to NULL and
 * `*out_jpeg_len` is set to 0 when non-NULL.
 */
FS_API int32_t fs_raf_extract_jpeg_buffer(
    const uint8_t* raf_bytes,
    size_t raf_len,
    uint8_t** out_jpeg,
    size_t* out_jpeg_len,
    FsRafMetadata* out_meta);

/**
 * Extracts the embedded JPEG preview directly from a .RAF file path on disk
 * (reading only the 92-byte header and the embedded JPEG slice) and writes it
 * atomically to `out_jpeg_path_utf8`.
 */
FS_API int32_t fs_raf_extract_jpeg_from_path(
    const char* raf_path_utf8,
    const char* out_jpeg_path_utf8,
    FsRafMetadata* out_meta);

/**
 * Extracts the embedded JPEG preview from a POSIX file descriptor (`raf_fd`)
 * using `fstat` and `pread` without ever closing `raf_fd`, and writes it
 * atomically to `out_jpeg_path_utf8`. Returns FS_ERR_UNSUPPORTED_PLATFORM on
 * Windows.
 */
FS_API int32_t fs_raf_extract_jpeg_from_fd(
    int32_t raf_fd,
    const char* out_jpeg_path_utf8,
    FsRafMetadata* out_meta);

/**
 * Inspects a JPEG buffer for EXIF Orientation (0x0112) and SOF0/SOF2 width/height.
 */
FS_API int32_t fs_jpeg_inspect_buffer(
    const uint8_t* jpeg_bytes,
    size_t jpeg_len,
    uint8_t* out_orientation,
    uint8_t* out_has_exif_tag,
    uint32_t* out_width,
    uint32_t* out_height);

#ifdef __cplusplus
}
#endif

#endif /* FUJISTUDIO_C_API_H */
