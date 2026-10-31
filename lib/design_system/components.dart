import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import '../core/api_client.dart';
import '../core/artwork_image.dart';
import 'tokens.dart';

/// 第三方材质只从此处进入业务 UI；内容列表不创建玻璃层。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = 22,
    this.lightweight = false,
  });
  final Widget child;
  final EdgeInsets padding;
  final double radius;

  /// 页面里随切换反复创建的小控件（按钮、胶囊）用轻量玻璃：着色器已预载、首帧即完整，
  /// 不会先露出无外框的图标再补上玻璃。常驻的栏与播放器仍用完整管线。
  final bool lightweight;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final solid =
        media.highContrast ||
        AppearanceScope.of(context)?.reduceTransparency == true;
    if (solid) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: DymuseTokens.surface(context),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: DymuseTokens.line(context)),
        ),
        child: Padding(padding: padding, child: child),
      );
    }
    final panel = glass.GlassContainer(
      quality: lightweight
          ? glass.GlassQuality.standard
          : DymuseTokens.glassQuality,
      shape: glass.LiquidRoundedSuperellipse(borderRadius: radius),
      useOwnLayer: true,
      padding: padding,
      child: child,
    );
    // Android 没有背后模糊，下面的封面和文字会原样透上来；垫一层半透明底色保证可读。
    if (!DymuseTokens.android) return panel;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: DymuseTokens.background(context).withValues(alpha: .82),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: panel,
    );
  }
}

/// 统一键盘焦点、悬停及语义；桌面操作区保持 44 点目标。
class ActionButton extends StatefulWidget {
  const ActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.child,
    this.selected = false,
    this.filled = false,
    this.compact = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Widget? child;
  final bool selected, filled, compact;
  @override
  State<ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<ActionButton> {
  bool hover = false, focus = false;
  @override
  Widget build(BuildContext context) {
    final tint = DymuseTokens.tint(context);
    final foreground = widget.filled
        ? DymuseTokens.dark(context)
              ? const Color(0xFF2D1520)
              : CupertinoColors.white
        : widget.selected
        ? tint
        : DymuseTokens.ink(context);
    return Semantics(
      button: true,
      label: widget.label,
      enabled: widget.onPressed != null,
      selected: widget.selected,
      child: MouseRegion(
        cursor: widget.onPressed == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        child: FocusableActionDetector(
          enabled: widget.onPressed != null,
          onShowFocusHighlight: (value) => setState(() => focus = value),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPressed?.call();
                return null;
              },
            ),
          },
          child: DecoratedBox(
            decoration: BoxDecoration(
              // macOS 悬停/选中用中性浅底，不铺强调色；Windows 保持原样式。
              color: widget.filled
                  ? tint
                  : DymuseTokens.macOS
                  ? widget.selected
                        ? DymuseTokens.ink(context).withValues(alpha: .1)
                        : hover
                        ? DymuseTokens.ink(context).withValues(alpha: .06)
                        : const Color(0x00000000)
                  : widget.selected || hover
                  ? tint.withValues(alpha: .1)
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(DymuseTokens.radius.control),
              border: Border.all(
                color: focus ? tint : const Color(0x00000000),
                width: 2,
              ),
            ),
            child: CupertinoButton(
              padding: EdgeInsets.symmetric(
                horizontal: widget.compact ? 8 : 14,
                vertical: 8,
              ),
              minimumSize: const Size(44, 44),
              onPressed: widget.onPressed,
              child: IconTheme(
                data: IconThemeData(color: foreground, size: 19),
                child: DefaultTextStyle(
                  style: TextStyle(
                    color: foreground,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  child:
                      widget.child ??
                      (widget.icon != null
                          ? Icon(widget.icon)
                          : Text(widget.label)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    this.url,
    this.headers,
    this.size = 52,
    this.seed = '',
    this.radius = 10,
  });
  final String? url;
  final Map<String, String>? headers;
  final double size, radius;
  final String seed;
  @override
  Widget build(BuildContext context) {
    final hash = seed.codeUnits.fold(0, (a, b) => a + b);
    final colors = [
      const Color(0xFFA47D94),
      const Color(0xFF617883),
      const Color(0xFF827CA5),
      const Color(0xFFAC876E),
    ];
    final base = colors[hash % colors.length];
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            base.withValues(alpha: .7),
            base,
            Color.lerp(base, const Color(0xFF252131), .65)!,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          CupertinoIcons.music_note_2,
          size: size * .3,
          color: const Color(0xCCFFFFFF),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: url == null
            ? placeholder
            : Image(
                image: ResizeImage.resizeIfNeeded(
                  (size * MediaQuery.devicePixelRatioOf(context)).round().clamp(
                    1,
                    1600,
                  ),
                  null,
                  ArtworkImage(url!, headers: headers ?? const {}),
                ),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Semantics(label: '封面加载失败，可刷新页面重试', child: placeholder),
                frameBuilder: (_, child, frame, _) =>
                    frame == null ? placeholder : child,
              ),
      ),
    );
  }
}

class RemoteArtwork extends StatelessWidget {
  const RemoteArtwork({
    super.key,
    required this.api,
    this.url,
    this.size = 52,
    this.seed = '',
    this.radius = 10,
  });
  final ApiClient api;
  final String? url;
  final double size, radius;
  final String seed;
  @override
  Widget build(BuildContext context) {
    var resolved = url == null || url!.trim().isEmpty
        ? null
        : Uri.parse(api.server).resolve(url!);
    final service = Uri.parse(api.server);
    final neteaseImage =
        resolved != null &&
        (resolved.host == 'music.126.net' ||
            resolved.host.endsWith('.music.126.net'));
    // 网易云图片服务拒绝 Dart 默认 User-Agent，图片使用应用标识和 HTTPS。
    if (neteaseImage && resolved.scheme == 'http') {
      resolved = resolved.replace(scheme: 'https');
    }
    if (resolved != null) {
      resolved = thumbnailAddress(
        resolved,
        size * MediaQuery.devicePixelRatioOf(context),
      );
    }
    // 只向同一服务发送令牌；远端专辑图片不能获得 Bearer。
    // 本机伪地址不是 http(s)，不能用 Uri.origin，按协议/主机/端口比较。
    final own =
        resolved != null &&
        resolved.scheme == service.scheme &&
        resolved.host == service.host &&
        resolved.port == service.port;
    return Artwork(
      url: resolved?.toString(),
      size: size,
      seed: seed,
      radius: radius,
      headers: {
        if (neteaseImage) 'User-Agent': 'Dymuse/0.1.0',
        if (own && api.token != null) 'Authorization': 'Bearer ${api.token}',
      },
    );
  }
}

/// 保留 Cupertino 拖动与读屏操作，补充整条轨道的点击跳转。
class SeekSlider extends StatelessWidget {
  const SeekSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });
  final double value;
  final ValueChanged<double>? onChanged, onChangeStart, onChangeEnd;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTapUp: onChanged == null
          ? null
          : (details) {
              // Flutter 3.41 的滑块圆心距两端 22 点，与拖动范围保持一致。
              const inset = 22.0;
              final extent = constraints.maxWidth - inset * 2;
              if (extent <= 0) return;
              var next = ((details.localPosition.dx - inset) / extent).clamp(
                0.0,
                1.0,
              );
              if (Directionality.of(context) == TextDirection.rtl) {
                next = 1 - next;
              }
              onChangeStart?.call(value);
              onChanged!(next);
              onChangeEnd?.call(next);
            },
      child: SizedBox(
        height: 44,
        child: CupertinoSlider(
          value: value,
          onChanged: onChanged,
          onChangeStart: onChangeStart,
          onChangeEnd: onChangeEnd,
        ),
      ),
    ),
  );
}

class StatusMessage extends StatelessWidget {
  const StatusMessage({
    super.key,
    required this.title,
    required this.message,
    this.icon = CupertinoIcons.music_note_list,
    this.action,
  });
  final String title, message;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: DymuseTokens.secondary(context)),
          const SizedBox(height: 20),
          Text(title, style: DymuseTokens.title, textAlign: TextAlign.center),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 390),
            child: Text(
              message,
              style: DymuseTokens.body.copyWith(
                color: DymuseTokens.secondary(context),
              ),
              textAlign: TextAlign.center,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    ),
  );
}

String timeLabel(Duration value) {
  final seconds = value.inSeconds.clamp(0, 604800);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// Liquid Glass 胶囊按钮（Apple 平台的页面级操作）：玻璃胶囊 + 图标与文字。
/// [prominent] 为强调色（如“播放”），否则为墨色；[selected] 用强调色表示已选/已开启。
/// Windows 仍使用 ActionButton。
class GlassPillButton extends StatelessWidget {
  const GlassPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.text,
    this.prominent = false,
    this.selected = false,
    this.busy = false,
  });

  /// 语义标签；[text] 为空时也作为可见文字。
  final String label;
  final String? text;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool prominent, selected, busy;
  @override
  Widget build(BuildContext context) {
    final color = prominent || selected
        ? DymuseTokens.tint(context)
        : DymuseTokens.ink(context);
    final enabled = onPressed != null && !busy;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: enabled ? onPressed : null,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size(44, 44),
        onPressed: enabled ? onPressed : null,
        child: Opacity(
          opacity: onPressed == null && !busy ? .45 : 1,
          child: GlassPanel(
            lightweight: true,
            radius: 22,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SizedBox(
              height: 44,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy)
                    const CupertinoActivityIndicator(radius: 8)
                  else if (icon != null)
                    Icon(icon, size: 16, color: color),
                  if ((busy || icon != null) && text != '')
                    const SizedBox(width: 8),
                  if (text != '')
                    Text(
                      text ?? label,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
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

/// 页面主“播放”按钮的 Liquid Glass 版本（对应 Apple Music 的“播放”按钮）。
class GlassPlayButton extends StatelessWidget {
  const GlassPlayButton({super.key, required this.onPressed});
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => GlassPillButton(
    label: '播放',
    icon: CupertinoIcons.play_fill,
    prominent: true,
    onPressed: onPressed,
  );
}

/// 横向滚动的分段选择（现在就听的“推荐/私人 FM/排行榜/歌单广场”等）：
/// 选中项为实心胶囊，其余为玻璃胶囊；整行可横向滚动，滚出页边距到屏幕边缘，不裁切文字。
class GlassChoiceRow<T> extends StatelessWidget {
  const GlassChoiceRow({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelect,
  });
  final List<T> values;
  final T selected;
  final String Function(T value) labelOf;
  final ValueChanged<T> onSelect;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    clipBehavior: Clip.none,
    child: Row(
      children: [
        for (final value in values) ...[
          _Choice(
            label: labelOf(value),
            selected: value == selected,
            onPressed: () => onSelect(value),
          ),
          if (value != values.last) const SizedBox(width: 8),
        ],
      ],
    ),
  );
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onPressed,
  });
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: selected
            ? (DymuseTokens.dark(context)
                  ? const Color(0xFF1B1A1E)
                  : const Color(0xFFFFFFFF))
            : DymuseTokens.ink(context),
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size(44, 44),
        onPressed: onPressed,
        child: selected
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: DymuseTokens.ink(context),
                  borderRadius: BorderRadius.circular(19),
                ),
                child: SizedBox(
                  height: 38,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Center(widthFactor: 1, child: text),
                  ),
                ),
              )
            : GlassPanel(
                lightweight: true,
                radius: 19,
                child: SizedBox(
                  height: 38,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Center(widthFactor: 1, child: text),
                  ),
                ),
              ),
      ),
    );
  }
}

/// 外部（如右键）打开菜单用的控制器。
typedef GlassPopupController = glass.GlassMenuController;

/// 玻璃菜单里的一项。
class GlassMenuEntry {
  const GlassMenuEntry(
    this.label,
    this.onTap, {
    this.icon,
    this.destructive = false,
    this.checked = false,
  });
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool destructive, checked;
}

/// 液态玻璃弹出菜单（iOS 26 风格）：从触发控件处“长”出来，不再从屏幕底部弹出。
/// - 轻点触发控件：菜单展开，再点选项。
/// - 长按触发控件：菜单展开后不要抬手，滑到目标项上松开即选中；松开时不在任何项上，菜单保持打开。
/// [builder] 返回触发控件；其中的点击请用传入的 `open`（需要自己处理点击时，如列表行，可不调用它）。
class GlassPopupMenu extends StatefulWidget {
  const GlassPopupMenu({
    super.key,
    required this.builder,
    required this.entries,
    this.width = 200,
    this.onOpen,
    this.controller,
  });
  final GlassPopupController? controller;
  final Widget Function(BuildContext context, VoidCallback open) builder;
  final List<GlassMenuEntry> entries;
  final double width;

  /// 菜单打开前的回调（例如顺手加载喜欢状态）。
  final VoidCallback? onOpen;
  @override
  State<GlassPopupMenu> createState() => _GlassPopupMenuState();
}

class _GlassPopupMenuState extends State<GlassPopupMenu> {
  late final _own = glass.GlassMenuController();
  glass.GlassMenuController get _controller => widget.controller ?? _own;

  void _open() {
    widget.onOpen?.call();
    _controller.open();
  }

  @override
  Widget build(BuildContext context) => glass.GlassMenu(
    controller: _controller,
    menuWidth: widget.width,
    autoAdjustToScreen: true,
    menuPadding: const EdgeInsets.all(12),
    quality: DymuseTokens.glassQuality,
    items: [
      for (final entry in widget.entries)
        glass.GlassMenuItem(
          title: entry.label,
          isDestructive: entry.destructive,
          icon: entry.icon == null ? null : Icon(entry.icon, size: 20),
          trailing: entry.checked
              ? const Icon(CupertinoIcons.checkmark, size: 16)
              : null,
          onTap: entry.onTap,
        ),
    ],
    triggerBuilder: (context, toggle) => GestureDetector(
      behavior: HitTestBehavior.translucent,
      // 桌面：右键直接打开菜单。
      onSecondaryTap: _open,
      onLongPressStart: (_) {
        HapticFeedback.mediumImpact();
        _open();
      },
      onLongPressMoveUpdate: (details) =>
          _controller.glideTo(details.globalPosition),
      onLongPressEnd: (_) => _controller.endGlide(),
      onLongPressCancel: _controller.cancelGlide,
      child: widget.builder(context, _open),
    ),
  );
}

/// 表单面板：手机上从底部整宽弹出；桌面窗口里限制宽度并居中，键盘出现时整体上移。
Future<T?> showFormSheet<T>(
  BuildContext context,
  Widget form,
) => showCupertinoModalPopup<T>(
  context: context,
  builder: (sheet) {
    final wide = MediaQuery.sizeOf(sheet).width > 700;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheet).bottom),
      child: Align(
        alignment: wide ? Alignment.center : Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: wide
              ? ClipRRect(borderRadius: BorderRadius.circular(18), child: form)
              : form,
        ),
      ),
    );
  },
);
