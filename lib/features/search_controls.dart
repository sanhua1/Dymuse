import 'package:flutter/cupertino.dart';
import '../core/api_client.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';
import 'catalog.dart';

/// 编辑器与玻璃背景分层，光标重绘不进入玻璃内容子树。
class DymuseSearchField extends StatelessWidget {
  const DymuseSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.placeholder,
    required this.onSearch,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final String placeholder;
  final ValueChanged<String> onSearch;

  void submit(String text) {
    if (!controller.value.composing.isCollapsed) return;
    onSearch(text.trim());
  }

  @override
  Widget build(BuildContext context) {
    // Liquid Glass 搜索：胶囊形输入框 + 等高圆形玻璃搜索按钮。
    // macOS 侧栏用紧凑高度；Windows 保持 44 点触控目标。
    final height = DymuseTokens.macOS ? 36.0 : 44.0;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: GlassPanel(
                      radius: height / 2,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                Center(
                  child: RepaintBoundary(
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: controller,
                      builder: (_, value, _) => CupertinoSearchTextField(
                        key: const ValueKey('dymuse-search-input'),
                        controller: controller,
                        focusNode: focusNode,
                        placeholder: placeholder,
                        // Windows 首字出现清除按钮会重排语义树，保持节点稳定以免失去输入焦点。
                        suffixMode: OverlayVisibilityMode.always,
                        suffixIcon: Icon(
                          CupertinoIcons.xmark_circle_fill,
                          semanticLabel: '清除搜索',
                          color: value.text.isEmpty
                              ? const Color(0x00000000)
                              : null,
                        ),
                        onSubmitted: submit,
                        onSuffixTap: () {
                          controller.clear();
                          onSearch('');
                          focusNode.requestFocus();
                        },
                        backgroundColor: const Color(0x00000000),
                        borderRadius: BorderRadius.circular(height / 2),
                        prefixInsets: const EdgeInsetsDirectional.fromSTEB(
                          12,
                          0,
                          0,
                          0,
                        ),
                        suffixInsets: const EdgeInsetsDirectional.fromSTEB(
                          0,
                          0,
                          8,
                          0,
                        ),
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          6,
                          0,
                          6,
                          0,
                        ),
                        style: TextStyle(
                          fontSize: 13,
                          color: DymuseTokens.ink(context),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _GlassCircleButton(
            size: height,
            label: '搜索',
            icon: CupertinoIcons.search,
            onPressed: () => submit(controller.text),
          ),
        ],
      ),
    );
  }
}

/// 圆形玻璃按钮：与搜索胶囊同一材质；悬停提亮、按下变淡，键盘焦点显示描边。
class _GlassCircleButton extends StatefulWidget {
  const _GlassCircleButton({
    required this.size,
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final double size;
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  @override
  State<_GlassCircleButton> createState() => _GlassCircleButtonState();
}

class _GlassCircleButtonState extends State<_GlassCircleButton> {
  bool hover = false, pressed = false, focus = false;
  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (value) => setState(() => hover = value),
        onShowFocusHighlight: (value) => setState(() => focus = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => pressed = true),
          onTapCancel: () => setState(() => pressed = false),
          onTapUp: (_) => setState(() => pressed = false),
          onTap: widget.onPressed,
          child: SizedBox.square(
            dimension: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: GlassPanel(
                      radius: size / 2,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                if (hover || focus)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: DymuseTokens.ink(
                          context,
                        ).withValues(alpha: hover ? .06 : 0),
                        border: focus
                            ? Border.all(
                                color: DymuseTokens.tint(context),
                                width: 2,
                              )
                            : null,
                      ),
                    ),
                  ),
                AnimatedOpacity(
                  opacity: pressed ? .45 : 1,
                  duration: const Duration(milliseconds: 80),
                  child: Icon(
                    widget.icon,
                    size: size * .45,
                    color: DymuseTokens.ink(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 搜索范围横向滚动，窄窗口和大文字不挤压标签。
class SearchScopes extends StatelessWidget {
  const SearchScopes({
    super.key,
    required this.selected,
    required this.onSelect,
  });
  final SearchCategory selected;
  final ValueChanged<SearchCategory> onSelect;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: DymuseTokens.apple
        ? GlassChoiceRow<SearchCategory>(
            values: SearchCategory.values,
            selected: selected,
            labelOf: (kind) => kind.label,
            onSelect: (value) {
              if (value != selected) onSelect(value);
            },
          )
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: CupertinoSlidingSegmentedControl<SearchCategory>(
              groupValue: selected,
              children: {
                for (final kind in SearchCategory.values)
                  kind: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Text(kind.label),
                  ),
              },
              onValueChanged: (value) {
                if (value != null && value != selected) onSelect(value);
              },
            ),
          ),
  );
}

/// 详情页共享整歌单收藏；状态写入确认后更新，失败保留可重试入口。
class PlaylistSubscriptionButton extends StatelessWidget {
  const PlaylistSubscriptionButton({
    super.key,
    required this.catalog,
    required this.collection,
  });
  final Catalog catalog;
  final Collection collection;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: catalog,
    builder: (_, _) {
      final active = catalog.subscribed(collection),
          busy = catalog.subscriptionBusy(collection);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Builder(
          builder: (context) {
            final toggle = busy
                ? null
                : () async {
                    try {
                      await catalog.changeSubscription(collection);
                    } catch (error) {
                      if (!context.mounted) return;
                      await showCupertinoDialog<void>(
                        context: context,
                        builder: (context) => CupertinoAlertDialog(
                          title: const Text('收藏未完成'),
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
                  };
            return DymuseTokens.apple
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: GlassPillButton(
                      label: active ? '取消收藏歌单' : '收藏歌单',
                      text: active ? '已收藏' : '收藏歌单',
                      icon: active
                          ? CupertinoIcons.check_mark_circled_solid
                          : CupertinoIcons.plus_circle,
                      selected: active,
                      busy: busy,
                      onPressed: toggle,
                    ),
                  )
                : ActionButton(
                    label: active ? '取消收藏歌单' : '收藏歌单',
                    selected: active,
                    icon: active
                        ? CupertinoIcons.check_mark_circled_solid
                        : CupertinoIcons.plus_circle,
                    onPressed: toggle,
                    child: busy
                        ? const CupertinoActivityIndicator()
                        : Text(active ? '已收藏' : '收藏歌单'),
                  );
          },
        ),
      );
    },
  );
}
