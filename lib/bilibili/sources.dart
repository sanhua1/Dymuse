// B 站订阅来源：把用户粘贴的链接/编号解析成“来源”，再分页取回其中的视频。
// 移植自 azusa-player-mobile 的 mediafetch（合集、系列、收藏夹、订阅合集、UP 主投稿、单个视频）。
import 'dart:io';

import 'client.dart';

/// 订阅来源类型。
enum BiliSourceType {
  collection('合集'),
  series('系列'),
  favorite('收藏夹'),
  season('订阅的合集'),
  uploads('UP 主投稿'),
  video('单个视频');

  const BiliSourceType(this.label);
  final String label;
}

/// 一个可订阅的来源：类型加定位参数（mid/sid/bvid 等）。
class BiliSource {
  const BiliSource(this.type, this.params);
  final BiliSourceType type;
  final Map<String, String> params;

  Map<String, dynamic> toJson() => {'type': type.name, 'params': params};
  static BiliSource? fromJson(Object? json) {
    if (json is! Map) return null;
    final type = BiliSourceType.values
        .where((t) => t.name == json['type'])
        .firstOrNull;
    final params = json['params'];
    if (type == null || params is! Map) return null;
    return BiliSource(type, {
      for (final e in params.entries) '${e.key}': '${e.value}',
    });
  }
}

/// 取回的来源内容。
class BiliSourceContent {
  const BiliSourceContent(this.name, this.cover, this.songs);
  final String name, cover;
  final List<BiliSong> songs;
}

/// 从文本里认出订阅来源；认不出返回 null。支持 b23.tv 短链（需联网展开，见 [expand]）。
BiliSource? parseBiliSource(String input) {
  final text = input.trim();
  RegExpMatch? m;
  // 订阅的合集：favlist?fid=…&ftype=collect
  m = RegExp(r'favlist\?[^#]*?fid=(\d+)[^#]*?ftype=collect').firstMatch(text);
  if (m != null) {
    return BiliSource(BiliSourceType.season, {'sid': m.group(1)!});
  }
  m = RegExp(r'favlist\?[^#]*?fid=(\d+)').firstMatch(text);
  if (m != null) {
    return BiliSource(BiliSourceType.favorite, {'mediaId': m.group(1)!});
  }
  final mid = RegExp(r'space\.bilibili\.com/(\d+)').firstMatch(text)?.group(1);
  m = RegExp(r'collectiondetail\?[^#]*?sid=(\d+)').firstMatch(text);
  if (m != null && mid != null) {
    return BiliSource(BiliSourceType.collection, {
      'mid': mid,
      'sid': m.group(1)!,
    });
  }
  m = RegExp(r'seriesdetail\?[^#]*?sid=(\d+)').firstMatch(text);
  if (m != null && mid != null) {
    return BiliSource(BiliSourceType.series, {'mid': mid, 'sid': m.group(1)!});
  }
  m = RegExp(r'(BV[0-9A-Za-z]{10})').firstMatch(text);
  if (m != null) {
    return BiliSource(BiliSourceType.video, {'bvid': m.group(1)!});
  }
  if (mid != null) {
    return BiliSource(BiliSourceType.uploads, {'mid': mid});
  }
  return null;
}

/// 展开 b23.tv 短链（只读取重定向地址，不下载内容）。
Future<String> expandBiliShortLink(String input) async {
  final link = RegExp(r'https?://b23\.tv/[0-9A-Za-z]+').firstMatch(input);
  if (link == null) return input;
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await http.getUrl(Uri.parse(link.group(0)!));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.userAgentHeader, BilibiliClient.userAgent);
    final response = await request.close().timeout(const Duration(seconds: 10));
    await response.drain<void>();
    final location = response.headers.value(HttpHeaders.locationHeader);
    return location ?? input;
  } catch (_) {
    return input;
  } finally {
    http.close(force: true);
  }
}

String _https(Object? url) {
  final text = '${url ?? ''}';
  if (text.isEmpty) return '';
  return text.startsWith('//')
      ? 'https:$text'
      : text.replaceFirst('http://', 'https://');
}

int _int(Object? value) {
  if (value is num) return value.toInt();
  final parts = '$value'.split(':').map((p) => int.tryParse(p) ?? 0);
  return parts.fold(0, (sum, part) => sum * 60 + part);
}

/// 每次取回的视频先去重（同一个 BV 只留一份），cid 留空到播放时再补。
class BiliSourceFetcher {
  BiliSourceFetcher(this.client);
  final BilibiliClient client;

  /// 一个来源最多取回的视频数，防止误订阅超大频道拖垮请求与存储。
  static const limit = 2000;

  Future<BiliSourceContent> fetch(
    BiliSource source, {
    void Function(int done, int total)? onProgress,
  }) async {
    final p = source.params;
    switch (source.type) {
      case BiliSourceType.video:
        final songs = await client.videoSongs(p['bvid']!);
        return BiliSourceContent(
          songs.isEmpty ? p['bvid']! : songs.first.album,
          songs.isEmpty ? '' : songs.first.cover,
          songs,
        );
      case BiliSourceType.collection:
        return _paged(
          onProgress,
          pageSize: 100,
          page: (n) => client.get(
            '/x/polymer/web-space/seasons_archives_list',
            {
              'mid': p['mid']!,
              'season_id': p['sid']!,
              'page_num': n,
              'page_size': 100,
              'sort_reverse': 'false',
            },
            withLogin: client.loggedIn,
          ),
          items: (d) => d['archives'],
          total: (d) => _int((d['page'] as Map?)?['total']),
          name: (d) => '${(d['meta'] as Map?)?['name'] ?? '合集 ${p['sid']}'}',
          cover: (d) => _https((d['meta'] as Map?)?['cover']),
          song: (item, d) => _archive(item as Map, p['mid'] ?? ''),
        );
      case BiliSourceType.series:
        final meta = await client.get('/x/series/series', {
          'series_id': p['sid']!,
        });
        final info = (meta['data'] as Map?)?['meta'] as Map? ?? const {};
        final content = await _paged(
          onProgress,
          pageSize: 100,
          page: (n) => client.get('/x/series/archives', {
            'mid': p['mid']!,
            'series_id': p['sid']!,
            'pn': n,
            'ps': 100,
            'only_normal': 'true',
            'sort': 'desc',
          }, withLogin: client.loggedIn),
          items: (d) => d['archives'],
          total: (d) => _int((d['page'] as Map?)?['total']),
          name: (d) => '${info['name'] ?? '系列 ${p['sid']}'}',
          cover: (d) => '',
          song: (item, d) => _archive(item as Map, p['mid'] ?? ''),
        );
        return content;
      case BiliSourceType.favorite:
        return _paged(
          onProgress,
          pageSize: 20,
          page: (n) => client.get('/x/v3/fav/resource/list', {
            'media_id': p['mediaId']!,
            'pn': n,
            'ps': 20,
            'platform': 'web',
          }, withLogin: client.loggedIn),
          items: (d) => d['medias'],
          total: (d) => _int((d['info'] as Map?)?['media_count']),
          name: (d) =>
              '${(d['info'] as Map?)?['title'] ?? '收藏夹 ${p['mediaId']}'}',
          cover: (d) => _https((d['info'] as Map?)?['cover']),
          song: (item, d) => _media(item as Map),
        );
      case BiliSourceType.season:
        return _paged(
          onProgress,
          pageSize: 20,
          page: (n) => client.get('/x/space/fav/season/list', {
            'season_id': p['sid']!,
            'pn': n,
            'ps': 20,
          }, withLogin: client.loggedIn),
          items: (d) => d['medias'],
          total: (d) => _int((d['info'] as Map?)?['media_count']),
          name: (d) => '${(d['info'] as Map?)?['title'] ?? '合集 ${p['sid']}'}',
          cover: (d) => _https((d['info'] as Map?)?['cover']),
          song: (item, d) => _media(item as Map),
        );
      case BiliSourceType.uploads:
        final card = await client.get('/x/web-interface/card', {
          'mid': p['mid']!,
        });
        final owner = ((card['data'] as Map?)?['card'] as Map?) ?? const {};
        return _paged(
          onProgress,
          pageSize: 50,
          wbi: true,
          pageWbi: (n) => client.wbiGet('/x/space/wbi/arc/search', {
            'mid': p['mid']!,
            'pn': n,
            'ps': 50,
            'order': 'pubdate',
          }, withLogin: client.loggedIn),
          items: (d) => (d['list'] as Map?)?['vlist'],
          total: (d) => _int((d['page'] as Map?)?['count']),
          name: (d) => '${owner['name'] ?? 'UP ${p['mid']}'} 的投稿',
          cover: (d) => _https(owner['face']),
          song: (item, d) {
            final m = item as Map;
            return BiliSong(
              bvid: '${m['bvid']}',
              cid: 0,
              title: '${m['title']}',
              artist: '${m['author'] ?? owner['name'] ?? ''}',
              artistId: '${m['mid'] ?? p['mid']}',
              cover: _https(m['pic']),
              duration: _int(m['length']),
              album: '${m['title']}',
            );
          },
        );
    }
  }

  BiliSong _archive(Map m, String mid) => BiliSong(
    bvid: '${m['bvid']}',
    cid: 0,
    title: '${m['title']}',
    artist: '',
    artistId: mid,
    cover: _https(m['pic']),
    duration: _int(m['duration']),
    album: '${m['title']}',
  );

  BiliSong _media(Map m) {
    final upper = m['upper'] as Map? ?? const {};
    return BiliSong(
      bvid: '${m['bvid'] ?? m['bv_id']}',
      cid: 0,
      title: '${m['title']}'.replaceAll(RegExp(r'<[^<>]*>'), ''),
      artist: '${upper['name'] ?? ''}',
      artistId: '${upper['mid'] ?? ''}',
      cover: _https(m['cover']),
      duration: _int(m['duration']),
      album: '${m['title']}'.replaceAll(RegExp(r'<[^<>]*>'), ''),
    );
  }

  Future<BiliSourceContent> _paged(
    void Function(int done, int total)? onProgress, {
    required int pageSize,
    Future<Map<String, dynamic>> Function(int page)? page,
    Future<Map<String, dynamic>> Function(int page)? pageWbi,
    bool wbi = false,
    required Object? Function(Map d) items,
    required int Function(Map d) total,
    required String Function(Map d) name,
    required String Function(Map d) cover,
    required BiliSong Function(Object? item, Map d) song,
  }) async {
    final seen = <String>{};
    final songs = <BiliSong>[];
    var title = '', picture = '', expected = 0;
    for (var n = 1; ; n++) {
      final json = await (wbi ? pageWbi! : page!)(n);
      final d = (json['data'] as Map?) ?? const {};
      if (n == 1) {
        title = name(d);
        picture = cover(d);
        expected = total(d);
      }
      final list = (items(d) as List?) ?? const [];
      for (final item in list) {
        if (item is! Map) continue;
        final entry = song(item, d);
        // 失效视频没有标题或 BV，直接跳过；同一个 BV 只留一份。
        if (entry.bvid.isEmpty ||
            entry.bvid == 'null' ||
            entry.title == '已失效视频') {
          continue;
        }
        if (seen.add(entry.bvid)) songs.add(entry);
      }
      onProgress?.call(songs.length, expected);
      if (list.isEmpty ||
          songs.length >= limit ||
          (expected > 0 && n * pageSize >= expected)) {
        break;
      }
    }
    return BiliSourceContent(title, picture, songs);
  }
}
