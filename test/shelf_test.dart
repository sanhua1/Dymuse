import 'package:dymuse/design_system/shelf.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

/// 纵向页面里嵌一排横向卡片，与“现在就听”首页结构相同。
Future<(ScrollController, ScrollController)> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final outer = ScrollController();
  await tester.pumpWidget(
    CupertinoApp(
      home: CustomScrollView(
        controller: outer,
        slivers: [
          SliverToBoxAdapter(
            child: HorizontalShelf(
              key: const ValueKey('shelf'),
              itemCount: 12,
              itemWidth: 170,
              height: 240,
              padding: 32,
              itemBuilder: (_, index) => GestureDetector(
                onTap: () {},
                child: Container(
                  color: const Color(0xFF888888),
                  child: Text('卡片$index'),
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 2000)),
        ],
      ),
    ),
  );
  await tester.pumpAndSettle();
  final inner = tester.widget<ListView>(find.byType(ListView)).controller!;
  return (outer, inner);
}

void main() {
  final mac = TargetPlatformVariant.only(TargetPlatform.macOS);

  testWidgets('Mac：鼠标按住可以横向拖动', (tester) async {
    final (_, inner) = await _pump(tester);
    await tester.dragFrom(
      const Offset(400, 100),
      const Offset(-300, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(inner.offset, greaterThan(200));
  }, variant: mac);

  testWidgets('Mac：触控板略斜的横滑由这一排处理，竖滑交给页面', (tester) async {
    final (outer, inner) = await _pump(tester);
    final pad = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await pad.panZoomStart(const Offset(400, 100));
    for (var i = 1; i <= 10; i++) {
      await pad.panZoomUpdate(
        const Offset(400, 100),
        pan: Offset(-30.0 * i, 6.0 * i),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await pad.panZoomEnd();
    await tester.pumpAndSettle();
    expect(inner.offset, greaterThan(250));
    final innerAfter = inner.offset;

    final vertical = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await vertical.panZoomStart(const Offset(400, 100));
    for (var i = 1; i <= 10; i++) {
      await vertical.panZoomUpdate(
        const Offset(400, 100),
        pan: Offset(2.0 * i, -30.0 * i),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await vertical.panZoomEnd();
    await tester.pumpAndSettle();
    expect(outer.offset, greaterThan(100));
    expect(inner.offset, innerAfter);
  }, variant: mac);

  testWidgets('Mac：指针停在这一排时显示翻页箭头，点右箭头翻页、到头后左箭头可回', (tester) async {
    final (_, inner) = await _pump(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 100));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('向右翻页'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('向右翻页'));
    await tester.pumpAndSettle();
    expect(inner.offset, greaterThan(600));
    await tester.tap(find.bySemanticsLabel('向左翻页'));
    await tester.pumpAndSettle();
    expect(inner.offset, 0);
    await mouse.removePointer();
  }, variant: mac);
}
