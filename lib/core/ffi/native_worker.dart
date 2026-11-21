import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart';
import 'native_library.dart';

/// Result returned by [NativeWorker.invertRgbaSmoke].
final class InvertRgbaResult {
  const InvertRgbaResult({
    required this.statusCode,
    required this.elapsedMicroseconds,
    this.rgbaBytes,
  });

  final int statusCode;
  final int elapsedMicroseconds;
  final Uint8List? rgbaBytes;

  bool get isOk => statusCode == FsStatusCode.FS_OK.value;
  double get elapsedMilliseconds => elapsedMicroseconds / 1000.0;
}

/// Result returned by [NativeWorker.extractRafPreviewFromFd] and
/// [NativeWorker.extractRafPreviewFromPath].
final class RafExtractionResult {
  const RafExtractionResult({
    required this.statusCode,
    required this.elapsedMicroseconds,
    required this.jpegOffset,
    required this.jpegLength,
    required this.jpegWidth,
    required this.jpegHeight,
    required this.exifOrientation,
    required this.hasExifTag,
    required this.cameraModel,
  });

  final int statusCode;
  final int elapsedMicroseconds;
  final int jpegOffset;
  final int jpegLength;
  final int jpegWidth;
  final int jpegHeight;
  final int exifOrientation;
  final bool hasExifTag;
  final String cameraModel;

  bool get isOk => statusCode == FsStatusCode.FS_OK.value;
  double get elapsedMilliseconds => elapsedMicroseconds / 1000.0;
}

/// Result returned by [NativeWorker.inspectJpegBytes].
final class JpegInspectResult {
  const JpegInspectResult({
    required this.statusCode,
    required this.elapsedMicroseconds,
    required this.exifOrientation,
    required this.hasExifTag,
    required this.width,
    required this.height,
  });

  final int statusCode;
  final int elapsedMicroseconds;
  final int exifOrientation;
  final bool hasExifTag;
  final int width;
  final int height;

  bool get isOk => statusCode == FsStatusCode.FS_OK.value;
  double get elapsedMilliseconds => elapsedMicroseconds / 1000.0;
}

/// Long-lived background Isolate bridging Dart requests to the stateless
/// C++20 FujiStudio core over `dart:ffi`.
///
/// Architectural Memory Contract (26MP Zero-Rework):
/// - All full-resolution (26MP+) image processing APIs introduced in Slices 1–4
///   MUST pass file paths or native file descriptors down to C++ rather than
///   shuttling full-resolution RGBA buffers across the Isolate boundary.
/// - `TransferableTypedData` RGBA buffers are reserved strictly for downsampled
///   preview frames (and the Day-0 smoke test).
/// - All native heap allocations are initialized to `ffi.nullptr` before `try`
///   and released in `finally` (`fs_free_buffer` / `calloc.free`) so exceptions
///   cannot leak native memory.
final class NativeWorker {
  NativeWorker._(
    this._isolate,
    this._commandPort,
    this._responsePort,
    this._exitPort,
    this._errorPort,
  ) {
    _responseSub = _responsePort.listen(_onWorkerMessage);
    _exitSub = _exitPort.listen((_) {
      _handleUnexpectedTermination();
    });
    _errorSub = _errorPort.listen((Object? errorPayload) {
      _handleUnexpectedTermination(errorPayload);
    });
  }

  final Isolate _isolate;
  final SendPort _commandPort;
  final ReceivePort _responsePort;
  final ReceivePort _exitPort;
  final ReceivePort _errorPort;

  late final StreamSubscription<Object?> _responseSub;
  late final StreamSubscription<Object?> _exitSub;
  late final StreamSubscription<Object?> _errorSub;

  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};

  int _nextRequestId = 1;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  /// Spawns and initializes a long-lived [NativeWorker] Isolate.
  ///
  /// Monitors startup errors and premature exits so `spawn()` never deadlocks
  /// and always closes temporary handshake ports on every exit path.
  static Future<NativeWorker> spawn({String? explicitLibraryPath}) async {
    final initPort = ReceivePort();
    final spawnErrorPort = ReceivePort();
    final spawnExitPort = ReceivePort();

    StreamSubscription<Object?>? initSub;
    StreamSubscription<Object?>? errorSub;
    StreamSubscription<Object?>? exitSub;
    Isolate? isolate;

    try {
      final handshake = Completer<SendPort>();

      initSub = initPort.listen((Object? message) {
        if (handshake.isCompleted) return;
        if (message is _WorkerInitError) {
          handshake.completeError(
            StateError('Failed to initialize NativeWorker: ${message.message}'),
          );
        } else if (message is SendPort) {
          handshake.complete(message);
        } else {
          handshake.completeError(
            StateError('Unexpected NativeWorker handshake message: $message'),
          );
        }
      });

      errorSub = spawnErrorPort.listen((Object? errorPayload) {
        if (handshake.isCompleted) return;
        handshake.completeError(
          StateError(
            'NativeWorker isolate failed during startup: $errorPayload',
          ),
        );
      });

      exitSub = spawnExitPort.listen((_) {
        if (handshake.isCompleted) return;
        handshake.completeError(
          StateError('NativeWorker isolate exited unexpectedly during startup.'),
        );
      });

      isolate = await Isolate.spawn<_WorkerBootstrap>(
        _workerEntryPoint,
        _WorkerBootstrap(
          replyPort: initPort.sendPort,
          explicitLibraryPath: explicitLibraryPath,
        ),
        onError: spawnErrorPort.sendPort,
        onExit: spawnExitPort.sendPort,
        debugName: 'FujiStudioNativeWorker',
      );

      final commandPort = await handshake.future;

      // Detach temporary startup listeners before attaching long-lived ones.
      isolate.removeErrorListener(spawnErrorPort.sendPort);
      isolate.removeOnExitListener(spawnExitPort.sendPort);

      final responsePort = ReceivePort();
      final exitPort = ReceivePort();
      final errorPort = ReceivePort();

      isolate.addOnExitListener(exitPort.sendPort);
      isolate.addErrorListener(errorPort.sendPort);
      commandPort.send(_AttachResponsePort(responsePort.sendPort));

      return NativeWorker._(
        isolate,
        commandPort,
        responsePort,
        exitPort,
        errorPort,
      );
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      rethrow;
    } finally {
      await initSub?.cancel();
      await errorSub?.cancel();
      await exitSub?.cancel();
      initPort.close();
      spawnErrorPort.close();
      spawnExitPort.close();
    }
  }

  /// Queries `fs_core_version()` from the C++20 core.
  Future<String> coreVersion() async {
    final result = await _sendRequest<String>(
      (id) => _VersionRequest(id: id),
    );
    return result;
  }

  /// Executes `fs_invert_rgba_smoke(...)` inside the long-lived Isolate.
  ///
  /// Passing `inputRgba: null`, non-positive dimensions, or oversized
  /// dimensions returns the corresponding negative [FsStatusCode] cleanly.
  Future<InvertRgbaResult> invertRgbaSmoke({
    required Uint8List? inputRgba,
    required int width,
    required int height,
  }) async {
    final result = await _sendRequest<InvertRgbaResult>(
      (id) => _InvertRgbaRequest(
        id: id,
        inputRgba: inputRgba == null
            ? null
            : TransferableTypedData.fromList(<Uint8List>[inputRgba]),
        inputByteLength: inputRgba?.length ?? 0,
        width: width,
        height: height,
      ),
    );
    return result;
  }

  /// Extracts the embedded JPEG preview from an open POSIX [fd] without
  /// transferring `.RAF` bytes across Isolates and without closing [fd].
  Future<RafExtractionResult> extractRafPreviewFromFd({
    required int fd,
    required String outJpegPath,
  }) async {
    return _sendRequest<RafExtractionResult>(
      (id) => _ExtractRafFromFdRequest(
        id: id,
        fd: fd,
        outJpegPath: outJpegPath,
      ),
    );
  }

  /// Extracts the embedded JPEG preview directly from [rafPath] on disk and
  /// writes it atomically to [outJpegPath].
  Future<RafExtractionResult> extractRafPreviewFromPath({
    required String rafPath,
    required String outJpegPath,
  }) async {
    return _sendRequest<RafExtractionResult>(
      (id) => _ExtractRafFromPathRequest(
        id: id,
        rafPath: rafPath,
        outJpegPath: outJpegPath,
      ),
    );
  }

  /// Inspects an encoded JPEG buffer for EXIF Orientation and SOF dimensions.
  Future<JpegInspectResult> inspectJpegBytes(Uint8List jpegBytes) async {
    return _sendRequest<JpegInspectResult>(
      (id) => _InspectJpegRequest(
        id: id,
        jpegBytes: TransferableTypedData.fromList(<Uint8List>[jpegBytes]),
      ),
    );
  }

  /// Idempotently shuts down the background Isolate and releases all ports.
  ///
  /// Concurrent or repeated calls return the exact same [Future] and complete
  /// only after all subscriptions and ports have been cleanly closed.
  Future<void> dispose() {
    return _disposeFuture ??= _performDispose(
      pendingFailureMessage:
          'NativeWorker was disposed before request completed.',
      killIsolate: true,
    );
  }

  void _handleUnexpectedTermination([Object? errorPayload]) {
    final detail = errorPayload == null ? '' : ' ($errorPayload)';
    _disposeFuture ??= _performDispose(
      pendingFailureMessage:
          'NativeWorker isolate terminated unexpectedly.$detail',
      killIsolate: true,
    );
  }

  Future<void> _performDispose({
    required String pendingFailureMessage,
    required bool killIsolate,
  }) async {
    _disposed = true;

    final pendingSnapshot = _pending.values.toList(growable: false);
    _pending.clear();
    for (final completer in pendingSnapshot) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(pendingFailureMessage));
      }
    }

    _isolate.removeOnExitListener(_exitPort.sendPort);
    _isolate.removeErrorListener(_errorPort.sendPort);

    try {
      _commandPort.send(const _ShutdownRequest());
    } catch (_) {
      // Ignore if the remote port is already gone.
    }

    await _responseSub.cancel();
    await _exitSub.cancel();
    await _errorSub.cancel();
    _responsePort.close();
    _exitPort.close();
    _errorPort.close();

    if (killIsolate) {
      _isolate.kill(priority: Isolate.beforeNextEvent);
    }
  }

  Future<T> _sendRequest<T>(_WorkerRequest Function(int id) buildRequest) {
    if (_disposed) {
      return Future<T>.error(
        StateError('Cannot send request to a disposed NativeWorker.'),
      );
    }
    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commandPort.send(buildRequest(id));
    return completer.future.then((value) => value as T);
  }

  void _onWorkerMessage(Object? message) {
    if (message is! _WorkerResponse) return;
    final completer = _pending.remove(message.id);
    if (completer == null || completer.isCompleted) return;

    if (message.error != null) {
      completer.completeError(StateError(message.error!));
      return;
    }

    final payload = message.payload;
    if (payload is _InvertRgbaPayload) {
      final bytes = payload.transferable?.materialize().asUint8List();
      completer.complete(
        InvertRgbaResult(
          statusCode: payload.statusCode,
          elapsedMicroseconds: payload.elapsedMicroseconds,
          rgbaBytes: bytes,
        ),
      );
      return;
    }

    completer.complete(payload);
  }
}

void _workerEntryPoint(_WorkerBootstrap bootstrap) {
  final FujiStudioBindings bindings;
  try {
    bindings = NativeLibrary.createBindings(
      explicitPath: bootstrap.explicitLibraryPath,
    );
  } catch (error) {
    bootstrap.replyPort.send(_WorkerInitError(error.toString()));
    return;
  }

  final commandPort = ReceivePort();
  bootstrap.replyPort.send(commandPort.sendPort);

  SendPort? responsePort;
  commandPort.listen((Object? message) {
    if (message is _AttachResponsePort) {
      responsePort = message.port;
      return;
    }

    if (message is _ShutdownRequest) {
      commandPort.close();
      return;
    }

    if (message is _VersionRequest) {
      try {
        final ptr = bindings.fs_core_version();
        final version = ptr == ffi.nullptr
            ? ''
            : ptr.cast<Utf8>().toDartString();
        responsePort?.send(_WorkerResponse(id: message.id, payload: version));
      } catch (error) {
        responsePort?.send(
          _WorkerResponse(id: message.id, error: error.toString()),
        );
      }
      return;
    }

    if (message is _InvertRgbaRequest) {
      try {
        final payload = _executeInvertRgba(bindings, message);
        responsePort?.send(_WorkerResponse(id: message.id, payload: payload));
      } catch (error) {
        responsePort?.send(
          _WorkerResponse(id: message.id, error: error.toString()),
        );
      }
      return;
    }

    if (message is _ExtractRafFromFdRequest) {
      try {
        final result = _executeExtractRafFromFd(bindings, message);
        responsePort?.send(_WorkerResponse(id: message.id, payload: result));
      } catch (error) {
        responsePort?.send(
          _WorkerResponse(id: message.id, error: error.toString()),
        );
      }
      return;
    }

    if (message is _ExtractRafFromPathRequest) {
      try {
        final result = _executeExtractRafFromPath(bindings, message);
        responsePort?.send(_WorkerResponse(id: message.id, payload: result));
      } catch (error) {
        responsePort?.send(
          _WorkerResponse(id: message.id, error: error.toString()),
        );
      }
      return;
    }

    if (message is _InspectJpegRequest) {
      try {
        final result = _executeInspectJpeg(bindings, message);
        responsePort?.send(_WorkerResponse(id: message.id, payload: result));
      } catch (error) {
        responsePort?.send(
          _WorkerResponse(id: message.id, error: error.toString()),
        );
      }
      return;
    }
  });
}

_InvertRgbaPayload _executeInvertRgba(
  FujiStudioBindings bindings,
  _InvertRgbaRequest request,
) {
  const int maxInt32 = 0x7FFFFFFF;
  const int maxImageDim = FS_MAX_IMAGE_DIMENSION;

  final sw = Stopwatch()..start();

  // 1. Validate non-positive dimensions before any arithmetic or allocation.
  if (request.width <= 0 || request.height <= 0) {
    sw.stop();
    return _InvertRgbaPayload(
      statusCode: FsStatusCode.FS_ERR_INVALID_DIMENSIONS.value,
      elapsedMicroseconds: sw.elapsedMicroseconds,
      transferable: null,
    );
  }

  // 2. Prevent int64 overflow and int64 -> int32 truncation across FFI boundary.
  if (request.width > maxInt32 ||
      request.height > maxInt32 ||
      request.width > maxImageDim ||
      request.height > maxImageDim ||
      request.width > (maxInt32 ~/ 4) ~/ request.height) {
    sw.stop();
    return _InvertRgbaPayload(
      statusCode: FsStatusCode.FS_ERR_OVERFLOW.value,
      elapsedMicroseconds: sw.elapsedMicroseconds,
      transferable: null,
    );
  }

  // 3. Guard against undersized input buffers when non-null.
  final expectedBytes = request.width * request.height * 4;
  if (request.inputRgba != null && request.inputByteLength < expectedBytes) {
    sw.stop();
    return _InvertRgbaPayload(
      statusCode: FsStatusCode.FS_ERR_INVALID_DIMENSIONS.value,
      elapsedMicroseconds: sw.elapsedMicroseconds,
      transferable: null,
    );
  }

  ffi.Pointer<ffi.Uint8> inputPtr = ffi.nullptr;
  ffi.Pointer<ffi.Pointer<ffi.Uint8>> outPtrPtr = ffi.nullptr;
  ffi.Pointer<ffi.Size> outLenPtr = ffi.nullptr;
  ffi.Pointer<ffi.Uint8> nativeOutPtr = ffi.nullptr;

  try {
    outPtrPtr = calloc<ffi.Pointer<ffi.Uint8>>();
    outLenPtr = calloc<ffi.Size>();

    var inputLen = 0;
    if (request.inputRgba != null) {
      final inputBytes = request.inputRgba!.materialize().asUint8List();
      inputLen = inputBytes.length;
      final allocLen = inputLen == 0 ? 1 : inputLen;
      inputPtr = calloc<ffi.Uint8>(allocLen);
      if (inputLen > 0) {
        inputPtr.asTypedList(inputLen).setAll(0, inputBytes);
      }
    }

    final statusCode = bindings.fs_invert_rgba_smoke(
      inputPtr,
      inputLen,
      request.width,
      request.height,
      outPtrPtr,
      outLenPtr,
    );

    // Release native input buffer immediately before packaging output to reduce peak RAM.
    if (inputPtr != ffi.nullptr) {
      calloc.free(inputPtr);
      inputPtr = ffi.nullptr;
    }

    nativeOutPtr = outPtrPtr.value;

    if (statusCode != FsStatusCode.FS_OK.value || nativeOutPtr == ffi.nullptr) {
      sw.stop();
      return _InvertRgbaPayload(
        statusCode: statusCode,
        elapsedMicroseconds: sw.elapsedMicroseconds,
        transferable: null,
      );
    }

    final outLen = outLenPtr.value;
    // Copy directly from native view into TransferableTypedData without an extra Uint8List clone.
    final transferable = TransferableTypedData.fromList(<Uint8List>[
      nativeOutPtr.asTypedList(outLen),
    ]);
    sw.stop();

    return _InvertRgbaPayload(
      statusCode: statusCode,
      elapsedMicroseconds: sw.elapsedMicroseconds,
      transferable: transferable,
    );
  } finally {
    if (nativeOutPtr != ffi.nullptr) {
      bindings.fs_free_buffer(nativeOutPtr);
    }
    if (outPtrPtr != ffi.nullptr) {
      calloc.free(outPtrPtr);
    }
    if (outLenPtr != ffi.nullptr) {
      calloc.free(outLenPtr);
    }
    if (inputPtr != ffi.nullptr) {
      calloc.free(inputPtr);
    }
  }
}

RafExtractionResult _buildRafResult(
  int statusCode,
  int elapsedMicroseconds,
  FsRafMetadata meta,
) {
  final modelChars = <int>[];
  for (var i = 0; i < FS_RAF_CAMERA_MODEL_MAX; i++) {
    final code = meta.camera_model[i];
    if (code == 0) break;
    modelChars.add(code & 0xFF);
  }
  return RafExtractionResult(
    statusCode: statusCode,
    elapsedMicroseconds: elapsedMicroseconds,
    jpegOffset: meta.jpeg_offset,
    jpegLength: meta.jpeg_length,
    jpegWidth: meta.jpeg_width,
    jpegHeight: meta.jpeg_height,
    exifOrientation: meta.exif_orientation,
    hasExifTag: meta.has_exif_tag != 0,
    cameraModel: String.fromCharCodes(modelChars),
  );
}

RafExtractionResult _executeExtractRafFromFd(
  FujiStudioBindings bindings,
  _ExtractRafFromFdRequest request,
) {
  final sw = Stopwatch()..start();
  ffi.Pointer<Utf8> outPathPtr = ffi.nullptr;
  ffi.Pointer<FsRafMetadata> metaPtr = ffi.nullptr;
  try {
    outPathPtr = request.outJpegPath.toNativeUtf8();
    metaPtr = calloc<FsRafMetadata>();
    final rc = bindings.fs_raf_extract_jpeg_from_fd(
      request.fd,
      outPathPtr.cast<ffi.Char>(),
      metaPtr,
    );
    sw.stop();
    return _buildRafResult(rc, sw.elapsedMicroseconds, metaPtr.ref);
  } finally {
    if (metaPtr != ffi.nullptr) {
      calloc.free(metaPtr);
    }
    if (outPathPtr != ffi.nullptr) {
      calloc.free(outPathPtr);
    }
  }
}

RafExtractionResult _executeExtractRafFromPath(
  FujiStudioBindings bindings,
  _ExtractRafFromPathRequest request,
) {
  final sw = Stopwatch()..start();
  ffi.Pointer<Utf8> rafPathPtr = ffi.nullptr;
  ffi.Pointer<Utf8> outPathPtr = ffi.nullptr;
  ffi.Pointer<FsRafMetadata> metaPtr = ffi.nullptr;
  try {
    rafPathPtr = request.rafPath.toNativeUtf8();
    outPathPtr = request.outJpegPath.toNativeUtf8();
    metaPtr = calloc<FsRafMetadata>();
    final rc = bindings.fs_raf_extract_jpeg_from_path(
      rafPathPtr.cast<ffi.Char>(),
      outPathPtr.cast<ffi.Char>(),
      metaPtr,
    );
    sw.stop();
    return _buildRafResult(rc, sw.elapsedMicroseconds, metaPtr.ref);
  } finally {
    if (metaPtr != ffi.nullptr) {
      calloc.free(metaPtr);
    }
    if (outPathPtr != ffi.nullptr) {
      calloc.free(outPathPtr);
    }
    if (rafPathPtr != ffi.nullptr) {
      calloc.free(rafPathPtr);
    }
  }
}

JpegInspectResult _executeInspectJpeg(
  FujiStudioBindings bindings,
  _InspectJpegRequest request,
) {
  final sw = Stopwatch()..start();
  ffi.Pointer<ffi.Uint8> bytesPtr = ffi.nullptr;
  ffi.Pointer<ffi.Uint8> orientationPtr = ffi.nullptr;
  ffi.Pointer<ffi.Uint8> hasExifPtr = ffi.nullptr;
  ffi.Pointer<ffi.Uint32> widthPtr = ffi.nullptr;
  ffi.Pointer<ffi.Uint32> heightPtr = ffi.nullptr;
  try {
    final bytes = request.jpegBytes.materialize().asUint8List();
    final allocLen = bytes.isEmpty ? 1 : bytes.length;
    bytesPtr = calloc<ffi.Uint8>(allocLen);
    if (bytes.isNotEmpty) {
      bytesPtr.asTypedList(bytes.length).setAll(0, bytes);
    }
    orientationPtr = calloc<ffi.Uint8>();
    hasExifPtr = calloc<ffi.Uint8>();
    widthPtr = calloc<ffi.Uint32>();
    heightPtr = calloc<ffi.Uint32>();

    final rc = bindings.fs_jpeg_inspect_buffer(
      bytesPtr,
      bytes.length,
      orientationPtr,
      hasExifPtr,
      widthPtr,
      heightPtr,
    );
    sw.stop();
    return JpegInspectResult(
      statusCode: rc,
      elapsedMicroseconds: sw.elapsedMicroseconds,
      exifOrientation: orientationPtr.value,
      hasExifTag: hasExifPtr.value != 0,
      width: widthPtr.value,
      height: heightPtr.value,
    );
  } finally {
    if (heightPtr != ffi.nullptr) calloc.free(heightPtr);
    if (widthPtr != ffi.nullptr) calloc.free(widthPtr);
    if (hasExifPtr != ffi.nullptr) calloc.free(hasExifPtr);
    if (orientationPtr != ffi.nullptr) calloc.free(orientationPtr);
    if (bytesPtr != ffi.nullptr) calloc.free(bytesPtr);
  }
}

final class _WorkerBootstrap {
  const _WorkerBootstrap({
    required this.replyPort,
    this.explicitLibraryPath,
  });

  final SendPort replyPort;
  final String? explicitLibraryPath;
}

final class _WorkerInitError {
  const _WorkerInitError(this.message);
  final String message;
}

final class _AttachResponsePort {
  const _AttachResponsePort(this.port);
  final SendPort port;
}

sealed class _WorkerRequest {
  const _WorkerRequest({required this.id});
  final int id;
}

final class _VersionRequest extends _WorkerRequest {
  const _VersionRequest({required super.id});
}

final class _InvertRgbaRequest extends _WorkerRequest {
  const _InvertRgbaRequest({
    required super.id,
    required this.inputRgba,
    required this.inputByteLength,
    required this.width,
    required this.height,
  });

  final TransferableTypedData? inputRgba;
  final int inputByteLength;
  final int width;
  final int height;
}

final class _ExtractRafFromFdRequest extends _WorkerRequest {
  const _ExtractRafFromFdRequest({
    required super.id,
    required this.fd,
    required this.outJpegPath,
  });

  final int fd;
  final String outJpegPath;
}

final class _ExtractRafFromPathRequest extends _WorkerRequest {
  const _ExtractRafFromPathRequest({
    required super.id,
    required this.rafPath,
    required this.outJpegPath,
  });

  final String rafPath;
  final String outJpegPath;
}

final class _InspectJpegRequest extends _WorkerRequest {
  const _InspectJpegRequest({
    required super.id,
    required this.jpegBytes,
  });

  final TransferableTypedData jpegBytes;
}

final class _ShutdownRequest {
  const _ShutdownRequest();
}

final class _WorkerResponse {
  const _WorkerResponse({
    required this.id,
    this.payload,
    this.error,
  });

  final int id;
  final Object? payload;
  final String? error;
}

final class _InvertRgbaPayload {
  const _InvertRgbaPayload({
    required this.statusCode,
    required this.elapsedMicroseconds,
    required this.transferable,
  });

  final int statusCode;
  final int elapsedMicroseconds;
  final TransferableTypedData? transferable;
}
