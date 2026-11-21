#include "fujistudio_c_api.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>
#include <string>
#include <vector>

#if defined(_WIN32)
  #ifndef NOMINMAX
    #define NOMINMAX
  #endif
  #include <windows.h>
  #include <io.h>
  #include <process.h>
#else
  #include <fcntl.h>
  #include <sys/stat.h>
  #include <sys/types.h>
  #include <unistd.h>
#endif

namespace {

constexpr const char kRafMagic[16] = {
    'F', 'U', 'J', 'I', 'F', 'I', 'L', 'M',
    'C', 'C', 'D', '-', 'R', 'A', 'W', ' '};

constexpr size_t kRafModelOffset = 0x1Cu;
constexpr size_t kRafModelBytes = 32u;
constexpr size_t kRafJpegOffsetPos = 0x54u;
constexpr size_t kRafJpegLengthPos = 0x58u;
constexpr size_t kMaxTrailingZeroPad = 64u;
constexpr size_t kMaxJpegMarkers = 64u;
constexpr uint16_t kMaxIfdEntries = 512u;

std::atomic<uint64_t> g_temp_counter{0};

uint16_t read_be16(const uint8_t* p) noexcept {
  return static_cast<uint16_t>(
      (static_cast<uint16_t>(p[0]) << 8u) |
      static_cast<uint16_t>(p[1]));
}

uint32_t read_be32(const uint8_t* p) noexcept {
  return (static_cast<uint32_t>(p[0]) << 24u) |
         (static_cast<uint32_t>(p[1]) << 16u) |
         (static_cast<uint32_t>(p[2]) << 8u) |
         static_cast<uint32_t>(p[3]);
}

uint16_t read_le16(const uint8_t* p) noexcept {
  return static_cast<uint16_t>(
      static_cast<uint16_t>(p[0]) |
      (static_cast<uint16_t>(p[1]) << 8u));
}

uint32_t read_le32(const uint8_t* p) noexcept {
  return static_cast<uint32_t>(p[0]) |
         (static_cast<uint32_t>(p[1]) << 8u) |
         (static_cast<uint32_t>(p[2]) << 16u) |
         (static_cast<uint32_t>(p[3]) << 24u);
}

uint16_t read_tiff16(const uint8_t* p, bool big_endian) noexcept {
  return big_endian ? read_be16(p) : read_le16(p);
}

uint32_t read_tiff32(const uint8_t* p, bool big_endian) noexcept {
  return big_endian ? read_be32(p) : read_le32(p);
}

void init_metadata(FsRafMetadata* meta) noexcept {
  if (meta == nullptr) {
    return;
  }
  std::memset(meta, 0, sizeof(FsRafMetadata));
  meta->exif_orientation = static_cast<uint8_t>(FS_ORIENTATION_NORMAL);
  meta->has_exif_tag = 0;
}

struct ParsedRafHeader {
  uint32_t jpeg_offset = 0;
  uint32_t jpeg_length = 0;
  char camera_model[FS_RAF_CAMERA_MODEL_MAX]{};
};

int32_t parse_and_validate_raf_header(
    const uint8_t* header,
    size_t header_len,
    uint64_t file_size,
    ParsedRafHeader* out) noexcept {
  if (file_size < FS_RAF_MIN_HEADER_BYTES ||
      header_len < FS_RAF_MIN_HEADER_BYTES) {
    return FS_ERR_RAF_TRUNCATED;
  }

  if (std::memcmp(header, kRafMagic, sizeof(kRafMagic)) != 0) {
    return FS_ERR_RAF_INVALID_MAGIC;
  }

  std::memset(out->camera_model, 0, sizeof(out->camera_model));
  size_t model_len = 0;
  for (size_t i = 0; i < kRafModelBytes; ++i) {
    const uint8_t ch = header[kRafModelOffset + i];
    if (ch == 0u) {
      break;
    }
    if (ch >= 0x20u && ch <= 0x7Eu) {
      out->camera_model[model_len++] = static_cast<char>(ch);
    }
  }
  while (model_len > 0 && out->camera_model[model_len - 1] == ' ') {
    --model_len;
  }
  out->camera_model[model_len] = '\0';

  const uint32_t jpeg_offset = read_be32(header + kRafJpegOffsetPos);
  const uint32_t jpeg_length = read_be32(header + kRafJpegLengthPos);

  if (jpeg_offset < FS_RAF_MIN_HEADER_BYTES ||
      static_cast<uint64_t>(jpeg_offset) >= file_size) {
    return FS_ERR_RAF_INVALID_RANGE;
  }
  if (jpeg_length < FS_RAF_MIN_JPEG_BYTES) {
    return FS_ERR_RAF_INVALID_RANGE;
  }
  if (jpeg_length > FS_RAF_MAX_JPEG_BYTES) {
    return FS_ERR_RAF_JPEG_TOO_LARGE;
  }
  if (static_cast<uint64_t>(jpeg_length) >
      (file_size - static_cast<uint64_t>(jpeg_offset))) {
    return FS_ERR_RAF_INVALID_RANGE;
  }

  out->jpeg_offset = jpeg_offset;
  out->jpeg_length = jpeg_length;
  return FS_OK;
}

int32_t validate_and_trim_jpeg_slice(
    const uint8_t* jpeg_bytes,
    size_t raw_len,
    size_t* out_effective_len) noexcept {
  if (jpeg_bytes == nullptr || out_effective_len == nullptr) {
    return FS_ERR_NULL_POINTER;
  }
  if (raw_len < 2u || jpeg_bytes[0] != 0xFFu || jpeg_bytes[1] != 0xD8u) {
    return FS_ERR_JPEG_INVALID_SOI;
  }

  size_t trimmed_end = raw_len;
  size_t zero_count = 0;
  while (trimmed_end > 2u &&
         zero_count < kMaxTrailingZeroPad &&
         jpeg_bytes[trimmed_end - 1u] == 0x00u) {
    --trimmed_end;
    ++zero_count;
  }

  if (trimmed_end < 4u ||
      jpeg_bytes[trimmed_end - 2u] != 0xFFu ||
      jpeg_bytes[trimmed_end - 1u] != 0xD9u) {
    return FS_ERR_JPEG_INVALID_EOI;
  }

  *out_effective_len = trimmed_end;
  return FS_OK;
}

void parse_exif_app1_orientation(
    const uint8_t* tiff,
    size_t tiff_len,
    uint8_t* out_orientation,
    uint8_t* out_has_exif_tag) noexcept {
  if (tiff_len < 8u) {
    return;
  }

  bool big_endian = false;
  if (tiff[0] == 'I' && tiff[1] == 'I') {
    big_endian = false;
  } else if (tiff[0] == 'M' && tiff[1] == 'M') {
    big_endian = true;
  } else {
    return;
  }

  if (read_tiff16(tiff + 2u, big_endian) != 0x002Au) {
    return;
  }

  const uint32_t ifd0_offset = read_tiff32(tiff + 4u, big_endian);
  if (ifd0_offset < 8u ||
      static_cast<size_t>(ifd0_offset) > tiff_len - 2u) {
    return;
  }

  const uint16_t entry_count =
      read_tiff16(tiff + static_cast<size_t>(ifd0_offset), big_endian);
  const size_t entries_start = static_cast<size_t>(ifd0_offset) + 2u;
  const uint16_t clamped_count = std::min<uint16_t>(entry_count, kMaxIfdEntries);

  for (uint16_t i = 0; i < clamped_count; ++i) {
    const size_t entry_offset = entries_start + static_cast<size_t>(i) * 12u;
    if (entry_offset > tiff_len || (tiff_len - entry_offset) < 12u) {
      break;
    }

    const uint8_t* e = tiff + entry_offset;
    const uint16_t tag = read_tiff16(e + 0u, big_endian);
    if (tag == 0x0112u) {
      const uint16_t type = read_tiff16(e + 2u, big_endian);
      const uint32_t count = read_tiff32(e + 4u, big_endian);
      if (type == 3u && count == 1u) {
        const uint16_t val = read_tiff16(e + 8u, big_endian);
        if (val >= 1u && val <= 8u) {
          *out_orientation = static_cast<uint8_t>(val);
          *out_has_exif_tag = 1u;
        } else {
          *out_orientation = static_cast<uint8_t>(FS_ORIENTATION_NORMAL);
          *out_has_exif_tag = 0u;
        }
      }
      return;
    }
  }
}

int32_t inspect_jpeg_impl(
    const uint8_t* jpeg_bytes,
    size_t jpeg_len,
    uint8_t* out_orientation,
    uint8_t* out_has_exif_tag,
    uint32_t* out_width,
    uint32_t* out_height) noexcept {
  uint8_t local_orientation = static_cast<uint8_t>(FS_ORIENTATION_NORMAL);
  uint8_t local_has_exif = 0u;
  uint32_t local_width = 0u;
  uint32_t local_height = 0u;

  auto write_outputs = [&]() noexcept {
    if (out_orientation != nullptr) {
      *out_orientation = local_orientation;
    }
    if (out_has_exif_tag != nullptr) {
      *out_has_exif_tag = local_has_exif;
    }
    if (out_width != nullptr) {
      *out_width = local_width;
    }
    if (out_height != nullptr) {
      *out_height = local_height;
    }
  };

  write_outputs();

  if (jpeg_bytes == nullptr) {
    return FS_ERR_NULL_POINTER;
  }
  if (jpeg_len < 4u || jpeg_bytes[0] != 0xFFu || jpeg_bytes[1] != 0xD8u) {
    return FS_ERR_JPEG_INVALID_SOI;
  }

  size_t pos = 2u;
  bool parsed_exif = false;
  bool parsed_sof = false;

  for (size_t marker_idx = 0;
       marker_idx < kMaxJpegMarkers && pos < jpeg_len;
       ++marker_idx) {
    if (jpeg_bytes[pos] != 0xFFu) {
      break;
    }
    while (pos < jpeg_len && jpeg_bytes[pos] == 0xFFu) {
      ++pos;
    }
    if (pos >= jpeg_len) {
      break;
    }

    const uint8_t marker = jpeg_bytes[pos++];
    if (marker == 0x00u) {
      continue;
    }
    if (marker == 0xD9u || marker == 0xDAu) {
      break;
    }
    if (marker == 0x01u || (marker >= 0xD0u && marker <= 0xD7u)) {
      continue;
    }

    if (jpeg_len - pos < 2u) {
      break;
    }
    const uint8_t* seg = jpeg_bytes + pos;
    const uint16_t seg_len = read_be16(seg);
    if (seg_len < 2u || static_cast<size_t>(seg_len) > (jpeg_len - pos)) {
      break;
    }

    if (!parsed_exif && marker == 0xE1u && seg_len >= 16u) {
      static constexpr char kExifPrefix[6] = {'E', 'x', 'i', 'f', '\0', '\0'};
      if (std::memcmp(seg + 2u, kExifPrefix, sizeof(kExifPrefix)) == 0) {
        parse_exif_app1_orientation(
            seg + 8u,
            static_cast<size_t>(seg_len) - 8u,
            &local_orientation,
            &local_has_exif);
        parsed_exif = true;
      }
    } else if (!parsed_sof && (marker == 0xC0u || marker == 0xC2u) &&
               seg_len >= 9u) {
      local_height = static_cast<uint32_t>(read_be16(seg + 3u));
      local_width = static_cast<uint32_t>(read_be16(seg + 5u));
      parsed_sof = true;
    }

    pos += static_cast<size_t>(seg_len);
    if (parsed_exif && parsed_sof) {
      break;
    }
  }

  write_outputs();
  return FS_OK;
}

void fill_metadata(
    const ParsedRafHeader& hdr,
    size_t effective_jpeg_len,
    uint8_t orientation,
    uint8_t has_exif_tag,
    uint32_t width,
    uint32_t height,
    FsRafMetadata* out_meta) noexcept {
  if (out_meta == nullptr) {
    return;
  }
  init_metadata(out_meta);
  out_meta->jpeg_offset = hdr.jpeg_offset;
  out_meta->jpeg_length = static_cast<uint32_t>(effective_jpeg_len);
  out_meta->jpeg_width = width;
  out_meta->jpeg_height = height;
  out_meta->exif_orientation = orientation;
  out_meta->has_exif_tag = has_exif_tag;
  std::memcpy(
      out_meta->camera_model,
      hdr.camera_model,
      sizeof(out_meta->camera_model));
}

#if defined(_WIN32)
bool utf8_to_wide(const char* utf8, std::wstring* out) {
  if (utf8 == nullptr || out == nullptr) {
    return false;
  }
  if (utf8[0] == '\0') {
    return false;
  }
  const int needed = MultiByteToWideChar(
      CP_UTF8,
      MB_ERR_INVALID_CHARS,
      utf8,
      -1,
      nullptr,
      0);
  if (needed <= 0) {
    return false;
  }
  std::wstring wide(static_cast<size_t>(needed), L'\0');
  const int written = MultiByteToWideChar(
      CP_UTF8,
      MB_ERR_INVALID_CHARS,
      utf8,
      -1,
      wide.data(),
      needed);
  if (written <= 0) {
    return false;
  }
  if (!wide.empty() && wide.back() == L'\0') {
    wide.pop_back();
  }
  *out = std::move(wide);
  return true;
}
#endif

uint64_t current_pid_u64() noexcept {
#if defined(_WIN32)
  return static_cast<uint64_t>(_getpid());
#else
  return static_cast<uint64_t>(::getpid());
#endif
}

int32_t write_file_atomically(
    const char* out_path_utf8,
    const uint8_t* data,
    size_t len) {
  if (out_path_utf8 == nullptr || out_path_utf8[0] == '\0' || data == nullptr) {
    return FS_ERR_NULL_POINTER;
  }

  const uint64_t pid = current_pid_u64();
  const uint64_t seq = g_temp_counter.fetch_add(1u, std::memory_order_relaxed);
  const std::string tmp_path_utf8 =
      std::string(out_path_utf8) + ".tmp." + std::to_string(pid) + "." +
      std::to_string(seq);

#if defined(_WIN32)
  std::wstring dst_w;
  std::wstring tmp_w;
  if (!utf8_to_wide(out_path_utf8, &dst_w) ||
      !utf8_to_wide(tmp_path_utf8.c_str(), &tmp_w)) {
    return FS_ERR_IO_WRITE_FAILED;
  }

  FILE* fp = _wfopen(tmp_w.c_str(), L"wb");
  if (fp == nullptr) {
    return FS_ERR_IO_WRITE_FAILED;
  }

  size_t total_written = 0;
  while (total_written < len) {
    const size_t chunk = std::fwrite(
        data + total_written,
        1u,
        len - total_written,
        fp);
    if (chunk == 0u) {
      std::fclose(fp);
      DeleteFileW(tmp_w.c_str());
      return FS_ERR_IO_WRITE_FAILED;
    }
    total_written += chunk;
  }

  if (std::fflush(fp) != 0) {
    std::fclose(fp);
    DeleteFileW(tmp_w.c_str());
    return FS_ERR_IO_WRITE_FAILED;
  }
  _commit(_fileno(fp));
  if (std::fclose(fp) != 0) {
    DeleteFileW(tmp_w.c_str());
    return FS_ERR_IO_WRITE_FAILED;
  }

  if (!MoveFileExW(
          tmp_w.c_str(),
          dst_w.c_str(),
          MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(tmp_w.c_str());
    return FS_ERR_IO_WRITE_FAILED;
  }
  return FS_OK;
#else
  const int fd = ::open(
      tmp_path_utf8.c_str(),
      O_WRONLY | O_CREAT | O_TRUNC,
      0644);
  if (fd < 0) {
    return FS_ERR_IO_WRITE_FAILED;
  }

  size_t total_written = 0;
  while (total_written < len) {
    const ssize_t n = ::write(fd, data + total_written, len - total_written);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      ::close(fd);
      ::unlink(tmp_path_utf8.c_str());
      return FS_ERR_IO_WRITE_FAILED;
    }
    if (n == 0) {
      ::close(fd);
      ::unlink(tmp_path_utf8.c_str());
      return FS_ERR_IO_WRITE_FAILED;
    }
    total_written += static_cast<size_t>(n);
  }

  while (::fsync(fd) < 0) {
    if (errno != EINTR) {
      break;
    }
  }
  if (::close(fd) != 0) {
    ::unlink(tmp_path_utf8.c_str());
    return FS_ERR_IO_WRITE_FAILED;
  }

  if (std::rename(tmp_path_utf8.c_str(), out_path_utf8) != 0) {
    ::unlink(tmp_path_utf8.c_str());
    return FS_ERR_IO_WRITE_FAILED;
  }
  return FS_OK;
#endif
}

#if !defined(_WIN32)
bool pread_exact(int fd, uint8_t* dst, size_t len, uint64_t offset) noexcept {
  size_t total = 0;
  while (total < len) {
    const uint64_t pos = offset + static_cast<uint64_t>(total);
    if (pos > static_cast<uint64_t>(std::numeric_limits<off_t>::max())) {
      return false;
    }
    const ssize_t n = ::pread(
        fd,
        dst + total,
        len - total,
        static_cast<off_t>(pos));
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      return false;
    }
    if (n == 0) {
      return false;
    }
    total += static_cast<size_t>(n);
  }
  return true;
}
#endif

}  // namespace

extern "C" {

FS_API int32_t fs_jpeg_inspect_buffer(
    const uint8_t* jpeg_bytes,
    size_t jpeg_len,
    uint8_t* out_orientation,
    uint8_t* out_has_exif_tag,
    uint32_t* out_width,
    uint32_t* out_height) {
  try {
    return inspect_jpeg_impl(
        jpeg_bytes,
        jpeg_len,
        out_orientation,
        out_has_exif_tag,
        out_width,
        out_height);
  } catch (...) {
    return FS_ERR_ALLOC_FAILED;
  }
}

FS_API int32_t fs_raf_extract_jpeg_buffer(
    const uint8_t* raf_bytes,
    size_t raf_len,
    uint8_t** out_jpeg,
    size_t* out_jpeg_len,
    FsRafMetadata* out_meta) {
  if (out_jpeg != nullptr) {
    *out_jpeg = nullptr;
  }
  if (out_jpeg_len != nullptr) {
    *out_jpeg_len = 0;
  }
  init_metadata(out_meta);

  try {
    if (raf_bytes == nullptr || out_jpeg == nullptr || out_jpeg_len == nullptr) {
      return FS_ERR_NULL_POINTER;
    }

    ParsedRafHeader hdr;
    const int32_t hdr_rc = parse_and_validate_raf_header(
        raf_bytes,
        raf_len,
        static_cast<uint64_t>(raf_len),
        &hdr);
    if (hdr_rc != FS_OK) {
      return hdr_rc;
    }

    const uint8_t* jpeg_slice = raf_bytes + hdr.jpeg_offset;
    size_t effective_len = 0;
    const int32_t jpeg_rc = validate_and_trim_jpeg_slice(
        jpeg_slice,
        static_cast<size_t>(hdr.jpeg_length),
        &effective_len);
    if (jpeg_rc != FS_OK) {
      return jpeg_rc;
    }

    uint8_t orientation = static_cast<uint8_t>(FS_ORIENTATION_NORMAL);
    uint8_t has_exif_tag = 0u;
    uint32_t width = 0u;
    uint32_t height = 0u;
    const int32_t inspect_rc = inspect_jpeg_impl(
        jpeg_slice,
        effective_len,
        &orientation,
        &has_exif_tag,
        &width,
        &height);
    if (inspect_rc != FS_OK) {
      return inspect_rc;
    }

    auto* out_buf = static_cast<uint8_t*>(std::malloc(effective_len));
    if (out_buf == nullptr) {
      return FS_ERR_ALLOC_FAILED;
    }
    std::memcpy(out_buf, jpeg_slice, effective_len);

    *out_jpeg = out_buf;
    *out_jpeg_len = effective_len;
    fill_metadata(
        hdr,
        effective_len,
        orientation,
        has_exif_tag,
        width,
        height,
        out_meta);
    return FS_OK;
  } catch (const std::bad_alloc&) {
    if (out_jpeg != nullptr) {
      *out_jpeg = nullptr;
    }
    if (out_jpeg_len != nullptr) {
      *out_jpeg_len = 0;
    }
    return FS_ERR_ALLOC_FAILED;
  } catch (...) {
    if (out_jpeg != nullptr) {
      *out_jpeg = nullptr;
    }
    if (out_jpeg_len != nullptr) {
      *out_jpeg_len = 0;
    }
    return FS_ERR_ALLOC_FAILED;
  }
}

FS_API int32_t fs_raf_extract_jpeg_from_path(
    const char* raf_path_utf8,
    const char* out_jpeg_path_utf8,
    FsRafMetadata* out_meta) {
  init_metadata(out_meta);
  try {
    if (raf_path_utf8 == nullptr || out_jpeg_path_utf8 == nullptr) {
      return FS_ERR_NULL_POINTER;
    }
    if (raf_path_utf8[0] == '\0' || out_jpeg_path_utf8[0] == '\0') {
      return FS_ERR_IO_OPEN_FAILED;
    }

    FILE* fp = nullptr;
    uint64_t file_size = 0;

#if defined(_WIN32)
    std::wstring raf_w;
    if (!utf8_to_wide(raf_path_utf8, &raf_w)) {
      return FS_ERR_IO_OPEN_FAILED;
    }
    fp = _wfopen(raf_w.c_str(), L"rb");
    if (fp == nullptr) {
      return FS_ERR_IO_OPEN_FAILED;
    }
    if (_fseeki64(fp, 0, SEEK_END) != 0) {
      std::fclose(fp);
      return FS_ERR_IO_READ_FAILED;
    }
    const __int64 end_pos = _ftelli64(fp);
    if (end_pos < 0 || _fseeki64(fp, 0, SEEK_SET) != 0) {
      std::fclose(fp);
      return FS_ERR_IO_READ_FAILED;
    }
    file_size = static_cast<uint64_t>(end_pos);
#else
    fp = std::fopen(raf_path_utf8, "rb");
    if (fp == nullptr) {
      return FS_ERR_IO_OPEN_FAILED;
    }
    if (::fseeko(fp, 0, SEEK_END) != 0) {
      std::fclose(fp);
      return FS_ERR_IO_READ_FAILED;
    }
    const off_t end_pos = ::ftello(fp);
    if (end_pos < 0 || ::fseeko(fp, 0, SEEK_SET) != 0) {
      std::fclose(fp);
      return FS_ERR_IO_READ_FAILED;
    }
    file_size = static_cast<uint64_t>(end_pos);
#endif

    if (file_size < FS_RAF_MIN_HEADER_BYTES) {
      std::fclose(fp);
      return FS_ERR_RAF_TRUNCATED;
    }

    uint8_t header[FS_RAF_MIN_HEADER_BYTES];
    if (std::fread(header, 1u, sizeof(header), fp) != sizeof(header)) {
      std::fclose(fp);
      return FS_ERR_IO_READ_FAILED;
    }

    ParsedRafHeader hdr;
    const int32_t hdr_rc = parse_and_validate_raf_header(
        header,
        sizeof(header),
        file_size,
        &hdr);
    if (hdr_rc != FS_OK) {
      std::fclose(fp);
      return hdr_rc;
    }

#if defined(_WIN32)
    if (_fseeki64(fp, static_cast<__int64>(hdr.jpeg_offset), SEEK_SET) != 0) {
      std::fclose(fp);
      return FS_ERR_IO_READ_FAILED;
    }
#else
    if (::fseeko(fp, static_cast<off_t>(hdr.jpeg_offset), SEEK_SET) != 0) {
      std::fclose(fp);
      return FS_ERR_IO_READ_FAILED;
    }
#endif

    std::vector<uint8_t> jpeg_buf(static_cast<size_t>(hdr.jpeg_length));
    size_t total_read = 0;
    while (total_read < jpeg_buf.size()) {
      const size_t n = std::fread(
          jpeg_buf.data() + total_read,
          1u,
          jpeg_buf.size() - total_read,
          fp);
      if (n == 0u) {
        std::fclose(fp);
        return FS_ERR_IO_READ_FAILED;
      }
      total_read += n;
    }
    std::fclose(fp);

    size_t effective_len = 0;
    const int32_t jpeg_rc = validate_and_trim_jpeg_slice(
        jpeg_buf.data(),
        jpeg_buf.size(),
        &effective_len);
    if (jpeg_rc != FS_OK) {
      return jpeg_rc;
    }

    uint8_t orientation = static_cast<uint8_t>(FS_ORIENTATION_NORMAL);
    uint8_t has_exif_tag = 0u;
    uint32_t width = 0u;
    uint32_t height = 0u;
    const int32_t inspect_rc = inspect_jpeg_impl(
        jpeg_buf.data(),
        effective_len,
        &orientation,
        &has_exif_tag,
        &width,
        &height);
    if (inspect_rc != FS_OK) {
      return inspect_rc;
    }

    const int32_t write_rc = write_file_atomically(
        out_jpeg_path_utf8,
        jpeg_buf.data(),
        effective_len);
    if (write_rc != FS_OK) {
      return write_rc;
    }

    fill_metadata(
        hdr,
        effective_len,
        orientation,
        has_exif_tag,
        width,
        height,
        out_meta);
    return FS_OK;
  } catch (const std::bad_alloc&) {
    return FS_ERR_ALLOC_FAILED;
  } catch (...) {
    return FS_ERR_ALLOC_FAILED;
  }
}

FS_API int32_t fs_raf_extract_jpeg_from_fd(
    int32_t raf_fd,
    const char* out_jpeg_path_utf8,
    FsRafMetadata* out_meta) {
  init_metadata(out_meta);
  try {
    if (out_jpeg_path_utf8 == nullptr) {
      return FS_ERR_NULL_POINTER;
    }
#if defined(_WIN32)
    (void)raf_fd;
    return FS_ERR_UNSUPPORTED_PLATFORM;
#else
    if (raf_fd < 0) {
      return FS_ERR_IO_OPEN_FAILED;
    }
    if (out_jpeg_path_utf8[0] == '\0') {
      return FS_ERR_IO_WRITE_FAILED;
    }

    struct stat st{};
    if (::fstat(raf_fd, &st) != 0) {
      return FS_ERR_IO_READ_FAILED;
    }
    if (!S_ISREG(st.st_mode) || st.st_size < 0) {
      return FS_ERR_IO_READ_FAILED;
    }
    const uint64_t file_size = static_cast<uint64_t>(st.st_size);
    if (file_size < FS_RAF_MIN_HEADER_BYTES) {
      return FS_ERR_RAF_TRUNCATED;
    }

    uint8_t header[FS_RAF_MIN_HEADER_BYTES];
    if (!pread_exact(raf_fd, header, sizeof(header), 0u)) {
      return FS_ERR_IO_READ_FAILED;
    }

    ParsedRafHeader hdr;
    const int32_t hdr_rc = parse_and_validate_raf_header(
        header,
        sizeof(header),
        file_size,
        &hdr);
    if (hdr_rc != FS_OK) {
      return hdr_rc;
    }

    std::vector<uint8_t> jpeg_buf(static_cast<size_t>(hdr.jpeg_length));
    if (!pread_exact(
            raf_fd,
            jpeg_buf.data(),
            jpeg_buf.size(),
            static_cast<uint64_t>(hdr.jpeg_offset))) {
      return FS_ERR_IO_READ_FAILED;
    }

    size_t effective_len = 0;
    const int32_t jpeg_rc = validate_and_trim_jpeg_slice(
        jpeg_buf.data(),
        jpeg_buf.size(),
        &effective_len);
    if (jpeg_rc != FS_OK) {
      return jpeg_rc;
    }

    uint8_t orientation = static_cast<uint8_t>(FS_ORIENTATION_NORMAL);
    uint8_t has_exif_tag = 0u;
    uint32_t width = 0u;
    uint32_t height = 0u;
    const int32_t inspect_rc = inspect_jpeg_impl(
        jpeg_buf.data(),
        effective_len,
        &orientation,
        &has_exif_tag,
        &width,
        &height);
    if (inspect_rc != FS_OK) {
      return inspect_rc;
    }

    const int32_t write_rc = write_file_atomically(
        out_jpeg_path_utf8,
        jpeg_buf.data(),
        effective_len);
    if (write_rc != FS_OK) {
      return write_rc;
    }

    fill_metadata(
        hdr,
        effective_len,
        orientation,
        has_exif_tag,
        width,
        height,
        out_meta);
    return FS_OK;
#endif
  } catch (const std::bad_alloc&) {
    return FS_ERR_ALLOC_FAILED;
  } catch (...) {
    return FS_ERR_ALLOC_FAILED;
  }
}

}  // extern "C"
