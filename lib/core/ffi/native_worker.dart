import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
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

/// Normalized DNA-Aware Shadow Rescue parameters passed across [NativeWorker].
final class DnaRescueNativeParams {
  const DnaRescueNativeParams({
    required this.shadowLift,
    this.midtoneAnchor = 0.55,
    this.highlightProtect = 0.90,
    this.mode = 0,
    this.enabled = true,
    this.skinProtect = 0.0,
  });

  final double shadowLift;
  final double midtoneAnchor;
  final double highlightProtect;
  final int mode;
  final bool enabled;
  final double skinProtect;
}

/// Result returned by [NativeWorker.renderStudioSurface].
final class StudioRenderResult {
  const StudioRenderResult({
    required this.statusCode,
    required this.renderTimeMicros,
    required this.width,
    required this.height,
    this.rgbaBytes,
  });

  final int statusCode;
  final int renderTimeMicros;
  final int width;
  final int height;
  final Uint8List? rgbaBytes;

  bool get isOk => statusCode == FsStatusCode.FS_OK.value;
  double get renderTimeMs => renderTimeMicros / 1000.0;
}

/// Result returned by [NativeWorker.analyzeStudioSurface].
final class DnaRescueSuggestionResult {
  const DnaRescueSuggestionResult({
    required this.statusCode,
    required this.elapsedMicroseconds,
    required this.recommendedShadowLift,
    required this.p10Luma,
    required this.p50Luma,
    required this.p95Luma,
    required this.shadowPixelRatio,
    required this.recommendedMode,
  });

  final int statusCode;
  final int elapsedMicroseconds;
  final double recommendedShadowLift;
  final double p10Luma;
  final double p50Luma;
  final double p95Luma;
  final double shadowPixelRatio;
  final int recommendedMode;

  bool get isOk => statusCode == FsStatusCode.FS_OK.value;
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

/// Normalized `[0..1]` crop box in post-rotation inscribed image space.
final class NormCropBoxData {
  const NormCropBoxData({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  static const NormCropBoxData full = NormCropBoxData(
    left: 0.0,
    top: 0.0,
    right: 1.0,
    bottom: 1.0,
  );

  final double left;
  final double top;
  final double right;
  final double bottom;
}

/// Result returned by [NativeWorker.clampCrop].
final class ClampedCropResult {
  const ClampedCropResult({
    required this.statusCode,
    required this.elapsedMicroseconds,
    required this.clampedBox,
    required this.pixelWidth,
    required this.pixelHeight,
  });

  final int statusCode;
  final int elapsedMicroseconds;
  final NormCropBoxData clampedBox;
  final int pixelWidth;
  final int pixelHeight;

  bool get isOk => statusCode == FsStatusCode.FS_OK.value;
}

/// Geometry transform parameters passed across [NativeWorker].
final class GeometryNativeParams {
  const GeometryNativeParams({
    required this.rotationDeg,
    required this.aspectPreset,
    required this.cropBox,
    this.highQuality = true,
  });

  final double rotationDeg;
  final int aspectPreset;
  final NormCropBoxData cropBox;
  final bool highQuality;
}

/// Result returned by [NativeWorker.analyzeGeometryOnSurface].
final class GeometryProposalNative {
  const GeometryProposalNative({
    required this.statusCode,
    required this.elapsedMicroseconds,
    required this.suggestedRotationDeg,
    required this.horizonConfidence,
    required this.suggestedCropBox,
    required this.cropConfidence,
    required this.saliencyCx,
    required this.saliencyCy,
    required this.hasHorizonLine,
    required this.targetAspectPreset,
  });

  final int statusCode;
  final int elapsedMicroseconds;
  final double suggestedRotationDeg;
  final double horizonConfidence;
  final NormCropBoxData suggestedCropBox;
  final double cropConfidence;
  final double saliencyCx;
  final double saliencyCy;
  final bool hasHorizonLine;
  final int targetAspectPreset;

  bool get isOk => statusCode == FsStatusCode.FS_OK.value;
}

/// Single RGBA slot payload sent to [NativeWorker.renderCollage].
final class CollageSlotInputData {
  const CollageSlotInputData({
    required this.rgbaBytes,
    required this.width,
    required this.height,
    this.panX = 0.0,
    this.panY = 0.0,
    this.zoom = 1.0,
  });

  final Uint8List rgbaBytes;
  final int width;
  final int height;
  final double panX;
  final double panY;
  final double zoom;
}

/// Canvas configuration sent to [NativeWorker.renderCollage].
final class CollageNativeConfig {
  const CollageNativeConfig({
    required this.templateId,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.gutterPx,
    required this.outerMarginPx,
    required this.bgR,
    required this.bgG,
    required this.bgB,
    this.bgA = 255,
  });

  final int templateId;
  final int canvasWidth;
  final int canvasHeight;
  final int gutterPx;
  final int outerMarginPx;
  final int bgR;
  final int bgG;
  final int bgB;
  final int bgA;
}

/// Result returned by [NativeWorker.renderCollage].
final class CollageRenderResult {
  const CollageRenderResult({
    required this.statusCode,
    required this.renderTimeMicros,
    required this.width,
    required this.height,
    this.rgbaBytes,
  });

  final int statusCode;
  final int renderTimeMicros;
  final int width;
  final int height;
  final Uint8List? rgbaBytes;

  bool get isOk => statusCode == FsStatusCode.FS_OK.value;
  double get renderTimeMs => renderTimeMicros / 1000.0;
}

/// Output Unsharp Mask parameters passed to [NativeWorker].
final class OutputUsmNativeParams {
  const OutputUsmNativeParams({
    required this.amount,
    this.radius = 0.85,
    this.threshold = 3.0,
    this.haloClamp = 18.0,
    this.enabled = true,
  });

  final double amount;
  final double radius;
  final double threshold;
  final double haloClamp;
  final bool enabled;
}

/// File-backed RGBA slot payload sent to [NativeWorker.renderCollageToRawFile].
final class CollageRawFileSlot {
  const CollageRawFileSlot({
    required this.rawInputPath,
    required this.width,
    required this.height,
    this.panX = 0.0,
    this.panY = 0.0,
    this.zoom = 1.0,
    this.dnaRescue,
    this.geometry,
  });

  final String rawInputPath;
  final int width;
  final int height;
  final double panX;
  final double panY;
  final double zoom;
  final DnaRescueNativeParams? dnaRescue;
  final GeometryNativeParams? geometry;
}

/// Metadata-only result returned by [NativeWorker.runExportPipelineOnRawFile]
/// and [NativeWorker.renderCollageToRawFile] (never shuttles RGBA buffers).
final class ExportRgbaResult {
  const ExportRgbaResult({
    required this.statusCode,
    required this.renderTimeMicros,
    required this.width,
    required this.height,
    required this.rawOutputPath,
  });

  final int statusCode;
  final int renderTimeMicros;
  final int width;
  final int height;
  final String rawOutputPath;

  bool get isOk => statusCode == FsStatusCode.FS_OK.value;
  double get renderTimeMs => renderTimeMicros / 1000.0;
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

  /// Allocates a resident native RGBA surface inside the Worker Isolate (max 2
  /// concurrent surfaces) and copies [sourceRgba] once via [TransferableTypedData].
  Future<int> openStudioSurface({
    required int width,
    required int height,
    required Uint8List sourceRgba,
  }) async {
    return _sendRequest<int>(
      (id) => _OpenStudioSurfaceRequest(
        id: id,
        width: width,
        height: height,
        sourceByteLength: sourceRgba.length,
        sourceRgba: TransferableTypedData.fromList(<Uint8List>[sourceRgba]),
      ),
    );
  }

  /// Renders DNA-Aware Shadow Rescue on an open resident [surfaceId] with
  /// zero per-frame native heap allocations.
  Future<StudioRenderResult> renderStudioSurface({
    required int surfaceId,
    required DnaRescueNativeParams params,
  }) async {
    return _sendRequest<StudioRenderResult>(
      (id) => _RenderStudioSurfaceRequest(
        id: id,
        surfaceId: surfaceId,
        params: params,
      ),
    );
  }

  /// Analyzes the source pixels of [surfaceId] for 1-tap Auto Rescue.
  Future<DnaRescueSuggestionResult> analyzeStudioSurface({
    required int surfaceId,
  }) async {
    return _sendRequest<DnaRescueSuggestionResult>(
      (id) => _AnalyzeStudioSurfaceRequest(
        id: id,
        surfaceId: surfaceId,
      ),
    );
  }

  /// Idempotently closes and frees native buffers associated with [surfaceId].
  Future<void> closeStudioSurface(int surfaceId) async {
    await _sendRequest<void>(
      (id) => _CloseStudioSurfaceRequest(
        id: id,
        surfaceId: surfaceId,
      ),
    );
  }

  /// Clamps [requestedBox] inside the zero-black-corners inscribed space via
  /// `fs_geometry_clamp_crop`.
  Future<ClampedCropResult> clampCrop({
    required int srcWidth,
    required int srcHeight,
    required double rotationDeg,
    required int aspectPreset,
    required NormCropBoxData requestedBox,
  }) async {
    return _sendRequest<ClampedCropResult>(
      (id) => _ClampCropRequest(
        id: id,
        srcWidth: srcWidth,
        srcHeight: srcHeight,
        rotationDeg: rotationDeg,
        aspectPreset: aspectPreset,
        requestedBox: requestedBox,
      ),
    );
  }

  /// Runs Auto-Horizon + AI Saliency Crop directly on an open resident
  /// [surfaceId] without re-allocating or transferring pixels.
  Future<GeometryProposalNative> analyzeGeometryOnSurface({
    required int surfaceId,
    required int targetAspectPreset,
    bool useRescuedBuffer = false,
  }) async {
    return _sendRequest<GeometryProposalNative>(
      (id) => _AnalyzeGeometrySurfaceRequest(
        id: id,
        surfaceId: surfaceId,
        targetAspectPreset: targetAspectPreset,
        useRescuedBuffer: useRescuedBuffer,
      ),
    );
  }

  /// Renders rotated and cropped RGBA pixels directly from an open resident
  /// [surfaceId] via `fs_geometry_render_rgba_into`.
  Future<StudioRenderResult> renderGeometryOnSurface({
    required int surfaceId,
    required GeometryNativeParams params,
    required int outWidth,
    required int outHeight,
  }) async {
    return _sendRequest<StudioRenderResult>(
      (id) => _RenderGeometrySurfaceRequest(
        id: id,
        surfaceId: surfaceId,
        params: params,
        outWidth: outWidth,
        outHeight: outHeight,
      ),
    );
  }

  /// Stitches 2-4 slot images into a story collage canvas via
  /// `fs_collage_render_rgba_into`.
  Future<CollageRenderResult> renderCollage({
    required List<CollageSlotInputData> slots,
    required CollageNativeConfig config,
  }) async {
    final transferredSlots = slots
        .map<_CollageSlotTransfer>(
          (s) => _CollageSlotTransfer(
            rgba: TransferableTypedData.fromList(<Uint8List>[s.rgbaBytes]),
            byteLength: s.rgbaBytes.length,
            width: s.width,
            height: s.height,
            panX: s.panX,
            panY: s.panY,
            zoom: s.zoom,
          ),
        )
        .toList(growable: false);
    return _sendRequest<CollageRenderResult>(
      (id) => _RenderCollageRequest(
        id: id,
        slots: transferredSlots,
        config: config,
      ),
    );
  }

  /// Runs the deterministic full-res export pipeline directly on a disk-backed
  /// RGBA8888 file (`rawInputPath`) inside the Worker Isolate:
  /// 1) DNA Rescue v2 (in-place)
  /// 2) Horizon & Crop Catmull-Rom (highQuality=1, only if rotated/cropped)
  /// 3) Lanczos3 Downscale (only if `max(w, h) > targetMaxLongEdge`, no upscale)
  /// 4) Output USM (in-place)
  /// 5) Atomic write to `rawOutputPath`
  Future<ExportRgbaResult> runExportPipelineOnRawFile({
    required String rawInputPath,
    required int srcWidth,
    required int srcHeight,
    required String rawOutputPath,
    required DnaRescueNativeParams? dnaRescue,
    required GeometryNativeParams? geometry,
    required int targetMaxLongEdge,
    required OutputUsmNativeParams? outputUsm,
  }) async {
    return _sendRequest<ExportRgbaResult>(
      (id) => _RunExportPipelineRequest(
        id: id,
        rawInputPath: rawInputPath,
        srcWidth: srcWidth,
        srcHeight: srcHeight,
        rawOutputPath: rawOutputPath,
        dnaRescue: dnaRescue,
        geometry: geometry,
        targetMaxLongEdge: targetMaxLongEdge,
        outputUsm: outputUsm,
      ),
    );
  }

  /// Reads 2-4 disk-backed RGBA slot files, applies optional per-slot DNA Rescue
  /// in-place, stitches the collage canvas, applies optional Output USM in-place,
  /// and atomically writes the resulting RGBA8888 buffer to [rawOutputPath].
  Future<ExportRgbaResult> renderCollageToRawFile({
    required List<CollageRawFileSlot> slots,
    required CollageNativeConfig config,
    required OutputUsmNativeParams? outputUsm,
    required String rawOutputPath,
  }) async {
    return _sendRequest<ExportRgbaResult>(
      (id) => _RenderCollageToRawFileRequest(
        id: id,
        slots: List<CollageRawFileSlot>.unmodifiable(slots),
        config: config,
        outputUsm: outputUsm,
        rawOutputPath: rawOutputPath,
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

    if (payload is _StudioRenderPayload) {
      final bytes = payload.transferable?.materialize().asUint8List();
      completer.complete(
        StudioRenderResult(
          statusCode: payload.statusCode,
          renderTimeMicros: payload.renderTimeMicros,
          width: payload.width,
          height: payload.height,
          rgbaBytes: bytes,
        ),
      );
      return;
    }

    if (payload is _CollageRenderPayload) {
      final bytes = payload.transferable?.materialize().asUint8List();
      completer.complete(
        CollageRenderResult(
          statusCode: payload.statusCode,
          renderTimeMicros: payload.renderTimeMicros,
          width: payload.width,
          height: payload.height,
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

  final studioSurfaces = <int, _StudioSurface>{};
  var nextSurfaceId = 1;
  void cleanupAllSurfaces() {
    for (final surface in studioSurfaces.values) {
      surface.dispose();
    }
    studioSurfaces.clear();
  }

  SendPort? responsePort;
  commandPort.listen(
    (Object? message) {
      if (message is _AttachResponsePort) {
        responsePort = message.port;
        return;
      }

      if (message is _ShutdownRequest) {
        cleanupAllSurfaces();
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

      if (message is _OpenStudioSurfaceRequest) {
        try {
          final surfaceId = _executeOpenStudioSurface(
            message,
            studioSurfaces,
            () => nextSurfaceId++,
          );
          responsePort?.send(
            _WorkerResponse(id: message.id, payload: surfaceId),
          );
        } catch (error) {
          responsePort?.send(
            _WorkerResponse(id: message.id, error: error.toString()),
          );
        }
        return;
      }

      if (message is _RenderStudioSurfaceRequest) {
        try {
          final payload = _executeRenderStudioSurface(
            bindings,
            message,
            studioSurfaces,
          );
          responsePort?.send(_WorkerResponse(id: message.id, payload: payload));
        } catch (error) {
          responsePort?.send(
            _WorkerResponse(id: message.id, error: error.toString()),
          );
        }
        return;
      }

      if (message is _AnalyzeStudioSurfaceRequest) {
        try {
          final result = _executeAnalyzeStudioSurface(
            bindings,
            message,
            studioSurfaces,
          );
          responsePort?.send(_WorkerResponse(id: message.id, payload: result));
        } catch (error) {
          responsePort?.send(
            _WorkerResponse(id: message.id, error: error.toString()),
          );
        }
        return;
      }

      if (message is _CloseStudioSurfaceRequest) {
        try {
          final surface = studioSurfaces.remove(message.surfaceId);
          surface?.dispose();
          responsePort?.send(_WorkerResponse(id: message.id, payload: null));
        } catch (error) {
          responsePort?.send(
            _WorkerResponse(id: message.id, error: error.toString()),
          );
        }
        return;
      }

      if (message is _ClampCropRequest) {
        try {
          final result = _executeClampCrop(bindings, message);
          responsePort?.send(_WorkerResponse(id: message.id, payload: result));
        } catch (error) {
          responsePort?.send(
            _WorkerResponse(id: message.id, error: error.toString()),
          );
        }
        return;
      }

      if (message is _AnalyzeGeometrySurfaceRequest) {
        try {
          final result = _executeAnalyzeGeometrySurface(
            bindings,
            message,
            studioSurfaces,
          );
          responsePort?.send(_WorkerResponse(id: message.id, payload: result));
        } catch (error) {
          responsePort?.send(
            _WorkerResponse(id: message.id, error: error.toString()),
          );
        }
        return;
      }

      if (message is _RenderGeometrySurfaceRequest) {
        try {
          final payload = _executeRenderGeometrySurface(
            bindings,
            message,
            studioSurfaces,
          );
          responsePort?.send(_WorkerResponse(id: message.id, payload: payload));
        } catch (error) {
          responsePort?.send(
            _WorkerResponse(id: message.id, error: error.toString()),
          );
        }
        return;
      }

      if (message is _RenderCollageRequest) {
        try {
          final payload = _executeRenderCollage(bindings, message);
          responsePort?.send(_WorkerResponse(id: message.id, payload: payload));
        } catch (error) {
          responsePort?.send(
            _WorkerResponse(id: message.id, error: error.toString()),
          );
        }
        return;
      }

      if (message is _RunExportPipelineRequest) {
        try {
          final result = _executeRunExportPipeline(bindings, message);
          responsePort?.send(_WorkerResponse(id: message.id, payload: result));
        } catch (error) {
          responsePort?.send(
            _WorkerResponse(id: message.id, error: error.toString()),
          );
        }
        return;
      }

      if (message is _RenderCollageToRawFileRequest) {
        try {
          final result = _executeRenderCollageToRawFile(bindings, message);
          responsePort?.send(_WorkerResponse(id: message.id, payload: result));
        } catch (error) {
          responsePort?.send(
            _WorkerResponse(id: message.id, error: error.toString()),
          );
        }
        return;
      }
    },
    onDone: cleanupAllSurfaces,
  );
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

int _executeOpenStudioSurface(
  _OpenStudioSurfaceRequest request,
  Map<int, _StudioSurface> studioSurfaces,
  int Function() nextId,
) {
  if (studioSurfaces.length >= 2) {
    throw StateError('Maximum concurrent studio surfaces (2) exceeded.');
  }

  const int maxInt32 = 0x7FFFFFFF;
  const int maxImageDim = FS_MAX_IMAGE_DIMENSION;

  if (request.width <= 0 || request.height <= 0) {
    throw ArgumentError(
      'Invalid studio surface dimensions: ${request.width}x${request.height}',
    );
  }
  if (request.width > maxInt32 ||
      request.height > maxInt32 ||
      request.width > maxImageDim ||
      request.height > maxImageDim ||
      request.width > (maxInt32 ~/ 4) ~/ request.height) {
    throw RangeError(
      'Studio surface dimensions overflow int32/FS_MAX_IMAGE_DIMENSION.',
    );
  }

  final byteLen = request.width * request.height * 4;
  if (request.sourceByteLength < byteLen) {
    throw ArgumentError(
      'Undersized sourceRgba (${request.sourceByteLength} < $byteLen).',
    );
  }

  ffi.Pointer<ffi.Uint8> srcPtr = ffi.nullptr;
  ffi.Pointer<ffi.Uint8> dstPtr = ffi.nullptr;
  ffi.Pointer<FsDnaRescueParams> paramsPtr = ffi.nullptr;
  ffi.Pointer<FsDnaRescueSuggestion> suggestionPtr = ffi.nullptr;

  try {
    final sourceBytes = request.sourceRgba.materialize().asUint8List();
    srcPtr = calloc<ffi.Uint8>(byteLen);
    dstPtr = calloc<ffi.Uint8>(byteLen);
    paramsPtr = calloc<FsDnaRescueParams>();
    suggestionPtr = calloc<FsDnaRescueSuggestion>();
    srcPtr.asTypedList(byteLen).setRange(0, byteLen, sourceBytes);

    final id = nextId();
    studioSurfaces[id] = _StudioSurface(
      width: request.width,
      height: request.height,
      byteLen: byteLen,
      srcPtr: srcPtr,
      dstPtr: dstPtr,
      paramsPtr: paramsPtr,
      suggestionPtr: suggestionPtr,
    );
    srcPtr = ffi.nullptr;
    dstPtr = ffi.nullptr;
    paramsPtr = ffi.nullptr;
    suggestionPtr = ffi.nullptr;
    return id;
  } finally {
    if (suggestionPtr != ffi.nullptr) calloc.free(suggestionPtr);
    if (paramsPtr != ffi.nullptr) calloc.free(paramsPtr);
    if (dstPtr != ffi.nullptr) calloc.free(dstPtr);
    if (srcPtr != ffi.nullptr) calloc.free(srcPtr);
  }
}

_StudioRenderPayload _executeRenderStudioSurface(
  FujiStudioBindings bindings,
  _RenderStudioSurfaceRequest request,
  Map<int, _StudioSurface> studioSurfaces,
) {
  final surface = studioSurfaces[request.surfaceId];
  if (surface == null) {
    throw StateError('Studio surface ${request.surfaceId} is not open.');
  }

  surface.paramsPtr.ref
    ..shadow_lift = request.params.shadowLift
    ..midtone_anchor = request.params.midtoneAnchor
    ..highlight_protect = request.params.highlightProtect
    ..mode = request.params.mode
    ..enabled = request.params.enabled ? 1 : 0
    ..skin_protect = request.params.skinProtect;

  final sw = Stopwatch()..start();
  final rc = bindings.fs_dna_rescue_apply_rgba_into(
    surface.srcPtr,
    surface.byteLen,
    surface.width,
    surface.height,
    surface.paramsPtr,
    surface.dstPtr,
    surface.byteLen,
  );
  sw.stop();

  if (rc != FsStatusCode.FS_OK.value) {
    return _StudioRenderPayload(
      statusCode: rc,
      renderTimeMicros: sw.elapsedMicroseconds,
      width: surface.width,
      height: surface.height,
      transferable: null,
    );
  }

  surface.hasValidDst = true;
  final transferable = TransferableTypedData.fromList(<Uint8List>[
    surface.dstPtr.asTypedList(surface.byteLen),
  ]);
  return _StudioRenderPayload(
    statusCode: rc,
    renderTimeMicros: sw.elapsedMicroseconds,
    width: surface.width,
    height: surface.height,
    transferable: transferable,
  );
}

DnaRescueSuggestionResult _executeAnalyzeStudioSurface(
  FujiStudioBindings bindings,
  _AnalyzeStudioSurfaceRequest request,
  Map<int, _StudioSurface> studioSurfaces,
) {
  final surface = studioSurfaces[request.surfaceId];
  if (surface == null) {
    throw StateError('Studio surface ${request.surfaceId} is not open.');
  }

  final sw = Stopwatch()..start();
  final rc = bindings.fs_dna_rescue_analyze_rgba(
    surface.srcPtr,
    surface.byteLen,
    surface.width,
    surface.height,
    surface.suggestionPtr,
  );
  sw.stop();

  final sug = surface.suggestionPtr.ref;
  return DnaRescueSuggestionResult(
    statusCode: rc,
    elapsedMicroseconds: sw.elapsedMicroseconds,
    recommendedShadowLift: sug.recommended_shadow_lift,
    p10Luma: sug.p10_luma,
    p50Luma: sug.p50_luma,
    p95Luma: sug.p95_luma,
    shadowPixelRatio: sug.shadow_pixel_ratio,
    recommendedMode: sug.recommended_mode,
  );
}

int? _validateRgbaDimensions(int width, int height) {
  const int maxInt32 = 0x7FFFFFFF;
  const int maxImageDim = FS_MAX_IMAGE_DIMENSION;
  if (width <= 0 || height <= 0) {
    return FsStatusCode.FS_ERR_INVALID_DIMENSIONS.value;
  }
  if (width > maxInt32 ||
      height > maxInt32 ||
      width > maxImageDim ||
      height > maxImageDim ||
      width > (maxInt32 ~/ 4) ~/ height) {
    return FsStatusCode.FS_ERR_OVERFLOW.value;
  }
  return null;
}

ClampedCropResult _executeClampCrop(
  FujiStudioBindings bindings,
  _ClampCropRequest request,
) {
  final sw = Stopwatch()..start();
  final dimErr = _validateRgbaDimensions(request.srcWidth, request.srcHeight);
  if (dimErr != null) {
    sw.stop();
    return ClampedCropResult(
      statusCode: dimErr,
      elapsedMicroseconds: sw.elapsedMicroseconds,
      clampedBox: NormCropBoxData.full,
      pixelWidth: 0,
      pixelHeight: 0,
    );
  }

  ffi.Pointer<FsNormCropBox> reqPtr = ffi.nullptr;
  ffi.Pointer<FsNormCropBox> outPtr = ffi.nullptr;
  ffi.Pointer<ffi.Int32> outWPtr = ffi.nullptr;
  ffi.Pointer<ffi.Int32> outHPtr = ffi.nullptr;
  try {
    reqPtr = calloc<FsNormCropBox>()
      ..ref.left = request.requestedBox.left
      ..ref.top = request.requestedBox.top
      ..ref.right = request.requestedBox.right
      ..ref.bottom = request.requestedBox.bottom;
    outPtr = calloc<FsNormCropBox>();
    outWPtr = calloc<ffi.Int32>();
    outHPtr = calloc<ffi.Int32>();

    final rc = bindings.fs_geometry_clamp_crop(
      request.srcWidth,
      request.srcHeight,
      request.rotationDeg,
      request.aspectPreset,
      reqPtr,
      outPtr,
      outWPtr,
      outHPtr,
    );
    sw.stop();

    final clamped = outPtr.ref;
    return ClampedCropResult(
      statusCode: rc,
      elapsedMicroseconds: sw.elapsedMicroseconds,
      clampedBox: NormCropBoxData(
        left: clamped.left,
        top: clamped.top,
        right: clamped.right,
        bottom: clamped.bottom,
      ),
      pixelWidth: outWPtr.value,
      pixelHeight: outHPtr.value,
    );
  } finally {
    if (outHPtr != ffi.nullptr) calloc.free(outHPtr);
    if (outWPtr != ffi.nullptr) calloc.free(outWPtr);
    if (outPtr != ffi.nullptr) calloc.free(outPtr);
    if (reqPtr != ffi.nullptr) calloc.free(reqPtr);
  }
}

GeometryProposalNative _executeAnalyzeGeometrySurface(
  FujiStudioBindings bindings,
  _AnalyzeGeometrySurfaceRequest request,
  Map<int, _StudioSurface> studioSurfaces,
) {
  final surface = studioSurfaces[request.surfaceId];
  if (surface == null) {
    throw StateError('Studio surface ${request.surfaceId} is not open.');
  }

  ffi.Pointer<FsGeometryProposal> propPtr = ffi.nullptr;
  try {
    propPtr = calloc<FsGeometryProposal>();
    final inputPtr = (request.useRescuedBuffer && surface.hasValidDst)
        ? surface.dstPtr
        : surface.srcPtr;
    final sw = Stopwatch()..start();
    final rc = bindings.fs_geometry_analyze_rgba(
      inputPtr,
      surface.byteLen,
      surface.width,
      surface.height,
      request.targetAspectPreset,
      propPtr,
    );
    sw.stop();

    final p = propPtr.ref;
    return GeometryProposalNative(
      statusCode: rc,
      elapsedMicroseconds: sw.elapsedMicroseconds,
      suggestedRotationDeg: p.suggested_rotation_deg,
      horizonConfidence: p.horizon_confidence,
      suggestedCropBox: NormCropBoxData(
        left: p.suggested_crop_box.left,
        top: p.suggested_crop_box.top,
        right: p.suggested_crop_box.right,
        bottom: p.suggested_crop_box.bottom,
      ),
      cropConfidence: p.crop_confidence,
      saliencyCx: p.saliency_cx,
      saliencyCy: p.saliency_cy,
      hasHorizonLine: p.has_horizon_line != 0,
      targetAspectPreset: p.target_aspect_preset,
    );
  } finally {
    if (propPtr != ffi.nullptr) calloc.free(propPtr);
  }
}

_StudioRenderPayload _executeRenderGeometrySurface(
  FujiStudioBindings bindings,
  _RenderGeometrySurfaceRequest request,
  Map<int, _StudioSurface> studioSurfaces,
) {
  final surface = studioSurfaces[request.surfaceId];
  if (surface == null) {
    throw StateError('Studio surface ${request.surfaceId} is not open.');
  }

  final sw = Stopwatch()..start();
  final dimErr = _validateRgbaDimensions(request.outWidth, request.outHeight);
  if (dimErr != null) {
    sw.stop();
    return _StudioRenderPayload(
      statusCode: dimErr,
      renderTimeMicros: sw.elapsedMicroseconds,
      width: 0,
      height: 0,
      transferable: null,
    );
  }

  final outByteLen = request.outWidth * request.outHeight * 4;
  ffi.Pointer<FsGeometryParams> paramsPtr = ffi.nullptr;
  ffi.Pointer<ffi.Uint8> outPtr = ffi.nullptr;

  try {
    paramsPtr = calloc<FsGeometryParams>()
      ..ref.rotation_deg = request.params.rotationDeg
      ..ref.aspect_preset = request.params.aspectPreset
      ..ref.crop_box.left = request.params.cropBox.left
      ..ref.crop_box.top = request.params.cropBox.top
      ..ref.crop_box.right = request.params.cropBox.right
      ..ref.crop_box.bottom = request.params.cropBox.bottom
      ..ref.high_quality = request.params.highQuality ? 1 : 0;

    outPtr = calloc<ffi.Uint8>(outByteLen);
    final rc = bindings.fs_geometry_render_rgba_into(
      surface.srcPtr,
      surface.byteLen,
      surface.width,
      surface.height,
      paramsPtr,
      outPtr,
      outByteLen,
      request.outWidth,
      request.outHeight,
    );
    sw.stop();

    if (rc != FsStatusCode.FS_OK.value) {
      return _StudioRenderPayload(
        statusCode: rc,
        renderTimeMicros: sw.elapsedMicroseconds,
        width: request.outWidth,
        height: request.outHeight,
        transferable: null,
      );
    }

    final transferable = TransferableTypedData.fromList(<Uint8List>[
      outPtr.asTypedList(outByteLen),
    ]);
    return _StudioRenderPayload(
      statusCode: rc,
      renderTimeMicros: sw.elapsedMicroseconds,
      width: request.outWidth,
      height: request.outHeight,
      transferable: transferable,
    );
  } finally {
    if (outPtr != ffi.nullptr) calloc.free(outPtr);
    if (paramsPtr != ffi.nullptr) calloc.free(paramsPtr);
  }
}

_CollageRenderPayload _executeRenderCollage(
  FujiStudioBindings bindings,
  _RenderCollageRequest request,
) {
  final sw = Stopwatch()..start();
  final slots = request.slots;
  final cfg = request.config;

  if (slots.length < 2 || slots.length > 4) {
    sw.stop();
    return _CollageRenderPayload(
      statusCode: FsStatusCode.FS_ERR_COLLAGE_INVALID_SLOTS.value,
      renderTimeMicros: sw.elapsedMicroseconds,
      width: cfg.canvasWidth,
      height: cfg.canvasHeight,
      transferable: null,
    );
  }

  final canvasDimErr =
      _validateRgbaDimensions(cfg.canvasWidth, cfg.canvasHeight);
  if (canvasDimErr != null) {
    sw.stop();
    return _CollageRenderPayload(
      statusCode: canvasDimErr,
      renderTimeMicros: sw.elapsedMicroseconds,
      width: cfg.canvasWidth,
      height: cfg.canvasHeight,
      transferable: null,
    );
  }

  for (final slot in slots) {
    final slotDimErr = _validateRgbaDimensions(slot.width, slot.height);
    if (slotDimErr != null) {
      sw.stop();
      return _CollageRenderPayload(
        statusCode: slotDimErr,
        renderTimeMicros: sw.elapsedMicroseconds,
        width: cfg.canvasWidth,
        height: cfg.canvasHeight,
        transferable: null,
      );
    }
    final expectedSlotBytes = slot.width * slot.height * 4;
    if (slot.byteLength < expectedSlotBytes) {
      sw.stop();
      return _CollageRenderPayload(
        statusCode: FsStatusCode.FS_ERR_INVALID_DIMENSIONS.value,
        renderTimeMicros: sw.elapsedMicroseconds,
        width: cfg.canvasWidth,
        height: cfg.canvasHeight,
        transferable: null,
      );
    }
  }

  final canvasByteLen = cfg.canvasWidth * cfg.canvasHeight * 4;
  final slotPtrs = <ffi.Pointer<ffi.Uint8>>[];
  ffi.Pointer<FsCollageInputSlot> slotsArray = ffi.nullptr;
  ffi.Pointer<FsCollageConfig> configPtr = ffi.nullptr;
  ffi.Pointer<ffi.Uint8> outPtr = ffi.nullptr;

  try {
    slotsArray = calloc<FsCollageInputSlot>(slots.length);
    for (var i = 0; i < slots.length; i++) {
      final slot = slots[i];
      final bytes = slot.rgba.materialize().asUint8List();
      final allocLen = bytes.isEmpty ? 1 : bytes.length;
      final ptr = calloc<ffi.Uint8>(allocLen);
      slotPtrs.add(ptr);
      if (bytes.isNotEmpty) {
        ptr.asTypedList(bytes.length).setAll(0, bytes);
      }

      slotsArray[i]
        ..rgba = ptr
        ..rgba_len = bytes.length
        ..width = slot.width
        ..height = slot.height
        ..pan_x = slot.panX
        ..pan_y = slot.panY
        ..zoom = slot.zoom
        ..reserved = 0;
    }

    configPtr = calloc<FsCollageConfig>()
      ..ref.template_id = cfg.templateId
      ..ref.canvas_width = cfg.canvasWidth
      ..ref.canvas_height = cfg.canvasHeight
      ..ref.gutter_px = cfg.gutterPx
      ..ref.outer_margin_px = cfg.outerMarginPx
      ..ref.bg_r = cfg.bgR
      ..ref.bg_g = cfg.bgG
      ..ref.bg_b = cfg.bgB
      ..ref.bg_a = cfg.bgA;

    outPtr = calloc<ffi.Uint8>(canvasByteLen);

    final rc = bindings.fs_collage_render_rgba_into(
      slotsArray,
      slots.length,
      configPtr,
      outPtr,
      canvasByteLen,
    );
    sw.stop();

    if (rc != FsStatusCode.FS_OK.value) {
      return _CollageRenderPayload(
        statusCode: rc,
        renderTimeMicros: sw.elapsedMicroseconds,
        width: cfg.canvasWidth,
        height: cfg.canvasHeight,
        transferable: null,
      );
    }

    final transferable = TransferableTypedData.fromList(<Uint8List>[
      outPtr.asTypedList(canvasByteLen),
    ]);
    return _CollageRenderPayload(
      statusCode: rc,
      renderTimeMicros: sw.elapsedMicroseconds,
      width: cfg.canvasWidth,
      height: cfg.canvasHeight,
      transferable: transferable,
    );
  } finally {
    if (outPtr != ffi.nullptr) calloc.free(outPtr);
    if (configPtr != ffi.nullptr) calloc.free(configPtr);
    if (slotsArray != ffi.nullptr) calloc.free(slotsArray);
    for (final ptr in slotPtrs) {
      if (ptr != ffi.nullptr) calloc.free(ptr);
    }
  }
}

void _readExactRawRgbaFileIntoNative(
  String path,
  ffi.Pointer<ffi.Uint8> dst,
  int expectedBytes,
) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('Raw RGBA input file not found: $path');
  }
  final raf = file.openSync(mode: FileMode.read);
  try {
    final len = raf.lengthSync();
    if (len < expectedBytes) {
      throw StateError(
        'Raw RGBA file $path truncated ($len < $expectedBytes bytes).',
      );
    }
    final view = dst.asTypedList(expectedBytes);
    var offset = 0;
    while (offset < expectedBytes) {
      final n = raf.readIntoSync(view, offset, expectedBytes);
      if (n <= 0) {
        throw StateError('Unexpected EOF reading $path at $offset.');
      }
      offset += n;
    }
  } finally {
    raf.closeSync();
  }
}

void _writeAtomicRawRgbaFromNative(
  String outPath,
  ffi.Pointer<ffi.Uint8> src,
  int byteLen,
) {
  final outFile = File(outPath);
  outFile.parent.createSync(recursive: true);
  final tmpFile = File('$outPath.tmp');
  final raf = tmpFile.openSync(mode: FileMode.write);
  try {
    raf.writeFromSync(src.asTypedList(byteLen), 0, byteLen);
  } finally {
    raf.closeSync();
  }
  if (outFile.existsSync()) {
    outFile.deleteSync();
  }
  tmpFile.renameSync(outPath);
}

ExportRgbaResult _executeRunExportPipeline(
  FujiStudioBindings bindings,
  _RunExportPipelineRequest request,
) {
  final sw = Stopwatch()..start();
  final srcDimErr = _validateRgbaDimensions(request.srcWidth, request.srcHeight);
  if (srcDimErr != null) {
    sw.stop();
    return ExportRgbaResult(
      statusCode: srcDimErr,
      renderTimeMicros: sw.elapsedMicroseconds,
      width: 0,
      height: 0,
      rawOutputPath: request.rawOutputPath,
    );
  }

  var curW = request.srcWidth;
  var curH = request.srcHeight;
  var curBytes = curW * curH * 4;

  ffi.Pointer<ffi.Uint8> bufA = ffi.nullptr;
  ffi.Pointer<ffi.Uint8> bufB = ffi.nullptr;
  ffi.Pointer<FsDnaRescueParams> dnaPtr = ffi.nullptr;
  ffi.Pointer<FsNormCropBox> reqBoxPtr = ffi.nullptr;
  ffi.Pointer<FsNormCropBox> clampedBoxPtr = ffi.nullptr;
  ffi.Pointer<ffi.Int32> outWPtr = ffi.nullptr;
  ffi.Pointer<ffi.Int32> outHPtr = ffi.nullptr;
  ffi.Pointer<FsGeometryParams> geomPtr = ffi.nullptr;
  ffi.Pointer<FsOutputUsmParams> usmPtr = ffi.nullptr;

  try {
    bufA = calloc<ffi.Uint8>(curBytes);
    _readExactRawRgbaFileIntoNative(request.rawInputPath, bufA, curBytes);

    // 1. Zero-Haze DNA Rescue v2 (in-place on bufA)
    final dna = request.dnaRescue;
    if (dna != null && dna.enabled && dna.shadowLift > 0.0) {
      dnaPtr = calloc<FsDnaRescueParams>()
        ..ref.shadow_lift = dna.shadowLift
        ..ref.midtone_anchor = dna.midtoneAnchor
        ..ref.highlight_protect = dna.highlightProtect
        ..ref.mode = dna.mode
        ..ref.enabled = 1
        ..ref.skin_protect = dna.skinProtect;
      final rc = bindings.fs_dna_rescue_apply_rgba_into(
        bufA,
        curBytes,
        curW,
        curH,
        dnaPtr,
        bufA,
        curBytes,
      );
      if (rc != FsStatusCode.FS_OK.value) {
        sw.stop();
        return ExportRgbaResult(
          statusCode: rc,
          renderTimeMicros: sw.elapsedMicroseconds,
          width: curW,
          height: curH,
          rawOutputPath: request.rawOutputPath,
        );
      }
    }

    // 2. Horizon & Crop Catmull-Rom (high_quality = 1, only when rotated or cropped)
    final geom = request.geometry;
    final needsGeometry = geom != null &&
        (geom.rotationDeg.abs() > 1e-4 ||
            geom.aspectPreset != FsAspectPreset.FS_ASPECT_ORIGINAL.value ||
            geom.cropBox.left > 1e-4 ||
            geom.cropBox.top > 1e-4 ||
            geom.cropBox.right < 1.0 - 1e-4 ||
            geom.cropBox.bottom < 1.0 - 1e-4);

    if (needsGeometry) {
      reqBoxPtr = calloc<FsNormCropBox>()
        ..ref.left = geom.cropBox.left
        ..ref.top = geom.cropBox.top
        ..ref.right = geom.cropBox.right
        ..ref.bottom = geom.cropBox.bottom;
      clampedBoxPtr = calloc<FsNormCropBox>();
      outWPtr = calloc<ffi.Int32>();
      outHPtr = calloc<ffi.Int32>();

      final clampRc = bindings.fs_geometry_clamp_crop(
        curW,
        curH,
        geom.rotationDeg,
        geom.aspectPreset,
        reqBoxPtr,
        clampedBoxPtr,
        outWPtr,
        outHPtr,
      );
      if (clampRc != FsStatusCode.FS_OK.value) {
        sw.stop();
        return ExportRgbaResult(
          statusCode: clampRc,
          renderTimeMicros: sw.elapsedMicroseconds,
          width: curW,
          height: curH,
          rawOutputPath: request.rawOutputPath,
        );
      }

      final nextW = outWPtr.value;
      final nextH = outHPtr.value;
      final nextDimErr = _validateRgbaDimensions(nextW, nextH);
      if (nextDimErr != null) {
        sw.stop();
        return ExportRgbaResult(
          statusCode: nextDimErr,
          renderTimeMicros: sw.elapsedMicroseconds,
          width: nextW,
          height: nextH,
          rawOutputPath: request.rawOutputPath,
        );
      }

      final nextBytes = nextW * nextH * 4;
      geomPtr = calloc<FsGeometryParams>()
        ..ref.rotation_deg = geom.rotationDeg
        ..ref.aspect_preset = geom.aspectPreset
        ..ref.crop_box.left = clampedBoxPtr.ref.left
        ..ref.crop_box.top = clampedBoxPtr.ref.top
        ..ref.crop_box.right = clampedBoxPtr.ref.right
        ..ref.crop_box.bottom = clampedBoxPtr.ref.bottom
        ..ref.high_quality = 1;

      bufB = calloc<ffi.Uint8>(nextBytes);
      final renderRc = bindings.fs_geometry_render_rgba_into(
        bufA,
        curBytes,
        curW,
        curH,
        geomPtr,
        bufB,
        nextBytes,
        nextW,
        nextH,
      );
      if (renderRc != FsStatusCode.FS_OK.value) {
        sw.stop();
        return ExportRgbaResult(
          statusCode: renderRc,
          renderTimeMicros: sw.elapsedMicroseconds,
          width: nextW,
          height: nextH,
          rawOutputPath: request.rawOutputPath,
        );
      }

      // Immediately free previous full-res buffer before proceeding.
      calloc.free(bufA);
      bufA = bufB;
      bufB = ffi.nullptr;
      curW = nextW;
      curH = nextH;
      curBytes = nextBytes;
    }

    // 3. Lanczos3 Downscale (strictly no upscale)
    final maxEdge = request.targetMaxLongEdge;
    if (maxEdge > 0 && math.max(curW, curH) > maxEdge) {
      final int dstW;
      final int dstH;
      if (curW >= curH) {
        dstW = maxEdge;
        dstH = math.max(1, (curH * maxEdge / curW).round());
      } else {
        dstH = maxEdge;
        dstW = math.max(1, (curW * maxEdge / curH).round());
      }
      final dstDimErr = _validateRgbaDimensions(dstW, dstH);
      if (dstDimErr != null) {
        sw.stop();
        return ExportRgbaResult(
          statusCode: dstDimErr,
          renderTimeMicros: sw.elapsedMicroseconds,
          width: dstW,
          height: dstH,
          rawOutputPath: request.rawOutputPath,
        );
      }

      final dstBytes = dstW * dstH * 4;
      bufB = calloc<ffi.Uint8>(dstBytes);
      final resizeRc = bindings.fs_export_lanczos3_resize_rgba_into(
        bufA,
        curBytes,
        curW,
        curH,
        bufB,
        dstBytes,
        dstW,
        dstH,
      );
      if (resizeRc != FsStatusCode.FS_OK.value) {
        sw.stop();
        return ExportRgbaResult(
          statusCode: resizeRc,
          renderTimeMicros: sw.elapsedMicroseconds,
          width: dstW,
          height: dstH,
          rawOutputPath: request.rawOutputPath,
        );
      }

      calloc.free(bufA);
      bufA = bufB;
      bufB = ffi.nullptr;
      curW = dstW;
      curH = dstH;
      curBytes = dstBytes;
    }

    // 4. Output USM (in-place on bufA)
    final usm = request.outputUsm;
    if (usm != null && usm.enabled && usm.amount > 0.0) {
      usmPtr = calloc<FsOutputUsmParams>()
        ..ref.amount = usm.amount
        ..ref.radius = usm.radius
        ..ref.threshold = usm.threshold
        ..ref.halo_clamp = usm.haloClamp
        ..ref.enabled = 1;
      final usmRc = bindings.fs_export_output_usm_rgba_into(
        bufA,
        curBytes,
        curW,
        curH,
        usmPtr,
        bufA,
        curBytes,
      );
      if (usmRc != FsStatusCode.FS_OK.value) {
        sw.stop();
        return ExportRgbaResult(
          statusCode: usmRc,
          renderTimeMicros: sw.elapsedMicroseconds,
          width: curW,
          height: curH,
          rawOutputPath: request.rawOutputPath,
        );
      }
    }

    // 5. Atomic write to rawOutputPath
    _writeAtomicRawRgbaFromNative(request.rawOutputPath, bufA, curBytes);
    sw.stop();
    return ExportRgbaResult(
      statusCode: FsStatusCode.FS_OK.value,
      renderTimeMicros: sw.elapsedMicroseconds,
      width: curW,
      height: curH,
      rawOutputPath: request.rawOutputPath,
    );
  } finally {
    if (usmPtr != ffi.nullptr) calloc.free(usmPtr);
    if (geomPtr != ffi.nullptr) calloc.free(geomPtr);
    if (outHPtr != ffi.nullptr) calloc.free(outHPtr);
    if (outWPtr != ffi.nullptr) calloc.free(outWPtr);
    if (clampedBoxPtr != ffi.nullptr) calloc.free(clampedBoxPtr);
    if (reqBoxPtr != ffi.nullptr) calloc.free(reqBoxPtr);
    if (dnaPtr != ffi.nullptr) calloc.free(dnaPtr);
    if (bufB != ffi.nullptr) calloc.free(bufB);
    if (bufA != ffi.nullptr) calloc.free(bufA);
  }
}

ExportRgbaResult _executeRenderCollageToRawFile(
  FujiStudioBindings bindings,
  _RenderCollageToRawFileRequest request,
) {
  final sw = Stopwatch()..start();
  final slots = request.slots;
  final cfg = request.config;

  if (slots.length < 2 || slots.length > 4) {
    sw.stop();
    return ExportRgbaResult(
      statusCode: FsStatusCode.FS_ERR_COLLAGE_INVALID_SLOTS.value,
      renderTimeMicros: sw.elapsedMicroseconds,
      width: cfg.canvasWidth,
      height: cfg.canvasHeight,
      rawOutputPath: request.rawOutputPath,
    );
  }

  final canvasDimErr = _validateRgbaDimensions(cfg.canvasWidth, cfg.canvasHeight);
  if (canvasDimErr != null) {
    sw.stop();
    return ExportRgbaResult(
      statusCode: canvasDimErr,
      renderTimeMicros: sw.elapsedMicroseconds,
      width: cfg.canvasWidth,
      height: cfg.canvasHeight,
      rawOutputPath: request.rawOutputPath,
    );
  }

  for (final slot in slots) {
    final slotDimErr = _validateRgbaDimensions(slot.width, slot.height);
    if (slotDimErr != null) {
      sw.stop();
      return ExportRgbaResult(
        statusCode: slotDimErr,
        renderTimeMicros: sw.elapsedMicroseconds,
        width: cfg.canvasWidth,
        height: cfg.canvasHeight,
        rawOutputPath: request.rawOutputPath,
      );
    }
  }

  final canvasByteLen = cfg.canvasWidth * cfg.canvasHeight * 4;
  final slotPtrs = <ffi.Pointer<ffi.Uint8>>[];
  ffi.Pointer<FsCollageInputSlot> slotsArray = ffi.nullptr;
  ffi.Pointer<FsCollageConfig> configPtr = ffi.nullptr;
  ffi.Pointer<FsDnaRescueParams> dnaPtr = ffi.nullptr;
  ffi.Pointer<FsNormCropBox> reqBoxPtr = ffi.nullptr;
  ffi.Pointer<FsNormCropBox> clampedBoxPtr = ffi.nullptr;
  ffi.Pointer<ffi.Int32> outWPtr = ffi.nullptr;
  ffi.Pointer<ffi.Int32> outHPtr = ffi.nullptr;
  ffi.Pointer<FsGeometryParams> geomPtr = ffi.nullptr;
  ffi.Pointer<FsOutputUsmParams> usmPtr = ffi.nullptr;
  ffi.Pointer<ffi.Uint8> outPtr = ffi.nullptr;

  try {
    slotsArray = calloc<FsCollageInputSlot>(slots.length);
    for (var i = 0; i < slots.length; i++) {
      final slot = slots[i];
      var curW = slot.width;
      var curH = slot.height;
      var curBytes = curW * curH * 4;
      var curPtr = calloc<ffi.Uint8>(curBytes);
      slotPtrs.add(curPtr);
      _readExactRawRgbaFileIntoNative(slot.rawInputPath, curPtr, curBytes);

      final dna = slot.dnaRescue;
      if (dna != null && dna.enabled && dna.shadowLift > 0.0) {
        if (dnaPtr == ffi.nullptr) {
          dnaPtr = calloc<FsDnaRescueParams>();
        }
        dnaPtr.ref
          ..shadow_lift = dna.shadowLift
          ..midtone_anchor = dna.midtoneAnchor
          ..highlight_protect = dna.highlightProtect
          ..mode = dna.mode
          ..enabled = 1
          ..skin_protect = dna.skinProtect;
        final dnaRc = bindings.fs_dna_rescue_apply_rgba_into(
          curPtr,
          curBytes,
          curW,
          curH,
          dnaPtr,
          curPtr,
          curBytes,
        );
        if (dnaRc != FsStatusCode.FS_OK.value) {
          sw.stop();
          return ExportRgbaResult(
            statusCode: dnaRc,
            renderTimeMicros: sw.elapsedMicroseconds,
            width: cfg.canvasWidth,
            height: cfg.canvasHeight,
            rawOutputPath: request.rawOutputPath,
          );
        }
      }

      final geom = slot.geometry;
      final needsGeometry = geom != null &&
          (geom.rotationDeg.abs() > 1e-4 ||
              geom.aspectPreset != FsAspectPreset.FS_ASPECT_ORIGINAL.value ||
              geom.cropBox.left > 1e-4 ||
              geom.cropBox.top > 1e-4 ||
              geom.cropBox.right < 1.0 - 1e-4 ||
              geom.cropBox.bottom < 1.0 - 1e-4);
      if (needsGeometry) {
        if (reqBoxPtr == ffi.nullptr) reqBoxPtr = calloc<FsNormCropBox>();
        if (clampedBoxPtr == ffi.nullptr) clampedBoxPtr = calloc<FsNormCropBox>();
        if (outWPtr == ffi.nullptr) outWPtr = calloc<ffi.Int32>();
        if (outHPtr == ffi.nullptr) outHPtr = calloc<ffi.Int32>();
        if (geomPtr == ffi.nullptr) geomPtr = calloc<FsGeometryParams>();

        reqBoxPtr.ref
          ..left = geom.cropBox.left
          ..top = geom.cropBox.top
          ..right = geom.cropBox.right
          ..bottom = geom.cropBox.bottom;

        final clampRc = bindings.fs_geometry_clamp_crop(
          curW,
          curH,
          geom.rotationDeg,
          geom.aspectPreset,
          reqBoxPtr,
          clampedBoxPtr,
          outWPtr,
          outHPtr,
        );
        if (clampRc != FsStatusCode.FS_OK.value) {
          sw.stop();
          return ExportRgbaResult(
            statusCode: clampRc,
            renderTimeMicros: sw.elapsedMicroseconds,
            width: cfg.canvasWidth,
            height: cfg.canvasHeight,
            rawOutputPath: request.rawOutputPath,
          );
        }

        final nextW = outWPtr.value;
        final nextH = outHPtr.value;
        final nextDimErr = _validateRgbaDimensions(nextW, nextH);
        if (nextDimErr != null) {
          sw.stop();
          return ExportRgbaResult(
            statusCode: nextDimErr,
            renderTimeMicros: sw.elapsedMicroseconds,
            width: cfg.canvasWidth,
            height: cfg.canvasHeight,
            rawOutputPath: request.rawOutputPath,
          );
        }

        final nextBytes = nextW * nextH * 4;
        geomPtr.ref
          ..rotation_deg = geom.rotationDeg
          ..aspect_preset = geom.aspectPreset
          ..crop_box.left = clampedBoxPtr.ref.left
          ..crop_box.top = clampedBoxPtr.ref.top
          ..crop_box.right = clampedBoxPtr.ref.right
          ..crop_box.bottom = clampedBoxPtr.ref.bottom
          ..high_quality = geom.highQuality ? 1 : 0;

        final nextPtr = calloc<ffi.Uint8>(nextBytes);
        slotPtrs.add(nextPtr);

        final geomRc = bindings.fs_geometry_render_rgba_into(
          curPtr,
          curBytes,
          curW,
          curH,
          geomPtr,
          nextPtr,
          nextBytes,
          nextW,
          nextH,
        );
        if (geomRc != FsStatusCode.FS_OK.value) {
          sw.stop();
          return ExportRgbaResult(
            statusCode: geomRc,
            renderTimeMicros: sw.elapsedMicroseconds,
            width: cfg.canvasWidth,
            height: cfg.canvasHeight,
            rawOutputPath: request.rawOutputPath,
          );
        }

        slotPtrs.remove(curPtr);
        calloc.free(curPtr);
        curPtr = nextPtr;
        curW = nextW;
        curH = nextH;
        curBytes = nextBytes;
      }

      slotsArray[i]
        ..rgba = curPtr
        ..rgba_len = curBytes
        ..width = curW
        ..height = curH
        ..pan_x = slot.panX
        ..pan_y = slot.panY
        ..zoom = slot.zoom
        ..reserved = 0;
    }

    configPtr = calloc<FsCollageConfig>()
      ..ref.template_id = cfg.templateId
      ..ref.canvas_width = cfg.canvasWidth
      ..ref.canvas_height = cfg.canvasHeight
      ..ref.gutter_px = cfg.gutterPx
      ..ref.outer_margin_px = cfg.outerMarginPx
      ..ref.bg_r = cfg.bgR
      ..ref.bg_g = cfg.bgG
      ..ref.bg_b = cfg.bgB
      ..ref.bg_a = cfg.bgA;

    outPtr = calloc<ffi.Uint8>(canvasByteLen);
    final rc = bindings.fs_collage_render_rgba_into(
      slotsArray,
      slots.length,
      configPtr,
      outPtr,
      canvasByteLen,
    );

    // Free slot buffers immediately after stitching to lower peak RAM.
    for (final ptr in slotPtrs) {
      if (ptr != ffi.nullptr) calloc.free(ptr);
    }
    slotPtrs.clear();
    calloc.free(slotsArray);
    slotsArray = ffi.nullptr;
    calloc.free(configPtr);
    configPtr = ffi.nullptr;

    if (rc != FsStatusCode.FS_OK.value) {
      sw.stop();
      return ExportRgbaResult(
        statusCode: rc,
        renderTimeMicros: sw.elapsedMicroseconds,
        width: cfg.canvasWidth,
        height: cfg.canvasHeight,
        rawOutputPath: request.rawOutputPath,
      );
    }

    final usm = request.outputUsm;
    if (usm != null && usm.enabled && usm.amount > 0.0) {
      usmPtr = calloc<FsOutputUsmParams>()
        ..ref.amount = usm.amount
        ..ref.radius = usm.radius
        ..ref.threshold = usm.threshold
        ..ref.halo_clamp = usm.haloClamp
        ..ref.enabled = 1;
      final usmRc = bindings.fs_export_output_usm_rgba_into(
        outPtr,
        canvasByteLen,
        cfg.canvasWidth,
        cfg.canvasHeight,
        usmPtr,
        outPtr,
        canvasByteLen,
      );
      if (usmRc != FsStatusCode.FS_OK.value) {
        sw.stop();
        return ExportRgbaResult(
          statusCode: usmRc,
          renderTimeMicros: sw.elapsedMicroseconds,
          width: cfg.canvasWidth,
          height: cfg.canvasHeight,
          rawOutputPath: request.rawOutputPath,
        );
      }
    }

    _writeAtomicRawRgbaFromNative(request.rawOutputPath, outPtr, canvasByteLen);
    sw.stop();
    return ExportRgbaResult(
      statusCode: FsStatusCode.FS_OK.value,
      renderTimeMicros: sw.elapsedMicroseconds,
      width: cfg.canvasWidth,
      height: cfg.canvasHeight,
      rawOutputPath: request.rawOutputPath,
    );
  } finally {
    if (outPtr != ffi.nullptr) calloc.free(outPtr);
    if (usmPtr != ffi.nullptr) calloc.free(usmPtr);
    if (geomPtr != ffi.nullptr) calloc.free(geomPtr);
    if (outHPtr != ffi.nullptr) calloc.free(outHPtr);
    if (outWPtr != ffi.nullptr) calloc.free(outWPtr);
    if (clampedBoxPtr != ffi.nullptr) calloc.free(clampedBoxPtr);
    if (reqBoxPtr != ffi.nullptr) calloc.free(reqBoxPtr);
    if (dnaPtr != ffi.nullptr) calloc.free(dnaPtr);
    if (configPtr != ffi.nullptr) calloc.free(configPtr);
    if (slotsArray != ffi.nullptr) calloc.free(slotsArray);
    for (final ptr in slotPtrs) {
      if (ptr != ffi.nullptr) calloc.free(ptr);
    }
  }
}

final class _StudioSurface {
  _StudioSurface({
    required this.width,
    required this.height,
    required this.byteLen,
    required this.srcPtr,
    required this.dstPtr,
    required this.paramsPtr,
    required this.suggestionPtr,
  });

  final int width;
  final int height;
  final int byteLen;
  ffi.Pointer<ffi.Uint8> srcPtr;
  ffi.Pointer<ffi.Uint8> dstPtr;
  ffi.Pointer<FsDnaRescueParams> paramsPtr;
  ffi.Pointer<FsDnaRescueSuggestion> suggestionPtr;
  bool hasValidDst = false;

  void dispose() {
    if (suggestionPtr != ffi.nullptr) {
      calloc.free(suggestionPtr);
      suggestionPtr = ffi.nullptr;
    }
    if (paramsPtr != ffi.nullptr) {
      calloc.free(paramsPtr);
      paramsPtr = ffi.nullptr;
    }
    if (dstPtr != ffi.nullptr) {
      calloc.free(dstPtr);
      dstPtr = ffi.nullptr;
    }
    if (srcPtr != ffi.nullptr) {
      calloc.free(srcPtr);
      srcPtr = ffi.nullptr;
    }
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

final class _OpenStudioSurfaceRequest extends _WorkerRequest {
  const _OpenStudioSurfaceRequest({
    required super.id,
    required this.width,
    required this.height,
    required this.sourceByteLength,
    required this.sourceRgba,
  });

  final int width;
  final int height;
  final int sourceByteLength;
  final TransferableTypedData sourceRgba;
}

final class _RenderStudioSurfaceRequest extends _WorkerRequest {
  const _RenderStudioSurfaceRequest({
    required super.id,
    required this.surfaceId,
    required this.params,
  });

  final int surfaceId;
  final DnaRescueNativeParams params;
}

final class _AnalyzeStudioSurfaceRequest extends _WorkerRequest {
  const _AnalyzeStudioSurfaceRequest({
    required super.id,
    required this.surfaceId,
  });

  final int surfaceId;
}

final class _CloseStudioSurfaceRequest extends _WorkerRequest {
  const _CloseStudioSurfaceRequest({
    required super.id,
    required this.surfaceId,
  });

  final int surfaceId;
}

final class _ClampCropRequest extends _WorkerRequest {
  const _ClampCropRequest({
    required super.id,
    required this.srcWidth,
    required this.srcHeight,
    required this.rotationDeg,
    required this.aspectPreset,
    required this.requestedBox,
  });

  final int srcWidth;
  final int srcHeight;
  final double rotationDeg;
  final int aspectPreset;
  final NormCropBoxData requestedBox;
}

final class _AnalyzeGeometrySurfaceRequest extends _WorkerRequest {
  const _AnalyzeGeometrySurfaceRequest({
    required super.id,
    required this.surfaceId,
    required this.targetAspectPreset,
    this.useRescuedBuffer = false,
  });

  final int surfaceId;
  final int targetAspectPreset;
  final bool useRescuedBuffer;
}

final class _RenderGeometrySurfaceRequest extends _WorkerRequest {
  const _RenderGeometrySurfaceRequest({
    required super.id,
    required this.surfaceId,
    required this.params,
    required this.outWidth,
    required this.outHeight,
  });

  final int surfaceId;
  final GeometryNativeParams params;
  final int outWidth;
  final int outHeight;
}

final class _CollageSlotTransfer {
  const _CollageSlotTransfer({
    required this.rgba,
    required this.byteLength,
    required this.width,
    required this.height,
    required this.panX,
    required this.panY,
    required this.zoom,
  });

  final TransferableTypedData rgba;
  final int byteLength;
  final int width;
  final int height;
  final double panX;
  final double panY;
  final double zoom;
}

final class _RenderCollageRequest extends _WorkerRequest {
  const _RenderCollageRequest({
    required super.id,
    required this.slots,
    required this.config,
  });

  final List<_CollageSlotTransfer> slots;
  final CollageNativeConfig config;
}

final class _RunExportPipelineRequest extends _WorkerRequest {
  const _RunExportPipelineRequest({
    required super.id,
    required this.rawInputPath,
    required this.srcWidth,
    required this.srcHeight,
    required this.rawOutputPath,
    required this.dnaRescue,
    required this.geometry,
    required this.targetMaxLongEdge,
    required this.outputUsm,
  });

  final String rawInputPath;
  final int srcWidth;
  final int srcHeight;
  final String rawOutputPath;
  final DnaRescueNativeParams? dnaRescue;
  final GeometryNativeParams? geometry;
  final int targetMaxLongEdge;
  final OutputUsmNativeParams? outputUsm;
}

final class _RenderCollageToRawFileRequest extends _WorkerRequest {
  const _RenderCollageToRawFileRequest({
    required super.id,
    required this.slots,
    required this.config,
    required this.outputUsm,
    required this.rawOutputPath,
  });

  final List<CollageRawFileSlot> slots;
  final CollageNativeConfig config;
  final OutputUsmNativeParams? outputUsm;
  final String rawOutputPath;
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

final class _StudioRenderPayload {
  const _StudioRenderPayload({
    required this.statusCode,
    required this.renderTimeMicros,
    required this.width,
    required this.height,
    required this.transferable,
  });

  final int statusCode;
  final int renderTimeMicros;
  final int width;
  final int height;
  final TransferableTypedData? transferable;
}

final class _CollageRenderPayload {
  const _CollageRenderPayload({
    required this.statusCode,
    required this.renderTimeMicros,
    required this.width,
    required this.height,
    required this.transferable,
  });

  final int statusCode;
  final int renderTimeMicros;
  final int width;
  final int height;
  final TransferableTypedData? transferable;
}
