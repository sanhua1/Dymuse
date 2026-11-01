import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../core/api_client.dart';
import '../design_system/components.dart';
import 'login_required.dart';
import '../design_system/tokens.dart';
import 'catalog.dart';

/// 底部和完整播放器共用歌曲操作，节目不显示歌曲红心或歌单入口。
class SongActions extends StatelessWidget {
  const SongActions({
    super.key,
    required this.catalog,
    required this.track,
    this.bar = false,
  });
  final Catalog catalog;
  final Track? track;

  /// 桌面播放条里的紧凑样式：与旁边的歌词、队列按钮同尺寸。
  final bool bar;
  @override
  Widget build(BuildContext context) {
    if (track == null || track!.isPodcast) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FavoriteButton(catalog: catalog, track: track!, bar: bar),
        _PlaylistButton(catalog: catalog, track: track!, bar: bar),
      ],
    );
  }
}

class FavoriteButton extends StatefulWidget {
  const FavoriteButton({
    super.key,
    required this.catalog,
    required this.track,
    this.bar = false,
  });
  final Catalog catalog;
  final Track track;
  final bool bar;
  @override
  State<FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends State<FavoriteButton> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FavoriteButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id ||
        oldWidget.track.mode != widget.track.mode ||
        oldWidget.catalog != widget.catalog) {
      _load();
    }
  }

  void _load() {
    // 避免在父组件构建期间通知共享状态；读取失败仍允许点击后重试。
    scheduleMicrotask(() async {
      if (!mounted) return;
      try {
        await widget.catalog.loadFavorite(widget.track);
      } catch (_) {
        /* 点击时显示明确错误。 */
      }
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.catalog,
    builder: (_, _) {
      final liked =
          widget.catalog.favoriteValue(widget.track) ?? widget.track.favorite;
      final onPressed = widget.catalog.favoriteBusy(widget.track)
          ? null
          : () async {
              if (widget.track.mode == MusicMode.netease &&
                  !await ensureLoggedIn(context, widget.catalog.api)) {
                return;
              }
              try {
                await widget.catalog.changeFavorite(widget.track);
              } catch (error) {
                if (context.mounted) await _showError(context, error);
              }
            };
      final label = liked ? '取消喜欢' : '喜欢这首音乐';
      final icon = liked ? CupertinoIcons.heart_fill : CupertinoIcons.heart;
      return widget.bar
          ? BarButton(
              label: label,
              icon: icon,
              size: 18,
              selected: liked,
              onPressed: onPressed,
            )
          : ActionButton(
              label: label,
              icon: icon,
              selected: liked,
              onPressed: onPressed,
            );
    },
  );
}

class _PlaylistButton extends StatefulWidget {
  const _PlaylistButton({
    required this.catalog,
    required this.track,
    this.bar = false,
  });
  final Catalog catalog;
  final Track track;
  final bool bar;
  @override
  State<_PlaylistButton> createState() => _PlaylistButtonState();
}

class _PlaylistButtonState extends State<_PlaylistButton> {
  String? added;
  @override
  void didUpdateWidget(_PlaylistButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id ||
        oldWidget.track.mode != widget.track.mode) {
      added = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = added == null ? '添加到歌单' : '已加入$added，再添加到其他歌单';
    final icon = added == null
        ? CupertinoIcons.text_badge_plus
        : CupertinoIcons.check_mark_circled;
    Future<void> onPressed() async {
      if (widget.track.mode == MusicMode.netease &&
          !await ensureLoggedIn(context, widget.catalog.api)) {
        return;
      }
      if (!context.mounted) return;
      final result = await showPlaylistPicker(
        context,
        widget.catalog,
        widget.track,
      );
      if (mounted && result != null) setState(() => added = result);
    }

    return widget.bar
        ? BarButton(
            label: label,
            icon: icon,
            size: 18,
            selected: added != null,
            onPressed: onPressed,
          )
        : ActionButton(
            label: label,
            icon: icon,
            selected: added != null,
            onPressed: onPressed,
          );
  }
}

Future<void> _showError(BuildContext context, Object error) =>
    showCupertinoDialog<void>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('操作未完成'),
        content: Text(readableError(error)),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('好'),
          ),
        ],
      ),
    );

Future<String?> showPlaylistPicker(
  BuildContext context,
  Catalog catalog,
  Track track,
) {
  if (track.isPodcast) return Future.value();
  return showCupertinoModalPopup<String>(
    context: context,
    builder: (popupContext) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 480,
            maxHeight: (MediaQuery.sizeOf(popupContext).height * .8)
                .clamp(0, 480)
                .toDouble(),
          ),
          child: _PlaylistPicker(catalog: catalog, track: track),
        ),
      ),
    ),
  );
}

/// 选择器滚动自动分页，写入期间禁止重复提交，失败保留当前列表。
class _PlaylistPicker extends StatefulWidget {
  const _PlaylistPicker({required this.catalog, required this.track});
  final Catalog catalog;
  final Track track;
  @override
  State<_PlaylistPicker> createState() => _PlaylistPickerState();
}

class _PlaylistPickerState extends State<_PlaylistPicker> {
  final scroll = ScrollController();
  final List<Collection> playlists = [];
  late final session = widget.catalog.api.token;
  int? next = 0;
  bool loading = false, writing = false, pageFailed = false;
  String? error;
  @override
  void initState() {
    super.initState();
    widget.catalog.addListener(_changed);
    scroll.addListener(_nearEnd);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.catalog.removeListener(_changed);
    scroll.dispose();
    super.dispose();
  }

  bool get active => mounted && session == widget.catalog.api.token;
  void _changed() {
    if (mounted) setState(() {});
  }

  void _nearEnd() {
    if (active &&
        !loading &&
        !writing &&
        error == null &&
        next != null &&
        scroll.hasClients &&
        scroll.position.extentAfter < 300) {
      _load();
    }
  }

  Future<void> _load() async {
    if (!active || loading || next == null) return;
    final offset = next!;
    setState(() {
      loading = true;
      error = null;
      pageFailed = false;
    });
    try {
      final page = await widget.catalog.editablePlaylists(
        widget.track.mode,
        offset,
      );
      if (!active) return;
      final ids = playlists.map((item) => item.id).toSet();
      playlists.addAll(page.collections.where((item) => ids.add(item.id)));
      next = page.nextOffset != null && page.nextOffset! > offset
          ? page.nextOffset
          : null;
    } catch (failure) {
      if (active) {
        error = readableError(failure);
        pageFailed = true;
      }
    } finally {
      if (active) setState(() => loading = false);
    }
  }

  Future<void> _add(Collection playlist) async {
    if (!active || writing) return;
    setState(() {
      writing = true;
      error = null;
      pageFailed = false;
    });
    try {
      await widget.catalog.addToPlaylist(widget.track, playlist.id);
      if (mounted && active) Navigator.pop(context, playlist.title);
    } catch (failure) {
      if (active) setState(() => error = readableError(failure));
    } finally {
      if (active) setState(() => writing = false);
    }
  }

  Future<void> _create() async {
    final input = TextEditingController();
    ModalRoute<dynamic>? dialogRoute;
    final name = await showCupertinoDialog<String>(
      context: context,
      builder: (context) {
        dialogRoute = ModalRoute.of(context);
        return CupertinoAlertDialog(
          title: const Text('新建歌单'),
          content: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: CupertinoTextField(
              controller: input,
              autofocus: true,
              maxLength: 100,
              placeholder: '歌单名称',
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            CupertinoDialogAction(
              onPressed: () {
                final name = input.text.trim();
                if (name.isNotEmpty) Navigator.pop(context, name);
              },
              child: const Text('创建'),
            ),
          ],
        );
      },
    );
    // 对话框退出动画结束后释放输入控制器。
    await dialogRoute?.completed;
    input.dispose();
    if (!active || name == null) return;
    setState(() {
      writing = true;
      error = null;
      pageFailed = false;
    });
    try {
      final playlist = await widget.catalog.createPlaylist(
        widget.track.mode,
        name,
      );
      if (active) setState(() => playlists.insert(0, playlist));
    } catch (failure) {
      if (active) setState(() => error = readableError(failure));
    } finally {
      if (active) setState(() => writing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!active) {
      return CupertinoPopupSurface(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('登录状态已变化，请重新打开歌单选择器。'),
              ActionButton(
                label: '关闭歌单选择器',
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _nearEnd());
    return CupertinoPopupSurface(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              children: [
                const Expanded(child: Text('添加到歌单', style: DymuseTokens.title)),
                ActionButton(
                  label: '关闭歌单选择器',
                  icon: CupertinoIcons.xmark,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                DymuseTokens.liquid
                    ? widget.track.title
                    : '${widget.track.mode.label} · ${widget.track.title}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: DymuseTokens.caption,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                controller: scroll,
                itemCount: playlists.length + 1,
                itemBuilder: (context, index) {
                  if (index == playlists.length) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          if (loading || writing)
                            const CupertinoActivityIndicator(),
                          if (error != null)
                            Text(
                              error!,
                              style: TextStyle(
                                color: DymuseTokens.tint(context),
                              ),
                            ),
                          if (pageFailed && error != null && next != null)
                            ActionButton(
                              label: '重试载入歌单',
                              onPressed: loading || writing ? null : _load,
                            ),
                          if (!loading && playlists.isEmpty && error == null)
                            const Text('还没有可添加的歌单，可先新建一个。'),
                        ],
                      ),
                    );
                  }
                  final playlist = playlists[index];
                  return ActionButton(
                    label: '加入${playlist.title}',
                    onPressed: writing ? null : () => _add(playlist),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          RemoteArtwork(
                            api: widget.catalog.api,
                            url: playlist.cover,
                            seed: playlist.title,
                            size: 40,
                            radius: 7,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  playlist.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  playlist.subtitle,
                                  style: DymuseTokens.caption,
                                ),
                              ],
                            ),
                          ),
                          const Icon(CupertinoIcons.plus, size: 18),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            ActionButton(
              label: '新建歌单',
              onPressed: writing ? null : _create,
              child: const ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.plus, size: 16),
                    SizedBox(width: 8),
                    Text('新建歌单'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
