import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import 'package:window_manager/window_manager.dart';
import '../core/session.dart';
import '../design_system/tokens.dart';
import '../features/catalog.dart';
import '../platform/desktop_window.dart';
import '../playback/playback_controller.dart';
import '../playback/playback_checkpoints.dart';
import 'login_page.dart';
import 'netease_login.dart';
import '../update/update_dialog.dart';
import '../update/update_service.dart';
import 'mac_shell.dart';
import 'mobile_shell.dart';

class DymuseApp extends StatefulWidget {
  const DymuseApp({
    super.key,
    required this.session,
    required this.catalog,
    required this.playback,
    required this.appearance,
    required this.window,
    this.update,
  });
  final UpdateService? update;
  final Session session;
  final Catalog catalog;
  final PlaybackController playback;
  final Appearance appearance;
  final DesktopWindow window;
  @override
  State<DymuseApp> createState() => _DymuseAppState();
}

class _DymuseAppState extends State<DymuseApp> with WidgetsBindingObserver {
  String? activeUser;
  final _navigatorKey = GlobalKey<NavigatorState>();
  @override
  void initState() {
    super.initState();
    widget.session.loginPresenter = _presentLogin;
    unawaited(_startupUpdateCheck());
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(sessionChanged);
    widget.appearance.addListener(saveAppearance);
    unawaited(widget.window.setAppearance(widget.appearance.brightness));
    widget.playback.checkpoints = PlaybackCheckpoints(
      widget.session.preferences,
      scope: () => widget.session.user == null
          ? null
          : jsonEncode([
              widget.session.api.server,
              widget.session.user!['id'],
              widget.session.deviceId,
            ]),
    );
    widget.playback.listening
      ..preferences = widget.session.preferences
      ..scope = () => widget.session.user == null
          ? null
          : jsonEncode([
              widget.session.api.server,
              widget.session.user!['id'],
              widget.session.deviceId,
            ]);
    widget.window.beforeClose = () => widget.playback.shutdown().timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
  }

  /// 启动后等会话恢复完、界面稳定，再静默检查一次更新。
  Future<void> _startupUpdateCheck() async {
    final update = widget.update;
    if (update == null) return;
    await Future<void>.delayed(const Duration(seconds: 4));
    while (widget.session.restoring) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
    }
    final navigator = _navigatorKey.currentState;
    if (!mounted || navigator == null) return;
    await checkForUpdates(navigator, update);
  }

  void _presentLogin() {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    unawaited(showNeteaseLogin(navigator, widget.session));
  }

  void sessionChanged() {
    final user = widget.session.mustChangePassword || widget.session.firstLogin
        ? null
        : widget.session.user?['id']?.toString();
    if (user == activeUser) return;
    activeUser = user;
    widget.catalog.reset();
    if (user == null) {
      unawaited(widget.playback.reset());
    } else {
      unawaited(widget.playback.restore());
    }
  }

  void saveAppearance() {
    final prefs = widget.session.preferences, appearance = widget.appearance;
    unawaited(
      prefs.setString('appearance', appearance.brightness?.name ?? 'system'),
    );
    unawaited(
      prefs.setBool('reduceTransparency', appearance.reduceTransparency),
    );
    unawaited(prefs.setBool('reduceMotion', appearance.reduceMotion));
    unawaited(prefs.setString('accent', appearance.accentValue));
    unawaited(widget.window.setAppearance(appearance.brightness));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(sessionChanged);
    if (widget.session.loginPresenter == _presentLogin) {
      widget.session.loginPresenter = null;
    }
    widget.appearance.removeListener(saveAppearance);
    super.dispose();
  }

  /// 回到前台时拉取其他设备的改动；退到后台前把本机的改动推上去。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final sync = widget.session.sync;
    if (sync == null || !sync.configured) return;
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(sync.sync());
    }
  }

  @override
  void didChangePlatformBrightness() {
    if (widget.appearance.brightness == null) setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.session, widget.appearance]),
    builder: (_, _) {
      final appearance = widget.appearance;
      final brightness =
          appearance.brightness ??
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      return AppearanceScope(
        appearance: appearance,
        child: CupertinoApp(
          navigatorKey: _navigatorKey,
          title: 'Dymuse',
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: GlobalCupertinoLocalizations.delegates,
          theme: CupertinoThemeData(
            brightness: brightness,
            primaryColor: brightness == Brightness.dark
                ? appearance.accentDark
                : appearance.accentLight,
            textTheme: CupertinoTextThemeData(
              textStyle: TextStyle(
                color: brightness == Brightness.dark
                    ? const Color(0xFFF3F1F5)
                    : const Color(0xFF26242B),
                fontSize: 14,
                fontFamily: DymuseTokens.fontFamily,
                fontFamilyFallback: DymuseTokens.fontFallback,
              ),
            ),
          ),
          builder: (context, child) {
            final media = MediaQuery.of(context);
            final effective = CupertinoTheme.brightnessOf(context);
            final app = MediaQuery(
              data: media.copyWith(
                // 系统字体放得再大，也最多按 1.6 倍显示，布局不至于崩坏。
                textScaler: media.textScaler.clamp(
                  minScaleFactor: 1,
                  maxScaleFactor: 1.6,
                ),
                disableAnimations:
                    media.disableAnimations || appearance.reduceMotion,
              ),
              child: glass.LiquidGlassWidgets.wrap(
                theme: glass.GlassThemeData.simple(
                  quality: DymuseTokens.glassQuality,
                  brightness: effective,
                  // Android 上任何背后模糊都要每帧抓取并重绘背景，实测使
                  // 120Hz 下约一半的帧超时；关掉后玻璃只保留底色、描边与高光。
                  blur: DymuseTokens.android ? 0 : 12,
                  thickness: 18,
                ),
                // Apple 平台由系统负责缩放和边框；macOS 背景留给原生侧栏材质。
                child: DymuseTokens.mobile || DymuseTokens.macOS
                    ? child!
                    : DragToResizeArea(
                        resizeEdgeSize: 5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: DymuseTokens.surface(context),
                            border: Border.all(
                              color: DymuseTokens.line(context),
                            ),
                          ),
                          child: child!,
                        ),
                      ),
              ),
            );
            // Android 系统栏透明、图标随主题明暗，内容延伸到状态栏与手势条下方。
            if (!DymuseTokens.android) return app;
            final dark = effective == Brightness.dark;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                statusBarColor: const Color(0x00000000),
                systemNavigationBarColor: const Color(0x00000000),
                systemNavigationBarContrastEnforced: false,
                statusBarIconBrightness: dark
                    ? Brightness.light
                    : Brightness.dark,
                systemNavigationBarIconBrightness: dark
                    ? Brightness.light
                    : Brightness.dark,
              ),
              child: app,
            );
          },
          home: Builder(
            builder: (context) {
              if (widget.session.restoring) {
                return const Center(child: CupertinoActivityIndicator());
              }
              if (widget.session.user == null ||
                  widget.session.mustChangePassword ||
                  widget.session.firstLogin) {
                if (DymuseTokens.mobile) {
                  // 外壳不是 Scaffold，不会随键盘缩小；底部垫上键盘高度，
                  // 登录表单才会在输入法弹出时上移，焦点输入框保持可见。
                  return ColoredBox(
                    color: DymuseTokens.background(context),
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.viewInsetsOf(context).bottom,
                      ),
                      child: SafeArea(
                        child: WelcomePage(session: widget.session),
                      ),
                    ),
                  );
                }
                return ColoredBox(
                  color: DymuseTokens.macOS
                      ? DymuseTokens.background(context)
                      : const Color(0x00000000),
                  child: Column(
                    children: [
                      WindowTitleBar(window: widget.window),
                      Expanded(child: WelcomePage(session: widget.session)),
                    ],
                  ),
                );
              }
              if (DymuseTokens.mobile) {
                // Cupertino 弹层（播放页、设置）出现时背景页会被缩放；GlassPage 把
                // “正在被推后”告知玻璃层，冻结其采样坐标，否则玻璃与文字会错位。
                return glass.GlassPage(
                  child: MobileShell(
                    key: ValueKey(
                      '${widget.session.api.server}:${widget.session.user!['id']}',
                    ),
                    session: widget.session,
                    catalog: widget.catalog,
                    playback: widget.playback,
                    appearance: appearance,
                  ),
                );
              }
              return MacShell(
                key: ValueKey(
                  '${widget.session.api.server}:${widget.session.user!['id']}',
                ),
                session: widget.session,
                catalog: widget.catalog,
                playback: widget.playback,
                appearance: appearance,
                window: widget.window,
              );
            },
          ),
        ),
      );
    },
  );
}
