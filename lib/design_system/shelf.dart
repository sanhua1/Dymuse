import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';

import 'tokens.dart';

/// 横向一排卡片（首页推荐歌单、搜索里的歌单等）。
///
/// 桌面默认只有触控板能横滑：鼠标不能拖、滚轮只走纵向（Shift+滚轮才横向）。
/// 这里允许鼠标拖动，指针停在这一排时两侧显示翻页箭头（与 Apple Music 一致）；触控板保持系统手感。
class HorizontalShelf extends StatefulWidget {
  const HorizontalShelf({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.itemWidth,
    required this.height,
    this.spacing = 20,
    this.padding = 0,
  });
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double itemWidth, height, spacing, padding;

  @override
  State<HorizontalShelf> createState() => _HorizontalShelfState();
}

class _HorizontalShelfState extends State<HorizontalShelf> {
  final controller = ScrollController();
  bool hover = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _page(int direction) {
    if (!controller.hasClients) return;
    final position = controller.position;
    final target =
        (position.pixels + direction * position.viewportDimension * .8).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    controller.animateTo(
      target,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktop = !DymuseTokens.mobile;
    final list = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        scrollbars: false,
        // 桌面默认不允许鼠标拖动滚动；这一排允许。
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.trackpad,
          if (desktop) PointerDeviceKind.mouse,
        },
      ),
      child: ListView.separated(
        controller: controller,
        padding: EdgeInsets.symmetric(horizontal: widget.padding),
        scrollDirection: Axis.horizontal,
        itemCount: widget.itemCount,
        separatorBuilder: (_, _) => SizedBox(width: widget.spacing),
        itemBuilder: (context, index) => SizedBox(
          width: widget.itemWidth,
          child: widget.itemBuilder(context, index),
        ),
      ),
    );
    if (!desktop) return SizedBox(height: widget.height, child: list);
    return SizedBox(
      height: widget.height,
      child: MouseRegion(
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        child: Stack(
          children: [
            // 列表首次排版后才知道能否右翻；尺寸变化时刷新箭头。
            Positioned.fill(
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (_) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() {});
                  });
                  return false;
                },
                child: list,
              ),
            ),
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final ready =
                    controller.hasClients &&
                    controller.position.hasContentDimensions;
                final back =
                    ready &&
                    controller.position.pixels >
                        controller.position.minScrollExtent + 1;
                final forward =
                    ready &&
                    controller.position.pixels <
                        controller.position.maxScrollExtent - 1;
                final top = widget.itemWidth / 2 - 18;
                return Stack(
                  children: [
                    Positioned(
                      left: 6,
                      top: top,
                      child: _Arrow(
                        visible: hover && back,
                        left: true,
                        onPressed: () => _page(-1),
                      ),
                    ),
                    Positioned(
                      right: 6,
                      top: top,
                      child: _Arrow(
                        visible: hover && forward,
                        left: false,
                        onPressed: () => _page(1),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({
    required this.visible,
    required this.left,
    required this.onPressed,
  });
  final bool visible, left;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: DymuseTokens.motion,
      child: Semantics(
        button: true,
        label: left ? '向左翻页' : '向右翻页',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onPressed,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: DymuseTokens.background(context).withValues(alpha: .86),
                border: Border.all(color: DymuseTokens.line(context)),
                boxShadow: const [
                  BoxShadow(color: Color(0x33000000), blurRadius: 10),
                ],
              ),
              child: Icon(
                left
                    ? CupertinoIcons.chevron_left
                    : CupertinoIcons.chevron_right,
                size: 16,
                color: DymuseTokens.ink(context),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
