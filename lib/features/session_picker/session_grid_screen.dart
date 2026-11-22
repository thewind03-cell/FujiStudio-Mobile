import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/di/app_providers.dart';
import '../../core/schema/session_item.dart';
import '../../core/storage/asset_pairing_engine.dart';
import '../../core/storage/proxy_cache_manager.dart';
import '../../core/theme/fuji_theme.dart';
import '../story_collage/story_collage_screen.dart';
import '../studio_editor/dna_rescue_mapper.dart';
import '../studio_editor/geometry_mapper.dart';
import 'quick_loupe_screen.dart';
import 'session_controller.dart';

/// Mechanical Fujifilm culling contact-sheet grid with 3/4-column density
/// toggle, 4 live filter chips, cooperative proxy cancellation, and 1-hand
/// long-press KEEP toggle.
class SessionGridScreen extends ConsumerStatefulWidget {
  const SessionGridScreen({super.key});

  @override
  ConsumerState<SessionGridScreen> createState() => _SessionGridScreenState();
}

class _SessionGridScreenState extends ConsumerState<SessionGridScreen> {
  int _columnCount = 3;
  bool _isPopping = false;

  Future<void> _handleBack() async {
    if (_isPopping) return;
    _isPopping = true;
    var didPop = false;
    try {
      await ref.read(sessionControllerProvider.notifier).flushPendingSave();
      if (!mounted) return;
      didPop = true;
      Navigator.of(context).pop();
    } finally {
      if (mounted && !didPop) {
        _isPopping = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sessionControllerProvider);
    final controller = ref.read(sessionControllerProvider.notifier);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleBack());
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: <Widget>[
              _EvfTopBar(
                albumName: state.album?.name ?? 'PHIÊN',
                keepCount: state.keepCount,
                totalCount: state.totalCount,
                isSaving: state.isSaving || state.hasPendingChanges,
                columnCount: _columnCount,
                onBack: () => unawaited(_handleBack()),
                onToggleColumns: () {
                  setState(() {
                    _columnCount = _columnCount == 3 ? 4 : 3;
                  });
                },
              ),
              _FilterChipStrip(
                state: state,
                onSelect: controller.setFilter,
                onOpenCollage: () => unawaited(_openCollage(state)),
              ),
              if (state.missingFromGalleryCount > 0)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: const BoxDecoration(
                    color: FujiColors.surface,
                    border: Border(
                      bottom: BorderSide(color: FujiColors.border, width: 1),
                    ),
                  ),
                  child: Text(
                    '${state.missingFromGalleryCount} ảnh ngoài phạm vi quyền được bảo toàn trong JSON',
                    style: const TextStyle(
                      color: FujiColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ),
              Expanded(
                child: _buildGridContent(state, controller),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openCollage(SessionState state) async {
    if (state.totalCount < 2) return;
    final keepIds = <String>[];
    for (final id in state.galleryOrderedItemIds) {
      final item = state.itemById(id);
      if (item?.cullResult?.status == 'keep') {
        keepIds.add(id);
      }
    }

    List<String>? targetIds;
    if (keepIds.length >= 2 && keepIds.length <= 4) {
      targetIds = keepIds;
    } else {
      targetIds = await showCollageImagePickerSheet(
        context: context,
        sessionState: state,
        initialSelectedIds: keepIds.take(4).toList(),
      );
    }

    if (!mounted || targetIds == null || targetIds.length < 2) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => StoryCollageScreen(initialItemIds: targetIds!),
      ),
    );
  }

  Widget _buildGridContent(SessionState state, SessionController controller) {
    if (state.isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: FujiColors.accent),
      );
    }

    if (state.errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            state.errorMessage!,
            style: const TextStyle(color: FujiColors.textSecondary),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (state.visibleItemIds.isEmpty) {
      return const Center(
        child: Text(
          'Không có ảnh nào khớp bộ lọc.',
          style: TextStyle(color: FujiColors.textSecondary, fontSize: 13),
        ),
      );
    }

    return GridView.builder(
      key: const Key('session_photo_grid'),
      padding: const EdgeInsets.all(6),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _columnCount,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        childAspectRatio: 1.0,
      ),
      itemCount: state.visibleItemIds.length,
      itemBuilder: (context, index) {
        final itemId = state.visibleItemIds[index];
        final item = state.itemById(itemId);
        final paired = state.pairedAssetsById[itemId];
        if (item == null || paired == null) {
          return const SizedBox.shrink();
        }
        return PhotoGridTile(
          key: ValueKey<String>(itemId),
          item: item,
          pairedAsset: paired,
          onTap: () {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => QuickLoupeScreen(initialItemId: itemId),
              ),
            );
          },
          onLongPress: () {
            unawaited(HapticFeedback.mediumImpact());
            controller.toggleKeep(itemId);
          },
        );
      },
    );
  }
}

class _EvfTopBar extends StatelessWidget {
  const _EvfTopBar({
    required this.albumName,
    required this.keepCount,
    required this.totalCount,
    required this.isSaving,
    required this.columnCount,
    required this.onBack,
    required this.onToggleColumns,
  });

  final String albumName;
  final int keepCount;
  final int totalCount;
  final bool isSaving;
  final int columnCount;
  final VoidCallback onBack;
  final VoidCallback onToggleColumns;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(
        color: FujiColors.canvas,
        border: Border(
          bottom: BorderSide(color: FujiColors.border, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const Key('evf_back_button'),
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: onBack,
          ),
          Expanded(
            child: Text(
              albumName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: FujiColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: FujiColors.surface,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: FujiColors.border, width: 1),
            ),
            child: Text(
              '$keepCount / $totalCount',
              key: const Key('evf_keep_counter'),
              style: const TextStyle(
                color: FujiColors.keep,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                fontFeatures: FujiTheme.tabularFeatures,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            isSaving ? 'SAVING...' : 'SAVED',
            key: const Key('evf_save_status'),
            style: TextStyle(
              color: isSaving ? FujiColors.accent : FujiColors.textSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(width: 4),
          TextButton(
            key: const Key('evf_density_toggle'),
            style: TextButton.styleFrom(
              minimumSize: const Size(44, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: FujiColors.textPrimary,
            ),
            onPressed: onToggleColumns,
            child: Text(
              '$columnCount cột',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFeatures: FujiTheme.tabularFeatures,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterChipStrip extends StatelessWidget {
  const _FilterChipStrip({
    required this.state,
    required this.onSelect,
    required this.onOpenCollage,
  });

  final SessionState state;
  final void Function(GridFilterMode mode) onSelect;
  final VoidCallback onOpenCollage;

  @override
  Widget build(BuildContext context) {
    final canCollage = state.totalCount >= 2;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: FujiColors.canvas,
        border: Border(
          bottom: BorderSide(color: FujiColors.border, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: <Widget>[
                _chip(GridFilterMode.all, 'TẤT CẢ', state.totalCount),
                const SizedBox(width: 6),
                _chip(GridFilterMode.keep, 'CHỌN', state.keepCount),
                const SizedBox(width: 6),
                _chip(GridFilterMode.unmarked, 'CHƯA GẮN', state.unmarkedCount),
                const SizedBox(width: 6),
                _chip(GridFilterMode.reject, 'LOẠI', state.rejectCount),
              ],
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            key: const Key('grid_collage_button'),
            onTap: canCollage ? onOpenCollage : null,
            borderRadius: BorderRadius.circular(4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: canCollage
                    ? FujiColors.accent.withValues(alpha: 0.16)
                    : FujiColors.surface,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: canCollage ? FujiColors.accent : FujiColors.border,
                  width: 1,
                ),
              ),
              child: Text(
                '⊞ COLLAGE',
                style: TextStyle(
                  color: canCollage
                      ? FujiColors.accent
                      : FujiColors.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(GridFilterMode mode, String label, int count) {
    final selected = state.activeFilter == mode;
    return Center(
      child: InkWell(
        key: Key('filter_chip_${mode.name}'),
        onTap: () => onSelect(mode),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? FujiColors.surfaceElevated : FujiColors.surface,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: selected ? FujiColors.accent : FujiColors.border,
              width: 1,
            ),
          ),
          child: Text(
            '$label $count',
            style: TextStyle(
              color: selected ? FujiColors.accent : FujiColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFeatures: FujiTheme.tabularFeatures,
            ),
          ),
        ),
      ),
    );
  }
}

/// Grid cell displaying a `1600px`-backed thumbnail (decoded at `cacheWidth: 480`),
/// cooperative scroll cancellation, RAW pairing badge, and KEEP/REJECT cues.
class PhotoGridTile extends ConsumerStatefulWidget {
  const PhotoGridTile({
    super.key,
    required this.item,
    required this.pairedAsset,
    required this.onTap,
    required this.onLongPress,
  });

  final SessionItem item;
  final PairedAsset pairedAsset;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  ConsumerState<PhotoGridTile> createState() => _PhotoGridTileState();
}

class _PhotoGridTileState extends ConsumerState<PhotoGridTile> {
  ProxyCancelToken _cancelToken = ProxyCancelToken();
  File? _proxyFile;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _requestProxy();
  }

  @override
  void didUpdateWidget(covariant PhotoGridTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shouldReloadProxy(oldWidget.pairedAsset, widget.pairedAsset)) {
      _cancelToken.cancel();
      _proxyFile = null;
      _failed = false;
      _requestProxy();
    }
  }

  static bool _shouldReloadProxy(PairedAsset prev, PairedAsset next) {
    return prev.pairKey != next.pairKey ||
        prev.primaryAsset.uri != next.primaryAsset.uri ||
        prev.primaryAsset.sizeBytes != next.primaryAsset.sizeBytes ||
        prev.primaryAsset.dateModifiedSec != next.primaryAsset.dateModifiedSec;
  }

  void _requestProxy() {
    final token = ProxyCancelToken();
    _cancelToken = token;
    final manager = ref.read(proxyCacheManagerProvider);
    unawaited(
      manager
          .requestProxy(
            widget.pairedAsset,
            priority: ProxyPriority.gridViewport,
            cancelToken: token,
          )
          .then((file) {
            if (!mounted || token.isCancelled || file == null) return;
            setState(() {
              _proxyFile = file;
              _failed = false;
            });
          })
          .catchError((_) {
            if (!mounted || token.isCancelled) return;
            setState(() {
              _failed = true;
            });
          }),
    );
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.item.cullResult?.status;
    final isKeep = status == 'keep';
    final isReject = status == 'reject';
    final isEdited = DnaRescueMapper.isEdited(widget.item.editRecipe.dnaRescue) ||
        GeometryMapper.isEdited(widget.item.editRecipe.geometry);

    final rawBadge = switch (widget.pairedAsset.kind) {
      AssetPairKind.jpgPlusRaf => 'J+R',
      AssetPairKind.rafOnly => 'RAF',
      AssetPairKind.jpgOnly => null,
    };

    Widget imageLayer;
    if (_proxyFile != null && _proxyFile!.existsSync()) {
      imageLayer = Image.file(
        _proxyFile!,
        fit: BoxFit.cover,
        cacheWidth: 480,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(isError: true),
      );
    } else {
      imageLayer = _placeholder(isError: _failed);
    }

    if (isReject) {
      imageLayer = Opacity(opacity: 0.45, child: imageLayer);
    }

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: FujiColors.surface,
          borderRadius: BorderRadius.circular(2),
          border: Border.all(
            color: isReject ? FujiColors.reject : FujiColors.border,
            width: 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            imageLayer,
            if (rawBadge != null)
              Positioned(
                top: 4,
                left: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xCC0E0F11),
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(color: FujiColors.border, width: 0.8),
                  ),
                  child: Text(
                    rawBadge,
                    style: const TextStyle(
                      color: FujiColors.textPrimary,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                      fontFeatures: FujiTheme.tabularFeatures,
                    ),
                  ),
                ),
              ),
            if (isEdited)
              Positioned(
                top: 5,
                right: 5,
                child: Container(
                  key: Key('adj_dot_${widget.item.id}'),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: FujiColors.accent,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: FujiColors.canvas,
                      width: 1,
                    ),
                  ),
                ),
              ),
            if (isKeep)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  key: Key('keep_bar_${widget.item.id}'),
                  height: 3,
                  color: FujiColors.keep,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder({bool isError = false}) {
    return Container(
      color: FujiColors.surface,
      child: Center(
        child: Icon(
          isError ? Icons.broken_image_outlined : Icons.image_outlined,
          size: 18,
          color: FujiColors.textSecondary,
        ),
      ),
    );
  }
}
