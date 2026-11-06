import 'package:flutter/cupertino.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';
import '../features/bilibili_jump.dart';
import '../features/catalog.dart';
import 'playback_controller.dart';
import 'player_backdrop.dart';
import 'player_view.dart';

enum _PhoneView { artwork, lyrics, queue }

/// iPhone/iPad 的完整播放页（以 Sheet 呈现）：参照 Apple Music iOS——
/// 大封面 + 标题/进度/传输控制，底部在“歌词”“待播清单”间切换；
/// 歌词与队列视图顶部保留小封面标题头，控制区留在下方。横屏时左右分栏。
class PhonePlayer extends StatefulWidget {
  const PhonePlayer({
    super.key,
    required this.controller,
    required this.onClose,
    this.onOpenCollection,
  });
  final PlaybackController controller;
  final VoidCallback onClose;
  final ValueChanged<Collection>? onOpenCollection;
  @override
  State<PhonePlayer> createState() => _PhonePlayerState();
}

class _PhonePlayerState extends State<PhonePlayer> {
  _PhoneView view = _PhoneView.artwork;

  void toggle(_PhoneView target) =>
      setState(() => view = view == target ? _PhoneView.artwork : target);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller, track = controller.track;
      final podcast = track?.isPodcast == true;
      if (podcast && view == _PhoneView.lyrics) view = _PhoneView.artwork;
      return PlayerBackdrop(
        api: controller.api,
        url: track?.cover,
        playing: controller.engine.playing,
        child: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, box) {
              final landscape = box.maxWidth > box.maxHeight * 1.15;
              final controls = Padding(
                padding: EdgeInsets.fromLTRB(28, 0, 28, landscape ? 0 : 4),
                child: NowPlayingControls(
                  controller: controller,
                  onOpenCollection: widget.onOpenCollection,
                  showTitle: view == _PhoneView.artwork,
                ),
              );
              final switcher = _ViewSwitcher(
                view: view,
                lyrics: !podcast,
                onToggle: toggle,
              );
              // iPad 上内容居中并限宽，避免进度条和按钮被拉到屏幕两侧。
              return Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: landscape ? 1000 : 600,
                    maxHeight: box.maxHeight,
                  ),
                  child: Column(
                    children: [
                      _Grabber(onClose: widget.onClose),
                      Expanded(
                        child: landscape
                            ? Row(
                                children: [
                                  Expanded(
                                    child: _body(context, landscape: true),
                                  ),
                                  Expanded(
                                    child: Center(
                                      child: SingleChildScrollView(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            controls,
                                            const SizedBox(height: 8),
                                            switcher,
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : Column(
                                children: [
                                  Expanded(child: _body(context)),
                                  controls,
                                  const SizedBox(height: 4),
                                  switcher,
                                  const SizedBox(height: 6),
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
      );
    },
  );

  Widget _body(BuildContext context, {bool landscape = false}) {
    final controller = widget.controller, track = controller.track;
    switch (view) {
      case _PhoneView.artwork:
        return LayoutBuilder(
          builder: (context, box) {
            // 可用高度不足时（大字号、小屏）封面让位给控制区，不强制最小尺寸。
            final size = [
              if (box.maxWidth < box.maxHeight) box.maxWidth - 56,
              box.maxHeight - 16,
              420.0,
            ].reduce((a, b) => a < b ? a : b).clamp(0.0, 420.0).toDouble();
            return Center(
              child: RemoteArtwork(
                api: controller.api,
                url: track?.cover,
                seed: track?.album ?? 'Dymuse',
                size: size,
                radius: 16,
              ),
            );
          },
        );
      case _PhoneView.lyrics:
      case _PhoneView.queue:
        // 大字号或小屏下可用高度不足时隐藏标题头，把空间留给歌词/队列。
        return LayoutBuilder(
          builder: (context, box) => Column(
            children: [
              if (box.maxHeight >= 260)
                _Header(
                  controller: controller,
                  onOpenCollection: widget.onOpenCollection,
                ),
              Expanded(
                child: view == _PhoneView.lyrics
                    ? LyricsView(
                        controller: controller,
                        fontSize: 26,
                        padding: const EdgeInsets.fromLTRB(28, 24, 28, 60),
                      )
                    : _PhoneQueue(controller: controller),
              ),
            ],
          ),
        );
    }
  }
}

/// Sheet 顶部拖拽条；下拉手势由系统 Sheet 处理，按钮保证无障碍可收起。
class _Grabber extends StatelessWidget {
  const _Grabber({required this.onClose});
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '收起播放器',
    excludeSemantics: true,
    onTap: onClose,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onClose,
      child: SizedBox(
        height: 28,
        child: Center(
          child: Container(
            width: 36,
            height: 5,
            decoration: BoxDecoration(
              color: DymuseTokens.secondary(context).withValues(alpha: .5),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 歌词/队列视图的标题头：小封面 + 标题 + 可点击署名。
class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.onOpenCollection});
  final PlaybackController controller;
  final ValueChanged<Collection>? onOpenCollection;
  @override
  Widget build(BuildContext context) {
    final track = controller.track;
    final jump = BilibiliJump.forPlayer(context, controller, onOpenCollection);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 8),
      child: Row(
        children: [
          RemoteArtwork(
            api: controller.api,
            url: track?.cover,
            seed: track?.album ?? 'Dymuse',
            size: 56,
            radius: 8,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TrackTitle(
                  text: track?.title ?? '尚未播放',
                  onJump: jump,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (track != null)
                  TrackCredits(
                    track: track,
                    onOpen: onOpenCollection,
                    fontSize: 14,
                    onJump: jump,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部“歌词 / 待播清单”切换，再次点按回到封面。
class _ViewSwitcher extends StatelessWidget {
  const _ViewSwitcher({
    required this.view,
    required this.lyrics,
    required this.onToggle,
  });
  final _PhoneView view;
  final bool lyrics;
  final ValueChanged<_PhoneView> onToggle;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      if (lyrics)
        _SwitchButton(
          label: '歌词',
          icon: CupertinoIcons.quote_bubble,
          activeIcon: CupertinoIcons.quote_bubble_fill,
          selected: view == _PhoneView.lyrics,
          onPressed: () => onToggle(_PhoneView.lyrics),
        ),
      if (lyrics) const SizedBox(width: 48),
      _SwitchButton(
        label: '待播清单',
        icon: CupertinoIcons.list_bullet,
        activeIcon: CupertinoIcons.list_bullet,
        selected: view == _PhoneView.queue,
        onPressed: () => onToggle(_PhoneView.queue),
      ),
      // 只在歌词页、且这首歌有翻译或罗马音时出现。
      LyricLayerMenu(
        visible: view == _PhoneView.lyrics,
        builder: (context, open, active) => Row(
          children: [
            const SizedBox(width: 48),
            _SwitchButton(
              label: '歌词翻译',
              icon: CupertinoIcons.globe,
              activeIcon: CupertinoIcons.globe,
              selected: active,
              onPressed: open,
            ),
          ],
        ),
      ),
    ],
  );
}

class _SwitchButton extends StatelessWidget {
  const _SwitchButton({
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.selected,
    required this.onPressed,
  });
  final String label;
  final IconData icon, activeIcon;
  final bool selected;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: label,
    excludeSemantics: true,
    onTap: onPressed,
    child: CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: const Size(52, 48),
      onPressed: onPressed,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? DymuseTokens.ink(context).withValues(alpha: .12)
              : null,
          borderRadius: BorderRadius.circular(14),
        ),
        child: SizedBox(
          width: 52,
          height: 40,
          child: Icon(
            selected ? activeIcon : icon,
            size: 22,
            color: selected
                ? DymuseTokens.ink(context)
                : DymuseTokens.secondary(context),
          ),
        ),
      ),
    ),
  );
}

/// 待播清单：点按播放，接下来播放的行可左滑移除；“清除”清空接下来播放。
class _PhoneQueue extends StatelessWidget {
  const _PhoneQueue({required this.controller});
  final PlaybackController controller;
  @override
  Widget build(BuildContext context) {
    final items = controller.items, current = controller.index;
    final upcoming = items.length - current - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 4, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${items.length} 首',
                  style: DymuseTokens.caption.copyWith(
                    color: DymuseTokens.secondary(context),
                  ),
                ),
              ),
              if (upcoming > 0)
                CupertinoButton(
                  minimumSize: const Size(44, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  onPressed: controller.clearUpcoming,
                  child: const Text('清除', style: TextStyle(fontSize: 15)),
                ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const StatusMessage(title: '队列为空', message: '从当前音乐模式选择歌曲。')
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: items.length,
                  itemBuilder: (context, index) =>
                      _QueueRow(controller: controller, index: index),
                ),
        ),
      ],
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({required this.controller, required this.index});
  final PlaybackController controller;
  final int index;
  @override
  Widget build(BuildContext context) {
    final item = controller.items[index];
    final track = controller.catalog.cached(
      controller.mode,
      item['id'].toString(),
      isPodcast: item['kind'] == 'podcast',
    );
    final active = index == controller.index;
    final played = index < controller.index;
    final title =
        track?.title ?? item['title']?.toString() ?? '歌曲 ${item['id']}';
    final row = Semantics(
      button: true,
      selected: active,
      label: '播放 $title',
      excludeSemantics: true,
      onTap: item['unavailable'] == true
          ? null
          : () => controller.select(index),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: item['unavailable'] == true
            ? null
            : () => active ? null : controller.select(index),
        child: Opacity(
          opacity: played ? .5 : 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 60),
            child: Row(
              children: [
                RemoteArtwork(
                  api: controller.api,
                  url: track?.cover,
                  seed: track?.album ?? title,
                  size: 44,
                  radius: 7,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: active ? DymuseTokens.tint(context) : null,
                        ),
                      ),
                      if (track != null)
                        Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DymuseTokens.caption.copyWith(
                            color: DymuseTokens.secondary(context),
                          ),
                        ),
                    ],
                  ),
                ),
                if (active)
                  Icon(
                    CupertinoIcons.waveform,
                    size: 18,
                    color: DymuseTokens.tint(context),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    // 当前曲不能移除；其余行左滑后交给服务端接口，列表随回包刷新。
    if (active) return row;
    return Dismissible(
      key: ValueKey('queue-${item['id']}-$index'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        await controller.removeAt(index);
        return false;
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: const Color(0xFFD32F2F),
        child: const Icon(
          CupertinoIcons.delete,
          color: Color(0xFFFFFFFF),
          semanticLabel: '移除',
        ),
      ),
      child: row,
    );
  }
}
