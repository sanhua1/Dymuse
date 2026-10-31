import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dymuse/core/api_client.dart';
import 'package:dymuse/core/artwork_image.dart';
import 'package:dymuse/core/media_cache.dart';
import 'package:dymuse/bilibili/client.dart';
import 'package:dymuse/local/backend.dart';
import 'package:dymuse/local/bilibili_backend.dart';
import 'package:dymuse/netease/client.dart';

/// 只统计调用次数，用来验证请求缓存的读写区域。
class _CountingBackend extends LocalBackend {
  _CountingBackend(SharedPreferences prefs, NeteaseClient client)
    : super(prefs, client, BilibiliBackend(prefs, BilibiliClient()));
  int calls = 0;
  @override
  Future<dynamic> handle(String method, String path, Map<String, dynamic>? query, Map<String, dynamic>? body) async => {'n': ++calls};
}

void main() {
  late Directory root;
  late MediaCache cache;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('dymuse-cache-test-');
    cache = MediaCache(root, await SharedPreferences.getInstance());
  });

  test('读写命中，超出上限按最近使用淘汰，近 10 分钟内用过的保留', () async {
    await cache.setLimit(CacheGroup.artwork, 1);
    final old = DateTime.now().subtract(const Duration(hours: 2));
    for (final name in ['a', 'b', 'c']) {
      await cache.write(CacheKind.images, name, List.filled(600 * 1024, 1));
    }
    expect((await cache.read(CacheKind.images, 'a'))!.length, 600 * 1024);
    cache.file(CacheKind.images, 'a').setLastModifiedSync(old);
    cache
        .file(CacheKind.images, 'b')
        .setLastModifiedSync(old.add(const Duration(minutes: 1)));
    await cache.trim(CacheGroup.artwork);
    // 最旧的 a、b 删除；c 刚写入，即使仍超上限也不删。
    expect(await cache.read(CacheKind.images, 'a'), isNull);
    expect(await cache.read(CacheKind.images, 'b'), isNull);
    expect(await cache.read(CacheKind.images, 'c'), isNotNull);
    // 未完成的歌曲下载（.part）不计入“已缓存”，清除时保留。
    final part = File('${cache.file(CacheKind.audio, 's').path}.part')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    expect(cache.audioCached('s'), isFalse);
    await cache.clear(CacheGroup.audio);
    expect(part.existsSync(), isTrue);
    await cache.clear(CacheGroup.artwork);
    expect(await cache.usage(CacheGroup.artwork), 0);
  });

  test('请求缓存只在指定区域读写，并按用户隔离', () async {
    final backend = _CountingBackend(
      await SharedPreferences.getInstance(),
      NeteaseClient(),
    );
    final api = ApiClient()
      ..backend = backend
      ..cache = cache
      ..cacheScope = 'server|user-a';
    expect((await api.get('/x'))['n'], 1);
    await expectLater(
      runZonedCacheOnly(() => api.get('/x')),
      throwsA(isA<ApiException>()),
    );
    expect((await runZonedWrite(() => api.get('/x')))['n'], 2);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect((await runZonedCacheOnly(() => api.get('/x')))['n'], 2);
    api.cacheScope = 'server|user-b';
    await expectLater(
      runZonedCacheOnly(() => api.get('/x')),
      throwsA(isA<ApiException>()),
    );
    expect(backend.calls, 2);
  });

  test('网易云图片换节点重试，非网易云地址不变', () {
    expect(
      alternateHost('https://p1.music.126.net/a.jpg?param=64y64'),
      'https://p2.music.126.net/a.jpg?param=64y64',
    );
    expect(
      alternateHost('https://p4.music.126.net/a.jpg'),
      'https://p1.music.126.net/a.jpg',
    );
    expect(
      alternateHost('https://example.org/a.jpg'),
      'https://example.org/a.jpg',
    );
  });
}

Future<T> runZonedCacheOnly<T>(Future<T> Function() body) =>
    runZoned(body, zoneValues: {cacheOnly: true});
Future<T> runZonedWrite<T>(Future<T> Function() body) =>
    runZoned(body, zoneValues: {cacheWrite: true});
