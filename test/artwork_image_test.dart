import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:dymuse/core/artwork_image.dart';

void main() {
  test('网易云封面按像素分档，保留参数，相似域名不改写', () {
    final uri = Uri.parse('http://p1.music.126.net/cover.jpg?foo=bar');
    expect(
      thumbnailAddress(uri, 52).toString(),
      'https://p1.music.126.net/cover.jpg?foo=bar&param=64y64',
    );
    expect(thumbnailAddress(uri, 201).queryParameters['param'], '256y256');
    expect(thumbnailAddress(uri, 5000).queryParameters['param'], '1600y1600');
    final other = Uri.parse('https://p1.music.126.net.example.org/cover.jpg');
    expect(thumbnailAddress(other, 200), other);
  });

  test('图片请求只发送一个应用 User-Agent，拒绝失败和空响应', () async {
    var calls = 0;
    final loader = ArtworkLoader(
      client: MockClient((request) async {
        expect(request.headers['user-agent'], 'Dymuse/0.1.0');
        expect(request.followRedirects, isFalse);
        calls++;
        if (calls == 1) return http.Response.bytes([1, 2, 3], 200);
        if (calls == 2) return http.Response('Forbidden', 403);
        return http.Response.bytes([], 200);
      }),
    );
    expect(
      await loader.fetch('https://p1.music.126.net/a.jpg'),
      Uint8List.fromList([1, 2, 3]),
    );
    await expectLater(
      loader.fetch('https://p1.music.126.net/a.jpg'),
      throwsA(
        isA<ArtworkException>().having(
          (error) => error.code,
          'code',
          'HTTP_403',
        ),
      ),
    );
    await expectLater(
      loader.fetch('https://p1.music.126.net/a.jpg'),
      throwsA(
        isA<ArtworkException>().having(
          (error) => error.code,
          'code',
          'EMPTY_IMAGE',
        ),
      ),
    );
    loader.close();
  });

  test('同源重定向保留认证，跨源后不再转交认证或 Cookie', () async {
    final urls = <String>[];
    final loader = ArtworkLoader(
      client: MockClient((request) async {
        urls.add(request.url.host);
        if (urls.length == 1) {
          return http.Response('', 302, headers: {'location': '/second'});
        }
        if (urls.length == 2) {
          expect(request.headers['authorization'], 'Bearer fixture-token');
          return http.Response(
            '',
            302,
            headers: {'location': 'https://images.example.com/final'},
          );
        }
        expect(request.headers.containsKey('authorization'), isFalse);
        expect(request.headers.containsKey('cookie'), isFalse);
        return http.Response.bytes([1], 200);
      }),
    );
    await loader.fetch(
      'https://service.example.com/cover',
      headers: {
        'Authorization': 'Bearer fixture-token',
        'Cookie': 'fixture-only=1',
      },
    );
    expect(urls, [
      'service.example.com',
      'service.example.com',
      'images.example.com',
    ]);
    loader.close();
  });

  test('拒绝 HTTPS 降级、非 HTTP 重定向和循环重定向', () async {
    for (final target in ['http://images.example.com/a', 'file:///private']) {
      final loader = ArtworkLoader(
        client: MockClient(
          (_) async => http.Response('', 302, headers: {'location': target}),
        ),
      );
      await expectLater(
        loader.fetch('https://service.example.com/cover'),
        throwsA(isA<ArtworkException>()),
      );
      loader.close();
    }
    var count = 0;
    final loop = ArtworkLoader(
      client: MockClient((_) async {
        count++;
        return http.Response('', 302, headers: {'location': '/again'});
      }),
    );
    await expectLater(
      loop.fetch('https://service.example.com/cover'),
      throwsA(isA<ArtworkException>()),
    );
    expect(count, 4);
    loop.close();
  });

  test('封面超过字节限制即终止，不依赖 Content-Length', () async {
    final loader = ArtworkLoader(
      maxBytes: 3,
      client: MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.fromIterable([
            [1, 2],
            [3, 4],
          ]),
          200,
        ),
      ),
    );
    await expectLater(
      loader.fetch('https://service.example.com/cover'),
      throwsA(
        isA<ArtworkException>().having(
          (error) => error.code,
          'code',
          'TOO_LARGE',
        ),
      ),
    );
    loader.close();
  });

  test('等待超时主动发出中断，慢请求不会一直占用 UI', () async {
    var aborted = false;
    final loader = ArtworkLoader(
      timeout: const Duration(milliseconds: 20),
      client: MockClient.streaming((request, _) async {
        await (request as http.AbortableRequest).abortTrigger;
        aborted = true;
        throw http.RequestAbortedException(request.url);
      }),
    );
    await expectLater(
      loader.fetch('https://service.example.com/cover'),
      throwsA(isA<TimeoutException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(aborted, isTrue);
    loader.close();
  });

  test('封面缓存区分账号请求头，调试文字不包含凭证', () async {
    final loader = ArtworkLoader(
      client: MockClient((_) async => http.Response.bytes([1], 200)),
    );
    final first = ArtworkImage(
      'https://service.example.com/cover',
      headers: {'Authorization': 'Bearer first-secret'},
      loader: loader,
    );
    final same = ArtworkImage(
      'https://service.example.com/cover',
      headers: {'Authorization': 'Bearer first-secret'},
      loader: loader,
    );
    final other = ArtworkImage(
      'https://service.example.com/cover',
      headers: {'Authorization': 'Bearer second-secret'},
      loader: loader,
    );
    expect(await first.obtainKey(ImageConfiguration.empty), same);
    expect(first.hashCode, same.hashCode);
    expect(first, isNot(other));
    expect(first.toString(), isNot(contains('secret')));
    loader.close();
  });
}
