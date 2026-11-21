cmake_minimum_required(VERSION 3.22)

project(fujistudio_core VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(IOS)
  set(_FS_DEFAULT_BUILD_SHARED OFF)
else()
  set(_FS_DEFAULT_BUILD_SHARED ON)
endif()

option(FUJISTUDIO_BUILD_SHARED "Build shared library" ${_FS_DEFAULT_BUILD_SHARED})

if(FUJISTUDIO_BUILD_SHARED)
  add_library(fujistudio_core SHARED
    src/fujistudio_c_api.cpp
    src/raf_preview_extractor.cpp
  )
  target_compile_definitions(fujistudio_core
    PRIVATE
      FUJISTUDIO_CORE_EXPORTS
  )
else()
  add_library(fujistudio_core STATIC
    src/fujistudio_c_api.cpp
    src/raf_preview_extractor.cpp
  )
  target_compile_definitions(fujistudio_core
    PUBLIC
      FUJISTUDIO_CORE_STATIC
  )
endif()

target_include_directories(fujistudio_core
  PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

if(ANDROID)
  # Android target: linked via Gradle externalNativeBuild -> libfujistudio_core.so
  target_compile_options(fujistudio_core PRIVATE
    -fvisibility=hidden
    -Wall
    -Wextra
    -Wpedantic
  )
  if(FUJISTUDIO_BUILD_SHARED)
    target_link_options(fujistudio_core PRIVATE
      -Wl,--gc-sections
      -Wl,-z,max-page-size=16384
    )
  endif()
elseif(IOS)
  # iOS target: static library linked into Runner for DynamicLibrary.process().
  target_compile_options(fujistudio_core PRIVATE
    -fvisibility=hidden
    -Wall
    -Wextra
    -Wpedantic
  )
else()
  # Host target: builds library for `flutter test` + native CTest binary.
  include(CTest)
  include(CheckCXXSourceCompiles)

  if(WIN32)
    set_target_properties(fujistudio_core PROPERTIES
      PREFIX ""
      OUTPUT_NAME "fujistudio_core"
      RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
      LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
      ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    )
  else()
    set_target_properties(fujistudio_core PROPERTIES
      LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
      RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    )
  endif()

  if(MSVC)
    target_compile_options(fujistudio_core PRIVATE /W4 /permissive-)
  else()
    target_compile_options(fujistudio_core PRIVATE
      -fvisibility=hidden
      -Wall
      -Wextra
      -Wpedantic
    )
  endif()

  # Enable AddressSanitizer/UBSan automatically on host compilers that support linking it.
  option(FUJISTUDIO_ENABLE_SANITIZERS "Enable host sanitizers when supported by compiler/linker" ON)
  set(_FS_SANITIZER_FLAGS "")
  if(FUJISTUDIO_ENABLE_SANITIZERS AND NOT MSVC)
    set(CMAKE_REQUIRED_FLAGS "-fsanitize=address,undefined")
    set(CMAKE_REQUIRED_LINK_OPTIONS "-fsanitize=address,undefined")
    check_cxx_source_compiles("int main() { return 0; }" FS_SUPPORTS_ASAN_UBSAN)
    unset(CMAKE_REQUIRED_FLAGS)
    unset(CMAKE_REQUIRED_LINK_OPTIONS)
    if(FS_SUPPORTS_ASAN_UBSAN)
      set(_FS_SANITIZER_FLAGS -fsanitize=address,undefined -fno-omit-frame-pointer)
      target_compile_options(fujistudio_core PRIVATE ${_FS_SANITIZER_FLAGS})
      if(FUJISTUDIO_BUILD_SHARED)
        target_link_options(fujistudio_core PRIVATE -fsanitize=address,undefined)
      endif()
      message(STATUS "FujiStudio Host: ASan + UBSan enabled")
    else()
      message(STATUS "FujiStudio Host: ASan + UBSan not supported by current host toolchain; building without sanitizers")
    endif()
  endif()

  if(BUILD_TESTING)
    add_executable(core_abi_test tests/core_abi_test.cpp)
    target_link_libraries(core_abi_test PRIVATE fujistudio_core)
    set_target_properties(core_abi_test PROPERTIES
      RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    )
    if(MSVC)
      target_compile_options(core_abi_test PRIVATE /W4 /permissive-)
    else()
      target_compile_options(core_abi_test PRIVATE -Wall -Wextra -Wpedantic)
      if(_FS_SANITIZER_FLAGS)
        target_compile_options(core_abi_test PRIVATE ${_FS_SANITIZER_FLAGS})
        target_link_options(core_abi_test PRIVATE -fsanitize=address,undefined)
      endif()
    endif()

    add_test(NAME core_abi_test COMMAND core_abi_test)

    add_executable(raf_extractor_fuzz_test tests/raf_extractor_fuzz_test.cpp)
    target_link_libraries(raf_extractor_fuzz_test PRIVATE fujistudio_core)
    set_target_properties(raf_extractor_fuzz_test PROPERTIES
      RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    )
    if(MSVC)
      target_compile_options(raf_extractor_fuzz_test PRIVATE /W4 /permissive-)
    else()
      target_compile_options(raf_extractor_fuzz_test PRIVATE -Wall -Wextra -Wpedantic)
      if(_FS_SANITIZER_FLAGS)
        target_compile_options(raf_extractor_fuzz_test PRIVATE ${_FS_SANITIZER_FLAGS})
        target_link_options(raf_extractor_fuzz_test PRIVATE -fsanitize=address,undefined)
      endif()
    endif()

    add_test(NAME raf_extractor_fuzz_test COMMAND raf_extractor_fuzz_test)
  endif()
endif()
