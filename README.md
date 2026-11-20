# FujiStudio Mobile v1.0 (Day-0 Scaffold)

Android-first (iOS-ready) mobile companion to **FujiStudio Desktop v2.4.2**, built with **Flutter (Impeller)** and a **stateless C++20 core** bridged over `dart:ffi`.

## Architecture (Slice 0 Baseline)
- **Stateless C++20 Core (`native/`):**
  - Pure C ABI (`native/include/fujistudio_c_api.h`) exporting explicit `FS_API` symbols (`fs_core_version`, `fs_invert_rgba_smoke`, `fs_free_buffer`) with bounds checking (`input_len`, `FS_MAX_IMAGE_DIMENSION = 16384`, 32/64-bit overflow guards).
  - Dual-target CMake (`native/CMakeLists.txt`): `SHARED` (`libfujistudio_core.so`, 16 KB page aligned) on Android, `STATIC` (`FUJISTUDIO_BUILD_SHARED=OFF` default) on iOS, and host shared library + CTest (`core_abi_test` with ASan/UBSan when supported).
- **Long-Lived FFI Worker (`lib/core/ffi/native_worker.dart`):**
  - Single persistent background Isolate handling `dart:ffi` requests via `SendPort`/`ReceivePort`, with startup/crash/exit listeners, idempotent `dispose()`, and strict `try/finally` native memory cleanup (`fs_free_buffer`, `calloc.free`).
  - **26MP Memory Contract:** Full-resolution (26MP+) processing APIs in Slices 1–4 MUST pass file paths or native file descriptors to C++ rather than marshalling full-res RGBA buffers across the Isolate boundary. `TransferableTypedData` RGBA buffers are reserved for downsampled previews and Day-0 smoke verification.
- **Desktop v2.4.2 Schema Contract (`schemas/`, `lib/core/schema/`):**
  - Immutable Dart models (`SessionDocument`, `SessionItem`, `CullResult`, `EditRecipe`, `ActionProposal`, `CollageSpec`) enforcing `schema_version == "2.4.2"` and 100% **Unknown-Field Preservation** (including key presence, explicit `null` values, and original JSON `int`/`double` numeric types).
- **Scoped Storage & Release Hardening (`android/`):**
  - Scoped Storage permissions only (`READ_MEDIA_IMAGES` + `READ_EXTERNAL_STORAGE maxSdkVersion="32"`; `MANAGE_EXTERNAL_STORAGE` prohibited).
  - Flavors: `dev` (`org.fujistudio.mobile.dev`, `arm64-v8a` + `x86_64`) and `staging` (`org.fujistudio.mobile.staging`, `arm64-v8a` only enforced via `androidComponents` + R8/ProGuard + release keystore signing).

## Verification Commands
```powershell
# 1. Generate Dart FFI bindings (requires libclang; on Windows MinGW without MSVC, set C_INCLUDE_PATH)
dart run ffigen --config ffigen.yaml

# 2. Build & run C++20 host ABI tests (CTest + ASan/UBSan)
cmake -S native -B native/build-host
cmake --build native/build-host
ctest --test-dir native/build-host --output-on-failure

# 3. Analyze & run Flutter unit tests (Schema Round-Trip + NativeWorker FFI)
flutter pub get
flutter analyze
flutter test

# 4. Generate local staging keystore (optional, gitignored) & build staging release APK
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\gen_staging_keystore.ps1
flutter build apk --flavor staging --release --target-platform android-arm64
```
