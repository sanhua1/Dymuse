// 网易云协议客户端：移植自 api-enhanced 的 util/request.js 与 module/*，
// 由用户自己的账号直接请求网易云，不经过任何自建服务器。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'crypto.dart' as enc;

enum Crypto { eapi, weapi }

/// 上游业务错误；[status] 沿用后端接口的语义，便于界面沿用原有提示。
class NeteaseError implements Exception {
  const NeteaseError(this.code, this.message, [this.status = 502]);
  final String code;
  final String message;
  final int status;
  @override
  String toString() => message;
}

class NeteaseClient {
  NeteaseClient({Map<String, String>? cookie, this.onCookie, this.antiCheat})
    : cookie = {...?cookie} {
    this.cookie.putIfAbsent('deviceId', () => _newDeviceId);
  }

  /// 登录态 Cookie（MUSIC_U、__csrf、NMTID、deviceId 等），由会话持久化。
  final Map<String, String> cookie;
  final void Function(Map<String, String> cookie)? onCookie;

  /// 易盾反作弊令牌生成器（需要浏览器环境，由界面层提供）；没有时请求不带令牌。
  final Future<String> Function()? antiCheat;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 30);
  final Random _random = Random.secure();

  static const _os = {
    'os': 'pc',
    'appver': '3.1.17.204416',
    'osver': 'Microsoft-Windows-10-Professional-build-19045-64bit',
    'channel': 'netease',
  };
  static const _eapiUa = 'NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)';
  static const _weapiUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0';
  static const _eapiHost = 'https://interfacepc.music.163.com';
  static const _weapiHost = 'https://music.163.com';

  bool get loggedIn => (cookie['MUSIC_U'] ?? '').isNotEmpty;
  String get userId => cookie['userId'] ?? '';

  static String get _newDeviceId => List.generate(
    52,
    (_) => '0123456789ABCDEF'[Random.secure().nextInt(16)],
  ).join();

  String _hexRandom(int bytes) => List.generate(
    bytes,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  // 与 request.js 的 processCookieObject 一致。
  Map<String, String> _processed(Crypto crypto) => {
    ...cookie,
    '__remember_me': 'true',
    'ntes_kaola_ad': '1',
    for (final entry in _os.entries)
      entry.key: cookie[entry.key] ?? entry.value,
    if (cookie['NMTID'] == null && crypto == Crypto.weapi)
      'NMTID': '00O${_hexRandom(19)}',
  };

  String _join(Map<String, String> map) => map.entries
      .map(
        (e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
      )
      .join('; ');

  // 只取 name=value，忽略 Expires/Path 等属性。
  void _saveCookies(List<String> lines) {
    if (lines.isEmpty) return;
    for (final line in lines) {
      final pair = line.split(';').first;
      final index = pair.indexOf('=');
      if (index <= 0) continue;
      final value = pair.substring(index + 1).trim();
      if (value.isNotEmpty) cookie[pair.substring(0, index).trim()] = value;
    }
    onCookie?.call(cookie);
  }

  /// 发一个原始请求并返回解码后的 JSON 主体。
  Future<Map<String, dynamic>> request(
    String uri,
    Map<String, Object?> data, {
    Crypto crypto = Crypto.eapi,
    bool checkToken = false,
  }) async {
    final token = checkToken ? await antiCheat?.call() ?? '' : '';
    final c = _processed(crypto);
    final body = <String, Object?>{...data, 'e_r': false};
    final Uri url;
    final headers = <String, String>{};
    final Map<String, String> form;
    if (crypto == Crypto.weapi) {
      url = Uri.parse('$_weapiHost/weapi/${uri.substring(5)}');
      headers['Referer'] = _weapiHost;
      headers['User-Agent'] = _weapiUa;
      headers['Cookie'] = _join(c);
      body['csrf_token'] = c['__csrf'] ?? '';
      form = enc.weapi(body);
    } else {
      final now = DateTime.now().millisecondsSinceEpoch;
      final header = <String, String>{
        'osver': c['osver']!,
        'deviceId': c['deviceId']!,
        'os': c['os']!,
        'appver': c['appver']!,
        'versioncode': c['versioncode'] ?? '140',
        'mobilename': c['mobilename'] ?? '',
        'buildver': c['buildver'] ?? '$now'.substring(0, 10),
        'resolution': c['resolution'] ?? '1920x1080',
        '__csrf': c['__csrf'] ?? '',
        'channel': c['channel']!,
        'requestId':
            '${now}_${_random.nextInt(1000).toString().padLeft(4, '0')}',
        if (c['MUSIC_U'] != null) 'MUSIC_U': c['MUSIC_U']!,
        if (c['NMTID'] != null) 'NMTID': c['NMTID']!,
        if (checkToken && token.isNotEmpty) 'X-antiCheatToken': token,
      };
      url = Uri.parse('$_eapiHost/eapi/${uri.substring(5)}');
      headers['User-Agent'] = _eapiUa;
      headers['Cookie'] = _join(header);
      body['header'] = header;
      form = enc.eapi(uri, body);
    }
    final text = await _post(url, headers, form);
    final Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      throw const NeteaseError('NETEASE_UPSTREAM_FAILED', '网易云返回了无法解析的数据。');
    }
    if (json is! Map<String, dynamic>) {
      throw const NeteaseError('NETEASE_UPSTREAM_FAILED', '网易云返回了无法解析的数据。');
    }
    final code = (json['code'] as num?)?.toInt();
    // 与 request.js 的 SPECIAL_STATUS_CODES 一致：这些业务码不算失败。
    const special = {200, 201, 302, 400, 502, 800, 801, 802, 803};
    if (code != null && !special.contains(code)) {
      throw NeteaseError(
        code == 301 || code == 401
            ? 'NETEASE_SESSION_EXPIRED'
            : 'NETEASE_UPSTREAM_FAILED',
        code == 301 || code == 401
            ? '网易云登录已失效，请重新登录。'
            : '网易云请求失败（$code），请稍后重试。',
        code == 301 || code == 401 ? 401 : 502,
      );
    }
    return json;
  }

  Future<String> _post(
    Uri url,
    Map<String, String> headers,
    Map<String, String> form,
  ) async {
    Future<String> once() async {
      final req = await _http.postUrl(url);
      try {
        headers.forEach(req.headers.set);
        req.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        );
        req.write(Uri(queryParameters: form).query);
        final res = await req.close();
        _saveCookies(res.headers[HttpHeaders.setCookieHeader] ?? const []);
        final text = await utf8.decodeStream(res);
        if (res.statusCode != 200) {
          throw NeteaseError(
            'NETEASE_UPSTREAM_FAILED',
            '网易云暂时不可用（HTTP ${res.statusCode}），请稍后重试。',
          );
        }
        return text;
      } finally {
        req.abort();
      }
    }

    try {
      return await once().timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const NeteaseError('TIMEOUT', '连接网易云超时，请检查网络后重试。');
    } on SocketException {
      throw const NeteaseError('NETWORK', '无法连接网易云，请检查网络。');
    } on HandshakeException {
      throw const NeteaseError('NETWORK', '与网易云建立安全连接失败，请检查网络。');
    } on HttpException {
      throw const NeteaseError('NETWORK', '网络连接中断，请重试。');
    }
  }

  // ---- 登录 ----

  Future<String> qrKey() async =>
      (await request('/api/login/qrcode/unikey', {'type': 3}))['unikey']
          as String;

  static String qrUrl(String key) => 'https://music.163.com/login?codekey=$key';

  /// 800 过期 / 801 等待扫码 / 802 待确认 / 803 成功（Cookie 已写入）。
  Future<int> qrCheck(String key) async =>
      ((await request('/api/login/qrcode/client/login', {
                'key': key,
                'type': 3,
              }))['code']
              as num)
          .toInt();

  Future<Map<String, dynamic>> account() =>
      request('/api/w/nuser/account/get', {}, crypto: Crypto.weapi);

  void logout() {
    for (final key in [
      'MUSIC_U',
      '__csrf',
      'userId',
      'MUSIC_A',
      'NMTID',
      '__remember_me',
      'ntes_kaola_ad',
      'os',
      'osver',
      'appver',
      'channel',
      'versioncode',
      'mobilename',
      'buildver',
      'resolution',
    ]) {
      cookie.remove(key);
    }
    onCookie?.call(cookie);
  }

  // ---- 浏览与详情 ----

  Future<Map<String, dynamic>> search({
    required String keywords,
    int type = 1,
    int limit = 30,
    int offset = 0,
    bool combined = false,
  }) => request(combined ? '/api/search/get' : '/api/cloudsearch/pc', {
    's': keywords,
    if (combined) 'scene': 'normal',
    'type': type,
    'limit': limit,
    'offset': offset,
    if (!combined) 'total': true,
  });

  Future<Map<String, dynamic>> songDetail(Iterable<String> ids) => request(
    '/api/v3/song/detail',
    {'c': '[${ids.map((id) => '{"id":$id}').join(',')}]'},
    crypto: Crypto.weapi,
  );

  Future<Map<String, dynamic>> album(String id) =>
      request('/api/v1/album/$id', {}, crypto: Crypto.weapi);

  Future<Map<String, dynamic>> artistSongs(
    String id, {
    int limit = 50,
    int offset = 0,
  }) => request('/api/v1/artist/songs', {
    'id': id,
    'private_cloud': 'true',
    'work_type': 1,
    'order': 'hot',
    'offset': offset,
    'limit': limit,
  });

  Future<Map<String, dynamic>> artistAlbums(
    String id, {
    int limit = 30,
    int offset = 0,
  }) => request('/api/artist/albums/$id', {
    'limit': limit,
    'offset': offset,
    'total': true,
  }, crypto: Crypto.weapi);

  Future<Map<String, dynamic>> playlistDetail(String id) =>
      request('/api/v6/playlist/detail', {'id': id, 'n': 100000, 's': 8});

  Future<Map<String, dynamic>> toplist() => request('/api/toplist', {});

  Future<Map<String, dynamic>> topPlaylist({
    String cat = '全部',
    String order = 'hot',
    int limit = 50,
    int offset = 0,
  }) => request('/api/playlist/list', {
    'cat': cat,
    'order': order,
    'limit': limit,
    'offset': offset,
    'total': true,
  }, crypto: Crypto.weapi);

  Future<Map<String, dynamic>> playlistCatlist() =>
      request('/api/playlist/catalogue', {});

  Future<Map<String, dynamic>> recommendSongs() =>
      request('/api/v3/discovery/recommend/songs', {}, crypto: Crypto.weapi);

  Future<Map<String, dynamic>> recommendResource() =>
      request('/api/v1/discovery/recommend/resource', {}, crypto: Crypto.weapi);

  Future<Map<String, dynamic>> personalFm() =>
      request('/api/v1/radio/get', {}, crypto: Crypto.weapi);

  Future<Map<String, dynamic>> userPlaylist(
    String uid, {
    int limit = 100,
    int offset = 0,
  }) => request('/api/user/playlist', {
    'uid': uid,
    'limit': limit,
    'offset': offset,
    'includeVideo': true,
  }, crypto: Crypto.weapi);

  Future<Map<String, dynamic>> likelist(String uid) =>
      request('/api/song/like/get', {'uid': uid});

  Future<Map<String, dynamic>> like(String id, {bool like = true}) => request(
    '/api/radio/like',
    {'alg': 'itembased', 'trackId': id, 'like': like, 'time': '3'},
    crypto: Crypto.weapi,
  );

  Future<Map<String, dynamic>> djSublist({int limit = 100, int offset = 0}) =>
      request('/api/djradio/get/subed', {
        'limit': limit,
        'offset': offset,
        'total': true,
      }, crypto: Crypto.weapi);

  Future<Map<String, dynamic>> userAudio(String uid) =>
      request('/api/djradio/get/byuser', {'userId': uid}, crypto: Crypto.weapi);

  Future<Map<String, dynamic>> djProgram(
    String radioId, {
    int limit = 50,
    int offset = 0,
  }) => request('/api/dj/program/byradio', {
    'radioId': radioId,
    'limit': limit,
    'offset': offset,
    'asc': false,
  }, crypto: Crypto.weapi);

  Future<Map<String, dynamic>> djProgramDetail(String id) =>
      request('/api/dj/program/detail', {'id': id}, crypto: Crypto.weapi);

  Future<Map<String, dynamic>> lyric(String id) => request('/api/song/lyric', {
    'id': id,
    'tv': -1,
    'lv': -1,
    'rv': -1,
    'kv': -1,
    '_nmclfl': 1,
  });

  Future<Map<String, dynamic>> simiSong(String id, {int limit = 50}) => request(
    '/api/v1/discovery/simiSong',
    {'songid': id, 'limit': limit, 'offset': 0},
    crypto: Crypto.weapi,
  );

  Future<Map<String, dynamic>> songSimiGet(String id) =>
      request('/api/link/position/show/resource', {
        'positionCode': 'toolBarRcmdSong',
        'resourceId': id,
        'resourceType': 'song',
      });

  Future<Map<String, dynamic>> intelligenceList({
    required String id,
    required String pid,
    String? sid,
    int count = 50,
  }) => request('/api/playmode/intelligence/list', {
    'songId': id,
    'type': 'fromPlayOne',
    'playlistId': pid,
    'startMusicId': sid ?? id,
    'count': count,
  });

  Future<Map<String, dynamic>> playlistCreate(String name) => request(
    '/api/playlist/create',
    {'name': name, 'privacy': '10', 'type': 'NORMAL'},
    crypto: Crypto.weapi,
  );

  /// 收藏歌单需要易盾反作弊令牌（与上游 playlist_subscribe 相同，请求体不带固定令牌）。
  Future<Map<String, dynamic>> playlistSubscribe(
    String id, {
    required bool subscribed,
  }) => request(
    '/api/playlist/${subscribed ? 'subscribe' : 'unsubscribe'}',
    {'id': id},
    checkToken: true,
  );

  Future<Map<String, dynamic>> playlistAddTracks(
    String pid,
    String track,
  ) async {
    final body = {
      'op': 'add',
      'pid': pid,
      'trackIds': jsonEncode([track]),
      'imme': 'true',
    };
    try {
      return await request('/api/playlist/manipulate/tracks', body);
    } on NeteaseError catch (error) {
      if (!error.message.contains('512')) rethrow;
      return request('/api/playlist/manipulate/tracks', {
        ...body,
        'trackIds': jsonEncode([track, track]),
      });
    }
  }

  /// 这首歌各音质档位的详情；没有的档位为 null（l/m/h/sq/hr…）。
  Future<Map<String, dynamic>> musicDetail(String id) =>
      request('/api/song/music/detail/get', {'songId': id});

  /// 歌曲链接；[level] 为 standard/higher/exhigh/lossless/hires。
  /// 账号没有对应权限时网易云自行降级，返回里的 `level` 是实际档位。
  Future<List<dynamic>> songUrls(
    Iterable<String> ids, {
    String level = 'exhigh',
  }) async {
    final list = ids.toList();
    final body = await request('/api/song/enhance/player/url/v1', {
      'ids': jsonEncode(list),
      'level': level,
      'encodeType': 'flac',
    });
    final data = (body['data'] as List? ?? []).toList();
    data.sort(
      (a, b) =>
          list.indexOf('${a['id']}').compareTo(list.indexOf('${b['id']}')),
    );
    return data;
  }

  /// 收听上报：只发送单条真实事件，不批量、不伪造。
  Future<void> feedback({
    required String songId,
    required String action,
    required String origin,
    String? sourceId,
    int seconds = 0,
    bool completed = false,
  }) async {
    final source = {
      'playlist': 'list',
      'intelligence': 'list',
      'album': 'album',
      'search': 'search',
      'fm': 'radio',
    }[origin];
    final json = {
      'id': songId,
      'type': 'song',
      'mainsite': '1',
      'mainsiteWeb': '1',
      'source': ?source,
      if (sourceId != null) ...{
        'sourceId': sourceId,
        'content': 'id=$sourceId',
      },
      if (action == 'play') ...{
        'download': 0,
        'wifi': 0,
        'time': seconds,
        'end': completed ? 'playend' : 'interrupt',
      },
    };
    await request('/api/feedback/weblog', {
      'logs': jsonEncode([
        {'action': action, 'json': json},
      ]),
    }, crypto: Crypto.weapi);
  }

  void close() => _http.close(force: true);
}
