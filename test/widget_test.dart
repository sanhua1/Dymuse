import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dymuse/design_system/components.dart';
import 'package:dymuse/design_system/tokens.dart';
import 'package:dymuse/platform/desktop_window.dart';

void main() {
  testWidgets('降低透明度使用不透明容器', (tester) async {
    final appearance = Appearance(reduceTransparency: true);
    await tester.pumpWidget(
      CupertinoApp(
        home: AppearanceScope(
          appearance: appearance,
          child: const GlassPanel(child: Text('导航')),
        ),
      ),
    );
    expect(find.text('导航'), findsOneWidget);
    expect(tester.takeException(), isNull);
    appearance.dispose();
  });

  testWidgets('Windows 红黄绿窗口控件具有独立语义', (tester) async {
    final window = DesktopWindow();
    await tester.pumpWidget(CupertinoApp(home: WindowTitleBar(window: window)));
    expect(find.byKey(const ValueKey('关闭窗口')), findsOneWidget);
    expect(find.byKey(const ValueKey('最小化窗口')), findsOneWidget);
    expect(find.byKey(const ValueKey('进入全屏')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
