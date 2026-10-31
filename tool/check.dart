// 只读连通性检查：个别请求验证请求层与常用接口，不登录、不写账号。
import 'package:dymuse/netease/client.dart';

Future<void> main() async {
  final client = NeteaseClient();
  Future<void> probe(String name, Future<Object?> Function() run) async {
    final watch = Stopwatch()..start();
    try {
      final value = await run();
      print('$name ok ${watch.elapsedMilliseconds}ms ${value.toString().length > 80 ? value.toString().substring(0, 80) : value}');
    } catch (error) {
      print('$name FAILED ${watch.elapsedMilliseconds}ms $error');
    }
  }

  await probe('search', () async {
    final body = await client.search(keywords: '晴天', limit: 3);
    return (body['result']?['songs'] as List?)?.map((s) => s['name']).toList();
  });
  await probe('songDetail', () async {
    final body = await client.songDetail(['186016']);
    return (body['songs'] as List?)?.map((s) => s['name']).toList();
  });
  await probe('songUrl', () async {
    final data = await client.songUrls(['186016']);
    return data.map((d) => {'id': d['id'], 'br': d['br'], 'code': d['code'], 'url': (d['url'] ?? '').toString().length});
  });
  await probe('lyric', () async {
    final body = await client.lyric('186016');
    return (body['lrc']?['lyric'] as String?)?.substring(0, 40);
  });
  await probe('playlistDetail', () async {
    final body = await client.playlistDetail('3778678');
    return {'name': body['playlist']?['name'], 'tracks': (body['playlist']?['trackIds'] as List?)?.length};
  });
  await probe('toplist', () async {
    final body = await client.toplist();
    return (body['list'] as List?)?.length;
  });
  await probe('album', () async {
    final body = await client.album('32311');
    return {'name': body['album']?['name'], 'songs': (body['songs'] as List?)?.length};
  });
  client.close();
}
