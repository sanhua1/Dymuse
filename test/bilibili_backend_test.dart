import 'dart:convert';
import 'dart:io';

import 'package:dymuse/bilibili/client.dart';
import 'package:dymuse/bilibili/sources.dart';
import 'package:dymuse/local/backend.dart';
import 'package:dymuse/local/bilibili_backend.dart';
import 'package:dymuse/netease/client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> song(String bvid, String title, {int cid = 0}) => {
  'bvid': bvid,
  'cid': cid,
  'title': title,
  'artist': 'UP',
  'artistId': '1',
  'cover': 'https://i0.hdslb.com/a.jpg',
  'duration': 200,
  'album': title,
  'page': 1,
};

void main() {
  late SharedPreferences prefs;
  late BilibiliBackend bili;
  late LocalBackend backend;
  const a = 'BV1xx411c7mD', b = 'BV1yy411c7mE';

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // 红心里已有两首歌，详情和队列直接从本地取，不联网。
      'bili.hearts': '[${_j(song(a, '甲'))},${_j(song(b, '乙'))}]',
    });
    prefs = await SharedPreferences.getInstance();
    bili = BilibiliBackend(prefs, BilibiliClient());
    backend = LocalBackend(prefs, NeteaseClient(), bili);
  });

  Future<dynamic> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) => backend.handle(method, path, method == 'GET' ? body : null, body);

  test('在订阅里按原视频名搜索，不联网、与识别后的歌名无关', () async {
    await prefs.setString(
      'bili.subs.v2',
      jsonEncode({
        's1': {
          'ts': 1,
          'del': false,
          'name': '合集',
          'tracks': [
            song('BV1aa411c7mA', '【4K】《夜に駆ける》超好听 Cover'),
            song('BV1bb411c7mB', '另一首歌'),
          ],
        },
        's2': {
          'ts': 2,
          'del': true,
          'name': '已删订阅',
          'tracks': [song('BV1cc411c7mC', '夜に駆ける 已删除订阅里的')],
        },
      }),
    );
    final page =
        await call('GET', '/bilibili/tracks', {
              'q': '超好听 cover',
              'scope': 'subscriptions',
            })
            as Map;
    final items = (page['items'] as List).cast<Map>();
    expect(page['total'], 1);
    expect(items.single['rawTitle'], '【4K】《夜に駆ける》超好听 Cover');
    // 显示用的歌名已识别，但搜索用的是原标题。
    expect(items.single['title'], '夜に駆ける');
  });

  test('歌曲可查询所属来源，用于跳转与快捷订阅', () async {
    final custom = LocalBackend(
      prefs,
      NeteaseClient(),
      BilibiliBackend(prefs, _SourcesClient()),
    );
    final page =
        await custom.handle(
              'GET',
              '/bilibili/tracks/BV1xx411c7mD%3A0/sources',
              null,
              null,
            )
            as Map;
    final items = (page['items'] as List).cast<Map>();
    expect(items.map((e) => e['typeLabel']), ['合集', 'UP 主投稿']);
    expect(items.first['input'], contains('collectiondetail?sid=9'));
    // 返回的链接必须能被订阅来源解析器识别。
    expect(parseBiliSource('${items.first['input']}')!.type.name, 'collection');
    expect(parseBiliSource('${items.last['input']}')!.type.name, 'uploads');
  });

  test('合集里作者为空的歌：按 UP 主 mid 补上昵称，每个 mid 只查一次并存在本机', () async {
    await prefs.setString(
      'bili.subs.v2',
      jsonEncode({
        's1': {
          'ts': 1,
          'del': false,
          'name': '合集·某',
          'type': 'collection',
          'tracks': [
            {...song('BV1aa411c7mA', '甲'), 'artist': '', 'artistId': '5'},
            {...song('BV1bb411c7mB', '乙'), 'artist': '', 'artistId': '5'},
            // 自己带作者的不查。
            {...song('BV1cc411c7mC', '丙'), 'artist': '别的UP', 'artistId': '9'},
          ],
        },
      }),
    );
    final client = _NamesClient({'5': 'UP主甲'});
    BilibiliBackend fresh() => BilibiliBackend(prefs, client);
    var local = LocalBackend(prefs, NeteaseClient(), fresh());
    Future<List<Map>> list() async {
      final page =
          await local.handle(
                'GET',
                '/bilibili/subscriptions/s1/tracks',
                null,
                null,
              )
              as Map;
      return (page['items'] as List).cast<Map>();
    }

    var items = await list();
    expect(items.map((e) => (e['artists'] as List).join()), [
      'UP主甲',
      'UP主甲',
      '别的UP',
    ]);
    expect(client.lookups, ['5']);
    // 再看一遍不再联网；重启（新的后端实例）后也不用再查，昵称已存在本机。
    await list();
    local = LocalBackend(prefs, NeteaseClient(), fresh());
    items = await list();
    expect(items.first['artists'], ['UP主甲']);
    expect(client.lookups, ['5']);
    // 播放页取详情时同样带上昵称。
    final detail =
        await local.handle(
              'GET',
              '/bilibili/tracks/${Uri.encodeComponent('BV1aa411c7mA:0')}',
              null,
              null,
            )
            as Map;
    expect(detail['artists'], ['UP主甲']);
  });

  test('查不到 UP 主昵称时留空，不影响列表，本次运行不重复请求；被限流立刻停手', () async {
    await prefs.setString(
      'bili.subs.v2',
      jsonEncode({
        's1': {
          'ts': 1,
          'del': false,
          'name': '合集',
          'type': 'collection',
          'tracks': [
            {...song('BV1aa411c7mA', '甲'), 'artist': '', 'artistId': '6'},
            {...song('BV1bb411c7mB', '乙'), 'artist': '', 'artistId': '7'},
          ],
        },
      }),
    );
    final client = _NamesClient({}, limited: true);
    final local = LocalBackend(
      prefs,
      NeteaseClient(),
      BilibiliBackend(prefs, client),
    );
    for (var i = 0; i < 2; i++) {
      final page =
          await local.handle(
                'GET',
                '/bilibili/subscriptions/s1/tracks',
                null,
                null,
              )
              as Map;
      final items = (page['items'] as List).cast<Map>();
      expect(items.length, 2);
      expect(items.first['artists'], isEmpty);
    }
    // 第一次就被限流：只发了一个请求，第二个 mid 没有再试，冷却期内第二次列表也不重试。
    expect(client.lookups, ['6']);
    expect(prefs.getString('bili.names'), isNull);
  });

  test('合集、系列的歌带上所属 UP 主的昵称；个人投稿的 author 为空串时退回名片昵称', () async {
    final client = _ArchiveClient();
    final fetcher = BiliSourceFetcher(client);
    final collection = await fetcher.fetch(
      const BiliSource(BiliSourceType.collection, {'mid': '5', 'sid': '1'}),
    );
    expect(collection.songs.map((e) => e.artist), ['UP主甲', 'UP主甲']);
    expect(collection.songs.first.artistId, '5');
    // 名片接口失败不影响订阅：作者留空，展示时再按 mid 补。
    client.nameFails = true;
    final noName = await fetcher.fetch(
      const BiliSource(BiliSourceType.collection, {'mid': '5', 'sid': '1'}),
    );
    expect(noName.songs.map((e) => e.artist), ['', '']);
    client.nameFails = false;
    final uploads = await fetcher.fetch(
      const BiliSource(BiliSourceType.uploads, {'mid': '5'}),
    );
    expect(uploads.songs.map((e) => e.artist), ['UP主甲', '合作作者']);
  });

  test('重启后继续播放搜索来的歌：本地没有时联网补查，播放过的会留下', () async {
    const id = 'BV1zz411c7mZ:55';
    final client = _LookupClient();
    BilibiliBackend fresh() => BilibiliBackend(prefs, client);
    // 新进程：内存里没有这首歌，红心、歌单、订阅里也没有。
    var local = LocalBackend(prefs, NeteaseClient(), fresh());
    final detail =
        await local.handle(
              'GET',
              '/bilibili/tracks/${Uri.encodeComponent(id)}',
              null,
              null,
            )
            as Map;
    expect(detail['rawTitle'], '搜索来的歌');
    expect(client.lookups, 1);
    // 播放过一次后写入“最近播放”，再次重启不需要联网。
    await local.handle(
      'GET',
      '/bilibili/tracks/${Uri.encodeComponent(id)}/audio',
      null,
      null,
    );
    local = LocalBackend(prefs, NeteaseClient(), fresh());
    final again =
        await local.handle(
              'GET',
              '/bilibili/tracks/${Uri.encodeComponent(id)}',
              null,
              null,
            )
            as Map;
    expect(again['rawTitle'], '搜索来的歌');
    expect(client.lookups, 1);
  });

  test('识别各类订阅来源', () {
    expect(
      parseBiliSource(
        'https://space.bilibili.com/12/channel/collectiondetail?sid=34',
      )!.toJson(),
      {
        'type': 'collection',
        'params': {'mid': '12', 'sid': '34'},
      },
    );
    expect(
      parseBiliSource(
        'https://space.bilibili.com/12/channel/seriesdetail?sid=56&ctype=0',
      )!.type,
      BiliSourceType.series,
    );
    expect(
      parseBiliSource(
        'https://space.bilibili.com/12/favlist?fid=78&ftype=create',
      )!.type,
      BiliSourceType.favorite,
    );
    expect(
      parseBiliSource(
        'https://space.bilibili.com/12/favlist?fid=90&ftype=collect',
      )!.type,
      BiliSourceType.season,
    );
    expect(
      parseBiliSource('https://space.bilibili.com/12')!.type,
      BiliSourceType.uploads,
    );
    expect(parseBiliSource('看这个 BV1xx411c7mD 不错')!.params['bvid'], a);
    expect(parseBiliSource('随便一句话'), isNull);
  });

  test('红心列表与取消红心', () async {
    var page = await call('GET', '/bilibili/favorites') as Map;
    expect(page['total'], 2);
    expect((page['items'] as List).first['title'], '甲');
    expect((page['items'] as List).first['favorite'], true);
    await call('PUT', '/bilibili/tracks/$a:0/favorite', {'favorite': false});
    page = await call('GET', '/bilibili/favorites') as Map;
    expect(page['total'], 1);
    await call('PUT', '/bilibili/tracks/$a:0/favorite', {'favorite': true});
    page = await call('GET', '/bilibili/favorites') as Map;
    expect((page['items'] as List).first['title'], '甲', reason: '新红心排在最前');
  });

  test('本地歌单：新建、加歌、保存修订、归档', () async {
    final created =
        await call('POST', '/bilibili/playlists', {
              'name': '通勤',
              'trackIds': ['$a:0'],
            })
            as Map;
    final id = created['id'];
    expect(
      await call('POST', '/bilibili/playlists/$id/tracks', {'trackId': '$b:0'}),
      {'added': true},
    );
    expect(
      await call('POST', '/bilibili/playlists/$id/tracks', {'trackId': '$b:0'}),
      {'added': false},
      reason: '重复添加不会产生两份',
    );
    final list = await call('GET', '/bilibili/playlists') as Map;
    expect((list['items'] as List).single['trackCount'], 2);
    final detail = await call('GET', '/bilibili/playlists/$id') as Map;
    expect(detail['name'], '通勤');
    // 旧版本号保存会被拒绝。
    expect(
      call('PUT', '/bilibili/playlists/$id', {
        'name': '改名',
        'revision': 'stale',
        'trackIds': <String>[],
      }),
      throwsA(
        isA<LocalError>().having((e) => e.code, 'code', 'PLAYLIST_CHANGED'),
      ),
    );
    await call('POST', '/bilibili/playlists/$id/archive', {});
    expect(((await call('GET', '/bilibili/playlists')) as Map)['total'], 0);
  });

  test('开始播放：按红心列表建队并定位所选歌曲，进度分模式保存', () async {
    final snapshot =
        await call('POST', '/playback/bilibili/start', {
              'context': {'kind': 'favorites'},
              'selectedId': '$b:0',
            })
            as Map;
    final state = snapshot['state'] as Map;
    expect(state['index'], 1);
    expect((state['items'] as List).map((e) => e['id']), ['$a:0', '$b:0']);
    expect((state['items'] as List).first['mode'], 'bilibili');
    // 网易云队列不受影响。
    expect(await call('GET', '/playback/netease'), isNull);
    await call('PUT', '/playback/bilibili/progress', {
      'index': 0,
      'positionMs': 5000,
      'playing': true,
      'expectedRevision': snapshot['revision'],
    });
    final restored = await call('GET', '/playback/bilibili') as Map;
    expect((restored['state'] as Map)['positionMs'], 5000);
  });

  test('队列拒绝网易云歌曲 id', () async {
    expect(
      call('PUT', '/playback/bilibili', {
        'state': {
          'items': [
            {'id': '12345', 'mode': 'bilibili'},
          ],
          'index': 0,
        },
      }),
      throwsA(
        isA<LocalError>().having((e) => e.code, 'code', 'INVALID_MUSIC_ID'),
      ),
    );
  });

  test('扫码登录：Cookie 取自 Set-Cookie，也兼容回包地址里的旧写法', () {
    final fromHeader = BilibiliClient.loginCookiesFrom([
      Cookie('SESSDATA', 'abc%2C123%2Cxyz'),
      Cookie('bili_jct', 'jct'),
      Cookie('DedeUserID', '42'),
      Cookie('other', 'x'),
    ], '');
    expect(fromHeader, {
      'SESSDATA': 'abc%2C123%2Cxyz',
      'bili_jct': 'jct',
      'DedeUserID': '42',
    });
    final fromUrl = BilibiliClient.loginCookiesFrom(
      [],
      'https://passport.biligame.com/x/passport-login/web/crossDomain'
      '?DedeUserID=7&SESSDATA=sess%2Cx&bili_jct=jj&gourl=https%3A%2F%2Fwww.bilibili.com',
    );
    expect(fromUrl['SESSDATA'], 'sess%2Cx');
    expect(fromUrl['bili_jct'], 'jj');
    expect(fromUrl['DedeUserID'], '7');
    // Set-Cookie 与地址同时出现时以 Set-Cookie 为准。
    final both = BilibiliClient.loginCookiesFrom([
      Cookie('SESSDATA', 'new'),
    ], '?SESSDATA=old');
    expect(both['SESSDATA'], 'new');
  });
}

String _j(Map<String, dynamic> value) =>
    '{${value.entries.map((e) => '"${e.key}":${e.value is String ? '"${e.value}"' : e.value}').join(',')}}';

class _SourcesClient extends BilibiliClient {
  @override
  Future<List<Map<String, String>>> videoSources(String bvid) async => [
    {
      'typeLabel': '合集',
      'label': '某合集',
      'input': 'https://space.bilibili.com/5/channel/collectiondetail?sid=9',
    },
    {
      'typeLabel': 'UP 主投稿',
      'label': 'UP',
      'input': 'https://space.bilibili.com/5',
    },
  ];
}

/// 名片接口的替身：记录查过哪些 mid；[limited] 时一律返回被限流。
class _NamesClient extends BilibiliClient {
  _NamesClient(this.names, {this.limited = false});
  final Map<String, String> names;
  final bool limited;
  final lookups = <String>[];
  @override
  Future<String> uploaderName(String mid) async {
    lookups.add(mid);
    if (limited) {
      throw const BilibiliError('BILIBILI_RATE_LIMITED', '限流', 429);
    }
    return names[mid] ?? '';
  }
}

/// 合集与个人投稿接口的替身：合集里的视频没有任何作者字段，个人投稿的 author 可能是空串。
class _ArchiveClient extends BilibiliClient {
  bool nameFails = false;
  @override
  Future<String> uploaderName(String mid) async {
    if (nameFails) throw const BilibiliError('X', '失败');
    return 'UP主甲';
  }

  @override
  Future<Map<String, dynamic>> get(
    String path,
    Map<String, Object?> params, {
    bool withLogin = false,
  }) async {
    if (path.contains('seasons_archives_list')) {
      return {
        'data': {
          'archives': [
            {'bvid': 'BV1aa411c7mA', 'title': '甲', 'duration': 10},
            {'bvid': 'BV1bb411c7mB', 'title': '乙', 'duration': 20},
          ],
          'page': {'total': 2},
          'meta': {'name': '某合集'},
        },
      };
    }
    if (path.contains('/card')) {
      return {
        'data': {
          'card': {'name': 'UP主甲', 'face': ''},
        },
      };
    }
    throw StateError('未预期的请求 $path');
  }

  @override
  Future<Map<String, dynamic>> wbiGet(
    String path,
    Map<String, Object?> params, {
    bool withLogin = false,
  }) async => {
    'data': {
      'list': {
        'vlist': [
          // author 是空串（不是 null）：要退回名片里的昵称。
          {
            'bvid': 'BV1aa411c7mA',
            'title': '甲',
            'author': '',
            'mid': 5,
            'length': '01:00',
          },
          {
            'bvid': 'BV1bb411c7mB',
            'title': '乙',
            'author': '合作作者',
            'mid': 5,
            'length': '02:00',
          },
        ],
      },
      'page': {'count': 2},
    },
  };
}

class _LookupClient extends BilibiliClient {
  int lookups = 0;
  @override
  Future<List<BiliSong>> videoSongs(String bvid) async {
    lookups++;
    return [
      BiliSong(
        bvid: bvid,
        cid: 55,
        title: '搜索来的歌',
        artist: 'UP',
        artistId: '1',
        cover: '',
        duration: 100,
        album: '某合集',
      ),
    ];
  }

  @override
  Future<BiliAudio> audioUrl(String bvid, int cid) async =>
      const BiliAudio('https://x/a.m4s', {});
}
