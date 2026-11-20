import 'dart:ffi' as ffi;
import 'dart:io';

import 'bindings.g.dart';

/// Loads the FujiStudio C++20 core dynamic library for Android, iOS, or
/// desktop host test environments.
final class NativeLibrary {
  NativeLibrary._();

  static const String _androidLibName = 'libfujistudio_core.so';
  static const String _overrideEnvKey = 'FUJISTUDIO_CORE_LIB_PATH';

  /// Opens the platform-appropriate [ffi.DynamicLibrary].
  ///
  /// - Android: loads `libfujistudio_core.so` packaged by Gradle CMake.
  /// - iOS: resolves statically linked symbols via `DynamicLibrary.process()`.
  /// - Host (Windows / macOS / Linux): resolves the CMake host build output
  ///   under `native/build-host/` (or `FUJISTUDIO_CORE_LIB_PATH` if set).
  static ffi.DynamicLibrary open({String? explicitPath}) {
    if (explicitPath != null && explicitPath.isNotEmpty) {
      return ffi.DynamicLibrary.open(explicitPath);
    }

    if (Platform.isAndroid) {
      return ffi.DynamicLibrary.open(_androidLibName);
    }

    if (Platform.isIOS) {
      return ffi.DynamicLibrary.process();
    }

    final envPath = Platform.environment[_overrideEnvKey];
    if (envPath != null && envPath.isNotEmpty) {
      return ffi.DynamicLibrary.open(envPath);
    }

    final candidates = _hostLibraryCandidates();
    for (final path in candidates) {
      if (File(path).existsSync()) {
        return ffi.DynamicLibrary.open(path);
      }
    }

    throw StateError(
      'Unable to locate FujiStudio host native library. Checked:\n'
      '${candidates.map((p) => '  - $p').join('\n')}\n'
      'Build the host library first with:\n'
      '  cmake -S native -B native/build-host && cmake --build native/build-host',
    );
  }

  /// Creates typed [FujiStudioBindings] bound to the loaded native library.
  static FujiStudioBindings createBindings({String? explicitPath}) {
    return FujiStudioBindings(open(explicitPath: explicitPath));
  }

  static List<String> _hostLibraryCandidates() {
    final sep = Platform.pathSeparator;
    final cwd = Directory.current.path;
    final base = '$cwd${sep}native${sep}build-host';

    if (Platform.isWindows) {
      return <String>[
        '$base${sep}fujistudio_core.dll',
        '$base${sep}Release${sep}fujistudio_core.dll',
        '$base${sep}Debug${sep}fujistudio_core.dll',
        '$base${sep}libfujistudio_core.dll',
      ];
    }

    if (Platform.isMacOS) {
      return <String>[
        '$base${sep}libfujistudio_core.dylib',
        '$base${sep}Release${sep}libfujistudio_core.dylib',
        '$base${sep}Debug${sep}libfujistudio_core.dylib',
      ];
    }

    return <String>[
      '$base${sep}libfujistudio_core.so',
      '$base${sep}Release${sep}libfujistudio_core.so',
      '$base${sep}Debug${sep}libfujistudio_core.so',
    ];
  }
}
