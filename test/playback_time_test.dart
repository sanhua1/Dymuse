import 'package:dymuse/features/catalog.dart';
import 'package:dymuse/playback/playback_controller.dart';
import 'package:dymuse/playback/player_view.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/windows_fixture.dart';

void main() {
  testWidgets('播放页两端时间：默认右边总时长，点任一端切换为剩余时长', (tester) async {
    final api = WindowsFixtureApi()..token = 'fixture';
    final engine = WindowsFixtureEngine()
      ..position.value = const Duration(seconds: 30);
    final playback = PlaybackController(api, Catalog(api), engine)
      ..current = const Track(
        id: '101',
        mode: MusicMode.netease,
        title: '歌',
        artist: '歌手',
      );

    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: SizedBox(
            width: 360,
            child: NowPlayingControls(
              controller: playback,
              onOpenCollection: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 默认：左已播 0:30，右总时长 2:00。
    expect(find.text('0:30'), findsOneWidget);
    expect(find.text('2:00'), findsOneWidget);
    expect(find.text('-1:30'), findsNothing);

    // 点右侧总时长 -> 显示剩余。
    await tester.tap(find.text('2:00'));
    await tester.pump();
    expect(find.text('-1:30'), findsOneWidget);
    expect(find.text('2:00'), findsNothing);

    // 点左侧已播 -> 切回总时长。
    await tester.tap(find.text('0:30'));
    await tester.pump();
    expect(find.text('2:00'), findsOneWidget);
    expect(find.text('-1:30'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    playback.dispose();
    api.close();
  });
}
