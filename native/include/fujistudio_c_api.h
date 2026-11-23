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
  FS_ERR_UNSUPPORTED_PLATFORM = -19,

  FS_ERR_INVALID_PARAMS       = -20,
  FS_ERR_COLLAGE_INVALID_SLOTS = -21
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

typedef enum FsDnaRescueMode {
  FS_DNA_MODE_SOOC_SAFE   = 0,
  FS_DNA_MODE_DEEP_RESCUE = 1
} FsDnaRescueMode;

/** Normalized input parameters (24 bytes, explicit 4-byte alignment). */
typedef struct FsDnaRescueParams {
  float   shadow_lift;
  float   midtone_anchor;
  float   highlight_protect;
  int32_t mode;
  int32_t enabled;
  float   skin_protect;
} FsDnaRescueParams;

/** Auto-analyze suggestion output (24 bytes). */
typedef struct FsDnaRescueSuggestion {
  float   recommended_shadow_lift;
  float   p10_luma;
  float   p50_luma;
  float   p95_luma;
  float   shadow_pixel_ratio;
  int32_t recommended_mode;
} FsDnaRescueSuggestion;

/**
 * Applies DNA-Aware Shadow Rescue into caller-allocated `out_rgba`
 * (supports both in-place `out_rgba == input_rgba` and separate buffers).
 */
FS_API int32_t fs_dna_rescue_apply_rgba_into(
    const uint8_t* input_rgba,
    size_t input_len,
    int32_t width,
    int32_t height,
    const FsDnaRescueParams* params,
    uint8_t* out_rgba,
    size_t out_len);

/**
 * Analyzes shadow luma distribution of an RGBA8888 buffer for 1-tap Auto Rescue.
 */
FS_API int32_t fs_dna_rescue_analyze_rgba(
    const uint8_t* input_rgba,
    size_t input_len,
    int32_t width,
    int32_t height,
    FsDnaRescueSuggestion* out_suggestion);

typedef enum FsAspectPreset {
  FS_ASPECT_ORIGINAL = 0,
  FS_ASPECT_4_5      = 1,
  FS_ASPECT_1_1      = 2,
  FS_ASPECT_3_2      = 3,
  FS_ASPECT_9_16     = 4
} FsAspectPreset;

typedef enum FsCollageTemplate {
  FS_COLLAGE_SPLIT_2_V    = 0,
  FS_COLLAGE_SPLIT_2_H    = 1,
  FS_COLLAGE_GRID_3_STRIP = 2,
  FS_COLLAGE_GRID_3_TOP   = 3,
  FS_COLLAGE_GRID_3_LEFT  = 4,
  FS_COLLAGE_GRID_4_EVEN  = 5
} FsCollageTemplate;

typedef struct FsNormCropBox {
  float left;
  float top;
  float right;
  float bottom;
} FsNormCropBox;

typedef struct FsGeometryParams {
  float         rotation_deg;
  int32_t       aspect_preset;
  FsNormCropBox crop_box;
  int32_t       high_quality;
} FsGeometryParams;

typedef struct FsGeometryProposal {
  float         suggested_rotation_deg;
  float         horizon_confidence;
  FsNormCropBox suggested_crop_box;
  float         crop_confidence;
  float         saliency_cx;
  float         saliency_cy;
  int32_t       has_horizon_line;
  int32_t       target_aspect_preset;
} FsGeometryProposal;

typedef struct FsCollageInputSlot {
  const uint8_t* rgba;
  size_t         rgba_len;
  int32_t        width;
  int32_t        height;
  float          pan_x;
  float          pan_y;
  float          zoom;
  int32_t        reserved;
} FsCollageInputSlot;

typedef struct FsCollageConfig {
  int32_t template_id;
  int32_t canvas_width;
  int32_t canvas_height;
  int32_t gutter_px;
  int32_t outer_margin_px;
  uint8_t bg_r;
  uint8_t bg_g;
  uint8_t bg_b;
  uint8_t bg_a;
} FsCollageConfig;

/**
 * Clamps a normalized crop box inside the zero-black-corners inscribed space
 * for the given source dimensions, rotation angle, and aspect preset.
 */
FS_API int32_t fs_geometry_clamp_crop(
    int32_t src_width,
    int32_t src_height,
    float rotation_deg,
    int32_t aspect_preset,
    const FsNormCropBox* requested_box,
    FsNormCropBox* out_clamped_box,
    int32_t* out_pixel_width,
    int32_t* out_pixel_height);

/**
 * Analyzes an RGBA8888 buffer for automatic horizon leveling and saliency-based
 * social aspect cropping.
 */
FS_API int32_t fs_geometry_analyze_rgba(
    const uint8_t* input_rgba,
    size_t input_len,
    int32_t width,
    int32_t height,
    int32_t target_aspect_preset,
    FsGeometryProposal* out_proposal);

/**
 * Renders rotated and cropped RGBA8888 output into caller-allocated `out_rgba`.
 * In-place aliasing (`out_rgba == input_rgba`) is rejected with FS_ERR_INVALID_PARAMS.
 */
FS_API int32_t fs_geometry_render_rgba_into(
    const uint8_t* input_rgba,
    size_t input_len,
    int32_t src_width,
    int32_t src_height,
    const FsGeometryParams* params,
    uint8_t* out_rgba,
    size_t out_len,
    int32_t out_width,
    int32_t out_height);

/**
 * Stitches 2-4 RGBA8888 slot images into a caller-allocated story collage canvas.
 */
FS_API int32_t fs_collage_render_rgba_into(
    const FsCollageInputSlot* slots,
    int32_t slot_count,
    const FsCollageConfig* config,
    uint8_t* out_canvas_rgba,
    size_t out_canvas_len);

/**
 * Output Unsharp Mask configuration on luminance channel (20 bytes, explicit
 * 4-byte alignment).
 */
typedef struct FsOutputUsmParams {
  float   amount;      /**< [0.0, 1.5], e.g. 0.0 (off), 0.35 (subtle), 0.60 (standard) */
  float   radius;      /**< [0.5, 2.0] px, default 0.85 */
  float   threshold;   /**< [0.0, 20.0] on 0..255 luma scale, default 3.0 */
  float   halo_clamp;  /**< [0.0, 40.0] max amplitude on 0..255 scale, default 18.0 */
  int32_t enabled;     /**< 0 => bit-exact bypass */
} FsOutputUsmParams;

/**
 * Resizes an RGBA8888 buffer using a separable 2-pass weight-normalized
 * Lanczos3 (a = 3) filter into caller-allocated `out_rgba`.
 * Rejects in-place or overlapping buffers with FS_ERR_INVALID_PARAMS.
 * When `out_width == src_width && out_height == src_height`, copies bit-exactly.
 */
FS_API int32_t fs_export_lanczos3_resize_rgba_into(
    const uint8_t* input_rgba,
    size_t input_len,
    int32_t src_width,
    int32_t src_height,
    uint8_t* out_rgba,
    size_t out_len,
    int32_t out_width,
    int32_t out_height);

/**
 * Applies luma-only Output Sharpening (USM) into caller-allocated `out_rgba`.
 * Safely supports both in-place (`out_rgba == input_rgba`) and separate buffers.
 */
FS_API int32_t fs_export_output_usm_rgba_into(
    const uint8_t* input_rgba,
    size_t input_len,
    int32_t width,
    int32_t height,
    const FsOutputUsmParams* params,
    uint8_t* out_rgba,
    size_t out_len);

#ifdef __cplusplus
}
#endif

#endif /* FUJISTUDIO_C_API_H */
