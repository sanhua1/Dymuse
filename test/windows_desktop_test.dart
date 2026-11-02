import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dymuse/app/dymuse_app.dart';
import 'package:dymuse/app/mac_shell.dart';
import 'package:dymuse/core/session.dart';
import 'package:dymuse/design_system/tokens.dart';
import 'package:dymuse/features/catalog.dart';
import 'package:dymuse/features/search_controls.dart';
import 'package:dymuse/platform/desktop_window.dart';
import 'package:dymuse/playback/playback_controller.dart';
import 'support/windows_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final windows = TargetPlatformVariant({TargetPlatform.windows});

  Future<
    ({
      Session session,
      WindowsFixtureApi api,
      WindowsFixtureEngine engine,
      PlaybackController playback,
      Catalog catalog,
      DesktopWindow window,
      Appearance appearance,
      Future<void> Function() close,
    })
  >
  showApp(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'deviceId': 'windows-widget-fixture',
    });
    final api = WindowsFixtureApi()..token = 'fixture';
    final engine = WindowsFixtureEngine(), catalog = Catalog(api);
    final playback = PlaybackController(api, catalog, engine);
    final session = Session(api, await SharedPreferences.getInstance())
      ..user = {'id': 'fixture', 'nickname': 'Windows 隔离验证'}
      ..restoring = false;
    final window = DesktopWindow();
    final appearance = Appearance(reduceTransparency: true, reduceMotion: true);
    await tester.pumpWidget(
      DymuseApp(
        session: session,
        catalog: catalog,
        playback: playback,
        appearance: appearance,
        window: window,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    Future<void> close() async {
      await tester.pumpWidget(const SizedBox());
      playback.dispose();
      catalog.dispose();
      window.dispose();
      appearance.dispose();
      session.dispose();
      api.close();
    }

    return (
      session: session,
      api: api,
      engine: engine,
      playback: playback,
      catalog: catalog,
      window: window,
      appearance: appearance,
      close: close,
    );
  }

  testWidgets('Windows复用V2桌面布局，保留窗口控件且不创建macOS菜单', (tester) async {
    tester.view.physicalSize = const Size(1240, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = await showApp(tester);
    try {
      expect(DymuseTokens.liquid, true);
      expect(DymuseTokens.fontFamily, 'Segoe UI');
      expect(find.byType(MacShell), findsOneWidget);
      expect(find.byType(PlatformMenuBar), findsNothing);
      expect(find.byKey(const ValueKey('关闭窗口')), findsOneWidget);
      expect(find.byKey(const ValueKey('最小化窗口')), findsOneWidget);
      expect(find.byKey(const ValueKey('进入全屏')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await h.close();
    }
  }, variant: windows);

  testWidgets('Ctrl F保持输入焦点，搜索框空格和Ctrl右键不切歌', (tester) async {
    final h = await showApp(tester);
    try {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      final field = tester.widget<DymuseSearchField>(
        find.byType(DymuseSearchField),
      );
      expect(field.focusNode.hasFocus, true);
      final input = find.byKey(const ValueKey('dymuse-search-input'));
      await tester.enterText(input, 'A');
      await tester.pump();
      expect(field.focusNode.hasFocus, true);
      await tester.enterText(input, '爱情 转移');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        h.api.calls.any(
          (call) =>
              call.path.contains('/search') &&
              call.query?['keywords'] == '爱情 转移',
        ),
        true,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(h.engine.toggles, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await h.close();
    }
  }, variant: windows);

  testWidgets('720点窗口与两倍文字无溢出', (tester) async {
    tester.view.physicalSize = const Size(720, 600);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final h = await showApp(tester);
    try {
      await h.playback.start(
        Track.netease(WindowsFixtureApi.song('101')),
        context: {'kind': 'daily'},
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    } finally {
      await h.close();
    }
  }, variant: windows);
}
