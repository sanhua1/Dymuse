import 'dart:convert';
import 'dart:io';

import 'package:dymuse/netease/client.dart';
import 'package:flutter_test/flutter_test.dart';

/// eapi 请求的 User-Agent 与 Cookie 里的客户端身份必须一致，否则网易云取链会回 -460。
void main() {
  test('eapi：User-Agent 与 header 同为 Windows 电脑版同一版本', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    String? ua, cookie;
    server.listen((request) async {
      await request.drain<void>();
      ua = request.headers.value('user-agent');
      cookie = request.headers.value('cookie');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'code': 200, 'data': []}));
      await request.response.close();
    });
    final client = NeteaseClient(
      cookie: {'MUSIC_U': 'own'},
      eapiHost: 'http://127.0.0.1:${server.port}',
    );
    await client.songUrls(['1']);
    client.close();
    await server.close(force: true);
    expect(cookie, contains('os=pc'));
    expect(cookie, contains('appver=3.1.17.204416'));
    expect(ua, contains('Windows NT'));
    expect(ua, contains('NeteaseMusicDesktop/3.1.17.204416'));
    expect(ua, isNot(contains('iPhone')));
  });

  test('收听上报：eapi 发到 clientlog，用 Mac 客户端身份，不写回会话 Cookie', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    String? path, cookie;
    server.listen((request) async {
      await request.drain<void>();
      path = request.uri.path;
      cookie = request.headers.value('cookie');
      request.response.headers.contentType = ContentType.json;
      request.response.headers.add('set-cookie', 'os=osx; Path=/');
      request.response.write(jsonEncode({'code': 200, 'data': 'success'}));
      await request.response.close();
    });
    final client = NeteaseClient(
      cookie: {'MUSIC_U': 'own'},
      eapiHost: 'http://127.0.0.1:1',
      weapiHost: 'http://127.0.0.1:1',
      feedbackHost: 'http://127.0.0.1:${server.port}',
    );
    await client.feedback(songId: '1', action: 'play', origin: 'playlist');
    client.close();
    await server.close(force: true);
    expect(path, '/eapi/feedback/weblog');
    expect(cookie, contains('os=osx'));
    expect(cookie, contains('appver=3.1.10.5100'));
    expect(cookie, contains('MUSIC_U=own'));
    expect(client.cookie['os'], isNull);
  });
}
