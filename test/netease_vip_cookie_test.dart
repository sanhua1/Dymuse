import 'dart:convert';
import 'dart:io';

import 'package:dymuse/netease/client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假网易云：按请求里的 MUSIC_U 决定回复，并故意下发一个 Set-Cookie。
void main() {
  late HttpServer server;
  final seen = <String>[];

  setUp(() async {
    seen.clear();
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) async {
      await request.drain<void>();
      final cookie = request.headers.value('cookie') ?? '';
      final user = RegExp(r'MUSIC_U=([^;]*)').firstMatch(cookie)?.group(1);
      seen.add('$user');
      request.response.headers.add('set-cookie', 'MUSIC_U=hijacked; Path=/');
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          user == 'old-vip'
              ? {'code': 301}
              : {
                  'code': 200,
                  'data': [
                    {'id': 1, 'url': 'https://x/$user.mp3'},
                  ],
                },
        ),
      );
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  NeteaseClient client({
    Map<String, String>? Function()? vip,
    Future<void> Function()? expired,
  }) => NeteaseClient(
    cookie: {'MUSIC_U': 'own'},
    vipCookie: vip,
    onVipExpired: expired,
    eapiHost: 'http://127.0.0.1:${server.port}',
  );

  test('没有取链账号：用自己的账号', () async {
    final data = await client().songUrls(['1']);
    expect(data.single['url'], 'https://x/own.mp3');
    expect(seen, ['own']);
  });

  test('有取链账号：取链用它，且不改写自己的 Cookie', () async {
    final c = client(vip: () => {'MUSIC_U': 'vip'});
    final data = await c.songUrls(['1']);
    expect(data.single['url'], 'https://x/vip.mp3');
    expect(seen, ['vip']);
    expect(c.cookie['MUSIC_U'], 'own');
  });

  test('取链账号失效：重新拉取后用新账号重试', () async {
    var current = {'MUSIC_U': 'old-vip'};
    final c = client(
      vip: () => current,
      expired: () async => current = {'MUSIC_U': 'new-vip'},
    );
    final data = await c.songUrls(['1']);
    expect(data.single['url'], 'https://x/new-vip.mp3');
    expect(seen, ['old-vip', 'new-vip']);
  });

  test('重新拉取后仍失效：退回使用者自己的账号', () async {
    var asked = 0;
    final c = client(
      vip: () => {'MUSIC_U': 'old-vip'},
      expired: () async => asked++,
    );
    final data = await c.songUrls(['1']);
    expect(data.single['url'], 'https://x/own.mp3');
    expect(seen, ['old-vip', 'own']);
    expect(asked, 1);
  });
}
