import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;

/// 语义 Token；各平台使用系统字体，不分发 Apple 字体。
abstract final class DymuseTokens {
  /// Windows 复用桌面视觉，窗口和键盘操作仍由本机处理。
  static bool get windows => defaultTargetPlatform == TargetPlatform.windows;

  /// macOS 保留原生标题栏、窗口按钮和菜单；判断与测试宿主无关。
  static bool get macOS => defaultTargetPlatform == TargetPlatform.macOS;

  /// iPhone/iPad 使用独立的移动导航（Tab、迷你播放器、全屏播放页）。
  static bool get iOS => defaultTargetPlatform == TargetPlatform.iOS;

  /// Android 手机与 iPhone 共用移动导航，界面风格也沿用 iOS 的 Liquid Glass。
  static bool get android => defaultTargetPlatform == TargetPlatform.android;

  /// 手机：使用独立的移动导航，不创建桌面窗口。
  static bool get mobile => iOS || android;

  /// Apple 平台共用系统字体与完整玻璃管线。
  static bool get apple => macOS || iOS;

  /// 受支持平台共用玻璃组件，渲染质量由各平台单独选择。
  static bool get liquid => apple || android || windows;

  /// Apple 的 Impeller(Metal) 使用完整玻璃管线；Windows 与 Android 用轻量着色器
  /// （Android 上完整管线每块玻璃都做实时折射，实测明显卡顿）。
  static glass.GlassQuality get glassQuality =>
      apple ? glass.GlassQuality.premium : glass.GlassQuality.standard;

  /// Apple 与 Android 交给系统字体（SF/苹方、Roboto），Windows 指定 Segoe UI。
  static String? get fontFamily => apple || android ? null : 'Segoe UI';

  /// 磨砂一端的底色（随明暗）。
  static Color frostTint(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xB81C1C20)
      : const Color(0xBFF4F4F8);

  /// 把一份玻璃参数向磨砂方向推 [t]（0 不变，1 完全磨砂）；t 为 0 时原样返回。
  static glass.LiquidGlassSettings? frostLerp(
    glass.LiquidGlassSettings? base,
    double t,
    Brightness brightness,
  ) {
    if (base == null || t <= 0) return base;
    double mix(double a, double b) => a + (b - a) * t;
    return glass.LiquidGlassSettings(
      thickness: mix(base.thickness, 6),
      blur: mix(base.blur, 26),
      chromaticAberration: mix(base.chromaticAberration, 0),
      lightIntensity: mix(base.lightIntensity, .3),
      refractiveIndex: mix(base.refractiveIndex, 1.1),
      saturation: mix(base.saturation, 1),
      ambientStrength: mix(base.ambientStrength, .8),
      lightAngle: base.lightAngle,
      glassColor: Color.lerp(base.glassColor, frostTint(brightness), t)!,
    );
  }

  /// 全局玻璃主题：t 为 0 时就是原来的样子；越大越接近磨砂。
  static glass.GlassThemeData glassTheme(
    Brightness brightness,
    double t, {
    bool noBlur = false,
  }) {
    double mix(double a, double b) => a + (b - a) * t;
    final theme = glass.GlassThemeData.simple(
      quality: glassQuality,
      brightness: brightness,
      blur: noBlur ? 0 : mix(12, 26),
      thickness: mix(18, 6),
      chromaticAberration: t > 0 ? mix(.01, 0) : null,
      lightIntensity: t > 0 ? mix(.5, .3) : null,
      refractiveIndex: t > 0 ? mix(1.2, 1.1) : null,
    );
    if (t <= 0 || noBlur) return theme;
    glass.GlassThemeVariant tint(glass.GlassThemeVariant v, Brightness b) =>
        v.copyWith(
          settings: v.settings?.copyWith(
            glassColor: Color.lerp(const Color(0x00FFFFFF), frostTint(b), t),
          ),
        );
    return glass.GlassThemeData(
      light: tint(theme.light, Brightness.light),
      dark: tint(theme.dark, Brightness.dark),
      interaction: theme.interaction,
      brightness: brightness,
    );
  }

  /// 默认主题色（玫红）；用户可在设置里换成 [AccentColor] 中的其他颜色。
  static const accent = Color(0xFFB83258);
  static const accentDark = Color(0xFFFF91AE);
  static const spacing = (
    xs: 4.0,
    sm: 8.0,
    md: 12.0,
    lg: 16.0,
    xl: 24.0,
    page: 32.0,
  );
  static const radius = (control: 12.0, panel: 22.0, artwork: 10.0);
  static const motion = Duration(milliseconds: 220);
  static const sidebar = 220.0;
  static const wideBreakpoint = 1080.0;
  static const compactBreakpoint = 860.0;
  static const minWindow = Size(720, 600);
  static const initialWindow = Size(1240, 820);
  static List<String> get fontFallback => apple
      ? const ['PingFang SC']
      : android
      ? const ['Noto Sans CJK SC', 'Noto Sans SC']
      : const ['Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI'];
  static const macSidebar = 232.0;
  static const heading = TextStyle(
    fontSize: 30,
    fontWeight: FontWeight.w700,
    letterSpacing: -.8,
  );
  static const title = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    letterSpacing: -.4,
  );
  static const body = TextStyle(fontSize: 14, height: 1.4);
  static const caption = TextStyle(fontSize: 12, height: 1.35);

  static bool dark(BuildContext context) =>
      CupertinoTheme.brightnessOf(context) == Brightness.dark;
  static Color ink(BuildContext context) =>
      dark(context) ? const Color(0xFFF3F1F5) : const Color(0xFF26242B);
  static Color secondary(BuildContext context) =>
      dark(context) ? const Color(0xFFB0ABB7) : const Color(0xFF6C6773);
  static Color background(BuildContext context) =>
      dark(context) ? const Color(0xFF18171B) : const Color(0xFFFBFAFC);
  static Color surface(BuildContext context) =>
      dark(context) ? const Color(0xFF26242B) : const Color(0xFFF1EFF4);
  static Color line(BuildContext context) =>
      dark(context) ? const Color(0xFF3B3742) : const Color(0xFFE4E1E8);

  /// 当前主题色。读 CupertinoTheme 的亮暗已建立依赖，换色时 CupertinoApp 的主题随之
  /// 变化，调用处会重建，所以这里读设置不再单独登记依赖。
  static Color tint(BuildContext context) {
    final appearance = context
        .getInheritedWidgetOfExactType<AppearanceScope>()
        ?.notifier;
    if (appearance == null) {
      return dark(context) ? AccentColor.rose.dark : AccentColor.rose.light;
    }
    return dark(context) ? appearance.accentDark : appearance.accentLight;
  }
}

/// 可选主题色：浅色模式用较深的颜色保证文字对比度，深色模式用较亮的颜色。
enum AccentColor {
  rose('玫红', DymuseTokens.accent, DymuseTokens.accentDark),
  red('红色', Color(0xFFC62828), Color(0xFFFF8A80)),
  orange('橙色', Color(0xFFB85A0F), Color(0xFFFFB067)),
  green('绿色', Color(0xFF237A3B), Color(0xFF6FD98C)),
  teal('青色', Color(0xFF0F7480), Color(0xFF5ED3DE)),
  blue('蓝色', Color(0xFF1F63C6), Color(0xFF7AB4FF)),
  indigo('靛蓝', Color(0xFF4A44C2), Color(0xFFA29DFF)),
  purple('紫色', Color(0xFF8136B8), Color(0xFFD29BFF));

  const AccentColor(this.label, this.light, this.dark);
  final String label;
  final Color light, dark;
}

/// 可访问性选项独立于高对比度，不能依赖包把它们混作一项。
class Appearance extends ChangeNotifier {
  Appearance({
    this.brightness,
    this.reduceTransparency = false,
    this.reduceMotion = false,
    this.accent = AccentColor.rose,
  });
  Brightness? brightness;
  bool reduceTransparency, reduceMotion;
  AccentColor accent;

  /// 玻璃质感：0 是最强的液态玻璃（折射、高光），1 是磨砂（强模糊、较实的底色）；
  /// 每台设备自己的设置。
  double glassFrost = 0;

  void setGlassFrost(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if (glassFrost == clamped) return;
    glassFrost = clamped;
    notifyListeners();
  }

  /// 播放页背景的色块是否在播放时缓慢漂移（每台设备自己的设置）。
  bool backdropDrift = true;

  void setBackdropDrift(bool value) {
    if (backdropDrift == value) return;
    backdropDrift = value;
    notifyListeners();
  }

  /// 手机迷你播放器里是否显示进度条（每台设备自己的设置）。
  bool miniProgress = true;

  /// 主页实际采用的值：设置里改动后，等设置页关闭回到主页时才生效，
  /// 这样小播放器的变化是在眼前发生的过渡动画，而不是在被盖住时悄悄完成。
  late bool miniProgressShown = miniProgress;

  void setMiniProgress(bool value) {
    if (miniProgress == value) return;
    miniProgress = value;
    notifyListeners();
  }

  void commitMiniProgress() {
    if (miniProgressShown == miniProgress) return;
    miniProgressShown = miniProgress;
    notifyListeners();
  }

  /// 用户手动选的主题色；不为空时优先于 [accent]。
  Color? custom;

  /// 浅色模式要用较深的颜色保证文字对比度，深色模式用较亮的颜色；
  /// 手动选的颜色在不改色相的前提下把明度调进合适范围。
  Color get accentLight =>
      custom == null ? accent.light : _tone(custom!, min: .26, max: .44);
  Color get accentDark =>
      custom == null ? accent.dark : _tone(custom!, min: .66, max: .8);

  static Color _tone(Color color, {required double min, required double max}) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness(hsl.lightness.clamp(min, max))
        .withSaturation(hsl.saturation.clamp(.3, .95))
        .toColor();
  }

  /// 保存与同步用的文字：预设写名字，手动颜色写 #RRGGBB。
  String get accentValue => custom == null
      ? accent.name
      : '#${(custom!.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// 读回 [accentValue]；认不出时返回 null。
  static ({AccentColor? preset, Color? custom})? parseAccent(String? text) {
    if (text == null || text.isEmpty) return null;
    final hex = RegExp(r'^#([0-9A-Fa-f]{6})$').firstMatch(text);
    if (hex != null) {
      return (
        preset: null,
        custom: Color(0xFF000000 | int.parse(hex.group(1)!, radix: 16)),
      );
    }
    for (final color in AccentColor.values) {
      if (color.name == text) return (preset: color, custom: null);
    }
    return null;
  }

  /// 套用 [accentValue] 读回的结果。
  void applyAccent(String? text) {
    final parsed = parseAccent(text);
    if (parsed == null) return;
    custom = parsed.custom;
    if (parsed.preset != null) accent = parsed.preset!;
    notifyListeners();
  }

  void update({
    Brightness? brightness,
    bool system = false,
    bool? transparency,
    bool? motion,
    AccentColor? accent,
    Color? custom,
  }) {
    // 选了预设就取消手动颜色；选了手动颜色则覆盖预设。
    if (accent != null) this.custom = null;
    if (custom != null) this.custom = custom;
    this.accent = accent ?? this.accent;
    if (system) {
      this.brightness = null;
    } else if (brightness != null) {
      this.brightness = brightness;
    }
    reduceTransparency = transparency ?? reduceTransparency;
    reduceMotion = motion ?? reduceMotion;
    notifyListeners();
  }
}

class AppearanceScope extends InheritedNotifier<Appearance> {
  const AppearanceScope({
    super.key,
    required Appearance appearance,
    required super.child,
  }) : super(notifier: appearance);
  static Appearance? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}
