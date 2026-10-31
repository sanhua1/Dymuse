import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../core/api_client.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';
import '../playback/playback_controller.dart';
import 'browse_page.dart';
import 'catalog.dart';

/// 心动页直接展示实际播放队列，浏览续推与播放预取共用一个入口。
class IntelligencePage extends StatefulWidget {
  const IntelligencePage({
    super.key,
    required this.playback,
    required this.onExpand,
    this.privateFm = false,
    this.header,
  });
  final PlaybackController playback;
  final VoidCallback onExpand;
  final bool privateFm;

  /// 私人 FM 放在列表最上方、随列表滚动的页眉（现在就听标题与分段标签）。
  final Widget? header;
  @override
  State<IntelligencePage> createState() => _IntelligencePageState();
}

class _IntelligencePageState extends State<IntelligencePage> {
  final scroll = ScrollController();
  final wanted = <String>{}, attempted = <String>{};
  String? generation, autoKey, metadataError;
  bool metadataScheduled = false, hydrating = false;
  PlaybackController get playback => widget.playback;
  bool get active => widget.privateFm ? playback.fm : playback.intelligence;
  String get title => widget.privateFm ? '私人 FM' : '心动模式';
  Future<void> more() =>
      widget.privateFm ? playback.moreFm() : playback.moreIntelligence();

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  /// 只补齐当前已构建列表行的详情，避免一次装载整条长队列。
  void requestMetadata(String id) {
    if (playback.catalog.cached(MusicMode.netease, id) != null ||
        attempted.contains(id)) {
      return;
    }
    wanted.add(id);
    if (metadataScheduled || hydrating) return;
    metadataScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => hydrate());
  }

  Future<void> hydrate() async {
    metadataScheduled = false;
    if (!mounted || hydrating || wanted.isEmpty) return;
    final current = generation, session = playback.api.token;
    final ids = wanted.take(100).toList();
    wanted.removeAll(ids);
    attempted.addAll(ids);
    hydrating = true;
    try {
      await playback.catalog.hydrate(ids);
      if (mounted && generation == current && session == playback.api.token) {
        metadataError = null;
      }
    } catch (error) {
      if (mounted && generation == current && session == playback.api.token) {
        metadataError = readableError(error);
      }
    } finally {
      hydrating = false;
      if (mounted) {
        setState(() {});
        if (wanted.isNotEmpty) unawaited(hydrate());
      }
    }
  }

  /// 每个队尾只自动触发一次；无新结果或失败后保留刷新入口。
  void nearEnd() {
    if (!mounted ||
        !scroll.hasClients ||
        !active ||
        playback.extending ||
        playback.loading) {
      return;
    }
    if (scroll.position.extentAfter >= 480) return;
    if ([
      'failed',
      'exhausted',
    ].contains(playback.state['recommendationStatus'])) {
      return;
    }
    final key = '${playback.snapshot?['generation']}:${playback.items.length}';
    if (autoKey == key) return;
    autoKey = key;
    unawaited(more());
  }

  Future<void> favorite(Track track, bool liked) async {
    try {
      await playback.api.post('/netease/like', {
        'id': track.id,
        'like': !liked,
      });
    } catch (error) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('喜欢状态更新失败'),
          content: Text(readableError(error)),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context),
              child: const Text('好'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: playback,
    builder: (context, _) {
      final currentGeneration = playback.snapshot?['generation']?.toString();
      if (generation != currentGeneration) {
        generation = currentGeneration;
        wanted.clear();
        attempted.clear();
        autoKey = null;
        metadataError = null;
      }
      if (!active) {
        if (playback.loading) {
          return const Center(child: CupertinoActivityIndicator());
        }
        final message = StatusMessage(
          title: title,
          message:
              playback.error ??
              (widget.privateFm
                  ? '按你的网易云偏好持续推荐。开始收听才会切换当前队列。'
                  : '从我喜欢的音乐出发，听一些新的推荐。'),
          action: ActionButton(
            label: widget.privateFm ? '开始私人 FM' : '开始心动播放',
            onPressed: widget.privateFm
                ? playback.startFm
                : playback.startIntelligence,
          ),
        );
        if (widget.header == null) return message;
        // 还没开始收听时不可滚动：页眉固定在顶部，下面显示状态。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: MediaQuery.paddingOf(context).top),
            widget.header!,
            Expanded(child: message),
          ],
        );
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => nearEnd());
      return NotificationListener<ScrollNotification>(
        onNotification: (_) {
          nearEnd();
          return false;
        },
        child: CustomScrollView(
          controller: scroll,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            // iPhone 内容延伸到悬浮顶栏下方，开头留出顶栏高度；其他平台为 0。
            SliverPadding(
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
            ),
            CupertinoSliverRefreshControl(onRefresh: more),
            if (widget.header != null) SliverToBoxAdapter(child: widget.header),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(title, style: DymuseTokens.heading),
                        ),
                        ActionButton(
                          label: '刷新推荐',
                          icon: CupertinoIcons.arrow_clockwise,
                          onPressed: playback.extending || playback.loading
                              ? null
                              : more,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${widget.privateFm ? '网易云私人 FM' : '根据我喜欢的音乐推荐'} · 当前队列 ${playback.items.length} 首',
                      style: DymuseTokens.body.copyWith(
                        color: DymuseTokens.secondary(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              sliver: SliverList.builder(
                itemCount: playback.items.length,
                itemBuilder: (context, index) {
                  final item = playback.items[index],
                      id = playback.items[index]['id'].toString();
                  requestMetadata(id);
                  final track =
                      playback.catalog.cached(MusicMode.netease, id) ??
                      Track(
                        id: id,
                        mode: MusicMode.netease,
                        title: item['title']?.toString().isNotEmpty == true
                            ? item['title'].toString()
                            : '歌曲 $id',
                      );
                  return TrackRow(
                    key: ValueKey(id),
                    track: track,
                    index: index,
                    api: playback.api,
                    playback: playback,
                    favorite: track.favorite,
                    onPlay: () {
                      if (track.available) playback.select(index);
                    },
                    onActivate: () {
                      if (index == playback.index) {
                        widget.onExpand();
                      } else if (track.available) {
                        playback.select(index);
                      }
                    },
                    onFavorite: (liked) => favorite(track, liked),
                  );
                },
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    if (playback.extending) const CupertinoActivityIndicator(),
                    if (playback.error != null)
                      Text(playback.error!, style: DymuseTokens.caption),
                    if (playback.state['recommendationStatus'] == 'exhausted')
                      const Text('暂时没有新的推荐，可下拉或点击刷新。'),
                    if (playback.state['recommendationStatus'] == 'failed')
                      ActionButton(
                        label: '重试推荐',
                        onPressed: playback.extending ? null : more,
                      ),
                    if (metadataError != null)
                      ActionButton(
                        label: '重试歌曲信息',
                        onPressed: () => setState(() {
                          attempted.clear();
                          metadataError = null;
                        }),
                      ),
                  ],
                ),
              ),
            ),
            // macOS 底部悬浮播放条下方留白；其他平台为 0。
            SliverPadding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom,
              ),
            ),
          ],
        ),
      );
    },
  );
}
