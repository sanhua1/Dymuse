import 'dart:convert';
import 'dart:io';

import 'package:dymuse/core/api_client.dart';
import 'package:dymuse/core/session.dart';
import 'package:dymuse/features/login_required.dart';
import 'package:dymuse/netease/client.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Session> newSession([Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues({
    'deviceId': 'test-device',
    ...initial,
  });
  FlutterSecureStorage.setMockInitialValues({});
  final session = Session(
    ApiClient(),
    await SharedPreferences.getInstance(),
    storage: const FlutterSecureStorage(),
  );
  await session.restore();
  return session;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('游客会话', () {
    test('默认没有登录也不是游客；先不登录后成为游客并记住', () async {
      var session = await newSession();
      expect(session.user, isNull);
      expect(session.guest, isFalse);

      await session.enterGuest();
      expect(session.guest, isTrue);
      expect(session.api.guest, isTrue);
      expect(session.user?['id'], 'guest');
      expect(session.username, '游客');
      expect(session.vipType, 0);

      // 重新启动：仍是游客，不回到登录页
      session = await newSession({'netease.guest': true});
      expect(session.guest, isTrue);
      expect(session.user?['id'], 'guest');
    });

    test('游客要登录：回到登录页，并且仍能申请二维码', () async {
      final session = await newSession();
      await session.enterGuest();
      await session.startLogin();
      expect(session.user, isNull);
      expect(session.guest, isFalse);
      expect(session.api.guest, isFalse);
      expect(session.preferences.containsKey('netease.guest'), isFalse);
      expect(session.api.backend, isNotNull);
    });

    test('登录失效后也会换上一个没有登录信息的连接（否则登录页申请不了二维码）', () async {
      final session = await newSession();
      session.expire();
      expect(session.user, isNull);
      expect(session.api.backend, isNotNull);
    });

    test('依赖账号的接口在游客下被拦住，且不会当成登录失效', () async {
      final session = await newSession();
      await session.enterGuest();
      for (final path in [
        '/netease/likelist',
        '/netease/liked/playlist',
        '/netease/user/playlist',
        '/netease/playlists/editable',
        '/netease/playlists/1/tracks',
        '/netease/playlists/1/subscription',
      ]) {
        await expectLater(
          session.api.get(path),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', 'LOGIN_REQUIRED')
                .having((e) => e.status, 'status', 0),
          ),
          reason: path,
        );
      }
      await expectLater(
        session.api.post('/netease/like', {'id': '1', 'like': true}),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'LOGIN_REQUIRED'),
        ),
      );
      await expectLater(
        session.api.post('/netease/playlist/create', {'name': 'x'}),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'LOGIN_REQUIRED'),
        ),
      );
      // 仍是游客，没有被踢回登录页
      expect(session.guest, isTrue);
      expect(session.user?['id'], 'guest');
    });
  });

  group('登录提示', () {
    final results = <bool>[];
    setUp(results.clear);

    testWidgets('页面提示带登录入口，点按触发登录', (tester) async {
      var requested = 0;
      final api = ApiClient()..guest = true;
      api.onLoginRequested = () => requested++;
      await tester.pumpWidget(
        CupertinoApp(
          home: LoginRequiredView(api: api, title: '我的歌单'),
        ),
      );
      expect(find.text('我的歌单需要登录网易云账号'), findsOneWidget);
      expect(find.textContaining('请登录网易云账号之后使用这些功能'), findsOneWidget);
      await tester.tap(find.text('登录网易云账号'));
      expect(requested, 1);
    });

    testWidgets('游客点需要账号的操作：弹提示，选“去登录”才跳转', (tester) async {
      var requested = 0;
      final api = ApiClient()..guest = true;
      api.onLoginRequested = () => requested++;
      await tester.pumpWidget(
        CupertinoApp(
          home: Builder(
            builder: (context) => CupertinoButton(
              onPressed: () async =>
                  results.add(await ensureLoggedIn(context, api)),
              child: const Text('操作'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('操作'));
      await tester.pumpAndSettle();
      expect(find.text('需要登录网易云账号'), findsOneWidget);
      expect(find.text('请登录网易云账号之后使用这些功能。'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(results, [false]);
      expect(requested, 0);

      await tester.tap(find.text('操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('去登录'));
      await tester.pumpAndSettle();
      expect(results, [false, false]);
      expect(requested, 1);
    });

    testWidgets('已登录直接放行，不弹提示', (tester) async {
      final api = ApiClient();
      await tester.pumpWidget(
        CupertinoApp(
          home: Builder(
            builder: (context) => CupertinoButton(
              onPressed: () async =>
                  results.add(await ensureLoggedIn(context, api)),
              child: const Text('操作'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('操作'));
      await tester.pumpAndSettle();
      expect(results, [true]);
      expect(find.text('需要登录网易云账号'), findsNothing);
    });
  });

  group('游客推荐歌单', () {
    test('把公开的推荐歌单整理成“推荐”页用的形状', () async {
      // 测试框架默认让所有 HttpClient 返回 400；这里要连本机的假服务器。
      HttpOverrides.global = null;
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'code': 200,
            'result': [
              {
                'id': 1,
                'name': '歌单甲',
                'picUrl': 'https://x/a.jpg',
                'trackCount': 12,
                'playCount': 9,
              },
              {'id': 2, 'name': '歌单乙', 'picUrl': null},
            ],
          }),
        );
        await request.response.close();
      });
      final client = NeteaseClient(
        weapiHost: 'http://127.0.0.1:${server.port}',
      );
      final data = await client.personalizedPlaylists();
      expect(paths, ['/weapi/personalized/playlist']);
      expect(data['code'], 200);
      expect(data['recommend'], [
        {'id': 1, 'name': '歌单甲', 'picUrl': 'https://x/a.jpg', 'trackCount': 12},
        {'id': 2, 'name': '歌单乙', 'picUrl': null, 'trackCount': null},
      ]);
    });
  });
}
