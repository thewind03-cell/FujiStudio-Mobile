#include "fujistudio_c_api.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <random>
#include <string>
#include <vector>

namespace {

namespace fs = std::filesystem;

int g_failures = 0;

void expect(bool cond, const char* msg) {
  if (!cond) {
    std::cerr << "[FAIL] " << msg << "\n";
    ++g_failures;
  }
}

void write_be32(std::vector<uint8_t>& buf, size_t off, uint32_t v) {
  buf[off + 0] = static_cast<uint8_t>((v >> 24u) & 0xFFu);
  buf[off + 1] = static_cast<uint8_t>((v >> 16u) & 0xFFu);
  buf[off + 2] = static_cast<uint8_t>((v >> 8u) & 0xFFu);
  buf[off + 3] = static_cast<uint8_t>(v & 0xFFu);
}

void append_u16(std::vector<uint8_t>& buf, uint16_t v, bool big_endian) {
  if (big_endian) {
    buf.push_back(static_cast<uint8_t>((v >> 8u) & 0xFFu));
    buf.push_back(static_cast<uint8_t>(v & 0xFFu));
  } else {
    buf.push_back(static_cast<uint8_t>(v & 0xFFu));
    buf.push_back(static_cast<uint8_t>((v >> 8u) & 0xFFu));
  }
}

void append_u32(std::vector<uint8_t>& buf, uint32_t v, bool big_endian) {
  if (big_endian) {
    buf.push_back(static_cast<uint8_t>((v >> 24u) & 0xFFu));
    buf.push_back(static_cast<uint8_t>((v >> 16u) & 0xFFu));
    buf.push_back(static_cast<uint8_t>((v >> 8u) & 0xFFu));
    buf.push_back(static_cast<uint8_t>(v & 0xFFu));
  } else {
    buf.push_back(static_cast<uint8_t>(v & 0xFFu));
    buf.push_back(static_cast<uint8_t>((v >> 8u) & 0xFFu));
    buf.push_back(static_cast<uint8_t>((v >> 16u) & 0xFFu));
    buf.push_back(static_cast<uint8_t>((v >> 24u) & 0xFFu));
  }
}

std::vector<uint8_t> build_synthetic_jpeg(
    bool big_endian_tiff,
    uint16_t orientation,
    uint16_t width,
    uint16_t height,
    size_t min_total_bytes = 256,
    uint16_t extra_tail_junk = 0xFFFFu) {
  std::vector<uint8_t> jpeg;
  // SOI
  jpeg.push_back(0xFFu);
  jpeg.push_back(0xD8u);

  // Build TIFF payload for APP1
  std::vector<uint8_t> tiff;
  tiff.push_back(big_endian_tiff ? 'M' : 'I');
  tiff.push_back(big_endian_tiff ? 'M' : 'I');
  append_u16(tiff, 0x002Au, big_endian_tiff);
  append_u32(tiff, 8u, big_endian_tiff);  // IFD0 offset

  // IFD0: 2 entries (Make + Orientation)
  append_u16(tiff, 2u, big_endian_tiff);
  // Entry 0: dummy tag 0x010F
  append_u16(tiff, 0x010Fu, big_endian_tiff);
  append_u16(tiff, 2u, big_endian_tiff);
  append_u32(tiff, 4u, big_endian_tiff);
  tiff.push_back('F');
  tiff.push_back('U');
  tiff.push_back('J');
  tiff.push_back('\0');
  // Entry 1: Orientation (0x0112), SHORT(3), count=1
  append_u16(tiff, 0x0112u, big_endian_tiff);
  append_u16(tiff, 3u, big_endian_tiff);
  append_u32(tiff, 1u, big_endian_tiff);
  append_u16(tiff, orientation, big_endian_tiff);
  append_u16(tiff, extra_tail_junk, big_endian_tiff);

  // APP1 marker
  const uint16_t app1_len = static_cast<uint16_t>(2u + 6u + tiff.size());
  jpeg.push_back(0xFFu);
  jpeg.push_back(0xE1u);
  jpeg.push_back(static_cast<uint8_t>((app1_len >> 8u) & 0xFFu));
  jpeg.push_back(static_cast<uint8_t>(app1_len & 0xFFu));
  jpeg.push_back('E');
  jpeg.push_back('x');
  jpeg.push_back('i');
  jpeg.push_back('f');
  jpeg.push_back('\0');
  jpeg.push_back('\0');
  jpeg.insert(jpeg.end(), tiff.begin(), tiff.end());

  // SOF0 marker (0xFF 0xC0)
  // seg_len = 11 (2 len + 1 precision + 2 height + 2 width + 1 comp + 3 comp info)
  jpeg.push_back(0xFFu);
  jpeg.push_back(0xC0u);
  jpeg.push_back(0x00u);
  jpeg.push_back(0x0Bu);
  jpeg.push_back(8u);  // precision
  jpeg.push_back(static_cast<uint8_t>((height >> 8u) & 0xFFu));
  jpeg.push_back(static_cast<uint8_t>(height & 0xFFu));
  jpeg.push_back(static_cast<uint8_t>((width >> 8u) & 0xFFu));
  jpeg.push_back(static_cast<uint8_t>(width & 0xFFu));
  jpeg.push_back(1u);
  jpeg.push_back(1u);
  jpeg.push_back(0x11u);
  jpeg.push_back(0u);

  // SOS marker (0xFF 0xDA) + scan payload padded up to min_total_bytes
  jpeg.push_back(0xFFu);
  jpeg.push_back(0xDAu);
  jpeg.push_back(0x00u);
  jpeg.push_back(0x08u);
  jpeg.push_back(1u);
  jpeg.push_back(1u);
  jpeg.push_back(0u);
  jpeg.push_back(0u);
  jpeg.push_back(63u);
  jpeg.push_back(0u);

  while (jpeg.size() + 2u < min_total_bytes) {
    jpeg.push_back(0x5Au);
  }

  // EOI
  jpeg.push_back(0xFFu);
  jpeg.push_back(0xD9u);
  return jpeg;
}

std::vector<uint8_t> build_synthetic_raf(
    const std::string& camera_model,
    const std::vector<uint8_t>& jpeg,
    size_t trailing_zero_pad,
    size_t cfa_tail_bytes = 64) {
  const uint32_t jpeg_offset = 160u;
  const uint32_t jpeg_length =
      static_cast<uint32_t>(jpeg.size() + trailing_zero_pad);
  const size_t total_size =
      static_cast<size_t>(jpeg_offset) + static_cast<size_t>(jpeg_length) +
      cfa_tail_bytes;
  std::vector<uint8_t> raf(total_size, 0x00u);

  static constexpr char kMagic[16] = {
      'F', 'U', 'J', 'I', 'F', 'I', 'L', 'M',
      'C', 'C', 'D', '-', 'R', 'A', 'W', ' '};
  std::memcpy(raf.data(), kMagic, sizeof(kMagic));

  const size_t copy_len = std::min<size_t>(camera_model.size(), 32u);
  std::memcpy(raf.data() + 0x1Cu, camera_model.data(), copy_len);

  write_be32(raf, 0x54u, jpeg_offset);
  write_be32(raf, 0x58u, jpeg_length);

  std::memcpy(raf.data() + jpeg_offset, jpeg.data(), jpeg.size());
  // trailing_zero_pad bytes are already 0x00
  std::memset(
      raf.data() + jpeg_offset + jpeg_length,
      0xAA,
      cfa_tail_bytes);
  return raf;
}

// 1. SyntheticRafBuilder Property Test
void test_synthetic_raf_properties() {
  const int endians[2] = {0, 1};  // 0 = II, 1 = MM
  const size_t pads[3] = {0u, 2u, 16u};

  for (int endian : endians) {
    const bool big_endian = (endian == 1);
    for (uint16_t orientation = 1; orientation <= 8; ++orientation) {
      for (size_t pad : pads) {
        const auto expected_jpeg = build_synthetic_jpeg(
            big_endian,
            orientation,
            6240u,
            4160u,
            256u);
        const auto raf = build_synthetic_raf("X-T3   ", expected_jpeg, pad);

        uint8_t* out_jpeg = nullptr;
        size_t out_len = 0;
        FsRafMetadata meta{};
        const int32_t rc = fs_raf_extract_jpeg_buffer(
            raf.data(),
            raf.size(),
            &out_jpeg,
            &out_len,
            &meta);

        expect(rc == FS_OK, "SyntheticRafBuilder must return FS_OK");
        expect(out_jpeg != nullptr, "out_jpeg must be non-null");
        expect(
            out_len == expected_jpeg.size(),
            "out_len must match trimmed JPEG length bit-for-bit");
        if (out_jpeg != nullptr && out_len == expected_jpeg.size()) {
          expect(
              std::memcmp(out_jpeg, expected_jpeg.data(), out_len) == 0,
              "extracted JPEG bytes must match expected JPEG bit-for-bit");
        }
        expect(
            meta.exif_orientation == static_cast<uint8_t>(orientation),
            "meta.exif_orientation mismatch");
        expect(meta.has_exif_tag == 1u, "meta.has_exif_tag must be 1");
        expect(meta.jpeg_width == 6240u, "meta.jpeg_width must be 6240");
        expect(meta.jpeg_height == 4160u, "meta.jpeg_height must be 4160");
        expect(
            std::strcmp(meta.camera_model, "X-T3") == 0,
            "meta.camera_model must be trimmed to X-T3");

        fs_free_buffer(out_jpeg);
      }
    }
  }
}

// 2. Adversarial Unit Cases
void test_adversarial_cases() {
  uint8_t* out = reinterpret_cast<uint8_t*>(0x1);
  size_t out_len = 123;
  FsRafMetadata meta{};

  // Truncated headers 0..91 bytes (pass non-null data pointer even when len == 0)
  const uint8_t empty_sentinel = 0x00u;
  for (size_t len = 0; len < FS_RAF_MIN_HEADER_BYTES; ++len) {
    std::vector<uint8_t> short_buf(len, 0x00u);
    out = reinterpret_cast<uint8_t*>(0x1);
    out_len = 99;
    const uint8_t* ptr = short_buf.empty() ? &empty_sentinel : short_buf.data();
    const int32_t rc = fs_raf_extract_jpeg_buffer(
        ptr,
        short_buf.size(),
        &out,
        &out_len,
        &meta);
    expect(rc == FS_ERR_RAF_TRUNCATED, "0..91 byte buffer must return FS_ERR_RAF_TRUNCATED");
    expect(out == nullptr && out_len == 0, "error path must zero out_jpeg and out_len");
  }

  // Bad magic (missing trailing space)
  {
    auto jpeg = build_synthetic_jpeg(false, 1, 100, 100);
    auto raf = build_synthetic_raf("X-T3", jpeg, 0);
    raf[15] = '!';
    const int32_t rc = fs_raf_extract_jpeg_buffer(
        raf.data(),
        raf.size(),
        &out,
        &out_len,
        &meta);
    expect(rc == FS_ERR_RAF_INVALID_MAGIC, "bad magic must return FS_ERR_RAF_INVALID_MAGIC");
    expect(out == nullptr && out_len == 0, "bad magic must reset outputs");
  }

  // uint32_t addition overflow: jpeg_offset = 0xFFFFFF80, jpeg_length = 0x100
  {
    auto jpeg = build_synthetic_jpeg(false, 1, 100, 100);
    auto raf = build_synthetic_raf("X-T3", jpeg, 0);
    write_be32(raf, 0x54u, 0xFFFFFF80u);
    write_be32(raf, 0x58u, 0x100u);
    const int32_t rc = fs_raf_extract_jpeg_buffer(
        raf.data(),
        raf.size(),
        &out,
        &out_len,
        &meta);
    expect(rc == FS_ERR_RAF_INVALID_RANGE, "uint32 wrap overflow must return FS_ERR_RAF_INVALID_RANGE");
    expect(out == nullptr && out_len == 0, "overflow must reset outputs");
  }

  // jpeg_offset = 40 overlapping header
  {
    auto jpeg = build_synthetic_jpeg(false, 1, 100, 100);
    auto raf = build_synthetic_raf("X-T3", jpeg, 0);
    write_be32(raf, 0x54u, 40u);
    write_be32(raf, 0x58u, 200u);
    const int32_t rc = fs_raf_extract_jpeg_buffer(
        raf.data(),
        raf.size(),
        &out,
        &out_len,
        &meta);
    expect(rc == FS_ERR_RAF_INVALID_RANGE, "jpeg_offset=40 must return FS_ERR_RAF_INVALID_RANGE");
    expect(out == nullptr && out_len == 0, "overlapping offset must reset outputs");
  }

  // jpeg_length = 33 MB
  {
    auto jpeg = build_synthetic_jpeg(false, 1, 100, 100);
    auto raf = build_synthetic_raf("X-T3", jpeg, 0);
    write_be32(raf, 0x54u, 160u);
    write_be32(raf, 0x58u, 33u * 1024u * 1024u);
    const int32_t rc = fs_raf_extract_jpeg_buffer(
        raf.data(),
        raf.size(),
        &out,
        &out_len,
        &meta);
    expect(rc == FS_ERR_RAF_JPEG_TOO_LARGE, "33 MB jpeg_length must return FS_ERR_RAF_JPEG_TOO_LARGE");
    expect(out == nullptr && out_len == 0, "33 MB guard must reset outputs");
  }

  // APP1 seg_len = 0 and seg_len = 1
  for (uint16_t bad_seg_len : {uint16_t(0), uint16_t(1)}) {
    std::vector<uint8_t> jpeg = {
        0xFFu, 0xD8u,
        0xFFu, 0xE1u,
        static_cast<uint8_t>((bad_seg_len >> 8u) & 0xFFu),
        static_cast<uint8_t>(bad_seg_len & 0xFFu),
        'E', 'x', 'i', 'f', 0x00u, 0x00u,
        0xFFu, 0xD9u};
    uint8_t orientation = 0;
    uint8_t has_exif = 9;
    uint32_t w = 9, h = 9;
    const int32_t rc = fs_jpeg_inspect_buffer(
        jpeg.data(),
        jpeg.size(),
        &orientation,
        &has_exif,
        &w,
        &h);
    expect(rc == FS_OK, "malformed APP1 seg_len must not crash");
    expect(orientation == 1u && has_exif == 0u, "malformed APP1 seg_len must fallback to orientation=1, has_exif=0");
  }

  // TIFF ifd0_offset = 0xFFFFFFFF / entry_count = 65535 in 32-byte segment
  for (bool bad_ifd0 : {true, false}) {
    std::vector<uint8_t> seg_payload(32, 0x00u);
    // 'I','I', 0x002A LE
    seg_payload[0] = 'I';
    seg_payload[1] = 'I';
    seg_payload[2] = 0x2Au;
    seg_payload[3] = 0x00u;
    if (bad_ifd0) {
      seg_payload[4] = 0xFFu;
      seg_payload[5] = 0xFFu;
      seg_payload[6] = 0xFFu;
      seg_payload[7] = 0xFFu;
    } else {
      seg_payload[4] = 8u;
      seg_payload[8] = 0xFFu;
      seg_payload[9] = 0xFFu;  // entry_count = 65535
    }

    std::vector<uint8_t> jpeg = {0xFFu, 0xD8u, 0xFFu, 0xE1u};
    const uint16_t seg_len = static_cast<uint16_t>(2u + 6u + seg_payload.size());
    jpeg.push_back(static_cast<uint8_t>((seg_len >> 8u) & 0xFFu));
    jpeg.push_back(static_cast<uint8_t>(seg_len & 0xFFu));
    jpeg.insert(jpeg.end(), {'E', 'x', 'i', 'f', '\0', '\0'});
    jpeg.insert(jpeg.end(), seg_payload.begin(), seg_payload.end());
    jpeg.push_back(0xFFu);
    jpeg.push_back(0xD9u);

    uint8_t orientation = 0;
    uint8_t has_exif = 9;
    const int32_t rc = fs_jpeg_inspect_buffer(
        jpeg.data(),
        jpeg.size(),
        &orientation,
        &has_exif,
        nullptr,
        nullptr);
    expect(rc == FS_OK, "malformed TIFF bounds must not crash");
    expect(orientation == 1u && has_exif == 0u, "malformed TIFF bounds must fallback cleanly");
  }

  // Big-Endian MM with Orientation=6 at [8..9] and junk 0xFF 0xFF at [10..11]
  {
    const auto jpeg = build_synthetic_jpeg(true, 6u, 4000u, 3000u, 256u, 0xFFFFu);
    uint8_t orientation = 0;
    uint8_t has_exif = 0;
    uint32_t w = 0, h = 0;
    const int32_t rc = fs_jpeg_inspect_buffer(
        jpeg.data(),
        jpeg.size(),
        &orientation,
        &has_exif,
        &w,
        &h);
    expect(rc == FS_OK, "MM orientation=6 with junk tail must return FS_OK");
    expect(orientation == 6u, "MM orientation=6 must decode via uint16, not uint32");
    expect(has_exif == 1u, "MM orientation=6 must set has_exif_tag=1");
    expect(w == 4000u && h == 3000u, "MM SOF0 dimensions must decode accurately");
  }

  // Trailing 0x00 pad tolerance: 512 and 4096 bytes pass; 4097 bytes fail with FS_ERR_JPEG_INVALID_EOI
  {
    const auto jpeg = build_synthetic_jpeg(false, 1, 100, 100);
    for (size_t valid_pad : {size_t(512), size_t(4096)}) {
      const auto raf = build_synthetic_raf("X-T5", jpeg, valid_pad);
      uint8_t* pad_out = nullptr;
      size_t pad_len = 0;
      const int32_t rc = fs_raf_extract_jpeg_buffer(
          raf.data(), raf.size(), &pad_out, &pad_len, &meta);
      expect(rc == FS_OK, "RAF with 512/4096 trailing 0x00 pad must return FS_OK");
      expect(pad_out != nullptr && pad_len == jpeg.size(),
             "RAF with 512/4096 trailing 0x00 pad must trim to exact JPEG length");
      if (pad_out != nullptr && pad_len == jpeg.size()) {
        expect(std::memcmp(pad_out, jpeg.data(), pad_len) == 0,
               "RAF trimmed JPEG bytes must match bit-for-bit");
      }
      fs_free_buffer(pad_out);
    }

    const auto raf_over = build_synthetic_raf("X-T5", jpeg, 4097u);
    out = reinterpret_cast<uint8_t*>(0x1);
    out_len = 99;
    const int32_t rc_over = fs_raf_extract_jpeg_buffer(
        raf_over.data(), raf_over.size(), &out, &out_len, &meta);
    expect(rc_over == FS_ERR_JPEG_INVALID_EOI,
           "RAF with 4097 trailing 0x00 pad must return FS_ERR_JPEG_INVALID_EOI");
    expect(out == nullptr && out_len == 0u,
           "4097 pad rejection must reset outputs");
  }
}

// 3. Deterministic Seeded Mutation Fuzzing (10,000 samples)
void test_mutation_fuzzing() {
  constexpr uint64_t kSeed = 0x20261121F00DCAFEULL;
  constexpr size_t kIterations = 10000;
  std::mt19937_64 rng(kSeed);

  const auto base_jpeg = build_synthetic_jpeg(true, 6u, 6240u, 4160u, 256u);
  const auto base_raf = build_synthetic_raf("X-T5", base_jpeg, 4u, 128u);

  const uint32_t boundary_vals[4] = {
      0u,
      0xFFFFFFFFu,
      0x7FFFFFFFu,
      0x80000000u,
  };

  for (size_t iter = 0; iter < kIterations; ++iter) {
    const int op = static_cast<int>(rng() % 6u);
    std::vector<uint8_t> mutated = base_raf;

    switch (op) {
      case 0: {  // flip bits
        const size_t flips = 1u + (rng() % 8u);
        for (size_t f = 0; f < flips && !mutated.empty(); ++f) {
          const size_t idx = rng() % mutated.size();
          mutated[idx] ^= static_cast<uint8_t>(1u << (rng() % 8u));
        }
        break;
      }
      case 1: {  // truncate
        const size_t new_len = rng() % (mutated.size() + 1u);
        mutated.resize(new_len);
        break;
      }
      case 2: {  // overwrite boundary values
        if (mutated.size() >= 4u) {
          const size_t idx = rng() % (mutated.size() - 3u);
          const uint32_t val = boundary_vals[rng() % 4u];
          write_be32(mutated, idx, val);
        }
        break;
      }
      case 3: {  // insert fake 0xFF 0xE1
        const size_t pos = std::min<size_t>(
            mutated.size(),
            160u + (rng() % 128u));
        std::vector<uint8_t> fake_app1 = {
            0xFFu, 0xE1u,
            static_cast<uint8_t>(rng() & 0xFFu),
            static_cast<uint8_t>(rng() & 0xFFu),
            'E', 'x', 'i', 'f', '\0', '\0',
            'M', 'M', 0x00u, 0x2Au};
        mutated.insert(mutated.begin() + static_cast<std::ptrdiff_t>(pos),
                       fake_app1.begin(), fake_app1.end());
        break;
      }
      case 4: {  // delete EOI
        for (size_t i = 0; i + 1 < mutated.size(); ++i) {
          if (mutated[i] == 0xFFu && mutated[i + 1] == 0xD9u) {
            mutated[i] = 0x00u;
            mutated[i + 1] = 0x00u;
          }
        }
        break;
      }
      case 5: {  // pure random array
        const size_t len = rng() % 1024u;
        mutated.resize(len);
        for (size_t i = 0; i < len; ++i) {
          mutated[i] = static_cast<uint8_t>(rng() & 0xFFu);
        }
        break;
      }
    }

    uint8_t* out_jpeg = reinterpret_cast<uint8_t*>(0x1);
    size_t out_len = 777;
    FsRafMetadata meta{};
    const int32_t rc = fs_raf_extract_jpeg_buffer(
        mutated.empty() ? nullptr : mutated.data(),
        mutated.size(),
        &out_jpeg,
        &out_len,
        &meta);

    if (rc == FS_OK) {
      if (out_jpeg == nullptr ||
          out_len < 4u ||
          out_jpeg[0] != 0xFFu ||
          out_jpeg[1] != 0xD8u ||
          out_jpeg[out_len - 2u] != 0xFFu ||
          out_jpeg[out_len - 1u] != 0xD9u ||
          meta.exif_orientation < 1u ||
          meta.exif_orientation > 8u) {
        std::cerr << "[FAIL] Fuzz invariant violated at iter=" << iter
                  << " seed=" << kSeed << "\n";
        ++g_failures;
      }
      fs_free_buffer(out_jpeg);
    } else {
      if (out_jpeg != nullptr || out_len != 0u) {
        std::cerr << "[FAIL] Fuzz error output not reset at iter=" << iter
                  << " seed=" << kSeed << "\n";
        ++g_failures;
      }
    }

    // Also fuzz fs_jpeg_inspect_buffer directly on mutated slice.
    uint8_t orient = 0;
    uint8_t has_exif = 0;
    uint32_t w = 0, h = 0;
    const int32_t irc = fs_jpeg_inspect_buffer(
        mutated.empty() ? nullptr : mutated.data(),
        mutated.size(),
        &orient,
        &has_exif,
        &w,
        &h);
    if (irc == FS_OK && (orient < 1u || orient > 8u)) {
      std::cerr << "[FAIL] Fuzz inspect orientation out of range at iter="
                << iter << " seed=" << kSeed << "\n";
      ++g_failures;
    }
  }
}

// 4. File Path Extraction Test (4 KB JPEG + 20 MB fake CFA block)
void test_file_path_extraction() {
  const fs::path temp_dir =
      fs::temp_directory_path() / "fujistudio_raf_extractor_test";
  std::error_code ec;
  fs::remove_all(temp_dir, ec);
  fs::create_directories(temp_dir, ec);
  expect(!ec, "must create temp test directory");

  const auto jpeg_4kb = build_synthetic_jpeg(false, 8u, 1600u, 1067u, 4096u);
  expect(jpeg_4kb.size() == 4096u, "synthetic JPEG must be exactly 4096 bytes");

  constexpr size_t kCfaBytes = 20u * 1024u * 1024u;
  const auto raf = build_synthetic_raf("X-Pro3", jpeg_4kb, 8u, kCfaBytes);

  const fs::path raf_path = temp_dir / "sample_20mb.RAF";
  const fs::path out_jpeg_path = temp_dir / "extracted.jpg";
  {
    std::ofstream ofs(raf_path, std::ios::binary);
    ofs.write(
        reinterpret_cast<const char*>(raf.data()),
        static_cast<std::streamsize>(raf.size()));
    expect(ofs.good(), "must write 20MB synthetic RAF");
  }

  FsRafMetadata meta{};
  const int32_t rc = fs_raf_extract_jpeg_from_path(
      raf_path.string().c_str(),
      out_jpeg_path.string().c_str(),
      &meta);
  expect(rc == FS_OK, "fs_raf_extract_jpeg_from_path must return FS_OK");
  expect(meta.exif_orientation == 8u, "file extraction orientation must be 8");
  expect(meta.jpeg_width == 1600u && meta.jpeg_height == 1067u,
         "file extraction SOF dimensions mismatch");
  expect(std::strcmp(meta.camera_model, "X-Pro3") == 0,
         "file extraction camera_model must be X-Pro3");

  std::ifstream ifs(out_jpeg_path, std::ios::binary);
  std::vector<uint8_t> disk_jpeg(
      (std::istreambuf_iterator<char>(ifs)),
      std::istreambuf_iterator<char>());
  expect(disk_jpeg.size() == 4096u, "extracted JPEG on disk must be 4096 bytes");
  expect(disk_jpeg == jpeg_4kb, "extracted JPEG on disk must match bit-for-bit");

  bool found_tmp = false;
  for (const auto& entry : fs::directory_iterator(temp_dir)) {
    const std::string name = entry.path().filename().string();
    if (name.find(".tmp.") != std::string::npos) {
      found_tmp = true;
    }
  }
  expect(!found_tmp, "no .tmp.* files should remain after extraction");

  // Non-existent input path must return clean I/O error
  const fs::path missing_path = temp_dir / "does_not_exist.RAF";
  const int32_t missing_rc = fs_raf_extract_jpeg_from_path(
      missing_path.string().c_str(),
      out_jpeg_path.string().c_str(),
      &meta);
  expect(missing_rc == FS_ERR_IO_OPEN_FAILED,
         "missing input path must return FS_ERR_IO_OPEN_FAILED");

  fs::remove_all(temp_dir, ec);
}

}  // namespace

int main() {
  test_synthetic_raf_properties();
  test_adversarial_cases();
  test_mutation_fuzzing();
  test_file_path_extraction();

  if (g_failures > 0) {
    std::cerr << "raf_extractor_fuzz_test FAILED with " << g_failures
              << " failure(s).\n";
    return 1;
  }
  std::cout << "raf_extractor_fuzz_test PASSED (all 4 suites + 10,000 fuzz samples green).\n";
  return 0;
}
