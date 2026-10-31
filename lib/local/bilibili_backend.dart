// B 站模式的本地后端：搜索、取链、红心、歌单、订阅与登录，数据只存本机。
// 与网易云部分共用 [LocalBackend] 的路由入口（/bilibili/*）和队列存储。
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../bilibili/client.dart';
import '../bilibili/sources.dart';
import '../bilibili/title_rules.dart';
import '../sync/docs.dart';

/// 路由层错误；由 [LocalBackend] 转成统一的接口错误。
class BiliRouteError implements Exception {
  const BiliRouteError(this.code, this.message, [this.status = 400]);
  final String code, message;
  final int status;
}

Never _fail(int status, String code, String message) =>
    throw BiliRouteError(code, message, status);

typedef BiliJson = Map<String, dynamic>;

class BilibiliBackend {
  BilibiliBackend(this.prefs, this.client) : docs = LocalDocs(prefs);
  final SharedPreferences prefs;

  /// 红心、歌单、订阅的存储与同步格式（逐条带修改时间与删除标记）。
  final LocalDocs docs;
  final BilibiliClient client;
  late final BiliSourceFetcher _fetcher = BiliSourceFetcher(client);

  static const _accountKey = 'bili.account';

  /// 本次运行里见过的歌曲，详情接口优先用它，避免重复请求。
  final Map<String, BiliJson> _known = {};
  final Set<String> _refreshing = {};

  String _revisionOf(String id) =>
      '${_playlists.firstWhere((l) => l['id'] == id)['revision']}';

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(9999)}';

  // ---- 存储 ----

  int get _now => DateTime.now().millisecondsSinceEpoch;

  /// 红心：未删除的，新红心在前。
  List<BiliJson> get _hearts {
    final live =
        docs
            .hearts()
            .values
            .cast<BiliJson>()
            .where((h) => h['del'] != true)
            .toList()
          ..sort((a, b) => tsOf(b).compareTo(tsOf(a)));
    return [for (final h in live) (h['song'] as Map).cast<String, dynamic>()];
  }

  /// 红心写回：只改有变化的条目；去掉的留下墓碑。
  Future<void> _writeHearts(List<BiliJson> list) async {
    final table = docs.hearts();
    final ids = {for (final song in list) _idOf(song)};
    final now = _now;
    for (final song in list) {
      final id = _idOf(song);
      final old = table[id] as Map?;
      if (old == null || old['del'] == true) {
        table[id] = {'ts': now, 'del': false, 'song': song};
      }
    }
    for (final id in table.keys.toList()) {
      final old = (table[id] as Map).cast<String, dynamic>();
      if (old['del'] != true && !ids.contains(id)) {
        table[id] = {'ts': now, 'del': true, 'song': old['song']};
      }
    }
    await docs.writeHearts(table);
  }

  static String _revision(BiliJson record) {
    var latest = tsOf(record);
    for (final item in (record['items'] as Map? ?? {}).values) {
      latest = max(latest, tsOf(item as Map));
    }
    return '$latest';
  }

  /// 歌单：未删除的，歌曲按 order 排列；revision 取歌单与各曲目的最新修改时间。
  List<BiliJson> get _playlists {
    final result = <BiliJson>[];
    final all = docs.playlists().entries.toList()
      ..sort((a, b) => tsOf(b.value as Map).compareTo(tsOf(a.value as Map)));
    for (final entry in all) {
      final record = (entry.value as Map).cast<String, dynamic>();
      if (record['del'] == true) continue;
      final items =
          (record['items'] as Map? ?? {}).values
              .cast<BiliJson>()
              .where((i) => i['del'] != true)
              .toList()
            ..sort(
              (a, b) => ((a['order'] as num?) ?? 0).compareTo(
                (b['order'] as num?) ?? 0,
              ),
            );
      result.add({
        'id': entry.key,
        'name': record['name'],
        'description': record['description'] ?? '',
        'revision': _revision(record),
        'tracks': [
          for (final i in items) (i['song'] as Map).cast<String, dynamic>(),
        ],
      });
    }
    return result;
  }

  /// 歌单写回：新建、改名、增删与重排只更新受影响的记录。
  Future<void> _writePlaylists(List<BiliJson> lists) async {
    final table = docs.playlists();
    final now = _now;
    final keep = <String>{};
    for (final list in lists) {
      final id = '${list['id']}';
      keep.add(id);
      final tracks = (list['tracks'] as List).cast<BiliJson>();
      final old = (table[id] as Map?)?.cast<String, dynamic>();
      final record = old == null || old['del'] == true
          ? <String, dynamic>{
              'ts': now,
              'del': false,
              'items': <String, dynamic>{},
            }
          : LocalDocs.copy(old);
      if (record['name'] != list['name'] ||
          (record['description'] ?? '') != (list['description'] ?? '')) {
        record
          ..['ts'] = now
          ..['name'] = list['name']
          ..['description'] = list['description'] ?? '';
      }
      final items = (record['items'] as Map).cast<String, dynamic>();
      final wanted = <String>{};
      for (var i = 0; i < tracks.length; i++) {
        final sid = _idOf(tracks[i]);
        wanted.add(sid);
        final item = (items[sid] as Map?)?.cast<String, dynamic>();
        if (item == null || item['del'] == true || item['order'] != i) {
          items[sid] = {'ts': now, 'del': false, 'order': i, 'song': tracks[i]};
        }
      }
      for (final sid in items.keys.toList()) {
        final item = (items[sid] as Map).cast<String, dynamic>();
        if (item['del'] != true && !wanted.contains(sid)) {
          items[sid] = {...item, 'ts': now, 'del': true};
        }
      }
      record['items'] = items;
      table[id] = record;
    }
    for (final id in table.keys.toList()) {
      final old = (table[id] as Map).cast<String, dynamic>();
      if (old['del'] != true && !keep.contains(id)) {
        table[id] = {...old, 'ts': now, 'del': true};
      }
    }
    await docs.writePlaylists(table);
  }

  /// 订阅：未删除的，新订阅在前。
  List<BiliJson> get _subs {
    final all = docs.subs().entries.toList()
      ..sort((a, b) => tsOf(b.value as Map).compareTo(tsOf(a.value as Map)));
    return [
      for (final entry in all)
        if ((entry.value as Map)['del'] != true)
          {...(entry.value as Map).cast<String, dynamic>(), 'id': entry.key},
    ];
  }

  static const _subMeta = [
    'name',
    'customName',
    'type',
    'input',
    'source',
    'cover',
  ];

  /// 订阅写回：元信息变化更新 ts，歌曲列表变化更新 tracksTs。
  Future<void> _writeSubs(List<BiliJson> subs) async {
    final table = docs.subs();
    final now = _now;
    final keep = <String>{};
    for (final sub in subs) {
      final id = '${sub['id']}';
      keep.add(id);
      final old = (table[id] as Map?)?.cast<String, dynamic>();
      final fresh = old == null || old['del'] == true;
      final record = fresh ? <String, dynamic>{'ts': now} : LocalDocs.copy(old);
      var metaChanged = fresh;
      for (final key in _subMeta) {
        if (jsonEncode(record[key]) != jsonEncode(sub[key])) {
          record[key] = sub[key];
          metaChanged = true;
        }
      }
      if (metaChanged) record['ts'] = now;
      record['del'] = false;
      if (fresh || jsonEncode(record['tracks']) != jsonEncode(sub['tracks'])) {
        record['tracks'] = sub['tracks'];
        record['tracksTs'] = now;
      }
      record['updatedAt'] = sub['updatedAt'];
      table[id] = record;
    }
    for (final id in table.keys.toList()) {
      final old = (table[id] as Map).cast<String, dynamic>();
      if (old['del'] != true && !keep.contains(id)) {
        // 删除订阅后不再需要它的歌曲，墓碑只保留元信息。
        table[id] = {
          ...old,
          'ts': now,
          'del': true,
          'tracks': <dynamic>[],
          'tracksTs': now,
        };
      }
    }
    await docs.writeSubs(table);
  }

  void _remember(Iterable<BiliJson> songs) {
    for (final song in songs) {
      _known['${song['bvid']}:${song['cid']}'] = song;
    }
  }

  // ---- 展示 ----

  /// 最近一次出现在搜索结果里的歌曲；详情与队列沿用同样的歌名。
  final Set<String> _fromSearch = {};

  String _idOf(BiliJson song) => '${song['bvid']}:${song['cid']}';

  /// 展示用的歌名：开启歌名识别时从标题里取出真正的歌名，原标题另存在 rawTitle。
  String _name(BiliJson song, {bool search = false}) {
    final title = '${song['title']}';
    return TitleRules.of(
          prefs,
          search: search,
        )?.parse(title, '${song['artistId'] ?? ''}') ??
        title;
  }

  /// 列表与详情共用的歌曲展示字段。
  BiliJson _view(BiliJson song, {bool? favorite, bool search = false}) {
    final id = _idOf(song);
    return {
      'id': id,
      'title': _name(song, search: search || _fromSearch.contains(id)),
      'rawTitle': song['title'],
      'artists': [if ('${song['artist'] ?? ''}'.isNotEmpty) song['artist']],
      'artistId': song['artistId'],
      'album': song['album'] ?? '',
      'coverUrl': song['cover'],
      'duration': song['duration'] ?? 0,
      'favorite': favorite ?? _hearts.any((h) => _idOf(h) == id),
      'available': true,
    };
  }

  /// 展示过的歌曲都记住：之后取消红心、加入歌单时还能按 id 找回。
  List<BiliJson> _views(List<BiliJson> songs, {bool search = false}) {
    _remember(songs);
    for (final song in songs) {
      search ? _fromSearch.add(_idOf(song)) : _fromSearch.remove(_idOf(song));
    }
    final hearts = _hearts.map(_idOf).toSet();
    return [
      for (final song in songs)
        _view(song, favorite: hearts.contains(_idOf(song)), search: search),
    ];
  }

  BiliJson _slice(List<BiliJson> items, BiliJson input, {int max = 500}) {
    final offset = int.tryParse('${input['offset']}') ?? 0;
    final limit = (int.tryParse('${input['limit']}') ?? 100).clamp(1, max);
    final end = min(items.length, offset + limit);
    return {
      'items': offset >= items.length
          ? <BiliJson>[]
          : items.sublist(offset, end),
      'total': items.length,
    };
  }

  static const _recentKey = 'bili.recent';

  /// 最近播放过的歌曲：搜索结果、未订阅的来源里的歌不在任何本地列表里，
  /// 重启后靠这里找回，才能接着播放。
  List<BiliJson> get _recent {
    final raw = prefs.getString(_recentKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).cast<BiliJson>();
    } catch (_) {
      return [];
    }
  }

  Future<void> _rememberPlayed(BiliJson song) async {
    final id = _idOf(song);
    final list = [song, ..._recent.where((x) => _idOf(x) != id)];
    await prefs.setString(_recentKey, jsonEncode(list.take(50).toList()));
  }

  /// 本地找不到时联网取这个视频的信息补上（例如旧版本留下的播放进度）。
  Future<void> _ensure(String id) async {
    try {
      _song(id);
      return;
    } on BiliRouteError {
      // 本地没有，继续联网查。
    }
    final bvid = id.split(':').first;
    final cid = int.tryParse(id.split(':').last) ?? 0;
    final songs = await client.videoSongs(bvid);
    final match =
        songs.where((x) => x.cid == cid).firstOrNull ??
        (cid == 0 ? songs.firstOrNull : null);
    if (match != null) _known[id] = match.toJson();
  }

  BiliJson _song(String id) {
    final known = _known[id];
    if (known != null) return known;
    for (final list in [_hearts, _playlistSongs, _subSongs, _recent]) {
      for (final song in list) {
        if (_idOf(song) == id) return song;
      }
    }
    _fail(404, 'TRACK_NOT_FOUND', '找不到这首歌曲，请重新搜索或刷新订阅。');
  }

  Iterable<BiliJson> get _playlistSongs sync* {
    for (final list in _playlists) {
      yield* (list['tracks'] as List).cast<BiliJson>();
    }
  }

  Iterable<BiliJson> get _subSongs sync* {
    for (final sub in _subs) {
      yield* (sub['tracks'] as List).cast<BiliJson>();
    }
  }

  // ---- 路由 ----

  Future<dynamic> handle(
    String method,
    List<String> segments,
    BiliJson input,
  ) async {
    try {
      return await _route(method, segments, input);
    } on BilibiliError catch (error) {
      throw BiliRouteError(error.code, error.message, error.status);
    }
  }

  Future<dynamic> _route(String method, List<String> s, BiliJson input) async {
    if (s.isEmpty) _fail(404, 'NOT_FOUND', '接口不存在。');
    switch (s.first) {
      case 'tracks':
        if (s.length == 1) return _search(input);
        final id = Uri.decodeComponent(s[1]);
        if (s.length == 2) return _view(await _detail(id));
        if (s[2] == 'favorite')
          return _setFavorite(id, input['favorite'] == true);
        if (s[2] == 'audio') return _audio(id);
        if (s[2] == 'sources') {
          return {'items': await client.videoSources(id.split(':').first)};
        }
        break;
      case 'sources':
        if (s.length == 2 && s[1] == 'preview') return _preview(input);
        break;
      case 'favorites':
        final all = _hearts;
        return _slice(_views(all), input);
      case 'playlists':
        return _playlistsRoute(method, s, input);
      case 'subscriptions':
        return _subscriptionsRoute(method, s, input);
      case 'account':
        return _account();
      case 'auth':
        return _auth(s.skip(1).toList(), input);
    }
    _fail(404, 'NOT_FOUND', '接口不存在。');
  }

  // ---- 搜索与详情 ----

  /// 在已订阅的内容里按原视频名搜索：每个空格分隔的词都要出现（不分大小写），
  /// 同时查标题、UP 主和合集名。不请求 B 站，搜的是本机保存的原标题。
  List<BiliJson> _searchSubscriptions(String q) {
    final terms = q
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty);
    final seen = <String>{};
    final found = <BiliJson>[];
    for (final sub in _subs) {
      for (final song
          in (sub['tracks'] as List? ?? const []).cast<BiliJson>()) {
        final text =
            '${song['title']} ${song['artist'] ?? ''} ${song['album'] ?? ''}'
                .toLowerCase();
        if (terms.every(text.contains) && seen.add(_idOf(song)))
          found.add(song);
      }
    }
    return found;
  }

  Future<BiliJson> _search(BiliJson input) async {
    final q = '${input['q'] ?? ''}'.trim();
    if (q.isEmpty) return {'items': <BiliJson>[], 'total': 0};
    if (input['scope'] == 'subscriptions') {
      return _slice(_views(_searchSubscriptions(q)), input);
    }
    final offset = int.tryParse('${input['offset']}') ?? 0;
    final page = offset ~/ 20 + 1;
    final result = await client.search(q, page: page);
    final songs = [for (final song in result.songs) song.toJson()];
    _remember(songs);
    return {
      'items': _views(songs, search: true),
      'total': result.total,
      'pageSize': result.pageSize,
    };
  }

  Future<BiliJson> _detail(String id) async {
    await _ensure(id);
    return _song(id);
  }

  Future<BiliJson> _setFavorite(String id, bool favorite) async {
    await _ensure(id);
    final song = _song(id);
    final hearts = _hearts.where((h) => _idOf(h) != id).toList();
    if (favorite) hearts.insert(0, song);
    await _writeHearts(hearts);
    return {'favorite': favorite};
  }

  Future<BiliJson> _audio(String id) async {
    await _ensure(id);
    final song = _song(id);
    unawaited(_rememberPlayed(song));
    var cid = (song['cid'] as num).toInt();
    final bvid = '${song['bvid']}';
    if (cid == 0) cid = await client.cidOf(bvid);
    final audio = await client.audioUrl(bvid, cid);
    return {
      'url': audio.url,
      'headers': audio.headers,
      'codec': audio.codec,
      'bandwidth': audio.bandwidth,
    };
  }

  // ---- 歌单（本地） ----

  Future<dynamic> _playlistsRoute(
    String method,
    List<String> s,
    BiliJson input,
  ) async {
    final lists = _playlists;
    if (s.length == 1) {
      if (method == 'POST') {
        final name = '${input['name'] ?? ''}'.trim();
        if (name.isEmpty) _fail(400, 'INVALID_NAME', '请输入歌单名称。');
        for (final id in (input['trackIds'] as List? ?? const [])) {
          await _ensure('$id');
        }
        final tracks = <BiliJson>[
          for (final id in (input['trackIds'] as List? ?? const []))
            _song('$id'),
        ];
        final item = <String, dynamic>{
          'id': _newId(),
          'name': name,
          'description': '${input['description'] ?? ''}',
          'revision': _newId(),
          'tracks': tracks,
        };
        await _writePlaylists([item, ...lists]);
        return {'id': item['id'], 'revision': _revisionOf('${item['id']}')};
      }
      final items = [
        for (final list in lists)
          {
            'id': list['id'],
            'name': list['name'],
            'trackCount': (list['tracks'] as List).length,
            'coverUrl': (list['tracks'] as List).isEmpty
                ? null
                : ((list['tracks'] as List).first as Map)['cover'],
          },
      ];
      return _slice(items.cast<BiliJson>(), input, max: 200);
    }
    final id = s[1];
    final index = lists.indexWhere((l) => l['id'] == id);
    if (index < 0) _fail(404, 'PLAYLIST_NOT_FOUND', '歌单不存在。');
    final list = lists[index];
    final tracks = (list['tracks'] as List).cast<BiliJson>();
    if (s.length == 2) {
      if (method == 'PUT') {
        if ('${input['revision']}' != '${list['revision']}') {
          _fail(409, 'PLAYLIST_CHANGED', '歌单已在别处修改，请重新载入。');
        }
        final name = '${input['name'] ?? ''}'.trim();
        if (name.isEmpty) _fail(400, 'INVALID_NAME', '请输入歌单名称。');
        for (final tid in (input['trackIds'] as List? ?? const [])) {
          await _ensure('$tid');
        }
        list
          ..['name'] = name
          ..['description'] = '${input['description'] ?? ''}'
          ..['tracks'] = [
            for (final tid in (input['trackIds'] as List? ?? const []))
              _song('$tid'),
          ]
          ..['revision'] = _newId();
        await _writePlaylists(lists);
        return {'id': id, 'revision': _revisionOf(id)};
      }
      final page = _slice(_views(tracks), input, max: 500);
      return {
        ...page,
        'name': list['name'],
        'description': list['description'],
        'revision': list['revision'],
        'unavailableCount': 0,
      };
    }
    if (s[2] == 'tracks' && method == 'POST') {
      final tid = '${input['trackId']}';
      await _ensure(tid);
      final song = _song(tid);
      final exists = tracks.any((t) => _idOf(t) == tid);
      if (!exists) {
        list
          ..['tracks'] = [...tracks, song]
          ..['revision'] = _newId();
        await _writePlaylists(lists);
      }
      return {'added': !exists};
    }
    if (s[2] == 'archive' && method == 'POST') {
      lists.removeAt(index);
      await _writePlaylists(lists);
      return {'ok': true};
    }
    _fail(404, 'NOT_FOUND', '接口不存在。');
  }

  // ---- 订阅（本地存储，按需刷新） ----

  /// 刚浏览过的来源内容先留在内存里：预览后马上添加订阅不必重新取一遍。
  final Map<String, ({DateTime at, BiliSourceContent content})> _previews = {};

  Future<BiliSourceContent> _content(BiliSource source) async {
    final key = jsonEncode(source.toJson());
    final hit = _previews[key];
    if (hit != null &&
        DateTime.now().difference(hit.at) < const Duration(minutes: 10)) {
      return hit.content;
    }
    final content = await _fetcher.fetch(source);
    _previews[key] = (at: DateTime.now(), content: content);
    if (_previews.length > 6) _previews.remove(_previews.keys.first);
    return content;
  }

  /// 预览一个来源（不订阅）：歌曲分页、名称与类型，以及是否已订阅。
  Future<BiliJson> _preview(BiliJson input) async {
    final source = await _parse('${input['input'] ?? ''}'.trim());
    final content = await _content(source);
    final key = jsonEncode(source.toJson());
    final owned = _subs.where((sub) => jsonEncode(sub['source']) == key);
    return {
      ..._slice(_views([for (final s in content.songs) s.toJson()]), input),
      'name': content.name,
      'cover': content.cover,
      'typeLabel': source.type.label,
      'subscribedId': owned.isEmpty ? null : owned.first['id'],
    };
  }

  BiliJson _subView(BiliJson sub) => {
    'id': sub['id'],
    'name': sub['name'],
    'type': sub['type'],
    'typeLabel': BiliSourceType.values
        .firstWhere((t) => t.name == sub['type'])
        .label,
    'source': sub['input'],
    'trackCount': (sub['tracks'] as List).length,
    'coverUrl': sub['cover'],
    'updatedAt': sub['updatedAt'],
  };

  Future<BiliSource> _parse(String text) async {
    final expanded = await expandBiliShortLink(text);
    final source = parseBiliSource(expanded);
    if (source == null) {
      _fail(400, 'UNSUPPORTED_SOURCE', '无法识别这个来源。可以粘贴合集、系列、收藏夹、UP 主主页或视频的链接。');
    }
    return source;
  }

  Future<dynamic> _subscriptionsRoute(
    String method,
    List<String> s,
    BiliJson input,
  ) async {
    final subs = _subs;
    if (s.length == 1) {
      if (method == 'POST') {
        final text = '${input['input'] ?? ''}'.trim();
        if (text.isEmpty) _fail(400, 'INVALID_SOURCE', '请粘贴订阅的链接或编号。');
        final source = await _parse(text);
        // 同一来源不重复订阅。
        final key = jsonEncode(source.toJson());
        if (subs.any((sub) => jsonEncode(sub['source']) == key)) {
          _fail(409, 'ALREADY_SUBSCRIBED', '已经订阅过这个来源。');
        }
        final content = await _content(source);
        final songs = [for (final song in content.songs) song.toJson()];
        final custom = '${input['name'] ?? ''}'.trim();
        final sub = <String, dynamic>{
          'id': _newId(),
          'name': custom.isEmpty ? content.name : custom,
          'customName': custom.isNotEmpty,
          'type': source.type.name,
          'input': text,
          'source': source.toJson(),
          'cover': content.cover,
          'tracks': songs,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        };
        _remember(songs);
        await _writeSubs([sub, ...subs]);
        return _subView(sub);
      }
      return _slice([for (final sub in subs) _subView(sub)], input, max: 500);
    }
    final id = s[1];
    final index = subs.indexWhere((sub) => sub['id'] == id);
    if (index < 0) _fail(404, 'SUBSCRIPTION_NOT_FOUND', '订阅不存在。');
    final sub = subs[index];
    if (s.length == 3 && s[2] == 'tracks') {
      final tracks = (sub['tracks'] as List).cast<BiliJson>();
      _remember(tracks);
      return {
        ..._slice(_views(tracks), input, max: 500),
        'name': sub['name'],
        'updatedAt': sub['updatedAt'],
      };
    }
    if (s.length == 3 && s[2] == 'delete' && method == 'POST') {
      subs.removeAt(index);
      await _writeSubs(subs);
      return {'ok': true};
    }
    if (s.length == 3 && s[2] == 'refresh' && method == 'POST') {
      if (!_refreshing.add('$id')) {
        _fail(409, 'REFRESHING', '正在刷新这个订阅。');
      }
      try {
        final content = await _fetcher.fetch(
          BiliSource.fromJson(sub['source'])!,
        );
        final songs = [for (final song in content.songs) song.toJson()];
        _remember(songs);
        // 重新读取，避免刷新期间对订阅列表的其他修改被覆盖。
        final fresh = _subs;
        final at = fresh.indexWhere((x) => x['id'] == id);
        if (at < 0) return {'ok': true};
        fresh[at]
          ..['tracks'] = songs
          ..['cover'] = content.cover.isEmpty
              ? fresh[at]['cover']
              : content.cover
          ..['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
        if (fresh[at]['customName'] != true && content.name.isNotEmpty) {
          fresh[at]['name'] = content.name;
        }
        await _writeSubs(fresh);
        return _subView(fresh[at]);
      } finally {
        _refreshing.remove('$id');
      }
    }
    if (s.length == 2 && method == 'PUT') {
      // 编辑：改名，或换成新的来源（会重新取回内容）。
      final name = '${input['name'] ?? ''}'.trim();
      final text = '${input['input'] ?? ''}'.trim();
      if (text.isNotEmpty && text != sub['input']) {
        final source = await _parse(text);
        final content = await _fetcher.fetch(source);
        final songs = [for (final song in content.songs) song.toJson()];
        _remember(songs);
        sub
          ..['input'] = text
          ..['type'] = source.type.name
          ..['source'] = source.toJson()
          ..['tracks'] = songs
          ..['cover'] = content.cover
          ..['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
        if (sub['customName'] != true) sub['name'] = content.name;
      }
      if (name.isNotEmpty && name != sub['name']) {
        sub
          ..['name'] = name
          ..['customName'] = true;
      }
      await _writeSubs(subs);
      return _subView(sub);
    }
    if (s.length == 2) return _subView(sub);
    _fail(404, 'NOT_FOUND', '接口不存在。');
  }

  // ---- 账号 ----

  Future<BiliJson> _account() async {
    if (!client.loggedIn) return {'loggedIn': false};
    try {
      final info = await client.account();
      if (info == null) {
        client.logout();
        await prefs.remove(_accountKey);
        return {'loggedIn': false, 'expired': true};
      }
      final value = {
        'loggedIn': true,
        'name': info.name,
        'avatar': info.avatar,
        'mid': info.mid,
        'vip': info.vip,
      };
      await prefs.setString(_accountKey, jsonEncode(value));
      return value;
    } on BilibiliError {
      // 网络不通时沿用上次记下的资料，不把已有登录当作失效。
      final saved = prefs.getString(_accountKey);
      if (saved != null)
        return {...jsonDecode(saved) as BiliJson, 'offline': true};
      rethrow;
    }
  }

  Future<dynamic> _auth(List<String> s, BiliJson input) async {
    if (s.isNotEmpty && s.first == 'qr') {
      if (s.length == 1) {
        final qr = await client.qrGenerate();
        return {'url': qr.url, 'key': qr.key, 'expiresIn': 180};
      }
      final code = await client.qrPoll('${input['key']}');
      if (code == 0) return {'code': 0, 'account': await _account()};
      return {'code': code};
    }
    if (s.isNotEmpty && s.first == 'logout') {
      client.logout();
      await prefs.remove(_accountKey);
      return {'ok': true};
    }
    _fail(404, 'NOT_FOUND', '接口不存在。');
  }

  // ---- 队列 ----

  /// 按浏览上下文建立播放队列：整份列表（收藏、歌单、订阅）或搜索结果。
  /// 返回队列条目与所选歌曲的位置。
  Future<({List<BiliJson> items, int index})> queueFor(
    BiliJson context,
    String selectedId,
  ) async {
    final kind = '${context['kind']}';
    final id = '${context['id'] ?? ''}';
    List<BiliJson> songs;
    var searching = false;
    switch (kind) {
      case 'favorites':
        songs = _hearts;
      case 'playlist':
        final list = _playlists.where((l) => l['id'] == id).firstOrNull;
        songs = list == null ? [] : (list['tracks'] as List).cast<BiliJson>();
      case 'subscription':
        final sub = _subs.where((x) => x['id'] == id).firstOrNull;
        songs = sub == null ? [] : (sub['tracks'] as List).cast<BiliJson>();
      case 'source':
        songs = (await _content(
          await _parse(id),
        )).songs.map((s) => s.toJson()).toList();
      default:
        final q = '${context['q'] ?? ''}'.trim();
        final inSubs = context['scope'] == 'subscriptions';
        searching = !inSubs;
        songs = q.isEmpty
            ? []
            : inSubs
            ? _searchSubscriptions(q)
            : [for (final s in (await client.search(q)).songs) s.toJson()];
    }
    _remember(songs);
    if (searching) {
      _fromSearch.addAll(songs.map(_idOf));
    }
    var index = songs.indexWhere((song) => _idOf(song) == selectedId);
    if (index < 0) {
      // 所选歌曲不在上下文里（例如列表刚刷新）：只播放这一首。
      await _ensure(selectedId);
      songs = [_song(selectedId)];
      index = 0;
    }
    return (
      items: [
        for (final song in songs)
          {
            'id': _idOf(song),
            'mode': 'bilibili',
            'title': _name(song, search: _fromSearch.contains(_idOf(song))),
          },
      ],
      index: index,
    );
  }
}
