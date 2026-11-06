import 'package:dymuse/core/api_client.dart';
import 'package:dymuse/features/catalog.dart';
import 'package:dymuse/playback/playback_controller.dart';
import 'package:dymuse/playback/player_view.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/windows_fixture.dart';

/// 查询歌曲来源的替身接口：记录请求次数。
class _JumpApi extends WindowsFixtureApi {
  int sourceCalls = 0;
  @override
  Future<dynamic> request(
    String method,
    String path, {
    Json? query,
    Json? body,
  }) async {
    if (path.endsWith('/sources')) {
      sourceCalls++;
      return {
        'items': [
          {
            'typeLabel': '合集',
            'label': '某合集',
            'input':
                'https://space.bilibili.com/5/channel/collectiondetail?sid=9',
          },
          {
            'typeLabel': 'UP 主投稿',
            'label': 'UP主甲',
            'input': 'https://space.bilibili.com/5',
          },
        ],
      };
    }
    return super.request(method, path, query: query, body: body);
  }
}

void main() {
  Future<
    ({_JumpApi api, PlaybackController playback, Future<void> Function() close})
  >
  show(
    WidgetTester tester,
    Track track, {
    required void Function(Collection) onOpen,
    bool withOpen = true,
  }) async {
    final api = _JumpApi()..token = 'fixture';
    final playback = PlaybackController(
      api,
      Catalog(api),
      WindowsFixtureEngine(),
    )..current = track;
    // 控制器里有定时器，必须在测试结束前释放，否则会被判为“定时器未清理”。
    Future<void> close() async {
      await tester.pumpWidget(const SizedBox());
      playback.dispose();
      api.close();
    }

    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: SizedBox(
            width: 360,
            child: NowPlayingControls(
              controller: playback,
              onOpenCollection: withOpen ? onOpen : null,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return (api: api, playback: playback, close: close);
  }

  const bili = Track(
    id: 'BV1jump00001:0',
    mode: MusicMode.bilibili,
    title: '歌名',
    artist: 'UP主甲',
  );

  testWidgets('B 站播放页：点歌名或 UP 主名都等同于“跳转到…”，选了来源才打开', (tester) async {
    Collection? opened;
    final h = await show(tester, bili, onOpen: (c) => opened = c);

    // 点歌名：弹出来源列表。
    await tester.tap(find.text('歌名'));
    await tester.pumpAndSettle();
    expect(find.text('合集 · 某合集'), findsOneWidget);
    expect(find.text('UP 主投稿 · UP主甲'), findsOneWidget);
    // 取消不打开任何东西。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(opened, isNull);

    // 点 UP 主名：同一个列表（来源在 10 分钟内只查一次），选 UP 主投稿。
    await tester.tap(find.text('UP主甲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('UP 主投稿 · UP主甲'));
    await tester.pumpAndSettle();
    expect(opened?.kind, 'source');
    expect(opened?.id, 'https://space.bilibili.com/5');
    expect(opened?.subtitle, 'UP 主投稿');
    expect(h.api.sourceCalls, 1);
    await h.close();
  });

  testWidgets('网易云歌曲点歌名不会跳转', (tester) async {
    var opened = 0;
    final h = await show(
      tester,
      const Track(
        id: '101',
        mode: MusicMode.netease,
        title: '网易云歌',
        artist: '歌手',
      ),
      onOpen: (_) => opened++,
    );
    await tester.tap(find.text('网易云歌'));
    await tester.pumpAndSettle();
    expect(find.text('取消'), findsNothing);
    expect(h.api.sourceCalls, 0);
    expect(opened, 0);
    await h.close();
  });

  testWidgets('B 站歌曲没有传打开来源的回调时，歌名不是链接，点了没有反应', (tester) async {
    final h = await show(
      tester,
      const Track(
        id: 'BV1jump00002:0',
        mode: MusicMode.bilibili,
        title: '另一首',
        artist: 'UP',
      ),
      onOpen: (_) {},
      withOpen: false,
    );
    await tester.tap(find.text('另一首'));
    await tester.pumpAndSettle();
    expect(find.text('取消'), findsNothing);
    expect(h.api.sourceCalls, 0);
    await h.close();
  });
}
