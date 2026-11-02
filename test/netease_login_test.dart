import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dymuse/app/login_page.dart';
import 'package:dymuse/app/netease_login.dart';
import 'package:dymuse/core/api_client.dart';
import 'package:dymuse/core/session.dart';
import 'package:dymuse/netease/client.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Session> newSession() async {
  SharedPreferences.setMockInitialValues({'deviceId': 'test-device'});
  FlutterSecureStorage.setMockInitialValues({});
  final session = Session(
    ApiClient(),
    await SharedPreferences.getInstance(),
    storage: const FlutterSecureStorage(),
  );
  await session.restore();
  return session;
}

/// 登录页一直有二维码加载转圈，pumpAndSettle 永远等不完；改为推进固定时间。
Future<void> step(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 400));

/// 卸载页面并让网络超时计时器走完，否则测试框架报“计时器仍在等待”。
Future<void> finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 20));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('手机号登录协议', () {
    late HttpServer server;
    late NeteaseClient client;
    final paths = <String>[];
    Map<String, Object?> reply = {};
    var setCookie = false;

    setUp(() async {
      // 测试框架默认让所有 HttpClient 返回 400；这里要连本机的假服务器。
      HttpOverrides.global = null;
      server = await HttpServer.bind('127.0.0.1', 0);
      paths.clear();
      reply = {};
      setCookie = false;
      server.listen((request) async {
        paths.add(request.uri.path);
        await request.drain<void>();
        if (setCookie) {
          request.response.headers.add(
            HttpHeaders.setCookieHeader,
            'MUSIC_U=token123; Path=/; HttpOnly',
          );
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(reply));
        await request.response.close();
      });
      client = NeteaseClient(weapiHost: 'http://127.0.0.1:${server.port}');
    });
    tearDown(() => server.close(force: true));

    test('密码登录成功：Cookie 来自 Set-Cookie', () async {
      reply = {'code': 200};
      setCookie = true;
      await client.loginCellphone(phone: '13800000000', password: 'secret');
      expect(paths, ['/weapi/w/login/cellphone']);
      expect(client.loggedIn, isTrue);
    });

    test('验证码登录走同一接口，发送验证码走短信接口', () async {
      reply = {'code': 200};
      await client.sendCaptcha('13800000000');
      setCookie = true;
      await client.loginCellphone(phone: '13800000000', captcha: '1234');
      expect(paths, ['/weapi/sms/captcha/sent', '/weapi/w/login/cellphone']);
      expect(client.loggedIn, isTrue);
    });

    test('密码错误给出明确提示，不是风控', () async {
      reply = {'code': 502, 'message': '密码错误'};
      await expectLater(
        client.loginCellphone(phone: '13800000000', password: 'x'),
        throwsA(
          isA<NeteaseError>()
              .having((e) => e.code, 'code', 'LOGIN_FAILED')
              .having((e) => e.message, 'message', '手机号或密码错误。'),
        ),
      );
      expect(client.loggedIn, isFalse);
    });

    test('被要求安全验证（8821 / -462）时标记为风控', () async {
      for (final code in [8821, -462]) {
        reply = {'code': code, 'message': '需要验证'};
        await expectLater(
          client.loginCellphone(phone: '13800000000', password: 'x'),
          throwsA(
            isA<NeteaseError>().having(
              (e) => e.code,
              'code',
              NeteaseClient.loginRisk,
            ),
          ),
          reason: '$code',
        );
      }
    });

    test('验证码发送失败：报出网易云给的提示', () async {
      reply = {'code': 400, 'message': '发送过于频繁'};
      await expectLater(
        client.sendCaptcha('13800000000'),
        throwsA(
          isA<NeteaseError>().having((e) => e.message, 'message', '发送过于频繁'),
        ),
      );
    });

    test('返回 200 却没有登录凭证也算失败', () async {
      reply = {'code': 200};
      await expectLater(
        client.loginCellphone(phone: '13800000000', password: 'x'),
        throwsA(isA<NeteaseError>()),
      );
    });
  });

  group('欢迎页与登录页', () {
    Widget host(Widget child) => CupertinoApp(
      home: Center(child: SizedBox(width: 420, height: 760, child: child)),
    );

    testWidgets('欢迎页入口：登录、不登录；点登录进入三种方式，可返回', (tester) async {
      final session = (await tester.runAsync(newSession))!;
      await tester.pumpWidget(host(WelcomePage(session: session)));
      await tester.pump();
      expect(find.text('开始使用 Dymuse'), findsOneWidget);
      expect(find.text('登录网易云账号'), findsOneWidget);
      expect(find.text('不登录，直接使用'), findsOneWidget);

      await tester.tap(find.text('登录网易云账号'));
      await step(tester);
      expect(find.text('登录网易云'), findsOneWidget);
      expect(find.text('扫码'), findsOneWidget);
      expect(find.text('密码'), findsWidgets);
      expect(find.text('验证码'), findsWidgets);

      await tester.tap(find.text('返回'));
      await step(tester);
      expect(find.text('开始使用 Dymuse'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('不登录，直接使用会进入游客', (tester) async {
      final session = (await tester.runAsync(newSession))!;
      await tester.pumpWidget(host(WelcomePage(session: session)));
      await tester.pump();
      await tester.tap(find.text('不登录，直接使用'));
      await tester.pump();
      expect(session.guest, isTrue);
      await finish(tester);
    });

    testWidgets('手机号、密码、验证码的基本校验', (tester) async {
      final session = (await tester.runAsync(newSession))!;
      await tester.pumpWidget(host(NeteaseLoginView(session: session)));
      await tester.pump();

      await tester.tap(find.text('密码').first);
      await step(tester);
      expect(find.text('手机号'), findsOneWidget);
      await tester.tap(find.text('登录'));
      await tester.pump();
      expect(find.text('请输入 11 位手机号。'), findsOneWidget);

      await tester.enterText(
        find.byType(CupertinoTextField).first,
        '13800000000',
      );
      await tester.tap(find.text('登录'));
      await tester.pump();
      expect(find.text('请输入密码。'), findsOneWidget);

      await tester.tap(find.text('验证码').first);
      await step(tester);
      expect(find.text('获取验证码'), findsOneWidget);
      await tester.tap(find.text('登录'));
      await tester.pump();
      expect(find.text('请输入验证码。'), findsOneWidget);
      await finish(tester);
    });
  });

  group('从设置里登录', () {

    testWidgets('桌面是可返回的弹窗；关掉后仍是游客，Esc 也能关', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final session = (await tester.runAsync(newSession))!;
      await tester.runAsync(session.enterGuest);
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        CupertinoApp(
          navigatorKey: key,
          home: const Center(child: Text('主页')),
        ),
      );
      unawaited(showNeteaseLogin(key.currentState!, session));
      await step(tester);
      expect(find.text('登录网易云'), findsOneWidget);
      expect(find.text('先不登录，直接使用'), findsNothing);

      await tester.tap(find.text('返回'));
      await step(tester);
      expect(find.text('登录网易云'), findsNothing);
      expect(find.text('主页'), findsOneWidget);
      expect(session.guest, isTrue);

      unawaited(showNeteaseLogin(key.currentState!, session));
      await step(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await step(tester);
      expect(find.text('登录网易云'), findsNothing);
      await finish(tester);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
