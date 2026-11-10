// 网易云协议客户端：移植自 api-enhanced 的 util/request.js 与 module/*，
// 由用户自己的账号直接请求网易云，不经过任何自建服务器。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as hash;

import '../core/diag.dart';
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
  NeteaseClient({
    Map<String, String>? cookie,
    this.onCookie,
    this.antiCheat,
    this.vipCookie,
    this.onVipExpired,
    this.eapiHost = 'https://interfacepc.music.163.com',
    this.weapiHost = 'https://music.163.com',
  }) : cookie = {...?cookie} {
    this.cookie.putIfAbsent('deviceId', () => _newDeviceId);
  }

  /// 登录态 Cookie（MUSIC_U、__csrf、NMTID、deviceId 等），由会话持久化。
  final Map<String, String> cookie;
  final void Function(Map<String, String> cookie)? onCookie;

  /// 定制版：取链用的账号 Cookie（来自定制服务）。为 null 时取链沿用自己的账号。
  final Map<String, String>? Function()? vipCookie;

  /// 取链账号被网易云判为失效时调用，用来向定制服务重新拉取。
  final Future<void> Function()? onVipExpired;

  /// 接口主机；只有测试会改。
  final String eapiHost, weapiHost;

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
  Map<String, String> _processed(Crypto crypto, Map<String, String> source) => {
    ...source,
    '__remember_me': 'true',
    'ntes_kaola_ad': '1',
    for (final entry in _os.entries)
      entry.key: source[entry.key] ?? entry.value,
    if (source['NMTID'] == null && crypto == Crypto.weapi)
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

    /// 不按业务码判失败，原样返回（登录需要读 8821、502 等码和提示）。
    bool lenient = false,

    /// 只对这一次请求改用另一份 Cookie（取链账号）；响应里的 Set-Cookie 不写回本机会话。
    Map<String, String>? cookieOverride,

    /// 只读请求遇到 -460（网易云风控偶发拦截）时稍等后再试，最多再试 [_riskRetries] 次。
    bool retryRisk = false,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final json = await _requestOnce(
        uri,
        data,
        crypto: crypto,
        checkToken: checkToken,
        cookieOverride: cookieOverride,
      );
      final code = (json['code'] as num?)?.toInt();
      // 与 request.js 的 SPECIAL_STATUS_CODES 一致：这些业务码不算失败。
      const special = {200, 201, 302, 400, 502, 800, 801, 802, 803};
      if (lenient || code == null || special.contains(code)) return json;
      final retry = retryRisk && code == -460 && attempt < _riskRetries.length;
      Diag.log(
        'netease $uri code=$code crypto=${crypto.name} '
        'vip=${cookieOverride != null} attempt=${attempt + 1}'
        '${retry ? ' retrying' : ''}',
      );
      if (retry) {
        await Future<void>.delayed(_riskRetries[attempt]);
        continue;
      }
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
  }

  /// -460 后的等待时间；测试会改短。
  static List<Duration> _riskRetries = const [
    Duration(milliseconds: 600),
    Duration(milliseconds: 1500),
  ];
  static set riskRetriesForTest(List<Duration> value) => _riskRetries = value;

  Future<Map<String, dynamic>> _requestOnce(
    String uri,
    Map<String, Object?> data, {
    required Crypto crypto,
    required bool checkToken,
    Map<String, String>? cookieOverride,
  }) async {
    final token = checkToken ? await antiCheat?.call() ?? '' : '';
    final c = _processed(crypto, cookieOverride ?? cookie);
    final body = <String, Object?>{...data, 'e_r': false};
    final Uri url;
    final headers = <String, String>{};
    final Map<String, String> form;
    if (crypto == Crypto.weapi) {
      url = Uri.parse('$weapiHost/weapi/${uri.substring(5)}');
      headers['Referer'] = weapiHost;
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
      url = Uri.parse('$eapiHost/eapi/${uri.substring(5)}');
      headers['User-Agent'] = _eapiUa;
      headers['Cookie'] = _join(header);
      body['header'] = header;
      form = enc.eapi(uri, body);
    }
    final text = await _post(url, headers, form, save: cookieOverride == null);
    final Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      throw const NeteaseError('NETEASE_UPSTREAM_FAILED', '网易云返回了无法解析的数据。');
    }
    if (json is! Map<String, dynamic>) {
      throw const NeteaseError('NETEASE_UPSTREAM_FAILED', '网易云返回了无法解析的数据。');
    }
    return json;
  }

  Future<String> _post(
    Uri url,
    Map<String, String> headers,
    Map<String, String> form, {
    bool save = true,
  }) async {
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
        if (save) {
          _saveCookies(res.headers[HttpHeaders.setCookieHeader] ?? const []);
        }
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

  /// 向手机发送登录验证码。
  Future<void> sendCaptcha(String phone, {String countryCode = '86'}) async {
    final body = await request(
      '/api/sms/captcha/sent',
      {
        'ctcode': countryCode,
        'secrete': 'music_middleuser_pclogin',
        'cellphone': phone,
      },
      crypto: Crypto.weapi,
      lenient: true,
    );
    if (_code(body) == 200) return;
    throw NeteaseError(
      _isRisk(body) ? loginRisk : 'CAPTCHA_FAILED',
      _loginMessage(body, '验证码发送失败'),
      400,
    );
  }

  /// 手机号登录：[captcha] 有值时用验证码，否则用密码（MD5 后提交）。
  /// 成功后 Cookie 已由 Set-Cookie 写入；失败抛 [NeteaseError]，
  /// 需要安全验证时 code 为 [loginRisk]。
  Future<void> loginCellphone({
    required String phone,
    String? password,
    String? captcha,
    String countryCode = '86',
  }) async {
    final byCode = captcha != null && captcha.isNotEmpty;
    final body = await request(
      '/api/w/login/cellphone',
      {
        'type': '1',
        'https': 'true',
        'phone': phone,
        'countrycode': countryCode,
        if (byCode)
          'captcha': captcha
        else
          'password': hash.md5.convert(utf8.encode(password ?? '')).toString(),
        'remember': 'true',
        'secureCaptcha': '',
      },
      crypto: Crypto.weapi,
      lenient: true,
    );
    if (_code(body) == 200 && loggedIn) return;
    throw NeteaseError(
      _isRisk(body) ? loginRisk : 'LOGIN_FAILED',
      _loginMessage(body, '登录失败'),
      401,
    );
  }

  /// 登录被风控拦下，需要短信验证码。
  static const loginRisk = 'LOGIN_RISK';
  static const _riskCodes = {8821, -462, -460, 10004};
  static int? _code(Map<String, dynamic> body) =>
      (body['code'] as num?)?.toInt();
  static bool _isRisk(Map<String, dynamic> body) =>
      _riskCodes.contains(_code(body));

  static String _loginMessage(Map<String, dynamic> body, String fallback) {
    final code = _code(body);
    if (_isRisk(body)) return '需要安全验证，请改用短信验证码。';
    final text = '${body['message'] ?? body['msg'] ?? ''}'.trim();
    return switch (code) {
      501 => '账号不存在。',
      502 => '手机号或密码错误。',
      503 => '验证码错误或已过期。',
      509 => '密码错误次数过多，请稍后再试或改用验证码。',
      _ => text.isEmpty ? '$fallback（${code ?? '未知'}）。' : text,
    };
  }

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
    retryRisk: true,
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

  /// 推荐歌单（公开接口，不登录也能用）；游客的“推荐”页用它代替需要账号的个性化推荐。
  /// 返回与 [recommendResource] 相同的形状：`{code, recommend: [{id, name, picUrl, trackCount}]}`。
  Future<Map<String, dynamic>> personalizedPlaylists({int limit = 30}) async {
    final body = await request('/api/personalized/playlist', {
      'limit': limit,
      'total': true,
      'n': 1000,
    }, crypto: Crypto.weapi);
    return {
      'code': 200,
      'recommend': [
        for (final item in (body['result'] as List? ?? const []))
          if (item is Map)
            {
              'id': item['id'],
              'name': item['name'],
              'picUrl': item['picUrl'],
              'trackCount': item['trackCount'],
            },
      ],
    };
  }

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
  }) => request('/api/playlist/${subscribed ? 'subscribe' : 'unsubscribe'}', {
    'id': id,
  }, checkToken: true);

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
      request('/api/song/music/detail/get', {'songId': id}, retryRisk: true);

  /// 歌曲链接；[level] 为 standard/higher/exhigh/lossless/hires。
  /// 账号没有对应权限时网易云自行降级，返回里的 `level` 是实际档位。
  Future<List<dynamic>> songUrls(
    Iterable<String> ids, {
    String level = 'exhigh',
  }) async {
    final list = ids.toList();
    Future<Map<String, dynamic>> fetch(Map<String, String>? vip) => request(
      '/api/song/enhance/player/url/v1',
      {'ids': jsonEncode(list), 'level': level, 'encodeType': 'flac'},
      retryRisk: true,
      cookieOverride: vip == null
          ? null
          : {...vip, 'deviceId': cookie['deviceId']!},
    );
    final vip = vipCookie?.call();
    final Map<String, dynamic> body;
    if (vip == null) {
      body = await fetch(null);
    } else {
      Map<String, dynamic>? got;
      try {
        got = await fetch(vip);
      } on NeteaseError catch (e) {
        if (e.code != 'NETEASE_SESSION_EXPIRED') rethrow;
      }
      if (got == null) {
        // 取链账号失效：向定制服务取一次最新的再试；仍不行就退回使用者自己的账号。
        await onVipExpired?.call();
        final fresh = vipCookie?.call();
        if (fresh != null && fresh['MUSIC_U'] != vip['MUSIC_U']) {
          try {
            got = await fetch(fresh);
          } on NeteaseError catch (e) {
            if (e.code != 'NETEASE_SESSION_EXPIRED') rethrow;
          }
        }
      }
      body = got ?? await fetch(null);
    }
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
