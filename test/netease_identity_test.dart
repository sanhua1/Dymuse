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
}
