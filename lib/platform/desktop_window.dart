import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import '../design_system/tokens.dart';

/// Windows 自绘 macOS 外观；macOS 使用原生窗口按钮与侧栏材质。
/// 系统操作仍交给窗口插件。
class DesktopWindow extends ChangeNotifier with WindowListener {
  static const _native = MethodChannel('dymuse/window');
  bool focused = true, fullScreen = false, maximized = false;
  bool _closing = false;
  Future<void> Function()? beforeClose;
  Future<void> initialize() async {
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    if (DymuseTokens.macOS) {
      // ⌘Q、程序坞“退出”、注销都先完成关闭保存，再由原生端结束进程。
      _native.setMethodCallHandler((call) async {
        if (call.method != 'willTerminate') return null;
        await beforeClose?.call();
        return null;
      });
    }
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: DymuseTokens.initialWindow,
        minimumSize: DymuseTokens.minWindow,
        center: true,
        title: 'Dymuse',
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: DymuseTokens.macOS,
        // macOS 透明背景露出 Runner 中的原生侧栏材质。
        backgroundColor: DymuseTokens.macOS
            ? const Color(0x00000000)
            : const Color(0xFFFBFAFC),
      ),
      () async {
        await windowManager.setPreventClose(true);
        await windowManager.show();
        await windowManager.focus();
        // window_manager 设置标题栏样式后会重排按钮，由原生端放回侧栏内。
        if (DymuseTokens.macOS) {
          await _native.invokeMethod('layoutWindowButtons').catchError((_) {});
        }
      },
    );
  }

  /// 应用内强制浅色/深色时，原生材质跟随同一外观；null 表示跟随系统。
  Future<void> setAppearance(Brightness? brightness) async {
    if (!DymuseTokens.macOS) return;
    try {
      await _native.invokeMethod('setAppearance', brightness?.name ?? 'system');
    } on MissingPluginException {
      // 测试或旧 Runner 没有原生通道时保持系统外观。
    }
  }

  Future<void> toggleFullScreen() async =>
      windowManager.setFullScreen(!await windowManager.isFullScreen());
  Future<void> toggleMaximize() async {
    if (await windowManager.isFullScreen()) return;
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  /// 重新显示被关闭的 macOS 主窗口（窗口菜单、程序坞）。
  Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> close() async {
    // macOS 与“音乐”一致：关闭窗口只隐藏，播放继续；退出应用时才保存并结束。
    if (DymuseTokens.macOS) return windowManager.hide();
    if (_closing) return;
    _closing = true;
    try {
      await windowManager.hide();
      await beforeClose?.call();
    } finally {
      await windowManager.destroy();
    }
  }

  @override
  void onWindowClose() {
    close();
  }

  @override
  void onWindowFocus() {
    focused = true;
    notifyListeners();
  }

  @override
  void onWindowBlur() {
    focused = false;
    notifyListeners();
  }

  @override
  void onWindowEnterFullScreen() {
    fullScreen = true;
    notifyListeners();
  }

  @override
  void onWindowLeaveFullScreen() {
    fullScreen = false;
    notifyListeners();
  }

  @override
  void onWindowMaximize() {
    maximized = true;
    notifyListeners();
  }

  @override
  void onWindowUnmaximize() {
    maximized = false;
    notifyListeners();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }
}

/// 隐藏系统标题栏后的拖动区；双击缩放，Windows 右键弹出系统菜单。
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.window, this.child});
  final DesktopWindow window;
  final Widget? child;
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) => windowManager.startDragging(),
    onDoubleTap: window.toggleMaximize,
    onSecondaryTap: DymuseTokens.macOS
        ? null
        : () => windowManager.popUpWindowMenu(),
    child: child ?? const SizedBox.expand(),
  );
}

class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({super.key, required this.window, this.trailing});
  final DesktopWindow window;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 54,
    child: Row(
      children: [
        // macOS 原生红黄绿按钮由系统绘制，这里只留出位置。
        if (DymuseTokens.macOS)
          const SizedBox(width: 84)
        else ...[
          const SizedBox(width: 14),
          TrafficLights(window: window),
        ],
        Expanded(
          child: WindowDragArea(
            window: window,
            child: Align(
              alignment: Alignment.center,
              child: Text(
                'Dymuse',
                style: TextStyle(
                  color: DymuseTokens.secondary(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        if (trailing != null) trailing! else const SizedBox(width: 86),
      ],
    ),
  );
}

class TrafficLights extends StatefulWidget {
  const TrafficLights({super.key, required this.window});
  final DesktopWindow window;
  @override
  State<TrafficLights> createState() => _TrafficLightsState();
}

class _TrafficLightsState extends State<TrafficLights> {
  bool hover = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.window,
    builder: (_, _) {
      final window = widget.window;
      final active = window.focused || hover;
      return MouseRegion(
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _light(
              '关闭窗口',
              const Color(0xFFFF5F57),
              CupertinoIcons.xmark,
              window.close,
              active,
            ),
            _light(
              '最小化窗口',
              const Color(0xFFFFBD2E),
              CupertinoIcons.minus,
              windowManager.minimize,
              active,
            ),
            _light(
              window.fullScreen ? '退出全屏' : '进入全屏',
              const Color(0xFF28C840),
              window.fullScreen
                  ? CupertinoIcons.arrow_down_right_arrow_up_left
                  : CupertinoIcons.arrow_up_left_arrow_down_right,
              window.toggleFullScreen,
              active,
            ),
          ],
        ),
      );
    },
  );
  Widget _light(
    String label,
    Color color,
    IconData icon,
    VoidCallback callback,
    bool active,
  ) => Semantics(
    label: label,
    button: true,
    child: CupertinoButton(
      key: ValueKey(label),
      padding: EdgeInsets.zero,
      minimumSize: const Size(24, 32),
      onPressed: callback,
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? color : const Color(0xFFABA8AE),
          border: Border.all(color: const Color(0x19000000), width: .6),
        ),
        child: hover
            ? Icon(icon, size: 8, color: const Color(0xAA000000))
            : null,
      ),
    ),
  );
}
