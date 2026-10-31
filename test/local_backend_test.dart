import 'dart:convert';

import 'package:dymuse/bilibili/client.dart';
import 'package:dymuse/local/backend.dart';
import 'package:dymuse/local/bilibili_backend.dart';
import 'package:dymuse/netease/client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用固定数据代替网易云，验证本地后端的队列与收听状态机。
class FakeClient implements NeteaseClient {
  final feedbacks = <String>[];

  @override
  Map<String, String> get cookie => {'MUSIC_U': 'x', 'userId': '42'};

  @override
  void Function(Map<String, String> cookie)? get onCookie => null;

  @override
  bool get loggedIn => true;

  @override
  String get userId => '42';

  @override
  Future<Map<String, dynamic>> playlistDetail(String id) async => {
    'playlist': {
      'id': id,
      'name': '测试歌单',
      'trackIds': [
        for (var i = 1; i <= 5; i++) {'id': '$i'},
      ],
      'creator': {'userId': '42'},
      'specialType': 0,
      'subscribed': false,
    },
  };

  @override
  Future<Map<String, dynamic>> album(String id) async => {
    'album': {'name': '专辑'},
    'songs': [
      for (var i = 1; i <= 3; i++) {'id': '${100 + i}', 'name': '歌曲$i'},
    ],
  };

  @override
  Future<Map<String, dynamic>> artistSongs(
    String id, {
    int limit = 50,
    int offset = 0,
  }) async => {
    'songs': [
      {'id': 301, 'name': '歌手 1'},
      {'id': 302, 'name': '歌手 2'},
    ],
    'more': false,
  };

  @override
  Future<Map<String, dynamic>> personalFm() async => {
    'data': [
      {'id': 11, 'name': 'FM 1'},
      {'id': 12, 'name': 'FM 2'},
    ],
  };

  @override
  Future<Map<String, dynamic>> userPlaylist(
    String uid, {
    int limit = 100,
    int offset = 0,
  }) async => {
    'playlist': [
      {
        'id': '9',
        'name': '我喜欢的音乐',
        'specialType': 5,
        'creator': {'userId': '42'},
        'trackCount': 5,
      },
    ],
    'more': false,
  };

  @override
  Future<Map<String, dynamic>> intelligenceList({
    required String id,
    required String pid,
    String? sid,
    int count = 50,
  }) async => {
    'data': [
      {'id': '3', 'name': '心动 3'},
      {'id': '4', 'name': '心动 4'},
    ],
  };

  @override
  Future<Map<String, dynamic>> simiSong(String id, {int limit = 50}) async => {
    'songs': [
      {'id': '21', 'name': '相似 21'},
      {'id': '22', 'name': '相似 22'},
    ],
  };

  @override
  Future<Map<String, dynamic>> songSimiGet(String id) async => {'data': []};

  final urlLevels = <String>[];

  @override
  Future<Map<String, dynamic>> musicDetail(String id) async => {
    'data': {
      'h': {'br': 320000},
      'sq': null,
    },
  };

  @override
  Future<List<dynamic>> songUrls(
    Iterable<String> ids, {
    String level = 'exhigh',
  }) async {
    urlLevels.add(level);
    return [
      {'id': ids.first, 'url': 'http://x/$level.mp3', 'level': level},
    ];
  }

  @override
  Future<void> feedback({
    required String songId,
    required String action,
    required String origin,
    String? sourceId,
    int seconds = 0,
    bool completed = false,
  }) async => feedbacks.add('$action:$songId:$seconds');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late SharedPreferences prefs;
  late FakeClient client;
  late LocalBackend backend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'aio.profile': jsonEncode({
        'userId': '42',
        'nickname': '测试',
        'avatarUrl': '',
        'vipType': 11,
      }),
    });
    prefs = await SharedPreferences.getInstance();
    client = FakeClient();
    backend = LocalBackend(prefs, client, BilibiliBackend(prefs, BilibiliClient()));
  });

  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async =>
      (await backend.handle(method, path, null, body)) as Map<String, dynamic>;

  List<dynamic> itemsOf(Map<String, dynamic> snapshot) =>
      (snapshot['state'] as Map)['items'] as List;

  test('歌单建立队列、恢复顺序并在队尾续推', () async {
    final started = await call('POST', '/queues/collection', {
      'kind': 'playlist',
      'collectionId': '9',
      'songId': '3',
    });
    final state = started['state'] as Map;
    expect(itemsOf(started).length, 5);
    expect(state['index'], 2);
    expect(state['origin'], 'playlist');
    expect((state['playlistId']), '9');
    expect(started['restoredPaused'], isTrue);

    // 搜索推荐队列的续推只对 search 生效；当前是歌单队列，应拒绝。
    await expectLater(
      backend.handle('POST', '/queues/extend', null, {
        'generation': started['generation'],
      }),
      throwsA(
        isA<LocalError>()
            .having((e) => e.code, 'code', 'NOT_RECOMMENDATION_QUEUE')
            .having((e) => e.status, 'status', 409),
      ),
    );
  });

  test('歌手歌曲列表整张建队，不做推荐续推', () async {
    final started = await call('POST', '/queues/collection', {
      'kind': 'artist',
      'collectionId': '77',
      'songId': '302',
    });
    expect(itemsOf(started).map((item) => item['id']), ['301', '302']);
    expect((started['state'] as Map)['index'], 1);
    expect((started['state'] as Map)['origin'], 'manual');
    final missing = await call('POST', '/queues/collection', {
      'kind': 'artist',
      'collectionId': '77',
      'songId': '999',
    });
    expect((missing['state'] as Map)['index'], 0);
  });

  test('进度保存、插入、移除与整份保存都推进 revision', () async {
    final started = await call('POST', '/queues/collection', {
      'kind': 'album',
      'collectionId': '1',
    });
    var revision = (started['revision'] as num).toInt();
    final progress = await call('PUT', '/playback/netease/progress', {
      'index': 1,
      'positionMs': 1200,
      'playing': true,
      'expectedRevision': revision,
    });
    expect(progress['revision'], revision + 1);
    revision = (progress['revision'] as num).toInt();

    final inserted = await call('POST', '/playback/netease/insert', {
      'item': {'id': '777', 'mode': 'netease'},
      'next': true,
      'expectedRevision': revision,
    });
    expect(itemsOf(inserted)[2]['id'], '777');
    revision = (inserted['revision'] as num).toInt();

    final removed = await call('POST', '/playback/netease/remove', {
      'index': 2,
      'expectedRevision': revision,
    });
    expect(itemsOf(removed).length, 3);
    revision = (removed['revision'] as num).toInt();

    await expectLater(
      backend.handle('POST', '/playback/netease/remove', null, {
        'index': 1,
        'expectedRevision': revision - 1,
      }),
      throwsA(isA<LocalError>().having((e) => e.code, 'code', 'QUEUE_CHANGED')),
    );
  });

  test('私人FM续推去重，重复请求不重复加歌', () async {
    final started = await call('POST', '/queues/fm');
    expect(itemsOf(started).length, 2);
    final extended = await call('POST', '/queues/fm/extend', {
      'generation': started['generation'],
      'manual': true,
    });
    expect(itemsOf(extended).length, 2);
    final status = (extended['state'] as Map)['recommendationStatus'];
    expect(status, 'exhausted');
  });

  test('心动模式开启以喜欢歌单为种子，关闭恢复原队列', () async {
    final before = await call('POST', '/queues/collection', {
      'kind': 'playlist',
      'collectionId': '9',
    });
    final on = await call('POST', '/queues/intelligence', {'enabled': true});
    final state = on['state'] as Map;
    expect(state['intelligence'], isTrue);
    expect(itemsOf(on).map((item) => item['id']), ['1', '3', '4']);
    expect(before['generation'], isNot(on['generation']));

    final off = await call('POST', '/queues/intelligence', {'enabled': false});
    expect(itemsOf(off).length, 5);
    expect((off['state'] as Map)['origin'], 'playlist');
  });

  test('收听实例只在队列内创建，结束后各上报一次', () async {
    final started = await call('POST', '/queues/collection', {
      'kind': 'playlist',
      'collectionId': '9',
    });
    final generation = started['generation'];
    await expectLater(
      backend.handle('POST', '/listening/start', null, {
        'playId': 'a',
        'generation': generation,
        'songId': '999',
        'durationMs': 1000,
      }),
      throwsA(
        isA<LocalError>().having(
          (e) => e.code,
          'code',
          'LISTENING_QUEUE_CHANGED',
        ),
      ),
    );
    await call('POST', '/listening/start', {
      'playId': 'b',
      'generation': generation,
      'songId': '1',
      'durationMs': 200000,
    });
    final done = await call('POST', '/listening', {
      'playId': 'b',
      'listenedMs': 20000,
      'finished': true,
      'reason': 'completed',
    });
    expect(done['finished'], isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(client.feedbacks, ['startplay:1:0', 'play:1:20']);
    // 已结算的实例不会重复上报。
    final again = await call('POST', '/listening', {
      'playId': 'b',
      'listenedMs': 30000,
      'finished': true,
      'reason': 'completed',
    });
    expect(again['listenedMs'], 20000);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(client.feedbacks.length, 2);
  });

  test('取链按 level 请求，默认极高，无效档位被拒绝，档位详情可查', () async {
    Future<Map<String, dynamic>> url([Map<String, dynamic>? query]) async =>
        (await backend.handle('GET', '/song/url', {'id': '5', ...?query}, null))
            as Map<String, dynamic>;
    await url();
    await url({'level': 'lossless'});
    expect(client.urlLevels, ['exhigh', 'lossless']);
    await expectLater(
      url({'level': 'sky'}),
      throwsA(isA<LocalError>().having((e) => e.code, 'code', 'INVALID_LEVEL')),
    );
    final detail =
        (await backend.handle('GET', '/song/music/detail', {'id': '5'}, null))
            as Map<String, dynamic>;
    expect((detail['data'] as Map)['h'], isNotNull);
  });

  test('收藏别人的歌单、往自己的歌单加歌都能走通路由', () async {
    final fake = _ListClient();
    final b = LocalBackend(prefs, fake, BilibiliBackend(prefs, BilibiliClient()));
    final saved = await b.handle('POST', '/playlists/5/subscription', null, {
      'subscribed': true,
    });
    expect((saved as Map)['subscribed'], isTrue);
    fake.mine = true;
    final added = await b.handle('POST', '/playlists/6/tracks', null, {
      'trackId': '8',
    });
    expect((added as Map)['added'], isTrue);
    expect(fake.calls, ['subscribe:5:true', 'add:6:8']);
  });

  test('歌单分页按 trackIds 还原并补齐缺失详情', () async {
    final fake = _DetailClient();
    final page = LocalBackend(prefs, fake, BilibiliBackend(prefs, BilibiliClient()));
    final data =
        (await page.handle('GET', '/playlist/page', {
              'id': '9',
              'offset': 0,
              'limit': 2,
            }, null))
            as Map<String, dynamic>;
    expect(data['total'], 5);
    expect((data['items'] as List).first['name'], '歌曲1');
    expect((data['playlist'] as Map)['canSubscribe'], isFalse);
    expect(data['nextOffset'], 2);
  });
}

class _ListClient extends FakeClient {
  final calls = <String>[];
  bool mine = false;

  @override
  Future<Map<String, dynamic>> playlistDetail(String id) async => {
    'playlist': {
      'id': id,
      'name': '歌单',
      'trackIds': [
        {'id': '1'},
      ],
      'creator': {'userId': mine ? '42' : '77'},
      'specialType': 0,
      'subscribed': false,
    },
  };

  @override
  Future<Map<String, dynamic>> playlistSubscribe(
    String id, {
    required bool subscribed,
  }) async {
    calls.add('subscribe:$id:$subscribed');
    return {'code': 200};
  }

  @override
  Future<Map<String, dynamic>> playlistAddTracks(
    String id,
    String trackId,
  ) async {
    calls.add('add:$id:$trackId');
    return {'code': 200};
  }
}

class _DetailClient extends FakeClient {
  @override
  Future<Map<String, dynamic>> songDetail(Iterable<String> ids) async => {
    'songs': [
      for (final id in ids)
        if (id != '2') {'id': id, 'name': '歌曲$id', 'ar': [], 'al': {}},
    ],
  };

  @override
  Future<Map<String, dynamic>> playlistDetail(String id) async => {
    'playlist': {
      'id': id,
      'name': '测试歌单',
      'trackIds': [
        for (var i = 1; i <= 5; i++) {'id': '$i'},
      ],
      'creator': {'userId': '42'},
      'specialType': 0,
      'subscribed': false,
    },
  };
}

// 避免未使用告警：测试里用到的 JSON 编解码保持与真实响应一致。
// ignore: unused_element
Object? _decode(String value) => jsonDecode(value);
