import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/schema/edit_recipe.dart';
import '../../core/storage/asset_pairing_engine.dart';
import 'social_export_service.dart';

/// Single target queued into [BatchExportController].
@immutable
final class BatchExportTarget {
  const BatchExportTarget({
    required this.itemId,
    required this.pairedAsset,
    required this.recipe,
  });

  final String itemId;
  final PairedAsset pairedAsset;
  final EditRecipe recipe;
}

/// Disposition of a single item in a batch export run.
enum BatchExportItemStatus { exported, failed, cancelled }

/// Per-item outcome recorded by [BatchExportController].
@immutable
final class BatchExportItemOutcome {
  const BatchExportItemOutcome({
    required this.itemId,
    required this.fileName,
    required this.status,
    this.result,
    this.errorMessage,
  });

  final String itemId;
  final String fileName;
  final BatchExportItemStatus status;
  final SocialExportResult? result;
  final String? errorMessage;
}

/// Immutable progress and summary state of [BatchExportController].
@immutable
final class BatchExportState {
  BatchExportState({
    this.isRunning = false,
    this.isCancelled = false,
    this.isDone = false,
    this.totalCount = 0,
    this.completedCount = 0,
    this.failedCount = 0,
    this.cancelledCount = 0,
    this.currentIndex = 0,
    this.currentFileName,
    this.errorMessage,
    List<BatchExportItemOutcome> outcomes = const <BatchExportItemOutcome>[],
  }) : outcomes = List<BatchExportItemOutcome>.unmodifiable(outcomes);

  final bool isRunning;
  final bool isCancelled;
  final bool isDone;
  final int totalCount;
  final int completedCount;
  final int failedCount;
  final int cancelledCount;
  final int currentIndex;
  final String? currentFileName;
  final String? errorMessage;
  final List<BatchExportItemOutcome> outcomes;

  int get processedCount => completedCount + failedCount;

  double get progress {
    if (totalCount <= 0) return 0.0;
    return (processedCount / totalCount).clamp(0.0, 1.0);
  }

  BatchExportState copyWith({
    bool? isRunning,
    bool? isCancelled,
    bool? isDone,
    int? totalCount,
    int? completedCount,
    int? failedCount,
    int? cancelledCount,
    int? currentIndex,
    Object? currentFileName = _unset,
    Object? errorMessage = _unset,
    List<BatchExportItemOutcome>? outcomes,
  }) {
    return BatchExportState(
      isRunning: isRunning ?? this.isRunning,
      isCancelled: isCancelled ?? this.isCancelled,
      isDone: isDone ?? this.isDone,
      totalCount: totalCount ?? this.totalCount,
      completedCount: completedCount ?? this.completedCount,
      failedCount: failedCount ?? this.failedCount,
      cancelledCount: cancelledCount ?? this.cancelledCount,
      currentIndex: currentIndex ?? this.currentIndex,
      currentFileName: identical(currentFileName, _unset)
          ? this.currentFileName
          : currentFileName as String?,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
      outcomes: outcomes ?? this.outcomes,
    );
  }
}

const Object _unset = Object();

/// Sequential (`maxConcurrent = 1`) batch export queue with cooperative
/// cancellation and double-tap protection so exporting 5–10+ 26MP photos never
/// causes an OOM spike.
final class BatchExportController extends ChangeNotifier {
  BatchExportController({
    required SocialExportService exportService,
  }) : this._internal(exportService: exportService);

  BatchExportController._internal({
    required this._exportService,
  });

  static const int maxConcurrent = 1;

  final SocialExportService _exportService;

  BatchExportState _state = BatchExportState();
  bool _cancelled = false;
  bool _disposed = false;

  BatchExportState get state => _state;

  /// Requests cooperative cancellation. The currently running item finishes
  /// cleanly and all subsequent queued items are skipped and counted as
  /// cancelled.
  void cancel() {
    if (_disposed || !_state.isRunning || _cancelled) return;
    _cancelled = true;
    _state = _state.copyWith(isCancelled: true);
    notifyListeners();
  }

  /// Runs a strictly sequential (`maxConcurrent = 1`) export across [targets].
  ///
  /// Protected against double-taps via `if (state.isRunning) return;`.
  Future<BatchExportState> startBatch({
    required List<BatchExportTarget> targets,
    ExportProfileSpec? exportProfileOverride,
    String? albumKey,
  }) async {
    if (_disposed || _state.isRunning) {
      return _state;
    }

    _cancelled = false;
    final total = targets.length;
    if (total == 0) {
      _state = BatchExportState(
        isRunning: false,
        isDone: true,
        totalCount: 0,
      );
      notifyListeners();
      return _state;
    }

    _cancelled = false;
    _state = BatchExportState(
      isRunning: true,
      isCancelled: false,
      isDone: false,
      totalCount: total,
      completedCount: 0,
      failedCount: 0,
      cancelledCount: 0,
      currentIndex: 0,
      currentFileName: targets.first.pairedAsset.displayName,
    );
    notifyListeners();

    try {
      await _exportService.ensureSufficientStorageSpace(itemCount: total);
    } catch (error) {
      if (_disposed) return _state;
      final message = error.toString();
      _state = BatchExportState(
        isRunning: false,
        isCancelled: false,
        isDone: true,
        totalCount: total,
        completedCount: 0,
        failedCount: total,
        cancelledCount: 0,
        currentIndex: 0,
        currentFileName: null,
        errorMessage: message,
        outcomes: <BatchExportItemOutcome>[
          for (final target in targets)
            BatchExportItemOutcome(
              itemId: target.itemId,
              fileName: target.pairedAsset.displayName,
              status: BatchExportItemStatus.failed,
              errorMessage: message,
            ),
        ],
      );
      notifyListeners();
      return _state;
    }

    final outcomes = <BatchExportItemOutcome>[];
    var completed = 0;
    var failed = 0;
    var cancelled = 0;

    for (var i = 0; i < total; i++) {
      if (_cancelled || _disposed) {
        for (var j = i; j < total; j++) {
          cancelled++;
          outcomes.add(
            BatchExportItemOutcome(
              itemId: targets[j].itemId,
              fileName: targets[j].pairedAsset.displayName,
              status: BatchExportItemStatus.cancelled,
            ),
          );
        }
        break;
      }

      final target = targets[i];
      _state = _state.copyWith(
        currentIndex: i + 1,
        currentFileName: target.pairedAsset.displayName,
      );
      notifyListeners();

      try {
        final result = await _exportService.exportSingleItem(
          itemId: target.itemId,
          pairedAsset: target.pairedAsset,
          recipe: target.recipe,
          exportProfileOverride: exportProfileOverride,
          albumKey: albumKey,
        );
        completed++;
        outcomes.add(
          BatchExportItemOutcome(
            itemId: target.itemId,
            fileName: target.pairedAsset.displayName,
            status: BatchExportItemStatus.exported,
            result: result,
          ),
        );
      } catch (error) {
        failed++;
        outcomes.add(
          BatchExportItemOutcome(
            itemId: target.itemId,
            fileName: target.pairedAsset.displayName,
            status: BatchExportItemStatus.failed,
            errorMessage: error.toString(),
          ),
        );
      }

      if (_disposed) {
        for (var j = i + 1; j < total; j++) {
          cancelled++;
          outcomes.add(
            BatchExportItemOutcome(
              itemId: targets[j].itemId,
              fileName: targets[j].pairedAsset.displayName,
              status: BatchExportItemStatus.cancelled,
            ),
          );
        }
        break;
      }

      _state = _state.copyWith(
        completedCount: completed,
        failedCount: failed,
        outcomes: outcomes,
      );
      notifyListeners();

      if (_cancelled) {
        for (var j = i + 1; j < total; j++) {
          cancelled++;
          outcomes.add(
            BatchExportItemOutcome(
              itemId: targets[j].itemId,
              fileName: targets[j].pairedAsset.displayName,
              status: BatchExportItemStatus.cancelled,
            ),
          );
        }
        break;
      }
    }

    _state = BatchExportState(
      isRunning: false,
      isCancelled: _cancelled,
      isDone: true,
      totalCount: total,
      completedCount: completed,
      failedCount: failed,
      cancelledCount: cancelled,
      currentIndex: completed + failed,
      currentFileName: null,
      outcomes: outcomes,
    );
    if (!_disposed) {
      notifyListeners();
    }
    return _state;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelled = true;
    super.dispose();
  }
}
