// B 站协议客户端：移植自 azusa-player-mobile 的 utils/mediafetch/*，
// 由用户自己的网络直接请求 B 站，不经过任何自建服务器。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'wbi.dart';

class BilibiliError implements Exception {
  const BilibiliError(this.code, this.message, [this.status = 502]);
  final String code;
  final String message;
  final int status;
  @override
  String toString() => message;
}

/// 一首“歌”：视频的一个分 P。歌曲 id 为 `bvid:cid`。
class BiliSong {
  const BiliSong({
    required this.bvid,
    required this.cid,
    required this.title,
    required this.artist,
    required this.artistId,
    required this.cover,
    required this.duration,
    this.album = '',
    this.page = 1,
  });
  final String bvid, title, artist, artistId, cover, album;
  final int cid, duration, page;

  String get id => '$bvid:$cid';
  Map<String, dynamic> toJson() => {
    'bvid': bvid,
    'cid': cid,
    'title': title,
    'artist': artist,
    'artistId': artistId,
    'cover': cover,
    'duration': duration,
    'album': album,
    'page': page,
  };
}

/// 取到的音频直链；播放时必须带 [headers]（Referer），否则 CDN 拒绝。
class BiliAudio {
  const BiliAudio(this.url, this.headers, {this.codec, this.bandwidth});
  final String url;
  final Map<String, String> headers;
  final String? codec;
  final int? bandwidth;
}

class BilibiliClient {
  BilibiliClient({Map<String, String>? cookie, this.onCookie})
    : cookie = {...?cookie};

  /// 登录态 Cookie（SESSDATA、bili_jct 等），由会话持久化。
  final Map<String, String> cookie;
  final void Function(Map<String, String> cookie)? onCookie;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 30);

  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0';
  static const referer = 'https://www.bilibili.com/';
  static const _api = 'https://api.bilibili.com';

  /// B 站对请求频率敏感（412/风控），请求之间保持最小间隔。
  static const _minGap = Duration(milliseconds: 350);
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _gate = Future.value();

  String? _imgKey, _subKey;
  String? _buvid;

  bool get loggedIn => (cookie['SESSDATA'] ?? '').isNotEmpty;

  /// 串行排队并保证间隔。
  Future<T> _throttled<T>(Future<T> Function() run) {
    final turn = _gate.then((_) async {
      final wait = _minGap - DateTime.now().difference(_last);
      if (!wait.isNegative) await Future<void>.delayed(wait);
      try {
        return await run();
      } finally {
        _last = DateTime.now();
      }
    });
    _gate = turn.then((_) {}, onError: (_) {});
    return turn;
  }

  String get _cookieHeader {
    final all = {
      if (_buvid != null) 'buvid3': _buvid!,
      for (final key in const [
        'SESSDATA',
        'bili_jct',
        'DedeUserID',
        'DedeUserID__ckMd5',
        'sid',
        'buvid3',
      ])
        if (cookie[key] != null) key: cookie[key]!,
    };
    return all.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Future<Map<String, dynamic>> _getJson(
    String url, {
    bool withLogin = false,
    List<Cookie>? setCookies,
  }) => _throttled(() async {
    try {
      final req = await _http.getUrl(Uri.parse(url));
      try {
        req.headers
          ..set(HttpHeaders.userAgentHeader, userAgent)
          ..set(HttpHeaders.refererHeader, referer)
          ..set(HttpHeaders.acceptHeader, 'application/json');
        final cookies = withLogin
            ? _cookieHeader
            : (_buvid == null ? '' : 'buvid3=$_buvid');
        if (cookies.isNotEmpty)
          req.headers.set(HttpHeaders.cookieHeader, cookies);
        final res = await req.close().timeout(const Duration(seconds: 15));
        setCookies?.addAll(res.cookies);
        final text = await utf8.decodeStream(res);
        if (res.statusCode == 412) {
          throw const BilibiliError(
            'BILIBILI_RATE_LIMITED',
            'B 站暂时限制了请求，请稍后再试。',
            429,
          );
        }
        if (res.statusCode != 200) {
          throw BilibiliError(
            'BILIBILI_UPSTREAM_FAILED',
            'B 站暂时不可用（HTTP ${res.statusCode}），请稍后重试。',
          );
        }
        final json = jsonDecode(text);
        if (json is! Map<String, dynamic>) {
          throw const BilibiliError(
            'BILIBILI_UPSTREAM_FAILED',
            'B 站返回了无法解析的数据。',
          );
        }
        return json;
      } finally {
        req.abort();
      }
    } on TimeoutException {
      throw const BilibiliError('TIMEOUT', '连接 B 站超时，请检查网络后重试。');
    } on SocketException {
      throw const BilibiliError('NETWORK', '无法连接 B 站，请检查网络。');
    } on HandshakeException {
      throw const BilibiliError('NETWORK', '与 B 站建立安全连接失败，请检查网络。');
    } on HttpException {
      throw const BilibiliError('NETWORK', '网络连接中断，请重试。');
    }
  });

  /// 取最新的 WBI key；未登录时 nav 返回 -101，但 wbi_img 仍在。
  Future<void> _refreshKeys() async {
    final json = await _getJson('$_api/x/web-interface/nav', withLogin: true);
    final img = (json['data'] as Map?)?['wbi_img'] as Map?;
    String name(String? url) {
      final file = (url ?? '').split('/').last;
      return file.contains('.')
          ? file.substring(0, file.lastIndexOf('.'))
          : file;
    }

    _imgKey = name(img?['img_url'] as String?);
    _subKey = name(img?['sub_url'] as String?);
    if ((_imgKey ?? '').length < 32 || (_subKey ?? '').length < 32) {
      throw const BilibiliError('BILIBILI_UPSTREAM_FAILED', '无法取得 B 站签名密钥。');
    }
  }

  /// 带 WBI 签名的 GET；密钥失效（-403/-799/-352）时刷新后重试一次。
  Future<Map<String, dynamic>> wbiGet(
    String path,
    Map<String, Object?> params, {
    bool withLogin = false,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_imgKey == null) await _refreshKeys();
      final query = signWbi(params, imgKey: _imgKey!, subKey: _subKey!);
      final json = await _getJson('$_api$path?$query', withLogin: withLogin);
      final code = (json['code'] as num?)?.toInt() ?? 0;
      if (code == 0) return json;
      if (attempt == 0 && const {-403, -799, -352, -400}.contains(code)) {
        _imgKey = null;
        continue;
      }
      throw _upstream(code, json['message']);
    }
    throw const BilibiliError('BILIBILI_UPSTREAM_FAILED', 'B 站请求失败，请稍后重试。');
  }

  Future<Map<String, dynamic>> get(
    String path,
    Map<String, Object?> params, {
    bool withLogin = false,
  }) async {
    final query = Uri(
      queryParameters: {for (final e in params.entries) e.key: '${e.value}'},
    ).query;
    final json = await _getJson(
      '$_api$path${query.isEmpty ? '' : '?$query'}',
      withLogin: withLogin,
    );
    final code = (json['code'] as num?)?.toInt() ?? 0;
    if (code != 0) throw _upstream(code, json['message']);
    return json;
  }

  BilibiliError _upstream(int code, Object? message) {
    if (code == -101) {
      return const BilibiliError(
        'BILIBILI_SESSION_EXPIRED',
        'B 站登录已失效，请重新登录。',
        401,
      );
    }
    if (code == -412 || code == -509 || code == -799) {
      return const BilibiliError(
        'BILIBILI_RATE_LIMITED',
        'B 站暂时限制了请求，请稍后再试。',
        429,
      );
    }
    return BilibiliError('BILIBILI_UPSTREAM_FAILED', 'B 站请求失败（$code），请稍后重试。');
  }

  /// 未登录搜索需要一个随机的 buvid；取到后复用。
  Future<void> _ensureBuvid() async {
    if (_buvid != null) return;
    final json = await get('/x/frontend/finger/spi', {});
    _buvid = (json['data'] as Map?)?['b_3'] as String?;
  }

  static String _https(String? url) {
    if (url == null || url.isEmpty) return '';
    return url.startsWith('//')
        ? 'https:$url'
        : url.replaceFirst('http://', 'https://');
  }

  static String _plain(String text) => text.replaceAll(RegExp(r'<[^<>]*>'), '');

  /// 搜索视频；每页 20 条，页码从 1 开始。返回的歌曲 cid 为 0（未解析），
  /// 取详情或播放时再用 [cidOf] 补上。
  Future<({List<BiliSong> songs, int total, int pageSize})> search(
    String keyword, {
    int page = 1,
  }) async {
    await _ensureBuvid();
    final json = await wbiGet('/x/web-interface/wbi/search/type', {
      'search_type': 'video',
      'keyword': keyword,
      'page': page,
    }, withLogin: loggedIn);
    final data = json['data'] as Map? ?? const {};
    final items = (data['result'] as List? ?? const []).cast<Map>();
    return (
      songs: [
        for (final item in items)
          BiliSong(
            bvid: '${item['bvid']}',
            cid: 0,
            title: _plain('${item['title']}'),
            artist: '${item['author'] ?? ''}',
            artistId: '${item['mid'] ?? ''}',
            cover: _https(item['pic'] as String?),
            duration: _seconds('${item['duration'] ?? '0'}'),
            album: _plain('${item['title']}'),
          ),
      ],
      total: (data['numResults'] as num?)?.toInt() ?? items.length,
      pageSize: (data['pagesize'] as num?)?.toInt() ?? 20,
    );
  }

  static int _seconds(String text) {
    final parts = text.split(':').map((p) => int.tryParse(p) ?? 0).toList();
    return parts.fold(0, (sum, part) => sum * 60 + part);
  }

  /// 一个视频能跳转到的订阅来源：所属合集、多 P 视频本身、UP 主投稿。
  /// 每项带 `label`（显示名）、`typeLabel`（类型）和 `input`（添加订阅时能解析的链接或编号）。
  /// B 站的视频详情不返回“系列”，所以系列无法从视频反查。
  Future<List<Map<String, String>>> videoSources(String bvid) async {
    final json = await wbiGet('/x/web-interface/wbi/view/detail', {
      'bvid': bvid,
    });
    final view = (json['data'] as Map?)?['View'] as Map?;
    if (view == null) {
      throw const BilibiliError('BILIBILI_UPSTREAM_FAILED', '视频信息不可用。');
    }
    final owner = view['owner'] as Map? ?? const {};
    final season = view['ugc_season'] as Map?;
    final pages = (view['pages'] as List? ?? const []).length;
    final mid = '${owner['mid'] ?? ''}';
    return [
      if (season != null && '${season['id']}'.isNotEmpty)
        {
          'typeLabel': '合集',
          'label': '${season['title']}',
          'input':
              'https://space.bilibili.com/${season['mid'] ?? mid}/channel/collectiondetail?sid=${season['id']}',
        },
      if (pages > 1)
        {
          'typeLabel': '多 P 视频',
          'label': '${view['title']}（$pages P）',
          'input': bvid,
        },
      if (mid.isNotEmpty)
        {
          'typeLabel': 'UP 主投稿',
          'label': '${owner['name'] ?? mid}',
          'input': 'https://space.bilibili.com/$mid',
        },
    ];
  }

  /// 视频详情：每个分 P 一首歌。
  Future<List<BiliSong>> videoSongs(String bvid) async {
    final json = await wbiGet('/x/web-interface/wbi/view/detail', {
      'bvid': bvid,
    });
    final view = (json['data'] as Map?)?['View'] as Map?;
    if (view == null) {
      throw const BilibiliError('BILIBILI_UPSTREAM_FAILED', '视频信息不可用。');
    }
    final pages = (view['pages'] as List? ?? const []).cast<Map>();
    final owner = view['owner'] as Map? ?? const {};
    final title = '${view['title']}';
    return [
      for (var i = 0; i < pages.length; i++)
        BiliSong(
          bvid: '${view['bvid']}',
          cid: (pages[i]['cid'] as num).toInt(),
          title: pages.length == 1 ? title : '${pages[i]['part']}',
          artist: '${owner['name'] ?? ''}',
          artistId: '${owner['mid'] ?? ''}',
          cover: _https(view['pic'] as String?),
          duration: (pages[i]['duration'] as num?)?.toInt() ?? 0,
          album: title,
          page: i + 1,
        ),
    ];
  }

  /// baseUrl 常是不稳定的 PCDN（mcdn、非标准端口）；优先用备用地址里的正规 upos 节点。
  static String? _bestUrl(Map? stream) {
    if (stream == null) return null;
    final all = <String>[
      for (final key in const ['baseUrl', 'base_url'])
        if (stream[key] is String) stream[key] as String,
      for (final key in const ['backupUrl', 'backup_url'])
        ...((stream[key] as List?) ?? const []).whereType<String>(),
    ];
    bool regular(String url) {
      final uri = Uri.tryParse(url);
      return uri != null &&
          uri.host.endsWith('.bilivideo.com') &&
          !uri.host.contains('mcdn') &&
          (!uri.hasPort || uri.port == 443 || uri.port == 80);
    }

    for (final url in all) {
      if (regular(url)) return url;
    }
    return all.isEmpty ? null : all.first;
  }

  Future<int> cidOf(String bvid) async {
    final json = await get('/x/player/pagelist', {'bvid': bvid});
    final pages = json['data'] as List? ?? const [];
    if (pages.isEmpty)
      throw const BilibiliError('BILIBILI_UPSTREAM_FAILED', '视频没有可播放的分 P。');
    return ((pages.first as Map)['cid'] as num).toInt();
  }

  /// 取音频直链：dash 里码率最高的一条；有无损（flac）或杜比则优先。
  Future<BiliAudio> audioUrl(String bvid, int cid) async {
    final json = await wbiGet('/x/player/wbi/playurl', {
      'bvid': bvid,
      'cid': cid,
      'qn': 64,
      'fnval': 4048,
      'fourk': 1,
    }, withLogin: loggedIn);
    final data = json['data'] as Map? ?? const {};
    final dash = data['dash'] as Map?;
    const headers = {'Referer': referer, 'User-Agent': userAgent};
    if (dash != null) {
      Map? best(List? list) {
        final items = (list ?? const []).cast<Map>().toList()
          ..sort(
            (a, b) => ((b['bandwidth'] as num?) ?? 0).compareTo(
              (a['bandwidth'] as num?) ?? 0,
            ),
          );
        return items.isEmpty ? null : items.first;
      }

      final flac = (dash['flac'] as Map?)?['audio'] as Map?;
      final dolby = ((dash['dolby'] as Map?)?['audio'] as List?)?.cast<Map>();
      final picked = flac ?? best(dolby) ?? best(dash['audio'] as List?);
      final url = _bestUrl(picked);
      if (url is String && url.isNotEmpty) {
        return BiliAudio(
          url,
          headers,
          codec: picked?['codecs'] as String?,
          bandwidth: (picked?['bandwidth'] as num?)?.toInt(),
        );
      }
    }
    final durl = (data['durl'] as List?)?.cast<Map>();
    final fallback = durl == null || durl.isEmpty ? null : durl.first['url'];
    if (fallback is String && fallback.isNotEmpty)
      return BiliAudio(fallback, headers);
    throw const BilibiliError('PLAYBACK_UNAVAILABLE', '这个视频暂时无法取得音频。');
  }

  // ---- 账号 ----

  /// 扫码登录（网页端）：返回二维码内容与轮询用的 key。
  Future<({String url, String key})> qrGenerate() async {
    final json = await _getJson(
      'https://passport.bilibili.com/x/passport-login/web/qrcode/generate',
    );
    final data = json['data'] as Map?;
    final url = data?['url'], key = data?['qrcode_key'];
    if (url is! String || key is! String) {
      throw const BilibiliError('BILIBILI_UPSTREAM_FAILED', '无法生成 B 站登录二维码。');
    }
    return (url: url, key: key);
  }

  /// 登录成功后要保存的 Cookie 名。
  static const loginCookies = [
    'SESSDATA',
    'bili_jct',
    'DedeUserID',
    'DedeUserID__ckMd5',
    'sid',
  ];

  /// 从响应的 Set-Cookie 和回包里的跨域地址（旧版接口把 Cookie 放在它的查询串里）取出登录 Cookie。
  static Map<String, String> loginCookiesFrom(
    List<Cookie> cookies,
    String url,
  ) {
    final found = <String, String>{};
    for (final name in loginCookies) {
      final m = RegExp('[?&]$name=([^&]+)').firstMatch(url);
      if (m != null) found[name] = m.group(1)!;
    }
    // Set-Cookie 里的值优先（它才是服务器这次真正下发的）。
    for (final cookie in cookies) {
      if (loginCookies.contains(cookie.name) && cookie.value.isNotEmpty) {
        found[cookie.name] = cookie.value;
      }
    }
    return found;
  }

  /// 轮询扫码：86101 未扫码、86090 已扫码待确认、86038 已过期、0 成功。
  /// 成功时把登录 Cookie 写入 [cookie] 并通知持久化。
  Future<int> qrPoll(String key) async {
    final cookies = <Cookie>[];
    final json = await _getJson(
      'https://passport.bilibili.com/x/passport-login/web/qrcode/poll'
      '?qrcode_key=${Uri.encodeQueryComponent(key)}',
      setCookies: cookies,
    );
    final data = json['data'] as Map? ?? const {};
    final code = (data['code'] as num?)?.toInt() ?? -1;
    if (code != 0) return code;
    final found = loginCookiesFrom(cookies, '${data['url'] ?? ''}');
    if ((found['SESSDATA'] ?? '').isEmpty) {
      throw const BilibiliError('BILIBILI_UPSTREAM_FAILED', 'B 站没有返回登录凭证。');
    }
    cookie
      ..clear()
      ..addAll(found);
    onCookie?.call(cookie);
    return 0;
  }

  /// 当前登录的账号资料；未登录或登录失效返回 null。
  Future<({String name, String avatar, String mid, bool vip})?>
  account() async {
    if (!loggedIn) return null;
    final json = await _getJson('$_api/x/web-interface/nav', withLogin: true);
    final data = json['data'] as Map?;
    if (data == null || data['isLogin'] != true) return null;
    return (
      name: '${data['uname'] ?? ''}',
      avatar: _https(data['face'] as String?),
      mid: '${data['mid'] ?? ''}',
      vip: ((data['vipStatus'] as num?)?.toInt() ?? 0) == 1,
    );
  }

  void logout() {
    cookie.clear();
    onCookie?.call(cookie);
  }

  void close() => _http.close(force: true);
}
