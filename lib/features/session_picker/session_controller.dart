import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/schema/action_proposal.dart';
import '../../core/schema/collage_spec.dart';
import '../../core/schema/cull_result.dart';
import '../../core/schema/edit_recipe.dart';
import '../../core/schema/session_document.dart';
import '../../core/schema/session_item.dart';
import '../../core/session/session_store.dart';
import '../../core/storage/asset_pairing_engine.dart';
import '../../core/storage/proxy_cache_manager.dart';
import '../../core/storage/storage_gateway.dart';

/// Filter chips available on [SessionGridScreen].
enum GridFilterMode { all, keep, unmarked, reject }

/// Immutable state managed by [SessionController].
@immutable
final class SessionState {
  SessionState({
    this.album,
    this.albumKey,
    this.document,
    Map<String, PairedAsset> pairedAssetsById = const <String, PairedAsset>{},
    List<String> galleryOrderedItemIds = const <String>[],
    List<String> visibleItemIds = const <String>[],
    this.activeFilter = GridFilterMode.all,
    this.isLoading = false,
    this.isSaving = false,
    this.lastSavedAt,
    this.hasPendingChanges = false,
    this.missingFromGalleryCount = 0,
    this.errorMessage,
  }) : pairedAssetsById = Map<String, PairedAsset>.unmodifiable(pairedAssetsById),
       galleryOrderedItemIds = List<String>.unmodifiable(galleryOrderedItemIds),
       visibleItemIds = List<String>.unmodifiable(visibleItemIds);

  final MediaAlbumDescriptor? album;
  final String? albumKey;
  final SessionDocument? document;
  final Map<String, PairedAsset> pairedAssetsById;
  final List<String> galleryOrderedItemIds;
  final List<String> visibleItemIds;
  final GridFilterMode activeFilter;
  final bool isLoading;
  final bool isSaving;
  final DateTime? lastSavedAt;
  final bool hasPendingChanges;
  final int missingFromGalleryCount;
  final String? errorMessage;

  int get totalCount => galleryOrderedItemIds.length;

  int countForFilter(GridFilterMode mode) {
    final doc = document;
    if (doc == null) return 0;
    final itemsById = <String, SessionItem>{
      for (final item in doc.items) item.id: item,
    };
    var count = 0;
    for (final id in galleryOrderedItemIds) {
      final item = itemsById[id];
      if (item == null) continue;
      if (_matchesFilter(item, mode)) {
        count++;
      }
    }
    return count;
  }

  int get keepCount => countForFilter(GridFilterMode.keep);
  int get unmarkedCount => countForFilter(GridFilterMode.unmarked);
  int get rejectCount => countForFilter(GridFilterMode.reject);

  SessionItem? itemById(String itemId) {
    final doc = document;
    if (doc == null) return null;
    for (final item in doc.items) {
      if (item.id == itemId) return item;
    }
    return null;
  }

  static bool _matchesFilter(SessionItem item, GridFilterMode mode) {
    final status = item.cullResult?.status;
    return switch (mode) {
      GridFilterMode.all => true,
      GridFilterMode.keep => status == 'keep',
      GridFilterMode.reject => status == 'reject',
      GridFilterMode.unmarked => status != 'keep' && status != 'reject',
    };
  }

  SessionState copyWith({
    MediaAlbumDescriptor? album,
    String? albumKey,
    SessionDocument? document,
    Map<String, PairedAsset>? pairedAssetsById,
    List<String>? galleryOrderedItemIds,
    List<String>? visibleItemIds,
    GridFilterMode? activeFilter,
    bool? isLoading,
    bool? isSaving,
    DateTime? lastSavedAt,
    bool? hasPendingChanges,
    int? missingFromGalleryCount,
    String? errorMessage,
    bool clearError = false,
  }) {
    return SessionState(
      album: album ?? this.album,
      albumKey: albumKey ?? this.albumKey,
      document: document ?? this.document,
      pairedAssetsById: pairedAssetsById ?? this.pairedAssetsById,
      galleryOrderedItemIds:
          galleryOrderedItemIds ?? this.galleryOrderedItemIds,
      visibleItemIds: visibleItemIds ?? this.visibleItemIds,
      activeFilter: activeFilter ?? this.activeFilter,
      isLoading: isLoading ?? this.isLoading,
      isSaving: isSaving ?? this.isSaving,
      lastSavedAt: lastSavedAt ?? this.lastSavedAt,
      hasPendingChanges: hasPendingChanges ?? this.hasPendingChanges,
      missingFromGalleryCount:
          missingFromGalleryCount ?? this.missingFromGalleryCount,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Riverpod controller orchestrating 3-way reconciliation between Gallery
/// assets and Desktop v2.4.2 JSON sessions, culling updates, filtering,
/// proxy pinning, and lifecycle-safe persistence.
final class SessionController extends StateNotifier<SessionState> {
  SessionController({
    required this._storageGateway,
    required this._sessionStore,
    required this._proxyCacheManager,
    this._pairingEngine = const AssetPairingEngine(),
    bool bindAppLifecycle = true,
  }) : super(SessionState()) {
    if (bindAppLifecycle) {
      try {
        _lifecycleListener = AppLifecycleListener(
          onInactive: () => unawaited(flushPendingSave()),
          onPause: () => unawaited(flushPendingSave()),
          onHide: () => unawaited(flushPendingSave()),
        );
      } catch (_) {
        // Pure Dart unit tests may run without a Flutter binding.
      }
    }
  }

  final StorageGateway _storageGateway;
  final SessionStore _sessionStore;
  final ProxyCacheManager _proxyCacheManager;
  final AssetPairingEngine _pairingEngine;
  AppLifecycleListener? _lifecycleListener;
  String? _activeAlbumKey;

  int _saveGeneration = 0;

  static String deterministicItemIdForPairKey(String pairKey) {
    final hash = sha256.convert(utf8.encode(pairKey)).toString().substring(0, 12);
    return 'item_$hash';
  }

  /// Safely reads the current [EditRecipe] for [itemId] without exposing
  /// protected `StateNotifier.state` outside this controller.
  EditRecipe? editRecipeForItem(String itemId) {
    return state.itemById(itemId)?.editRecipe;
  }

  /// Safely reads the [SessionItem] for [itemId] without exposing
  /// protected `StateNotifier.state` outside this controller.
  SessionItem? sessionItemById(String itemId) {
    return state.itemById(itemId);
  }

  /// Safely reads the [PairedAsset] for [itemId] without exposing
  /// protected `StateNotifier.state` outside this controller.
  PairedAsset? pairedAssetForItem(String itemId) {
    return state.pairedAssetsById[itemId];
  }

  /// Opens [album], fetches all media descriptors via [StorageGateway], pairs
  /// `.JPG`/`.RAF` files, performs 3-way reconciliation with any saved
  /// `.fujistudio_session.json`, and pins the album's proxy cache keys.
  Future<void> openAlbum(MediaAlbumDescriptor album) async {
    await flushPendingSave();

    final albumKey = SessionStore.albumKeyFor(album.albumId);
    _activeAlbumKey = albumKey;
    state = SessionState(
      album: album,
      albumKey: albumKey,
      isLoading: true,
    );

    try {
      final allRawFiles = <RawMediaFileDescriptor>[];
      const pageSize = 200;
      var offset = 0;
      while (true) {
        final page = await _storageGateway.listMediaInAlbum(
          albumId: album.albumId,
          limit: pageSize,
          offset: offset,
        );
        if (page.isEmpty) break;
        allRawFiles.addAll(page);
        if (page.length < pageSize) break;
        offset += page.length;
      }

      final pairedAssets = _pairingEngine.pairAssets(allRawFiles);
      final existingDoc = await _sessionStore.loadSession(albumKey);

      final reconciled = _reconcileSession(
        album: album,
        pairedAssets: pairedAssets,
        existingDoc: existingDoc,
      );

      final pinnedKeys = pairedAssets
          .map(_proxyCacheManager.cacheKeyFor)
          .toSet();
      _proxyCacheManager.pinKeys(pinnedKeys);

      final visibleIds = _filterVisibleIds(
        reconciled.document,
        reconciled.galleryOrderedIds,
        GridFilterMode.all,
      );

      state = SessionState(
        album: album,
        albumKey: albumKey,
        document: reconciled.document,
        pairedAssetsById: reconciled.pairedById,
        galleryOrderedItemIds: reconciled.galleryOrderedIds,
        visibleItemIds: visibleIds,
        activeFilter: GridFilterMode.all,
        isLoading: false,
        isSaving: false,
        hasPendingChanges: false,
        missingFromGalleryCount: reconciled.missingCount,
      );

      // Record album in recent_index.json immediately on open.
      await _sessionStore.saveNow(
        albumKey,
        reconciled.document,
        recentEntry: _buildRecentEntry(
          album: album,
          albumKey: albumKey,
          state: state,
        ),
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: error.toString(),
      );
    }
  }

  /// Switches the active grid filter chip.
  void setFilter(GridFilterMode mode) {
    final doc = state.document;
    if (doc == null) {
      state = state.copyWith(activeFilter: mode);
      return;
    }
    final visible = _filterVisibleIds(doc, state.galleryOrderedItemIds, mode);
    state = state.copyWith(
      activeFilter: mode,
      visibleItemIds: visible,
    );
  }

  /// Toggles `KEEP` on [itemId] (keeps if unmarked/rejected, clears if already kept).
  void toggleKeep(String itemId) {
    final existing = state.itemById(itemId);
    if (existing == null) return;
    final nextStatus =
        existing.cullResult?.status == 'keep' ? null : 'keep';
    setCullStatus(itemId, nextStatus);
  }

  /// Sets or clears (`status == null`) the cull status for [itemId].
  void setCullStatus(String itemId, String? status) {
    final doc = state.document;
    final album = state.album;
    final albumKey = state.albumKey;
    if (doc == null || album == null || albumKey == null) return;

    var changed = false;
    final updatedItems = <SessionItem>[];
    for (final item in doc.items) {
      if (item.id != itemId) {
        updatedItems.add(item);
        continue;
      }
      changed = true;
      final CullResult? nextCull;
      if (status == null) {
        nextCull = null;
      } else if (item.cullResult != null) {
        nextCull = item.cullResult!.copyWith(status: status);
      } else {
        nextCull = CullResult(
          status: status,
          sharpnessScore: status == 'keep' ? 1.0 : 0.0,
        );
      }
      updatedItems.add(item.copyWith(cullResult: nextCull));
    }

    if (!changed) return;

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final updatedDoc = doc.copyWith(
      updatedAt: nowIso,
      items: updatedItems,
    );

    final visibleIds = _filterVisibleIds(
      updatedDoc,
      state.galleryOrderedItemIds,
      state.activeFilter,
    );

    _persistUpdatedDocument(updatedDoc, visibleIds: visibleIds);
  }

  /// Updates only `editRecipe` for [itemId], preserving 100% of `cullResult`,
  /// `actionProposals`, and Desktop v2.4.2 `unknownFields`.
  void updateItemEditRecipe(String itemId, EditRecipe updatedRecipe) {
    final doc = state.document;
    if (doc == null) return;

    var changed = false;
    final updatedItems = <SessionItem>[];
    for (final item in doc.items) {
      if (item.id != itemId) {
        updatedItems.add(item);
        continue;
      }
      changed = true;
      updatedItems.add(item.copyWith(editRecipe: updatedRecipe));
    }

    if (!changed) return;

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final updatedDoc = doc.copyWith(
      updatedAt: nowIso,
      items: updatedItems,
    );

    _persistUpdatedDocument(updatedDoc);
  }

  /// Inserts or updates an [ActionProposal] at the root `action_proposals`
  /// list of [SessionDocument], preserving all `unknownFields`.
  void recordActionProposal(ActionProposal proposal) {
    final doc = state.document;
    if (doc == null) return;

    final updatedProposals = <ActionProposal>[];
    var replaced = false;
    for (final existing in doc.actionProposals) {
      if (existing.proposalId == proposal.proposalId) {
        updatedProposals.add(proposal);
        replaced = true;
      } else {
        updatedProposals.add(existing);
      }
    }
    if (!replaced) {
      updatedProposals.add(proposal);
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final updatedDoc = doc.copyWith(
      updatedAt: nowIso,
      actionProposals: updatedProposals,
    );

    _persistUpdatedDocument(updatedDoc);
  }

  /// Inserts or updates a [CollageSpec] in `SessionDocument.collages`,
  /// preserving all `unknownFields`.
  void saveCollageSpec(CollageSpec collage) {
    final doc = state.document;
    if (doc == null) return;

    final updatedCollages = <CollageSpec>[];
    var replaced = false;
    for (final existing in doc.collages) {
      if (existing.collageId == collage.collageId) {
        updatedCollages.add(collage);
        replaced = true;
      } else {
        updatedCollages.add(existing);
      }
    }
    if (!replaced) {
      updatedCollages.add(collage);
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final updatedDoc = doc.copyWith(
      updatedAt: nowIso,
      collages: updatedCollages,
    );

    _persistUpdatedDocument(updatedDoc);
  }

  void _persistUpdatedDocument(
    SessionDocument updatedDoc, {
    List<String>? visibleIds,
  }) {
    final album = state.album;
    final albumKey = state.albumKey;
    if (album == null || albumKey == null) return;

    final nextState = state.copyWith(
      document: updatedDoc,
      visibleItemIds: visibleIds,
      isSaving: true,
      hasPendingChanges: true,
    );
    state = nextState;

    final gen = ++_saveGeneration;
    unawaited(
      _sessionStore
          .scheduleSave(
            albumKey,
            updatedDoc,
            recentEntry: _buildRecentEntry(
              album: album,
              albumKey: albumKey,
              state: nextState,
            ),
          )
          .then((_) {
            if (mounted && gen == _saveGeneration) {
              state = state.copyWith(
                isSaving: false,
                hasPendingChanges: false,
                lastSavedAt: DateTime.now(),
              );
            }
          }),
    );
  }

  /// Flushes any pending debounced session write immediately to disk.
  Future<void> flushPendingSave() async {
    final albumKey = _activeAlbumKey ?? (mounted ? state.albumKey : null);
    if (albumKey == null) return;
    await _sessionStore.flushNow(albumKey);
    if (mounted && (state.hasPendingChanges || state.isSaving)) {
      state = state.copyWith(
        isSaving: false,
        hasPendingChanges: false,
        lastSavedAt: DateTime.now(),
      );
    }
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    super.dispose();
  }

  _ReconciliationResult _reconcileSession({
    required MediaAlbumDescriptor album,
    required List<PairedAsset> pairedAssets,
    required SessionDocument? existingDoc,
  }) {
    final existingItems = existingDoc?.items ?? const <SessionItem>[];
    final byId = <String, SessionItem>{};
    final byUri = <String, SessionItem>{};
    final byFileNameLower = <String, SessionItem>{};

    for (final item in existingItems) {
      byId[item.id] = item;
      if (item.mediaUri != null && item.mediaUri!.isNotEmpty) {
        byUri[item.mediaUri!] = item;
      }
      byFileNameLower[item.fileName.toLowerCase()] = item;
    }

    final matchedOldIds = <String>{};
    final reconciledGalleryItems = <SessionItem>[];
    final pairedById = <String, PairedAsset>{};
    final galleryOrderedIds = <String>[];

    for (final pair in pairedAssets) {
      final candidateId = deterministicItemIdForPairKey(pair.pairKey);
      SessionItem? matched =
          byId[candidateId] ??
          byUri[pair.primaryAsset.uri] ??
          byFileNameLower[pair.displayName.toLowerCase()];

      if (matched != null && matchedOldIds.contains(matched.id)) {
        matched = null;
      }

      final SessionItem resolvedItem;
      if (matched != null) {
        matchedOldIds.add(matched.id);
        resolvedItem = matched.copyWith(
          mediaUri: pair.primaryAsset.uri,
          width: pair.width ?? matched.width,
          height: pair.height ?? matched.height,
          isRawPaired: pair.hasRaw,
          capturedAt: matched.capturedAt ?? _isoFromMs(pair.capturedAtMs),
        );
      } else {
        resolvedItem = SessionItem(
          id: candidateId,
          fileName: pair.displayName,
          mediaUri: pair.primaryAsset.uri,
          capturedAt: _isoFromMs(pair.capturedAtMs),
          width: pair.width,
          height: pair.height,
          isRawPaired: pair.hasRaw,
          cullResult: null,
          editRecipe: _defaultNeutralRecipe(),
        );
      }

      reconciledGalleryItems.add(resolvedItem);
      pairedById[resolvedItem.id] = pair;
      galleryOrderedIds.add(resolvedItem.id);
    }

    // Preserve any existing items absent from the current Gallery view (e.g.
    // Android 14+ limited photo picker selection) without rendering broken tiles.
    final hiddenMissingItems = <SessionItem>[];
    for (final oldItem in existingItems) {
      if (!matchedOldIds.contains(oldItem.id)) {
        hiddenMissingItems.add(oldItem);
      }
    }

    final allDocItems = <SessionItem>[
      ...reconciledGalleryItems,
      ...hiddenMissingItems,
    ];

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final document = existingDoc != null
        ? existingDoc.copyWith(
            updatedAt: nowIso,
            items: allDocItems,
          )
        : SessionDocument(
            schemaVersion: SessionDocument.expectedSchemaVersion,
            sessionId:
                'sess_${SessionStore.albumKeyFor(album.albumId)}_${DateTime.now().millisecondsSinceEpoch}',
            createdAt: nowIso,
            updatedAt: nowIso,
            sourceApp: 'FujiStudio Mobile 1.0',
            items: allDocItems,
          );

    return _ReconciliationResult(
      document: document,
      pairedById: pairedById,
      galleryOrderedIds: galleryOrderedIds,
      missingCount: hiddenMissingItems.length,
    );
  }

  static List<String> _filterVisibleIds(
    SessionDocument document,
    List<String> galleryOrderedIds,
    GridFilterMode mode,
  ) {
    final itemsById = <String, SessionItem>{
      for (final item in document.items) item.id: item,
    };
    final out = <String>[];
    for (final id in galleryOrderedIds) {
      final item = itemsById[id];
      if (item != null && SessionState._matchesFilter(item, mode)) {
        out.add(id);
      }
    }
    return List<String>.unmodifiable(out);
  }

  static EditRecipe _defaultNeutralRecipe() {
    return EditRecipe(
      dnaRescue: DnaRescueSpec(enabled: false, shadowLift: 0.0),
      geometry: GeometrySpec(rotationDeg: 0.0),
      lut: LutSpec(enabled: false, intensity: 0.0),
      exportProfile: ExportProfileSpec(
        format: 'jpeg',
        quality: 92,
        colorSpace: 'sRGB',
        maxLongEdgePx: 2048,
      ),
    );
  }

  static String _isoFromMs(int ms) {
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();
  }

  static RecentSessionEntry _buildRecentEntry({
    required MediaAlbumDescriptor album,
    required String albumKey,
    required SessionState state,
  }) {
    return RecentSessionEntry(
      albumId: album.albumId,
      albumKey: albumKey,
      albumName: album.name,
      coverUri: album.coverUri,
      keepCount: state.keepCount,
      totalCount: state.totalCount,
      updatedAtIso:
          state.document?.updatedAt ?? DateTime.now().toUtc().toIso8601String(),
    );
  }
}

final class _ReconciliationResult {
  const _ReconciliationResult({
    required this.document,
    required this.pairedById,
    required this.galleryOrderedIds,
    required this.missingCount,
  });

  final SessionDocument document;
  final Map<String, PairedAsset> pairedById;
  final List<String> galleryOrderedIds;
  final int missingCount;
}
