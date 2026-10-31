import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../core/api_client.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';
import '../features/catalog.dart';
import '../features/song_actions.dart';
import 'lyric_layers.dart';
import 'playback_controller.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({
    super.key,
    required this.controller,
    required this.onExpand,
    required this.onQueue,
    required this.queueVisible,
  });
  final PlaybackController controller;
  final VoidCallback onExpand, onQueue;
  final bool queueVisible;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) {
      final track = controller.track;
      return GlassPanel(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Semantics(
                  label: '打开正在播放',
                  button: true,
                  child: CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: onExpand,
                    child: RemoteArtwork(
                      api: controller.api,
                      url: track?.cover,
                      size: 48,
                      seed: track?.album ?? 'Dymuse',
                      radius: 8,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: GestureDetector(
                    onTap: onExpand,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track?.title ?? '选一首，开始听',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            track?.artist ?? controller.mode.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: DymuseTokens.caption.copyWith(
                              color: DymuseTokens.secondary(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SongActions(catalog: controller.catalog, track: track),
                PlaybackButtons(controller: controller),
                if (MediaQuery.sizeOf(context).width >= 1000) ...[
                  const SizedBox(width: 28),
                  const Icon(CupertinoIcons.speaker_2, size: 16),
                  SizedBox(
                    width: 100,
                    child: Semantics(
                      label: '音量',
                      value: '${(controller.volume * 100).round()}%',
                      child: CupertinoSlider(
                        value: controller.volume,
                        onChanged: controller.setVolume,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                ActionButton(
                  label: '播放队列',
                  icon: CupertinoIcons.list_bullet,
                  selected: queueVisible,
                  onPressed: onQueue,
                ),
                ActionButton(
                  label: '展开播放器',
                  icon: CupertinoIcons.chevron_up,
                  onPressed: onExpand,
                ),
              ],
            ),
            const SizedBox(height: 4),
            PlaybackProgress(controller: controller, compact: true),
            if (controller.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          controller.error!,
                          style: TextStyle(
                            fontSize: 11,
                            color: DymuseTokens.tint(context),
                          ),
                        ),
                      ),
                    ),
                    ActionButton(
                      label: '重试播放',
                      onPressed: controller.retry,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
}

class PlaybackButtons extends StatelessWidget {
  const PlaybackButtons({
    super.key,
    required this.controller,
    this.large = false,
  });
  final PlaybackController controller;
  final bool large;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ActionButton(
        label: '上一首',
        icon: CupertinoIcons.backward_end_fill,
        onPressed: controller.items.isEmpty ? null : controller.previous,
      ),
      const SizedBox(width: 4),
      ValueListenableBuilder(
        valueListenable: controller.engine.playing,
        builder: (_, playing, _) => ActionButton(
          label: playing ? '暂停' : '播放',
          filled: large,
          onPressed: controller.items.isEmpty || controller.loading
              ? null
              : controller.toggle,
          child: controller.loading
              ? const CupertinoActivityIndicator()
              : Icon(
                  playing
                      ? CupertinoIcons.pause_fill
                      : CupertinoIcons.play_fill,
                  size: large ? 28 : 23,
                ),
        ),
      ),
      const SizedBox(width: 4),
      ActionButton(
        label: '下一首',
        icon: CupertinoIcons.forward_end_fill,
        onPressed: controller.items.isEmpty ? null : () => controller.next(),
      ),
    ],
  );
}

/// 高频进度只重建此区域，不驱动整页和玻璃容器。
class PlaybackProgress extends StatefulWidget {
  const PlaybackProgress({
    super.key,
    required this.controller,
    this.compact = false,
  });
  final PlaybackController controller;
  final bool compact;
  @override
  State<PlaybackProgress> createState() => _PlaybackProgressState();
}

class _PlaybackProgressState extends State<PlaybackProgress> {
  double? dragging;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.controller.engine.position,
      widget.controller.engine.duration,
      widget.controller.engine.buffering,
    ]),
    builder: (_, _) {
      final engine = widget.controller.engine;
      final total = engine.duration.value.inMilliseconds.toDouble();
      final progress =
          dragging ??
          (total <= 0
              ? 0.0
              : (engine.position.value.inMilliseconds / total).clamp(0.0, 1.0));
      return Row(
        children: [
          if (!widget.compact)
            SizedBox(
              width: 46,
              child: Text(
                timeLabel(Duration(milliseconds: (progress * total).round())),
                style: DymuseTokens.caption,
              ),
            ),
          Expanded(
            child: Semantics(
              label: '播放进度',
              value: timeLabel(
                Duration(milliseconds: (progress * total).round()),
              ),
              child: SeekSlider(
                value: progress,
                onChangeStart: (_) => setState(() => dragging = progress),
                onChanged: total <= 0
                    ? null
                    : (value) => setState(() => dragging = value),
                onChangeEnd: (value) async {
                  await widget.controller.seek(
                    Duration(milliseconds: (value * total).round()),
                  );
                  if (mounted) setState(() => dragging = null);
                },
              ),
            ),
          ),
          if (engine.buffering.value)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: CupertinoActivityIndicator(radius: 6),
            ),
          if (!widget.compact)
            SizedBox(
              width: 46,
              child: Text(
                timeLabel(engine.duration.value),
                textAlign: TextAlign.end,
                style: DymuseTokens.caption,
              ),
            ),
        ],
      );
    },
  );
}

class QueuePanel extends StatelessWidget {
  const QueuePanel({
    super.key,
    required this.controller,
    required this.onClose,
    required this.onExpand,
  });
  final PlaybackController controller;
  final VoidCallback onClose, onExpand;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) => Container(
      decoration: BoxDecoration(
        color: DymuseTokens.background(context),
        border: Border(left: BorderSide(color: DymuseTokens.line(context))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 10, 4),
            child: Row(
              children: [
                const Expanded(child: Text('待播清单', style: DymuseTokens.title)),
                ActionButton(
                  label: '关闭队列',
                  icon: CupertinoIcons.xmark,
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              '${controller.mode.label} · ${controller.items.length} 首',
              style: DymuseTokens.caption.copyWith(
                color: DymuseTokens.secondary(context),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (controller.state['origin'] == 'podcast' &&
              controller.state['nextOffset'] != null)
            ActionButton(
              label: '载入后续节目',
              icon: CupertinoIcons.arrow_clockwise,
              onPressed: controller.extending ? null : controller.morePodcasts,
            ),
          Expanded(
            child: controller.items.isEmpty
                ? const StatusMessage(title: '队列为空', message: '从当前音乐模式选择歌曲。')
                : NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification.metrics.extentAfter < 480 &&
                          controller.error == null) {
                        controller.morePodcasts();
                      }
                      return false;
                    },
                    child: ListView.builder(
                      itemCount: controller.items.length,
                      itemBuilder: (context, index) {
                        final item = controller.items[index];
                        final track = controller.catalog.cached(
                          controller.mode,
                          item['id'].toString(),
                          isPodcast: item['kind'] == 'podcast',
                        );
                        final active = index == controller.index;
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          child: ActionButton(
                            label:
                                '播放 ${track?.title ?? item['title'] ?? item['id']}',
                            selected: active,
                            onPressed: item['unavailable'] == true
                                ? null
                                : () => active
                                      ? onExpand()
                                      : controller.select(index),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 26,
                                  child: active
                                      ? const Icon(
                                          CupertinoIcons.waveform,
                                          size: 15,
                                        )
                                      : Text(
                                          '${index + 1}',
                                          style: DymuseTokens.caption,
                                        ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        track?.title ??
                                            item['title']?.toString() ??
                                            '歌曲 ${item['id']}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (track != null)
                                        Text(
                                          track.artist,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: DymuseTokens.caption.copyWith(
                                            color: DymuseTokens.secondary(
                                              context,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    ),
  );
}

class FullPlayer extends StatefulWidget {
  const FullPlayer({
    super.key,
    required this.controller,
    required this.onClose,
    this.onOpenCollection,
    this.topInset = 0,
  });

  /// macOS 原生窗口按钮所在高度；背景延伸到顶部，内容从此下方开始。
  final double topInset;
  final PlaybackController controller;
  final VoidCallback onClose;

  /// 点击艺人/专辑/所属播客时打开对应页面；为空则只显示文字。
  final ValueChanged<Collection>? onOpenCollection;
  @override
  State<FullPlayer> createState() => _FullPlayerState();
}

class _FullPlayerState extends State<FullPlayer> {
  bool narrowLyrics = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (_, _) {
      final controller = widget.controller, track = controller.track;
      return DecoratedBox(
        decoration: BoxDecoration(
          color: DymuseTokens.background(context),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              DymuseTokens.surface(context),
              DymuseTokens.background(context),
              Color.lerp(
                DymuseTokens.background(context),
                DymuseTokens.tint(context),
                .09,
              )!,
            ],
          ),
        ),
        child: Column(
          children: [
            SizedBox(height: widget.topInset),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Row(
                children: [
                  ActionButton(
                    label: '收起播放器',
                    icon: CupertinoIcons.chevron_down,
                    onPressed: widget.onClose,
                  ),
                  Expanded(
                    child: Text(
                      DymuseTokens.liquid ? '' : controller.mode.label,
                      textAlign: TextAlign.center,
                      style: DymuseTokens.caption.copyWith(
                        color: DymuseTokens.secondary(context),
                      ),
                    ),
                  ),
                  if (track?.isPodcast != true &&
                      (MediaQuery.sizeOf(context).width >= 1080 ||
                          narrowLyrics))
                    LyricLayerMenu(
                      builder: (context, open, active) => ActionButton(
                        label: '歌词翻译',
                        icon: CupertinoIcons.globe,
                        selected: active,
                        onPressed: open,
                      ),
                    ),
                  if (track?.isPodcast != true &&
                      MediaQuery.sizeOf(context).width < 1080)
                    ActionButton(
                      label: '显示歌词',
                      icon: CupertinoIcons.text_alignleft,
                      selected: narrowLyrics,
                      onPressed: () =>
                          setState(() => narrowLyrics = !narrowLyrics),
                    )
                  else
                    const SizedBox(width: 44),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final showLyrics =
                      track?.isPodcast != true && constraints.maxWidth >= 1080;
                  if (track?.isPodcast != true && !showLyrics && narrowLyrics) {
                    return LyricsView(controller: widget.controller);
                  }
                  // 控制区与封面同宽，左右边缘对齐。
                  final art = (constraints.maxHeight * .47)
                      .clamp(180, 340)
                      .toDouble();
                  return Row(
                    children: [
                      Expanded(
                        child: Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(50, 16, 50, 24),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 380),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  RemoteArtwork(
                                    api: controller.api,
                                    url: track?.cover,
                                    seed: track?.album ?? 'Dymuse',
                                    size: art,
                                    radius: 16,
                                  ),
                                  const SizedBox(height: 28),
                                  SizedBox(
                                    width: art,
                                    child: NowPlayingControls(
                                      controller: controller,
                                      onOpenCollection: widget.onOpenCollection,
                                    ),
                                  ),
                                  if (controller.mode == MusicMode.netease &&
                                      track?.isPodcast != true)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 20),
                                      child: _GlassChip(
                                        label: '心动模式',
                                        icon: CupertinoIcons.heart_circle,
                                        selected: controller.intelligence,
                                        onPressed: controller.snapshot == null
                                            ? null
                                            : controller.setIntelligence,
                                        text: controller.intelligence
                                            ? '心动模式 · 已开启'
                                            : '心动模式',
                                      ),
                                    ),
                                  if (controller.error != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 16),
                                      child: Text(
                                        controller.error!,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: DymuseTokens.tint(context),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (showLyrics)
                        Expanded(
                          child: LyricsView(controller: widget.controller),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// 歌词视图：完整播放页与 macOS 右侧歌词栏共用；点击带时间的行跳转。
class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    required this.controller,
    this.fontSize = 22,
    this.padding = const EdgeInsets.fromLTRB(20, 100, 40, 100),
  });
  final PlaybackController controller;
  final double fontSize;
  final EdgeInsets padding;
  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  List<Json> lines = [];
  final store = LyricStore.instance;
  LyricBundle get bundle => store.bundle;
  int get layers => store.layers;
  String? lyricError, loadedId;
  bool lyricLoading = false;
  int ticket = 0, activeLine = -1;
  final scroll = ScrollController();

  /// 每行一个 key：长歌词会折行，行高不固定，按实际位置滚动。
  List<GlobalKey> keys = [];
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(changed);
    widget.controller.engine.position.addListener(positionChanged);
    store.attach();
    store.addListener(layersChanged);
    changed();
  }

  @override
  void dispose() {
    ticket++;
    store.removeListener(layersChanged);
    widget.controller.removeListener(changed);
    widget.controller.engine.position.removeListener(positionChanged);
    scroll.dispose();
    super.dispose();
  }

  void layersChanged() {
    if (mounted) setState(() {});
  }

  void changed() {
    final track = widget.controller.track;
    final key = track == null
        ? ''
        : '${track.mode.name}:${track.kind}:${track.id}';
    if (loadedId == key) return;
    loadedId = key;
    lines = [];
    // 在构建期间调用时延后通知，避免触发正在构建的“译”按钮重建。
    if (store.key != key) {
      Future.microtask(() => store.show(const LyricBundle(), key));
    }
    lyricError = null;
    activeLine = -1;
    ++ticket;
    lyricLoading = false;
    if (track != null && !track.isPodcast) unawaited(loadLyrics(track));
  }

  Future<void> loadLyrics(Track track) async {
    final current = ++ticket;
    // B 站视频没有歌词。
    if (track.mode == MusicMode.bilibili) {
      lines = [];
      lyricLoading = false;
      return;
    }
    lyricLoading = true;
    try {
      final data =
          await widget.controller.api.get('/netease/lyric', {'id': track.id})
              as Json;
      if (!mounted || current != ticket) return;
      store.show(LyricBundle.fromResponse(data, parseLrc), loadedId);
      lines = bundle.lines;
      positionChanged();
    } catch (e) {
      if (mounted && current == ticket) lyricError = readableError(e);
    } finally {
      if (mounted && current == ticket) setState(() => lyricLoading = false);
    }
  }

  void positionChanged() {
    if (!mounted || lines.isEmpty) return;
    final position = widget.controller.engine.position.value.inMilliseconds;
    var next = -1;
    for (var i = 0; i < lines.length; i++) {
      final time = (lines[i]['timeMs'] as num? ?? -1).toInt();
      if (time >= 0 && time <= position) next = i;
    }
    if (next == activeLine) return;
    setState(() => activeLine = next);
    if (next < 0) return;
    // 当前行加粗后可能改变折行，等这一帧排版完成再按实际位置滚动。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final line = next < keys.length ? keys[next].currentContext : null;
      if (!mounted ||
          line == null ||
          !scroll.hasClients ||
          scroll.position.isScrollingNotifier.value) {
        return;
      }
      unawaited(
        Scrollable.ensureVisible(
          line,
          alignment: .25,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : DymuseTokens.motion,
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (lyricLoading) return const Center(child: CupertinoActivityIndicator());
    if (lines.isEmpty) {
      return StatusMessage(
        title: '静静听',
        message: lyricError ?? '这首歌暂时没有歌词。',
        icon: CupertinoIcons.text_alignleft,
      );
    }
    if (keys.length != lines.length) {
      keys = [for (final _ in lines) GlobalKey()];
    }
    // 长句完整折行显示，行高随内容变化；一首歌通常只有几十行，一次排完即可按位置滚动。
    final list = SingleChildScrollView(
      controller: scroll,
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < lines.length; index++)
            _line(context, index),
        ],
      ),
    );
    return list;
  }

  /// 这一行要显示的各层：(文字, 层标记)。原词没有附加层时只剩原词。
  List<(String, String?)> _parts(Json line) {
    final original = line['text']?.toString() ?? '';
    final parts = <(String, String?)>[
      if (layers & LyricLayout.original != 0) (original, null),
      if (layers & LyricLayout.romaji != 0 && line['roma'] != null)
        (line['roma'].toString(), '音'),
      if (layers & LyricLayout.translation != 0 && line['trans'] != null)
        (line['trans'].toString(), '译'),
    ];
    // 关掉了原词、这一行又没有附加内容时，退回显示原词，免得出现空行。
    return parts.isEmpty ? [(original, null)] : parts;
  }

  Widget _line(BuildContext context, int index) {
    final line = lines[index];
    final active = index == activeLine,
        time = (line['timeMs'] as num? ?? -1).toInt();
    final parts = _parts(line);
    final ink = DymuseTokens.ink(context),
        muted = DymuseTokens.secondary(context);
    return GestureDetector(
      key: keys[index],
      behavior: HitTestBehavior.opaque,
      onTap: time < 0
          ? null
          : () => widget.controller.seek(Duration(milliseconds: time)),
      child: Semantics(
        button: time >= 0,
        label: [
          for (final (text, tag) in parts)
            tag == null ? text : '${tag == '译' ? '翻译' : '罗马音'}：$text',
        ].join('，'),
        excludeSemantics: true,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: widget.fontSize * .4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < parts.length; i++)
                Padding(
                  padding: EdgeInsets.only(
                    top: i == 0 ? 0 : widget.fontSize * .18,
                  ),
                  child: _layerText(
                    parts[i].$1,
                    parts[i].$2,
                    primary: i == 0,
                    active: active,
                    ink: ink,
                    muted: muted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 主行（原词，或关掉原词后的第一层）用大字；附加层缩小、变淡，并带层标记。
  Widget _layerText(
    String text,
    String? tag, {
    required bool primary,
    required bool active,
    required Color ink,
    required Color muted,
  }) {
    final size = primary ? widget.fontSize : widget.fontSize * .68;
    final style = TextStyle(
      fontSize: size,
      height: 1.3,
      fontWeight: primary && active ? FontWeight.w700 : FontWeight.w500,
      color: primary
          ? (active ? ink : muted)
          : (active
                ? ink.withValues(alpha: .78)
                : muted.withValues(alpha: .72)),
    );
    return Text(text, style: style);
  }
}

/// 支持一行多时间标签，按时间稳定排序；不显示元数据标签。
List<Json> parseLrc(String text) {
  final result = <Json>[];
  final pattern = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
  for (final line in text.split('\n')) {
    final times = pattern.allMatches(line).toList();
    final words = line.replaceAll(pattern, '').trim();
    for (final time in times) {
      final fraction = (time.group(3) ?? '').padRight(3, '0');
      result.add({
        'timeMs':
            int.parse(time.group(1)!) * 60000 +
            int.parse(time.group(2)!) * 1000 +
            int.parse(fraction),
        'text': words,
      });
    }
  }
  if (result.isEmpty) {
    return text
        .split('\n')
        .where((s) => s.trim().isNotEmpty && !s.startsWith('['))
        .map((s) => <String, dynamic>{'timeMs': -1, 'text': s.trim()})
        .toList();
  }
  result.sort((a, b) => (a['timeMs'] as int).compareTo(b['timeMs'] as int));
  return result;
}

/// “艺人 — 专辑”署名：每位艺人和专辑可单独点击跳转，缺少 id 的部分只显示文字。
class TrackCredits extends StatelessWidget {
  const TrackCredits({
    super.key,
    required this.track,
    required this.onOpen,
    this.center = false,
    this.fontSize = 14,
    this.showAlbum = false,
  });
  final Track track;
  final ValueChanged<Collection>? onOpen;
  final bool center, showAlbum;
  final double fontSize;
  @override
  Widget build(BuildContext context) {
    final color = DymuseTokens.secondary(context);
    final style = TextStyle(fontSize: fontSize, height: 1.3, color: color);
    final parts = <Widget>[];
    void link(String text, Collection? target, String label) {
      parts.add(
        target == null || onOpen == null
            ? Text(text, style: style)
            : _CreditLink(
                text: text,
                style: style,
                label: label,
                onTap: () => onOpen!(target),
              ),
      );
    }

    void separator(String text) => parts.add(Text(text, style: style));
    if (track.artists.isEmpty) {
      separator(track.artist);
    } else {
      for (var i = 0; i < track.artists.length; i++) {
        if (i > 0) separator(' / ');
        final artist = track.artists[i];
        link(
          artist.name,
          Collection(artist.id, artist.name, '歌手', null, 'artist'),
          '打开艺人 ${artist.name}',
        );
      }
    }
    if ((showAlbum || track.isPodcast) && track.album.isNotEmpty) {
      separator(' — ');
      link(track.album, track.albumTarget, '打开 ${track.album}');
    }
    return Wrap(
      alignment: center ? WrapAlignment.center : WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: parts,
    );
  }
}

class _CreditLink extends StatefulWidget {
  const _CreditLink({
    required this.text,
    required this.style,
    required this.label,
    required this.onTap,
  });
  final String text, label;
  final TextStyle style;
  final VoidCallback onTap;
  @override
  State<_CreditLink> createState() => _CreditLinkState();
}

class _CreditLinkState extends State<_CreditLink> {
  bool hover = false;
  @override
  Widget build(BuildContext context) => Semantics(
    link: true,
    label: widget.label,
    excludeSemantics: true,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          widget.text,
          style: widget.style.copyWith(
            color: hover ? DymuseTokens.ink(context) : null,
            decoration: hover ? TextDecoration.underline : null,
          ),
        ),
      ),
    ),
  );
}

/// 全屏播放器封面下方的控制区，参照 Apple Music（Liquid Glass 时代）：
/// 左对齐标题与署名、右侧喜欢/添加；细进度条与两端时间；
/// 无底色的大号传输按钮；音量条。控制直接放在内容背景上，不再套玻璃面板。
class NowPlayingControls extends StatelessWidget {
  const NowPlayingControls({
    super.key,
    required this.controller,
    required this.onOpenCollection,
    this.showTitle = true,
  });
  final PlaybackController controller;
  final ValueChanged<Collection>? onOpenCollection;

  /// 歌词、队列视图自带标题头时，控制区不再重复标题与署名。
  final bool showTitle;
  @override
  Widget build(BuildContext context) {
    final track = controller.track;
    final empty = controller.items.isEmpty;
    final noQueue = controller.snapshot == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showTitle) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track?.title ?? '尚未播放',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    if (track == null)
                      Text(
                        '选择一首你喜欢的音乐',
                        style: DymuseTokens.body.copyWith(
                          color: DymuseTokens.secondary(context),
                        ),
                      )
                    else
                      TrackCredits(
                        track: track,
                        onOpen: onOpenCollection,
                        fontSize: 16,
                      ),
                  ],
                ),
              ),
              SongActions(catalog: controller.catalog, track: track),
            ],
          ),
          const SizedBox(height: 18),
        ],
        _Scrubber(controller: controller),
        const SizedBox(height: 14),
        // 窄宽度下整体等比缩小，保持五个按钮的相对大小与间距。
        FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: 340,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _Transport(
                  label: controller.shuffle ? '关闭随机播放' : '随机播放',
                  icon: CupertinoIcons.shuffle,
                  size: 18,
                  selected: controller.shuffle,
                  onPressed: noQueue ? null : controller.setShuffle,
                ),
                _Transport(
                  label: '上一首',
                  icon: CupertinoIcons.backward_fill,
                  size: 30,
                  onPressed: empty ? null : controller.previous,
                ),
                ValueListenableBuilder(
                  valueListenable: controller.engine.playing,
                  builder: (_, playing, _) => _Transport(
                    label: playing ? '暂停' : '播放',
                    icon: playing
                        ? CupertinoIcons.pause_fill
                        : CupertinoIcons.play_fill,
                    size: 42,
                    loading: controller.loading,
                    onPressed: empty || controller.loading
                        ? null
                        : controller.toggle,
                  ),
                ),
                _Transport(
                  label: '下一首',
                  icon: CupertinoIcons.forward_fill,
                  size: 30,
                  onPressed: empty ? null : () => controller.next(),
                ),
                _Transport(
                  label: switch (controller.repeat) {
                    'all' => '重复全部',
                    'one' => '单曲重复',
                    _ => '不重复',
                  },
                  icon: controller.repeat == 'one'
                      ? CupertinoIcons.repeat_1
                      : CupertinoIcons.repeat,
                  size: 18,
                  selected: controller.repeat != 'off',
                  onPressed: noQueue ? null : controller.cycleRepeat,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Icon(
              CupertinoIcons.speaker_fill,
              size: 13,
              color: DymuseTokens.secondary(context),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Semantics(
                label: '音量',
                slider: true,
                value: '${(controller.volume * 100).round()}%',
                increasedValue:
                    '${((controller.volume + .1).clamp(0, 1) * 100).round()}%',
                decreasedValue:
                    '${((controller.volume - .1).clamp(0, 1) * 100).round()}%',
                onIncrease: () =>
                    controller.setVolume((controller.volume + .1).clamp(0, 1)),
                onDecrease: () =>
                    controller.setVolume((controller.volume - .1).clamp(0, 1)),
                child: _ThinBar(
                  value: controller.volume,
                  onChanged: controller.setVolume,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              CupertinoIcons.speaker_3_fill,
              size: 15,
              color: DymuseTokens.secondary(context),
            ),
          ],
        ),
      ],
    );
  }
}

/// 细进度条：轨道 6pt，拖动时加粗；下方两端为已播放与剩余时间。
class _Scrubber extends StatefulWidget {
  const _Scrubber({required this.controller});
  final PlaybackController controller;
  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> {
  double? dragging;
  @override
  Widget build(BuildContext context) {
    final engine = widget.controller.engine;
    return ListenableBuilder(
      listenable: Listenable.merge([
        engine.position,
        engine.duration,
        engine.buffering,
      ]),
      builder: (context, _) {
        final total = engine.duration.value;
        final position = engine.position.value;
        final progress =
            dragging ??
            (total <= Duration.zero
                ? 0.0
                : (position.inMilliseconds / total.inMilliseconds).clamp(
                    0.0,
                    1.0,
                  ));
        final shown = total * progress;
        final style = TextStyle(
          fontSize: 12,
          color: DymuseTokens.secondary(context),
          fontFeatures: const [FontFeature.tabularFigures()],
        );
        return Semantics(
          label: '播放进度',
          slider: true,
          value: timeLabel(position),
          increasedValue: timeLabel(position + const Duration(seconds: 10)),
          decreasedValue: timeLabel(position - const Duration(seconds: 10)),
          onIncrease: () =>
              widget.controller.seek(position + const Duration(seconds: 10)),
          onDecrease: () =>
              widget.controller.seek(position - const Duration(seconds: 10)),
          child: Column(
            children: [
              _ThinBar(
                value: progress,
                height: dragging == null ? 6 : 10,
                onChangeStart: total <= Duration.zero
                    ? null
                    : (value) => setState(() => dragging = value),
                onChanged: total <= Duration.zero
                    ? null
                    : (value) => setState(() => dragging = value),
                onChangeEnd: total <= Duration.zero
                    ? null
                    : (value) async {
                        await widget.controller.seek(total * value);
                        if (mounted) setState(() => dragging = null);
                      },
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(timeLabel(shown), style: style),
                  if (engine.buffering.value)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: CupertinoActivityIndicator(radius: 6),
                    ),
                  const Spacer(),
                  Text(
                    total > Duration.zero
                        ? '-${timeLabel(total - shown)}'
                        : '--:--',
                    style: style,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 从左向右填充的细轨道；点击或拖动设置值。悬停时轨道略微加粗。
class _ThinBar extends StatefulWidget {
  const _ThinBar({
    required this.value,
    this.height = 6,
    this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });
  final double value, height;
  final ValueChanged<double>? onChanged, onChangeStart, onChangeEnd;
  @override
  State<_ThinBar> createState() => _ThinBarState();
}

class _ThinBarState extends State<_ThinBar> {
  bool hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => hover = true),
    onExit: (_) => setState(() => hover = false),
    child: LayoutBuilder(
      builder: (context, constraints) {
        double at(Offset local) =>
            (local.dx / constraints.maxWidth).clamp(0.0, 1.0);
        final enabled = widget.onChanged != null;
        final height = widget.height + (hover && enabled ? 2 : 0);
        final ink = DymuseTokens.ink(context);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: enabled
              ? (details) {
                  final value = at(details.localPosition);
                  widget.onChangeStart?.call(value);
                  widget.onChanged!(value);
                  widget.onChangeEnd?.call(value);
                }
              : null,
          onHorizontalDragStart: enabled
              ? (details) => (widget.onChangeStart ?? widget.onChanged)!(
                  at(details.localPosition),
                )
              : null,
          onHorizontalDragUpdate: enabled
              ? (details) => widget.onChanged!(at(details.localPosition))
              : null,
          onHorizontalDragEnd: enabled
              ? (_) => widget.onChangeEnd?.call(widget.value)
              : null,
          child: SizedBox(
            height: 22,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                height: height,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: ink.withValues(alpha: .16),
                  borderRadius: BorderRadius.circular(height / 2),
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FractionallySizedBox(
                    widthFactor: widget.value.clamp(0.0, 1.0),
                    heightFactor: 1,
                    child: ColoredBox(
                      color: ink.withValues(alpha: hover ? .9 : .72),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// 传输按钮：只有图标、没有底色；悬停出现浅色圆形高亮，按下缩小变淡。
/// 随机/重复开启时为强调色。
class _Transport extends StatefulWidget {
  const _Transport({
    required this.label,
    required this.icon,
    required this.size,
    required this.onPressed,
    this.selected = false,
    this.loading = false,
  });
  final String label;
  final IconData icon;
  final double size;
  final VoidCallback? onPressed;
  final bool selected, loading;
  @override
  State<_Transport> createState() => _TransportState();
}

class _TransportState extends State<_Transport> {
  bool hover = false, pressed = false, focus = false;
  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final ink = DymuseTokens.ink(context);
    final tint = DymuseTokens.tint(context);
    final box = widget.size + 24;
    final color = !enabled
        ? ink.withValues(alpha: .3)
        : widget.selected
        ? tint
        : ink;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.label,
      excludeSemantics: true,
      child: FocusableActionDetector(
        enabled: enabled,
        onShowHoverHighlight: (value) => setState(() => hover = value),
        onShowFocusHighlight: (value) => setState(() => focus = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => pressed = true) : null,
          onTapCancel: () => setState(() => pressed = false),
          onTapUp: (_) => setState(() => pressed = false),
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: box,
            height: box,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hover && enabled
                  ? ink.withValues(alpha: .08)
                  : widget.selected
                  ? tint.withValues(alpha: .12)
                  : const Color(0x00000000),
              border: Border.all(
                color: focus ? tint : const Color(0x00000000),
                width: 2,
              ),
            ),
            child: widget.loading
                ? const CupertinoActivityIndicator()
                : AnimatedScale(
                    scale: pressed ? .86 : 1,
                    duration: const Duration(milliseconds: 100),
                    child: AnimatedOpacity(
                      opacity: pressed ? .6 : 1,
                      duration: const Duration(milliseconds: 100),
                      child: Icon(widget.icon, size: widget.size, color: color),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// 胶囊玻璃芯片（心动模式开关）：开启时强调色文字与图标。
class _GlassChip extends StatelessWidget {
  const _GlassChip({
    required this.label,
    required this.text,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });
  final String label, text;
  final IconData icon;
  final bool selected;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final color = onPressed == null
        ? DymuseTokens.secondary(context)
        : selected
        ? DymuseTokens.tint(context)
        : DymuseTokens.ink(context);
    return Center(
      child: Semantics(
        button: true,
        selected: selected,
        enabled: onPressed != null,
        label: label,
        excludeSemantics: true,
        child: GestureDetector(
          onTap: onPressed,
          child: MouseRegion(
            cursor: onPressed == null
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
            child: GlassPanel(
              radius: 18,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 6),
                  Text(
                    text,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// “译”菜单：选择显示原词、翻译、罗马音，并列出翻译人与版本。
/// 轻点或长按展开，长按后滑到选项上松开即选中；[builder] 画触发按钮。
/// 当前歌曲没有翻译与罗马音、或所在界面没在看歌词时，按钮淡出并收起。
class LyricLayerMenu extends StatelessWidget {
  const LyricLayerMenu({super.key, required this.builder, this.visible = true});
  final Widget Function(BuildContext context, VoidCallback open, bool active)
  builder;

  /// 所在界面是否正在看歌词；不在时按钮收起。
  final bool visible;
  @override
  Widget build(BuildContext context) {
    final store = LyricStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final shown = visible && store.available;
        final bundle = store.bundle, layers = store.layers;
        String version(int? v) => v == null ? '' : ' · 版本 $v';
        final menu = GlassPopupMenu(
          width: 230,
          entries: [
            GlassMenuEntry(
              '原词',
              () => store.toggle(LyricLayout.original),
              checked: layers & LyricLayout.original != 0,
            ),
            GlassMenuEntry(
              bundle.hasTranslation ? '翻译' : '翻译（这首歌没有）',
              bundle.hasTranslation
                  ? () => store.toggle(LyricLayout.translation)
                  : () {},
              checked:
                  bundle.hasTranslation &&
                  layers & LyricLayout.translation != 0,
            ),
            GlassMenuEntry(
              bundle.hasRomaji ? '罗马音' : '罗马音（这首歌没有）',
              bundle.hasRomaji ? () => store.toggle(LyricLayout.romaji) : () {},
              checked: bundle.hasRomaji && layers & LyricLayout.romaji != 0,
            ),
            if (bundle.hasTranslation && bundle.translator != null)
              GlassMenuEntry(
                '翻译：${bundle.translator}${version(bundle.translationVersion)}',
                () {},
                icon: CupertinoIcons.person,
              ),
            if (bundle.hasRomaji && bundle.romajiVersion != null)
              GlassMenuEntry(
                '罗马音${version(bundle.romajiVersion)}',
                () {},
                icon: CupertinoIcons.info,
              ),
          ],
          builder: (context, open) => builder(
            context,
            open,
            layers & (LyricLayout.translation | LyricLayout.romaji) != 0,
          ),
        );
        // 出现与消失时淡入淡出并平滑改变宽度，其余按钮随之滑动到新位置。
        final duration = MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : DymuseTokens.motion;
        return AnimatedSize(
          duration: duration,
          curve: Curves.easeOutCubic,
          child: AnimatedSwitcher(
            duration: duration,
            child: shown
                ? KeyedSubtree(key: const ValueKey(true), child: menu)
                : const SizedBox.shrink(key: ValueKey(false)),
          ),
        );
      },
    );
  }
}
