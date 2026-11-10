import 'dart:convert';
import 'dart:io';

import 'package:dymuse/netease/client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假网易云：前 [fails] 次回 -460，之后回正常数据。
void main() {
  late HttpServer server;
  var calls = 0;
  var fails = 0;

  setUp(() async {
    calls = 0;
    NeteaseClient.riskRetriesForTest = const [Duration.zero, Duration.zero];
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) async {
      await request.drain<void>();
      calls++;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          calls <= fails
              ? {'code': -460, 'message': 'Cheating'}
              : {
                  'code': 200,
                  'data': [
                    {'id': 1, 'url': 'https://x/1.mp3'},
                  ],
                  'songs': [
                    {'id': 1},
                  ],
                },
        ),
      );
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  NeteaseClient client() => NeteaseClient(
    cookie: {'MUSIC_U': 'own'},
    eapiHost: 'http://127.0.0.1:${server.port}',
    weapiHost: 'http://127.0.0.1:${server.port}',
  );

  test('取链偶发 -460：自动重试后成功', () async {
    fails = 2;
    final data = await client().songUrls(['1']);
    expect(data.single['url'], 'https://x/1.mp3');
    expect(calls, 3);
  });

  test('歌曲详情偶发 -460：自动重试后成功', () async {
    fails = 1;
    final body = await client().songDetail(['1']);
    expect(body['songs'], isNotEmpty);
    expect(calls, 2);
  });

  test('一直 -460：最多请求 3 次后报错', () async {
    fails = 99;
    await expectLater(
      client().songUrls(['1']),
      throwsA(
        isA<NeteaseError>().having(
          (e) => e.message,
          'message',
          contains('-460'),
        ),
      ),
    );
    expect(calls, 3);
  });

  test('没开重试的请求不重试', () async {
    fails = 99;
    await expectLater(
      client().request('/api/toplist', {}),
      throwsA(isA<NeteaseError>()),
    );
    expect(calls, 1);
  });
}
