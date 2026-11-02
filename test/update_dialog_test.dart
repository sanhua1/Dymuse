import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dymuse/update/update_dialog.dart';
import 'package:dymuse/update/update_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('更新提示：选“忽略此版本”后自动检查不再弹出，手动检查仍会提示', (tester) async {
    late HttpServer server;
    late SharedPreferences prefs;
    await tester.runAsync(() async {
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) async {
        final base = 'http://127.0.0.1:${server.port}';
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/latest')) {
          request.response.write(
            jsonEncode({
              'tag_name': 'v9.9.9',
              'prerelease': false,
              'assets': [
                {
                  'name': 'latest.json',
                  'browser_download_url': '$base/dl/v9.9.9/latest.json',
                },
              ],
            }),
          );
        } else {
          request.response.write(
            jsonEncode({
              'version': '9.9.9',
              'notes': '修复了一些问题',
              'assets': {
                'windows-x64': {'name': 'a.zip', 'size': 1, 'sha256': 'b' * 64},
              },
            }),
          );
        }
        await request.response.close();
      });
    });
    final service = UpdateService(
      prefs,
      sources: [
        UpdateSource(
          '测试',
          'http://127.0.0.1:${server.port}/api/latest',
          'http://127.0.0.1:${server.port}/dl',
        ),
      ],
      platform: 'windows-x64',
    );
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      CupertinoApp(navigatorKey: key, home: const SizedBox()),
    );

    Future<void> open({bool manual = false}) async {
      await tester.runAsync(() async {
        unawaited(checkForUpdates(key.currentState!, service, manual: manual));
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pump(const Duration(milliseconds: 400));
    }

    await open();
    expect(find.text('发现新版本 9.9.9'), findsOneWidget);
    expect(find.text('修复了一些问题'), findsOneWidget);
    expect(find.text('更新'), findsOneWidget);
    await tester.tap(find.text('忽略此版本'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('发现新版本 9.9.9'), findsNothing);
    expect(service.ignoredVersion, '9.9.9');

    await open();
    expect(find.text('发现新版本 9.9.9'), findsNothing);

    await open(manual: true);
    expect(find.text('发现新版本 9.9.9'), findsOneWidget);

    await tester.runAsync(() => server.close(force: true));
  });
}
