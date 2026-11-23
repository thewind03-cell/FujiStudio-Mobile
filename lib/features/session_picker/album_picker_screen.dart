import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/di/app_providers.dart';
import '../../core/session/session_store.dart';
import '../../core/storage/asset_pairing_engine.dart';
import '../../core/storage/proxy_cache_manager.dart';
import '../../core/storage/storage_gateway.dart';
import '../../core/theme/fuji_theme.dart';
import '../diagnostics/day0_diagnostics_screen.dart';
import 'session_grid_screen.dart';

/// Root screen displaying storage permissions, latest resumable session,
/// and 2-column album gallery grid.
class AlbumPickerScreen extends ConsumerStatefulWidget {
  const AlbumPickerScreen({super.key});

  @override
  ConsumerState<AlbumPickerScreen> createState() => _AlbumPickerScreenState();
}

class _AlbumPickerScreenState extends ConsumerState<AlbumPickerScreen> {
  StoragePermissionState _permissionState = StoragePermissionState.denied;
  bool _loading = true;
  String? _error;
  List<MediaAlbumDescriptor> _albums = const <MediaAlbumDescriptor>[];
  List<RecentSessionEntry> _recentSessions = const <RecentSessionEntry>[];
  Set<String> _savedAlbumKeys = const <String>{};
  bool _cleanedOrphansOnBoot = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshAll());
  }

  Future<void> _refreshAll() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final gateway = ref.read(storageGatewayProvider);
      if (!_cleanedOrphansOnBoot) {
        _cleanedOrphansOnBoot = true;
        unawaited(
          gateway.cleanOrphanExportTempFiles(olderThanSeconds: 3600).catchError(
            (_) => 0,
          ),
        );
      }
      final store = ref.read(sessionStoreProvider);

      final permission = await gateway.getPermissionState();
      if (permission == StoragePermissionState.denied) {
        if (!mounted) return;
        setState(() {
          _permissionState = permission;
          _albums = const <MediaAlbumDescriptor>[];
          _recentSessions = const <RecentSessionEntry>[];
          _savedAlbumKeys = const <String>{};
          _loading = false;
        });
        return;
      }

      final results = await Future.wait<Object>(<Future<Object>>[
        gateway.listAlbums(),
        store.loadRecentSessions(),
        store.savedAlbumKeys(),
      ]);

      if (!mounted) return;
      setState(() {
        _permissionState = permission;
        _albums = results[0] as List<MediaAlbumDescriptor>;
        _recentSessions = results[1] as List<RecentSessionEntry>;
        _savedAlbumKeys = results[2] as Set<String>;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _requestPermission() async {
    final gateway = ref.read(storageGatewayProvider);
    await gateway.requestReadPermission();
    await _refreshAll();
  }

  Future<void> _openAlbum(MediaAlbumDescriptor album) async {
    final controller = ref.read(sessionControllerProvider.notifier);
    unawaited(controller.openAlbum(album));
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const SessionGridScreen(),
      ),
    );
    await _refreshAll();
  }

  Future<void> _openRecent(RecentSessionEntry entry) async {
    final matched = _albums.where((a) => a.albumId == entry.albumId).firstOrNull;
    final album =
        matched ??
        MediaAlbumDescriptor(
          albumId: entry.albumId,
          name: entry.albumName,
          count: entry.totalCount,
          coverUri: entry.coverUri,
        );
    await _openAlbum(album);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FUJISTUDIO'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: FujiColors.border),
        ),
        actions: <Widget>[
          IconButton(
            key: const Key('open_diagnostics_button'),
            tooltip: 'Day-0 Diagnostics',
            icon: const Icon(Icons.build_outlined, size: 20),
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const Day0DiagnosticsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: FujiColors.accent),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                _error!,
                style: const TextStyle(color: FujiColors.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: _refreshAll,
                child: const Text('THỬ LẠI'),
              ),
            ],
          ),
        ),
      );
    }

    if (_permissionState == StoragePermissionState.denied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.photo_library_outlined,
                size: 48,
                color: FujiColors.textSecondary,
              ),
              const SizedBox(height: 16),
              const Text(
                'Cần quyền đọc thư viện ảnh để duyệt .JPG và .RAF trực tiếp qua Scoped Storage.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: FujiColors.textSecondary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('grant_permission_button'),
                style: FilledButton.styleFrom(
                  backgroundColor: FujiColors.accent,
                  foregroundColor: FujiColors.canvas,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                onPressed: _requestPermission,
                child: const Text(
                  'CẤP QUYỀN THƯ VIỆN ẢNH',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final latestRecent = _recentSessions.isNotEmpty
        ? _recentSessions.first
        : null;

    return RefreshIndicator(
      color: FujiColors.accent,
      onRefresh: _refreshAll,
      child: CustomScrollView(
        slivers: <Widget>[
          if (_permissionState == StoragePermissionState.limited)
            SliverToBoxAdapter(
              child: InkWell(
                key: const Key('limited_permission_banner'),
                onTap: _requestPermission,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: const BoxDecoration(
                    color: Color(0x22E5A93C),
                    border: Border(
                      bottom: BorderSide(color: FujiColors.accent, width: 1),
                    ),
                  ),
                  child: const Row(
                    children: <Widget>[
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: FujiColors.accent,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Đang cấp quyền một phần · Chọn thêm ảnh',
                          style: TextStyle(
                            color: FujiColors.accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: FujiColors.accent,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (latestRecent != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: _ResumeSessionCard(
                  entry: latestRecent,
                  onTap: () => _openRecent(latestRecent),
                ),
              ),
            ),
          if (_albums.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  'Chưa có thư mục ảnh nào khả dụng.',
                  style: TextStyle(color: FujiColors.textSecondary),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.all(12),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.05,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final album = _albums[index];
                    final albumKey = SessionStore.albumKeyFor(album.albumId);
                    final hasSaved = _savedAlbumKeys.contains(albumKey);
                    return _AlbumGridCard(
                      album: album,
                      hasSavedSession: hasSaved,
                      onTap: () => _openAlbum(album),
                    );
                  },
                  childCount: _albums.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ResumeSessionCard extends StatelessWidget {
  const _ResumeSessionCard({
    required this.entry,
    required this.onTap,
  });

  final RecentSessionEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('resume_session_card'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: FujiColors.surface,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: FujiColors.border, width: 1),
        ),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 90,
              child: AspectRatio(
                aspectRatio: 3 / 2,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: _AlbumCoverThumbnail(
                    coverUri: entry.coverUri,
                    albumId: entry.albumId,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'TIẾP TỤC PHIÊN GẦN NHẤT',
                    style: TextStyle(
                      color: FujiColors.accent,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    entry.albumName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: FujiColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'CHỌN ${entry.keepCount} / ${entry.totalCount}',
                    style: const TextStyle(
                      color: FujiColors.textSecondary,
                      fontSize: 12,
                      fontFeatures: FujiTheme.tabularFeatures,
                    ),
                  ),
                  if (entry.updatedAtIso.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      _formatSavedStamp(entry.updatedAtIso),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: FujiColors.textSecondary,
                        fontSize: 10,
                        fontFeatures: FujiTheme.tabularFeatures,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right,
              color: FujiColors.textSecondary,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  static String _formatSavedStamp(String iso) {
    final parsed = DateTime.tryParse(iso)?.toLocal();
    if (parsed == null) return iso;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)} '
        '${two(parsed.hour)}:${two(parsed.minute)}';
  }
}

class _AlbumGridCard extends StatelessWidget {
  const _AlbumGridCard({
    required this.album,
    required this.hasSavedSession,
    required this.onTap,
  });

  final MediaAlbumDescriptor album;
  final bool hasSavedSession;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        decoration: BoxDecoration(
          color: FujiColors.surface,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: FujiColors.border, width: 1),
        ),
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 3 / 2,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: _AlbumCoverThumbnail(
                      coverUri: album.coverUri,
                      albumId: album.albumId,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: FujiColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (hasSavedSession)
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(left: 6),
                    decoration: const BoxDecoration(
                      color: FujiColors.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${album.count}',
              style: const TextStyle(
                color: FujiColors.textSecondary,
                fontSize: 11,
                fontFeatures: FujiTheme.tabularFeatures,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlbumCoverThumbnail extends ConsumerStatefulWidget {
  const _AlbumCoverThumbnail({
    required this.coverUri,
    required this.albumId,
  });

  final String? coverUri;
  final String albumId;

  @override
  ConsumerState<_AlbumCoverThumbnail> createState() =>
      _AlbumCoverThumbnailState();
}

class _AlbumCoverThumbnailState extends ConsumerState<_AlbumCoverThumbnail> {
  ProxyCancelToken? _cancelToken;
  File? _file;

  @override
  void initState() {
    super.initState();
    _loadCover();
  }

  @override
  void didUpdateWidget(covariant _AlbumCoverThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverUri != widget.coverUri) {
      _cancelToken?.cancel();
      _file = null;
      _loadCover();
    }
  }

  void _loadCover() {
    final uri = widget.coverUri;
    if (uri == null || uri.isEmpty) return;
    final token = ProxyCancelToken();
    _cancelToken = token;

    final isRaf = uri.toLowerCase().endsWith('.raf');
    final synthetic = PairedAsset(
      pairKey: 'cover|${widget.albumId}|$uri',
      stem: 'cover',
      normalizedDir: 'cover',
      kind: isRaf ? AssetPairKind.rafOnly : AssetPairKind.jpgOnly,
      primaryAsset: RawMediaFileDescriptor(
        mediaId: widget.albumId,
        uri: uri,
        displayName: isRaf ? 'cover.RAF' : 'cover.JPG',
        relativePath: '',
        mimeType: isRaf ? 'image/x-fuji-raf' : 'image/jpeg',
        sizeBytes: 0,
        dateTakenMs: null,
        dateModifiedSec: 0,
      ),
      capturedAtMs: 0,
    );

    unawaited(
      ref
          .read(proxyCacheManagerProvider)
          .requestProxy(
            synthetic,
            priority: ProxyPriority.gridViewport,
            cancelToken: token,
          )
          .then((file) {
            if (!mounted || token.isCancelled || file == null) return;
            setState(() {
              _file = file;
            });
          })
          .catchError((_) {}),
    );
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_file != null && _file!.existsSync()) {
      return Image.file(
        _file!,
        fit: BoxFit.cover,
        cacheWidth: 480,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      color: FujiColors.surfaceElevated,
      child: const Center(
        child: Icon(
          Icons.photo_outlined,
          size: 20,
          color: FujiColors.textSecondary,
        ),
      ),
    );
  }
}
