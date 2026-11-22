import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/di/app_providers.dart';
import '../../core/storage/asset_pairing_engine.dart';
import '../../core/storage/proxy_cache_manager.dart';
import '../../core/theme/fuji_theme.dart';
import '../studio_editor/dna_rescue_mapper.dart';
import '../studio_editor/studio_editor_screen.dart';

/// Full-resolution (`1600px` proxy) single-image loupe viewer with `1x..3x`
/// pinch zoom, 1-ahead prefetching, telemetry line, and thumb-reachable
/// mechanical action bar.
class QuickLoupeScreen extends ConsumerStatefulWidget {
  const QuickLoupeScreen({
    super.key,
    required this.initialItemId,
  });

  final String initialItemId;

  @override
  ConsumerState<QuickLoupeScreen> createState() => _QuickLoupeScreenState();
}

class _QuickLoupeScreenState extends ConsumerState<QuickLoupeScreen> {
  PageController? _pageController;
  int _currentIndex = 0;
  ProxyCancelToken? _prefetchToken;

  @override
  void initState() {
    super.initState();
    final state = ref.read(sessionControllerProvider);
    final idx = state.visibleItemIds.indexOf(widget.initialItemId);
    _currentIndex = idx >= 0 ? idx : 0;
    _pageController = PageController(initialPage: _currentIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _prefetchAdjacent(_currentIndex);
      }
    });
  }

  @override
  void dispose() {
    _prefetchToken?.cancel();
    _pageController?.dispose();
    super.dispose();
  }

  void _prefetchAdjacent(int index) {
    _prefetchToken?.cancel();
    final state = ref.read(sessionControllerProvider);
    final nextIndex = index + 1;
    if (nextIndex < 0 || nextIndex >= state.visibleItemIds.length) return;
    final nextId = state.visibleItemIds[nextIndex];
    final nextPair = state.pairedAssetsById[nextId];
    if (nextPair == null) return;

    final token = ProxyCancelToken();
    _prefetchToken = token;
    unawaited(
      ref
          .read(proxyCacheManagerProvider)
          .requestProxy(
            nextPair,
            priority: ProxyPriority.activeViewer,
            cancelToken: token,
          )
          .catchError((_) => null),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sessionControllerProvider);
    final controller = ref.read(sessionControllerProvider.notifier);

    if (state.visibleItemIds.isEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(
          child: Text(
            'Không còn ảnh trong bộ lọc hiện tại.',
            style: TextStyle(color: FujiColors.textSecondary),
          ),
        ),
      );
    }

    final safeIndex = _currentIndex.clamp(0, state.visibleItemIds.length - 1);
    final currentId = state.visibleItemIds[safeIndex];
    final currentItem = state.itemById(currentId);
    final currentPair = state.pairedAssetsById[currentId];
    final currentStatus = currentItem?.cullResult?.status;
    final isDnaEdited = currentItem != null &&
        DnaRescueMapper.isEdited(currentItem.editRecipe.dnaRescue);

    return Scaffold(
      backgroundColor: FujiColors.canvas,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '${safeIndex + 1} / ${state.visibleItemIds.length}',
              style: const TextStyle(
                fontSize: 13,
                fontFeatures: FujiTheme.tabularFeatures,
              ),
            ),
            if (isDnaEdited) ...<Widget>[
              const SizedBox(width: 8),
              Container(
                key: const Key('loupe_adj_badge'),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: FujiColors.accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: FujiColors.accent, width: 0.8),
                ),
                child: const Text(
                  'ADJ',
                  style: TextStyle(
                    color: FujiColors.accent,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
              child: Text(
                'CHỌN ${state.keepCount}',
                style: const TextStyle(
                  color: FujiColors.keep,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  fontFeatures: FujiTheme.tabularFeatures,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: state.visibleItemIds.length,
              onPageChanged: (idx) {
                setState(() {
                  _currentIndex = idx;
                });
                _prefetchAdjacent(idx);
              },
              itemBuilder: (context, index) {
                final id = state.visibleItemIds[index];
                final pair = state.pairedAssetsById[id];
                if (pair == null) {
                  return const SizedBox.shrink();
                }
                return _LoupePageImage(
                  key: ValueKey<String>('loupe_$id'),
                  pairedAsset: pair,
                );
              },
            ),
          ),
          if (currentPair != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: const BoxDecoration(
                color: FujiColors.surface,
                border: Border(
                  top: BorderSide(color: FujiColors.border, width: 1),
                ),
              ),
              child: Text(
                _buildTelemetryLine(currentPair, currentItem?.unknownFields),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: FujiColors.textSecondary,
                  fontSize: 11,
                  fontFeatures: FujiTheme.tabularFeatures,
                ),
              ),
            ),
          SafeArea(
            top: false,
            child: Container(
              height: 60,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(
                color: FujiColors.canvas,
                border: Border(
                  top: BorderSide(color: FujiColors.border, width: 1),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: _LoupeActionButton(
                      key: const Key('loupe_reject_button'),
                      label: '✕ LOẠI',
                      active: currentStatus == 'reject',
                      activeColor: FujiColors.reject,
                      onPressed: () {
                        unawaited(HapticFeedback.lightImpact());
                        final next =
                            currentStatus == 'reject' ? null : 'reject';
                        controller.setCullStatus(currentId, next);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _LoupeActionButton(
                      key: const Key('loupe_keep_button'),
                      label: '● CHỌN',
                      active: currentStatus == 'keep',
                      activeColor: FujiColors.keep,
                      onPressed: () {
                        unawaited(HapticFeedback.mediumImpact());
                        controller.toggleKeep(currentId);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _LoupeActionButton(
                      key: const Key('loupe_develop_button'),
                      label: '⚙ HẬU KỲ',
                      active: isDnaEdited,
                      activeColor: FujiColors.accent,
                      onPressed: currentPair == null
                          ? () {}
                          : () {
                              Navigator.of(context).push<void>(
                                MaterialPageRoute<void>(
                                  builder: (_) => StudioEditorScreen(
                                    itemId: currentId,
                                    pairedAsset: currentPair,
                                  ),
                                ),
                              );
                            },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _buildTelemetryLine(
    PairedAsset pair,
    Map<String, Object?>? unknownFields,
  ) {
    final cameraModel = unknownFields?['camera_model'] as String?;
    final w = pair.width;
    final h = pair.height;
    final dims = (w != null && h != null && w > 0 && h > 0)
        ? '${w}x$h'
        : '—';
    final kindLabel = switch (pair.kind) {
      AssetPairKind.jpgPlusRaf => 'J+R',
      AssetPairKind.rafOnly => 'RAF',
      AssetPairKind.jpgOnly => 'JPG',
    };
    return <String>[
      pair.displayName,
      if (cameraModel != null && cameraModel.isNotEmpty) cameraModel,
      dims,
      kindLabel,
    ].join(' · ');
  }
}

class _LoupePageImage extends ConsumerStatefulWidget {
  const _LoupePageImage({
    super.key,
    required this.pairedAsset,
  });

  final PairedAsset pairedAsset;

  @override
  ConsumerState<_LoupePageImage> createState() => _LoupePageImageState();
}

class _LoupePageImageState extends ConsumerState<_LoupePageImage> {
  ProxyCancelToken _cancelToken = ProxyCancelToken();
  File? _proxyFile;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _LoupePageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shouldReloadProxy(oldWidget.pairedAsset, widget.pairedAsset)) {
      _cancelToken.cancel();
      _proxyFile = null;
      _failed = false;
      _load();
    }
  }

  static bool _shouldReloadProxy(PairedAsset prev, PairedAsset next) {
    return prev.pairKey != next.pairKey ||
        prev.primaryAsset.uri != next.primaryAsset.uri ||
        prev.primaryAsset.sizeBytes != next.primaryAsset.sizeBytes ||
        prev.primaryAsset.dateModifiedSec != next.primaryAsset.dateModifiedSec;
  }

  void _load() {
    final token = ProxyCancelToken();
    _cancelToken = token;
    unawaited(
      ref
          .read(proxyCacheManagerProvider)
          .requestProxy(
            widget.pairedAsset,
            priority: ProxyPriority.activeViewer,
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
    if (_failed) {
      return const Center(
        child: Icon(
          Icons.broken_image_outlined,
          size: 40,
          color: FujiColors.textSecondary,
        ),
      );
    }
    if (_proxyFile == null || !_proxyFile!.existsSync()) {
      return const Center(
        child: CircularProgressIndicator(color: FujiColors.accent),
      );
    }
    return InteractiveViewer(
      minScale: 1.0,
      maxScale: 3.0,
      child: Center(
        child: Image.file(
          _proxyFile!,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
      ),
    );
  }
}

class _LoupeActionButton extends StatelessWidget {
  const _LoupeActionButton({
    super.key,
    required this.label,
    required this.active,
    required this.activeColor,
    required this.onPressed,
  });

  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: active
            ? activeColor.withValues(alpha: 0.16)
            : FujiColors.surface,
        foregroundColor: active ? activeColor : FujiColors.textPrimary,
        side: BorderSide(
          color: active ? activeColor : FujiColors.border,
          width: 1,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
