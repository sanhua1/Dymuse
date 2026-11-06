import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import '../core/api_client.dart';
import '../core/artwork_image.dart';
import 'tokens.dart';

/// 底部 Tab 栏的玻璃参数（取自 liquid_glass_widgets 的 kBottomBarGlassDefaults）。
/// 迷你播放器用同一组参数，两者看起来才是同一种玻璃。
const kBarGlassSettings = glass.LiquidGlassSettings(
  thickness: 30,
  blur: 3,
  chromaticAberration: 0.3,
  lightIntensity: 0.6,
  refractiveIndex: 1.59,
  saturation: 0.7,
  ambientStrength: 1,
  lightAngle: 0.75 * 3.141592653589793,
  glassColor: Color(0x3DFFFFFF),
);

/// 第三方材质只从此处进入业务 UI；内容列表不创建玻璃层。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = 22,
    this.lightweight = false,
    this.settings,
  });
  final Widget child;

  /// 自定义玻璃参数（例如与底部 Tab 栏一致）；null 沿用全局主题。
  final glass.LiquidGlassSettings? settings;
  final EdgeInsets padding;
  final double radius;

  /// 页面里随切换反复创建的小控件（按钮、胶囊）用轻量玻璃：着色器已预载、首帧即完整，
  /// 不会先露出无外框的图标再补上玻璃。常驻的栏与播放器仍用完整管线。
  final bool lightweight;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final appearance = AppearanceScope.of(context);
    final solid = media.highContrast || appearance?.reduceTransparency == true;
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
    return glass.GlassContainer(
      quality: lightweight
          ? glass.GlassQuality.standard
          : DymuseTokens.glassQuality,
      shape: glass.LiquidRoundedSuperellipse(borderRadius: radius),
      useOwnLayer: true,
      settings: DymuseTokens.android
          ? androidGlassSettings(context)
          : DymuseTokens.frostLerp(
              settings,
              appearance?.glassFrost ?? 0,
              CupertinoTheme.brightnessOf(context),
            ),
      padding: padding,
      child: child,
    );
  }
}

/// Android 的玻璃：没有背后模糊（为了流畅），垫一层近乎不透明的底色保证可读。
/// 面板、迷你播放器和底部标签栏共用这一份，样式才一致。
glass.LiquidGlassSettings androidGlassSettings(BuildContext context) =>
    glass.LiquidGlassSettings(
      blur: 0,
      thickness: 18,
      glassColor: DymuseTokens.background(context).withValues(alpha: .96),
    );

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

  /// 把业务里的封面地址整理成可请求的地址与请求头（网易云换 HTTPS 和应用标识，
  /// 只向自己的服务发送令牌）；[pixels] 是需要的像素宽度，用来换缩略图。没有封面返回 null。
  static ({String url, Map<String, String> headers})? request(
    ApiClient api,
    String? url,
    double pixels,
  ) {
    if (url == null || url.trim().isEmpty) return null;
    var resolved = Uri.parse(api.server).resolve(url);
    final service = Uri.parse(api.server);
    final neteaseImage =
        resolved.host == 'music.126.net' ||
        resolved.host.endsWith('.music.126.net');
    // 网易云图片服务拒绝 Dart 默认 User-Agent，图片使用应用标识和 HTTPS。
    if (neteaseImage && resolved.scheme == 'http') {
      resolved = resolved.replace(scheme: 'https');
    }
    resolved = thumbnailAddress(resolved, pixels);
    // 只向同一服务发送令牌；远端专辑图片不能获得 Bearer。
    // 本机伪地址不是 http(s)，不能用 Uri.origin，按协议/主机/端口比较。
    final own =
        resolved.scheme == service.scheme &&
        resolved.host == service.host &&
        resolved.port == service.port;
    return (
      url: resolved.toString(),
      headers: {
        if (neteaseImage) 'User-Agent': 'Dymuse/0.1.0',
        if (own && api.token != null) 'Authorization': 'Bearer ${api.token}',
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = request(
      api,
      url,
      size * MediaQuery.devicePixelRatioOf(context),
    );
    return Artwork(
      url: image?.url,
      size: size,
      seed: seed,
      radius: radius,
      headers: image?.headers,
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
    this.compact = false,
    this.flat = false,
  });

  /// 设置页等面板内的小号胶囊（高 36）。
  final bool compact;

  /// 不用实时玻璃着色器，改画静态的玻璃质感（半透明底 + 高光描边）。
  /// 用于会滚动的长页面：每个实时玻璃按钮滚动时都要逐帧重绘。
  final bool flat;

  /// 语义标签；[text] 为空时也作为可见文字。
  final String label;
  final String? text;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool prominent, selected, busy;

  Widget _pillSurface(
    BuildContext context, {
    required double radius,
    required EdgeInsets padding,
    required Widget child,
  }) {
    if (!flat) {
      return GlassPanel(
        lightweight: true,
        radius: radius,
        padding: padding,
        child: child,
      );
    }
    final dark = DymuseTokens.dark(context);
    final base = dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            base.withValues(alpha: dark ? .18 : .09),
            base.withValues(alpha: dark ? .10 : .05),
          ],
        ),
        border: Border.all(
          color: const Color(0xFFFFFFFF).withValues(alpha: dark ? .22 : .7),
        ),
      ),
      child: Padding(padding: padding, child: child),
    );
  }

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
          child: _pillSurface(
            context,
            radius: compact ? 18 : 22,
            padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 20),
            child: SizedBox(
              height: compact ? 36 : 44,
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
                        fontSize: compact ? 14 : 16,
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

/// 设置面板里的按钮：Liquid Glass 平台用小号玻璃胶囊（轻量档，Android 同样省电），Windows 保持 ActionButton。
class PanelButton extends StatelessWidget {
  const PanelButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.prominent = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool prominent;
  @override
  Widget build(BuildContext context) => DymuseTokens.liquid
      ? GlassPillButton(
          label: label,
          icon: icon,
          prominent: prominent,
          compact: true,
          onPressed: onPressed,
        )
      : ActionButton(
          label: label,
          icon: icon,
          filled: prominent,
          onPressed: onPressed,
        );
}

/// 列表行里悬停时的播放/暂停图标，32×32 点击区域，无自身底板。
class GlassSquareButton extends StatelessWidget {
  const GlassSquareButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    onTap: onPressed,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Center(
          child: SizedBox(
            width: 32,
            height: 32,
            // 行本身已有悬停玻璃底，这里只留图标，避免内外两层玻璃。
            child: Center(
              child: Icon(icon, size: 16, color: DymuseTokens.ink(context)),
            ),
          ),
        ),
      ),
    ),
  );
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
    this.glassTrigger = false,
  });
  final GlassPopupController? controller;

  /// 触发控件本身是玻璃按钮时为 true：菜单从它“长”出来再融回去。
  /// 触发控件是普通图标或整行内容时为 false：菜单从触发点中心展开、收回，
  /// 不画一个凭空出现又消失的玻璃圆点（那就是收回时“闪一下”的来源）。
  final bool glassTrigger;
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

  /// 菜单打开期间（含收回动画）固定使用打开时的菜单项：
  /// 点选项会让页面状态变化并重建菜单，项目数、勾选一变，收回中的菜单就会跳变。
  List<GlassMenuEntry>? _frozen;

  void _freeze(List<GlassMenuEntry> entries) {
    if (_frozen != null) return;
    _frozen = entries;
    _thawWhenClosed();
  }

  void _thawWhenClosed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_controller.isOpen) {
        _thawWhenClosed();
      } else if (_frozen != null) {
        setState(() => _frozen = null);
      }
    });
  }

  @override
  void didUpdateWidget(GlassPopupMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从外部（控制器）打开的菜单，也在内容变化前固定住。
    if (_controller.isOpen) _freeze(oldWidget.entries);
  }

  void _open() {
    widget.onOpen?.call();
    _freeze(widget.entries);
    _controller.open();
  }

  @override
  Widget build(BuildContext context) => glass.GlassMenu(
    controller: _controller,
    // 手机沿用触控尺寸；桌面按 macOS 菜单的 13pt 字号与紧凑行高。
    menuWidth: DymuseTokens.mobile ? widget.width : widget.width * .85,
    morphFromZero: !widget.glassTrigger,
    autoAdjustToScreen: true,
    menuPadding: EdgeInsets.all(DymuseTokens.mobile ? 12 : 6),
    quality: DymuseTokens.glassQuality,
    items: [
      for (final entry in _frozen ?? widget.entries)
        glass.GlassMenuItem(
          title: entry.label,
          isDestructive: entry.destructive,
          height: DymuseTokens.mobile ? 44 : 36,
          iconSize: DymuseTokens.mobile ? 20 : 15,
          titleStyle: DymuseTokens.mobile
              ? null
              : const TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
          icon: entry.icon == null
              ? null
              : Icon(entry.icon, size: DymuseTokens.mobile ? 20 : 15),
          trailing: entry.checked
              ? Icon(
                  CupertinoIcons.checkmark,
                  size: DymuseTokens.mobile ? 16 : 13,
                )
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

/// 选择表：手机用系统动作表（整宽大字）；桌面窗口里是一张紧凑的居中小卡片，
/// 与其它界面的 13～14pt 字号一致。选择返回对应值，取消返回 null。
Future<T?> showChoiceSheet<T>(
  BuildContext context, {
  required String title,
  String? message,
  required List<(String, T)> choices,
  T? current,
}) => showCupertinoModalPopup<T>(
  context: context,
  builder: (sheet) {
    if (DymuseTokens.mobile) {
      return CupertinoActionSheet(
        title: Text(title),
        message: message == null ? null : Text(message),
        actions: [
          for (final (label, value) in choices)
            CupertinoActionSheetAction(
              isDefaultAction: value == current,
              onPressed: () => Navigator.pop(sheet, value),
              child: Text(label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          child: const Text('取消'),
        ),
      );
    }
    Widget row(String label, VoidCallback onTap, {bool selected = false}) =>
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SizedBox(
            width: double.infinity,
            child: CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              minimumSize: const Size.fromHeight(36),
              borderRadius: BorderRadius.circular(DymuseTokens.radius.control),
              color: DymuseTokens.ink(sheet).withValues(alpha: .1),
              pressedOpacity: .6,
              onPressed: onTap,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: selected
                      ? DymuseTokens.tint(sheet)
                      : DymuseTokens.ink(sheet),
                ),
              ),
            ),
          ),
        );
    return Center(
      child: Container(
        width: 320,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        decoration: BoxDecoration(
          color: DymuseTokens.surface(sheet),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: DymuseTokens.line(sheet)),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(fontSize: 13),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 2),
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: DymuseTokens.secondary(sheet),
                  ),
                ),
              ),
              if (message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    message,
                    style: TextStyle(
                      fontSize: 12,
                      color: DymuseTokens.secondary(sheet),
                    ),
                  ),
                ),
              for (final (label, value) in choices)
                row(
                  label,
                  () => Navigator.pop(sheet, value),
                  selected: value == current,
                ),
              row('取消', () => Navigator.pop(sheet)),
            ],
          ),
        ),
      ),
    );
  },
);

/// 播放条按钮：无底色方块，悬停加深图标、按下变淡；开启状态为强调色与浅圆底。
class BarButton extends StatefulWidget {
  const BarButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.size = 18,
    this.selected = false,
    this.loading = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final bool selected, loading;
  @override
  State<BarButton> createState() => BarButtonState();
}

class BarButtonState extends State<BarButton> {
  bool hover = false, pressed = false, focus = false;
  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final tint = DymuseTokens.tint(context);
    final ink = DymuseTokens.ink(context);
    final color = !enabled
        ? DymuseTokens.secondary(context).withValues(alpha: .45)
        : widget.selected
        ? tint
        : ink.withValues(alpha: hover ? 1 : .82);
    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.label,
      excludeSemantics: true,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: SystemMouseCursors.basic,
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
          child: Container(
            width: widget.size + 20,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.selected
                  ? tint.withValues(alpha: .14)
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: focus ? tint : const Color(0x00000000),
                width: 2,
              ),
            ),
            child: widget.loading
                ? const CupertinoActivityIndicator(radius: 8)
                : AnimatedOpacity(
                    opacity: pressed ? .45 : 1,
                    duration: const Duration(milliseconds: 80),
                    child: Icon(widget.icon, size: widget.size, color: color),
                  ),
          ),
        ),
      ),
    );
  }
}

/// 设置项右边的“i”按钮：点开用对话框显示这一项的详细说明。
class InfoButton extends StatelessWidget {
  const InfoButton({super.key, required this.title, required this.text});
  final String title, text;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$title 说明',
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showCupertinoDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialog) => CupertinoAlertDialog(
          title: Text(title),
          content: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(text, textAlign: TextAlign.start),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('好'),
            ),
          ],
        ),
      ),
      child: SizedBox(
        width: 36,
        height: 28,
        child: Center(
          child: Icon(
            CupertinoIcons.info_circle,
            size: 16,
            color: DymuseTokens.secondary(context),
          ),
        ),
      ),
    ),
  );
}
