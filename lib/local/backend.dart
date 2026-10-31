// 本地后端：把原 Dymuse 服务的 /api/v1 接口在手机内实现一遍。
// 数据只存本机，账号就是当前登录的网易云账号。
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../netease/client.dart';
import 'bilibili_backend.dart';

class LocalError implements Exception {
  const LocalError(this.code, this.message, [this.status = 400]);
  final String code;
  final String message;
  final int status;
  @override
  String toString() => message;
}

Never _fail(int status, String code, String message) =>
    throw LocalError(code, message, status);

String _id() =>
    '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(999999)}';

class _Snapshot {
  _Snapshot(this.generation, this.revision, this.state, this.updatedAt);
  final String generation;
  final int revision;
  final Map<String, dynamic> state;
  final int updatedAt;
  Map<String, dynamic> get json => {
    'generation': generation,
    'revision': revision,
    'state': state,
    'updatedAt': updatedAt,
  };
}

/// 队列状态（单账号、单设备）与收听记录的本地实现。
class LocalBackend {
  LocalBackend(this.prefs, this.client, this.bili);

  final SharedPreferences prefs;
  final NeteaseClient client;
  final BilibiliBackend bili;

  static const _queueKey = 'aio.queue';
  static const _biliQueueKey = 'aio.queue.bilibili';
  static String _queueKeyOf(String mode) =>
      mode == 'bilibili' ? _biliQueueKey : _queueKey;
  static const _listeningKey = 'aio.listening';
  static const _profileKey = 'aio.profile';

  // ---- 账号 ----

  Map<String, dynamic>? get profile {
    final raw = prefs.getString(_profileKey);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// 用当前 Cookie 查询账号并缓存；返回是否仍然有效。
  Future<Map<String, dynamic>?> refreshAccount() async {
    final body = await client.account();
    final data = (body['data'] as Map?)?.cast<String, dynamic>() ?? body;
    final value = data['profile'] as Map?;
    if ((data['code'] as num?)?.toInt() != 200 || value == null) {
      await prefs.remove(_profileKey);
      return null;
    }
    final result = {
      'userId': '${value['userId']}',
      'nickname': '${value['nickname'] ?? ''}',
      'avatarUrl': '${value['avatarUrl'] ?? ''}',
      'vipType': (value['vipType'] as num?)?.toInt() ?? 0,
    };
    await prefs.setString(_profileKey, jsonEncode(result));
    return result;
  }

  Future<void> signOut() async {
    client.logout();
    await prefs.remove(_profileKey);
    await prefs.remove(_queueKey);
    await prefs.remove(_listeningKey);
  }

  // ---- 路由 ----

  Future<dynamic> handle(
    String method,
    String path,
    Map<String, dynamic>? query,
    Map<String, dynamic>? body,
  ) async {
    final input = <String, dynamic>{...?query, ...?body};
    final segments = path.split('/').where((part) => part.isNotEmpty).toList();
    try {
      return await _route(method, segments, input);
    } on NeteaseError catch (error) {
      throw LocalError(error.code, error.message, error.status);
    } on BiliRouteError catch (error) {
      throw LocalError(error.code, error.message, error.status);
    }
  }

  Future<dynamic> _route(
    String method,
    List<String> segments,
    Map<String, dynamic> input,
  ) async {
    if (segments.isEmpty) _fail(404, 'NOT_FOUND', '接口不存在。');
    switch (segments.first) {
      case 'auth':
        return _auth(method, segments.skip(1).toList(), input);
      case 'account':
        return _account(input);
      case 'search':
        return _search(segments.length > 1 && segments[1] == 'combined', input);
      case 'song':
        if (segments.length > 1 && segments[1] == 'detail') {
          return _songDetail(input);
        }
        if (segments.length > 1 && segments[1] == 'music') {
          return {'code': 200, ...await client.musicDetail(_text(input, 'id'))};
        }
        if (segments.length > 1 && segments[1] == 'url') {
          return _songUrl(input);
        }
        break;
      case 'lyric':
        return client.lyric(_text(input, 'id'));
      case 'album':
        return client.album(_text(input, 'id'));
      case 'artist':
        if (segments.length > 1 && segments[1] == 'songs') {
          return client.artistSongs(
            _text(input, 'id'),
            limit: _int(input, 'limit', 50, 1, 100),
            offset: _int(input, 'offset', 0, 0, 100000),
          );
        }
        if (segments.length > 1 && segments[1] == 'album') {
          return client.artistAlbums(
            _text(input, 'id'),
            limit: _int(input, 'limit', 30, 1, 100),
            offset: _int(input, 'offset', 0, 0, 100000),
          );
        }
        break;
      case 'playlist':
        if (segments.length > 1 && segments[1] == 'page') {
          return _playlistPage(input);
        }
        if (segments.length > 1 && segments[1] == 'catlist') {
          return client.playlistCatlist();
        }
        if (segments.length > 1 && segments[1] == 'create') {
          return client.playlistCreate(_text(input, 'name'));
        }
        break;
      case 'playlists':
        if (segments.length > 1 && segments[1] == 'editable') {
          return _editablePlaylists(input);
        }
        if (segments.length > 2 && segments[2] == 'tracks') {
          return _appendPlaylist(segments[1], _text(input, 'trackId'));
        }
        if (segments.length > 2 && segments[2] == 'subscription') {
          return _subscribePlaylist(segments[1], input['subscribed'] == true);
        }
        break;
      case 'liked':
        if (segments.length > 1 && segments[1] == 'playlist') {
          return {'playlist': await _likedPlaylist()};
        }
        break;
      case 'likelist':
        return client.likelist((profile?['userId'] ?? '').toString());
      case 'like':
        return _like(input);
      case 'toplist':
        return client.toplist();
      case 'top':
        if (segments.length > 1 && segments[1] == 'playlist') {
          return client.topPlaylist(
            cat: '${input['cat'] ?? '全部'}',
            order: '${input['order'] ?? 'hot'}',
            limit: _int(input, 'limit', 50, 1, 100),
            offset: _int(input, 'offset', 0, 0, 100000),
          );
        }
        break;
      case 'recommend':
        if (segments.length > 1 && segments[1] == 'songs') {
          return client.recommendSongs();
        }
        if (segments.length > 1 && segments[1] == 'resource') {
          return client.recommendResource();
        }
        break;
      case 'user':
        if (segments.length > 1 && segments[1] == 'playlist') {
          return client.userPlaylist(
            (profile?['userId'] ?? '').toString(),
            limit: _int(input, 'limit', 100, 1, 100),
            offset: _int(input, 'offset', 0, 0, 100000),
          );
        }
        break;
      case 'podcasts':
        return _podcasts(segments, input);
      case 'listening':
        return _listening(method, segments, input);
      case 'queues':
        return _queues(segments, input);
      case 'playback':
        return _playback(method, segments, input);
      case 'bilibili':
        return bili.handle(method, segments.skip(1).toList(), input);
    }
    _fail(404, 'NOT_FOUND', '接口不存在。');
  }

  String _text(Map<String, dynamic> input, String key) {
    final value = input[key]?.toString() ?? '';
    if (!RegExp(r'^\d{1,20}$').hasMatch(value)) {
      _fail(400, 'INVALID_ID', '网易云 ID 无效。');
    }
    return value;
  }

  int _int(
    Map<String, dynamic> input,
    String key,
    int fallback,
    int min,
    int max,
  ) {
    final value = int.tryParse('${input[key]}') ?? fallback;
    if (value < min) _fail(400, 'INVALID_PARAMETER', '请求参数无效。');
    return value > max ? max : value;
  }

  // ---- 登录 ----

  Map<String, dynamic>? _qr;
  DateTime? _qrExpires;

  Future<dynamic> _auth(
    String method,
    List<String> path,
    Map<String, dynamic> input,
  ) async {
    if (path.isNotEmpty && path[0] == 'qr') {
      if (path.length > 1 && path[1] == 'check') {
        return _checkQr();
      }
      return _createQr();
    }
    _fail(404, 'NOT_FOUND', '接口不存在。');
  }

  Future<Map<String, dynamic>> _createQr() async {
    final current = _qr;
    if (current != null &&
        _qrExpires != null &&
        _qrExpires!.isAfter(DateTime.now()) &&
        ![800, 803].contains(current['code'])) {
      return current;
    }
    final key = await client.qrKey();
    final value = {
      'key': key,
      'url': NeteaseClient.qrUrl(key),
      'code': 801,
      'expiresAt': DateTime.now()
          .add(const Duration(minutes: 3))
          .millisecondsSinceEpoch,
    };
    _qr = value;
    _qrExpires = DateTime.now().add(const Duration(minutes: 3));
    return {'code': 801, 'url': value['url'], 'expiresAt': value['expiresAt']};
  }

  DateTime? _qrChecked;

  Future<Map<String, dynamic>> _checkQr() async {
    final qr = _qr;
    if (qr == null) _fail(409, 'NETEASE_QR_REQUIRED', '请先生成二维码。');
    if (qr['code'] == 803) return {'code': 803, ...await _accountInfo()};
    if ((_qrExpires?.isBefore(DateTime.now()) ?? true)) {
      qr['code'] = 800;
      return {'code': 800, ...await _accountInfo()};
    }
    // 与后端一致：3 秒内复用上一次结果，避免高频轮询。
    final checked = _qrChecked;
    if (checked != null &&
        DateTime.now().difference(checked) < const Duration(seconds: 3)) {
      return {'code': qr['code'], ...await _accountInfo()};
    }
    _qrChecked = DateTime.now();
    final code = await client.qrCheck(qr['key'] as String);
    qr['code'] = code;
    if (code == 803) {
      final value = await refreshAccount();
      if (value == null) {
        qr['code'] = 800;
        _fail(401, 'NETEASE_SESSION_EXPIRED', '网易云登录失败，请重新扫码。');
      }
    }
    return {'code': code, ...await _accountInfo()};
  }

  Future<Map<String, dynamic>> _accountInfo() async {
    final value = profile;
    return {'bound': value != null, 'profile': value};
  }

  Future<dynamic> _account(Map<String, dynamic> input) async {
    if (profile == null && client.loggedIn) {
      final value = await refreshAccount();
      if (value == null)
        _fail(401, 'NETEASE_SESSION_EXPIRED', '网易云登录已失效，请重新登录。');
    }
    return _accountInfo();
  }

  // ---- 浏览 ----

  Future<dynamic> _search(bool combined, Map<String, dynamic> input) async {
    final keywords = '${input['keywords'] ?? ''}'.trim();
    if (keywords.isEmpty) _fail(400, 'INVALID_KEYWORDS', '请输入搜索内容。');
    final limit = combined ? 10 : _int(input, 'limit', 50, 1, 100);
    final offset = _int(input, 'offset', 0, 0, 100000);
    return client.search(
      keywords: keywords,
      type: combined ? 1018 : _int(input, 'type', 1, 0, 2000),
      limit: limit,
      offset: offset,
      combined: combined,
    );
  }

  Future<dynamic> _songDetail(Map<String, dynamic> input) async {
    final ids = '${input['ids'] ?? ''}';
    if (!RegExp(r'^\d{1,20}(,\d{1,20}){0,999}$').hasMatch(ids)) {
      _fail(400, 'INVALID_ID', '网易云 ID 无效。');
    }
    return client.songDetail(ids.split(','));
  }

  static const _levels = {'standard', 'higher', 'exhigh', 'lossless', 'hires'};

  /// 声音直链：按 level 取链（默认极高 320k）；非会员返回试听片段时保持原样，由播放器拒绝缓存。
  Future<dynamic> _songUrl(Map<String, dynamic> input) async {
    final id = _text(input, 'id');
    final level = '${input['level'] ?? 'exhigh'}';
    if (!_levels.contains(level)) _fail(400, 'INVALID_LEVEL', '音质档位无效。');
    final data = await client.songUrls([id], level: level);
    return {'code': 200, 'data': data};
  }

  Future<dynamic> _like(Map<String, dynamic> input) async {
    final id = _text(input, 'id');
    final like = input['like'] != false;
    final body = await client.like(id, like: like);
    return {'code': 200, 'result': body['code'] == 200 || body['code'] == null};
  }

  Future<Map<String, dynamic>> _likedPlaylist() async {
    final account = profile;
    final owner = '${account?['userId'] ?? ''}';
    if (owner.isEmpty) _fail(409, 'NETEASE_SESSION_EXPIRED', '网易云登录已失效，请重新登录。');
    // 喜欢歌单通常在“我的歌单”首页，取一页即可。
    final body = await client.userPlaylist(owner, limit: 1000);
    final list = (body['playlist'] as List? ?? []).cast<Map>();
    final liked = list.where(
      (item) =>
          (item['specialType'] as num?)?.toInt() == 5 &&
          '${item['creator']?['userId']}' == owner,
    );
    if (liked.isEmpty) _fail(404, 'LIKED_PLAYLIST_NOT_FOUND', '未找到我喜欢的音乐歌单。');
    final item = liked.first;
    return {
      'id': '${item['id']}',
      'name': '${item['name'] ?? '我喜欢的音乐'}',
      'coverUrl': item['coverImgUrl'] ?? item['picUrl'],
      'trackCount': (item['trackCount'] as num?)?.toInt() ?? 0,
      'isLiked': true,
    };
  }

  Future<dynamic> _playlistPage(Map<String, dynamic> input) async {
    final id = _text(input, 'id');
    final offset = _int(input, 'offset', 0, 0, 100000);
    final limit = _int(input, 'limit', 100, 1, 100);
    final body = await client.playlistDetail(id);
    final playlist = body['playlist'] as Map?;
    final tracks = playlist?['trackIds'] as List?;
    if (tracks == null) _fail(502, 'INVALID_PLAYLIST_RESPONSE', '歌单曲目列表不可用。');
    final slice = tracks.skip(offset).take(limit).toList();
    final ids = slice.map((item) => '${item['id']}').toList();
    final detail = ids.isEmpty
        ? <String, dynamic>{'songs': <dynamic>[]}
        : await client.songDetail(ids);
    final byId = {
      for (final song in (detail['songs'] as List? ?? []).cast<Map>())
        '${song['id']}': song,
    };
    final items = ids
        .map(
          (songId) =>
              byId[songId] ??
              {'id': songId, 'name': '暂不可用歌曲', 'unavailable': true},
        )
        .toList();
    final next = offset + ids.length;
    final owner = '${profile?['userId'] ?? ''}';
    return {
      'playlist': {
        'id': '${playlist!['id'] ?? id}',
        'name': '${playlist['name'] ?? '歌单'}',
        'coverUrl': playlist['coverImgUrl'] ?? playlist['picUrl'],
        'trackCount': tracks.length,
        'isLiked':
            owner.isNotEmpty &&
            (playlist['specialType'] as num?)?.toInt() == 5 &&
            '${playlist['creator']?['userId']}' == owner,
        'canSubscribe':
            owner.isNotEmpty &&
            playlist['creator']?['userId'] != null &&
            '${playlist['creator']['userId']}' != owner &&
            (playlist['specialType'] as num?)?.toInt() != 5,
        'subscribed': playlist['subscribed'] == true,
      },
      'items': items,
      'total': tracks.length,
      'nextOffset': next < tracks.length ? next : null,
    };
  }

  Future<dynamic> _editablePlaylists(Map<String, dynamic> input) async {
    final offset = _int(input, 'offset', 0, 0, 100000);
    final body = await client.userPlaylist(
      '${profile?['userId'] ?? ''}',
      limit: 100,
      offset: offset,
    );
    final list = (body['playlist'] as List? ?? []).cast<Map>();
    final owner = '${profile?['userId'] ?? ''}';
    final items = list
        .where(
          (item) =>
              '${item['creator']?['userId']}' == owner &&
              (item['specialType'] as num?)?.toInt() != 5,
        )
        .map(
          (item) => {
            'id': '${item['id']}',
            'name': '${item['name'] ?? '未命名歌单'}',
            'coverUrl': item['coverImgUrl'] ?? item['picUrl'],
            'trackCount': (item['trackCount'] as num?)?.toInt() ?? 0,
          },
        )
        .toList();
    return {
      'items': items,
      'nextOffset': body['more'] == true && list.isNotEmpty
          ? offset + list.length
          : null,
    };
  }

  Future<dynamic> _appendPlaylist(String playlistId, String trackId) async {
    final detail = await client.playlistDetail(playlistId);
    final playlist = detail['playlist'] as Map?;
    final owner = '${profile?['userId'] ?? ''}';
    if (playlist == null ||
        '${playlist['creator']?['userId']}' != owner ||
        (playlist['specialType'] as num?)?.toInt() == 5) {
      _fail(403, 'PLAYLIST_NOT_EDITABLE', '只能添加到本人创建的普通歌单。');
    }
    final tracks = playlist['trackIds'] as List?;
    if (tracks == null) _fail(502, 'INVALID_PLAYLIST_RESPONSE', '歌单曲目列表不可用。');
    if (tracks.any((item) => '${item['id']}' == trackId)) {
      return {'added': false};
    }
    final body = await client.playlistAddTracks(playlistId, trackId);
    if ((body['code'] as num?)?.toInt() != 200) {
      _fail(502, 'PLAYLIST_UPDATE_FAILED', '网易云未确认添加成功，请刷新歌单后重试。');
    }
    return {'added': true};
  }

  Future<dynamic> _subscribePlaylist(String playlistId, bool subscribed) async {
    final detail = await client.playlistDetail(playlistId);
    final playlist = detail['playlist'] as Map?;
    final owner = '${profile?['userId'] ?? ''}';
    if (playlist == null ||
        playlist['creator']?['userId'] == null ||
        owner.isEmpty) {
      _fail(502, 'INVALID_PLAYLIST_RESPONSE', '歌单所有者信息不可用。');
    }
    if ('${playlist['creator']['userId']}' == owner ||
        (playlist['specialType'] as num?)?.toInt() == 5) {
      _fail(403, 'PLAYLIST_SUBSCRIBE_FORBIDDEN', '此歌单不能使用收藏操作。');
    }
    if (playlist['subscribed'] == subscribed) return {'subscribed': subscribed};
    final body = await client.playlistSubscribe(
      playlistId,
      subscribed: subscribed,
    );
    if ((body['code'] as num?)?.toInt() != 200) {
      _fail(502, 'PLAYLIST_SUBSCRIBE_FAILED', '网易云未确认收藏状态，请刷新后重试。');
    }
    return {'subscribed': subscribed};
  }

  // ---- 播客 ----

  Map<String, dynamic> _program(Map value, [int offset = 0]) {
    final radio = value['radio'] as Map?;
    if (value['id'] == null || radio?['id'] == null) {
      _fail(502, 'INVALID_PROGRAM_RESPONSE', '节目详情不可用。');
    }
    final mainSong = value['mainSong'] as Map?;
    return {
      'id': '${value['id']}',
      'radioId': '${radio!['id']}',
      'audioId': mainSong?['id'] == null ? null : '${mainSong!['id']}',
      'title': '${value['name'] ?? '未命名节目'}',
      'artist': '${value['dj']?['nickname'] ?? radio['dj']?['nickname'] ?? ''}',
      'album': '${radio['name'] ?? ''}',
      'cover': value['coverUrl'] ?? radio['picUrl'],
      'duration': ((value['duration'] as num?) ?? 0) / 1000,
      'offset': offset,
    };
  }

  Future<Map<String, dynamic>> _podcastPrograms(
    String radioId,
    int offset,
    int limit,
  ) async {
    final body = await client.djProgram(radioId, offset: offset, limit: limit);
    final programs = body['programs'] as List?;
    if (programs == null) _fail(502, 'INVALID_PROGRAM_RESPONSE', '节目列表不可用。');
    final items = <Map<String, dynamic>>[];
    for (var i = 0; i < programs.length; i++) {
      items.add(_program(programs[i] as Map, offset + i));
    }
    if (items.any((item) => item['radioId'] != radioId)) {
      _fail(502, 'INVALID_PROGRAM_RESPONSE', '节目不属于当前播客。');
    }
    final next = offset + items.length;
    final total = (body['count'] as num?)?.toInt() ?? next;
    return {
      'items': items,
      'total': total,
      'nextOffset': items.isNotEmpty && (body['more'] == true || next < total)
          ? next
          : null,
    };
  }

  Future<Map<String, dynamic>> _podcastProgram(String id) async {
    final body = await client.djProgramDetail(id);
    final program = body['program'] as Map?;
    if (program == null) _fail(502, 'INVALID_PROGRAM_RESPONSE', '节目详情不可用。');
    return _program(program);
  }

  Future<dynamic> _podcasts(
    List<String> segments,
    Map<String, dynamic> input,
  ) async {
    if (segments.length == 1) {
      final offset = _int(input, 'offset', 0, 0, 100000);
      final limit = _int(input, 'limit', 50, 1, 100);
      final created = input['kind'] == 'created';
      final body = created
          ? await client.userAudio('${profile?['userId'] ?? ''}')
          : await client.djSublist(limit: limit, offset: offset);
      final radios = body['djRadios'] as List?;
      if (radios == null) _fail(502, 'INVALID_PODCAST_RESPONSE', '播客列表不可用。');
      final raw = (created ? radios.skip(offset).take(limit) : radios)
          .cast<Map>();
      final next = offset + raw.length;
      final total = created
          ? radios.length
          : (body['count'] as num?)?.toInt() ?? next;
      return {
        'items': raw
            .map(
              (radio) => {
                'id': '${radio['id']}',
                'title': '${radio['name'] ?? '未命名播客'}',
                'artist': '${radio['dj']?['nickname'] ?? ''}',
                'cover': radio['picUrl'],
                'programCount': (radio['programCount'] as num?)?.toInt() ?? 0,
              },
            )
            .toList(),
        'total': total,
        'nextOffset':
            raw.isNotEmpty && (body['hasMore'] == true || next < total)
            ? next
            : null,
      };
    }
    if (segments.length > 1 && segments[1] == 'programs') {
      return _podcastPrograms(
        _text(input, 'radioId'),
        _int(input, 'offset', 0, 0, 100000),
        _int(input, 'limit', 50, 1, 100),
      );
    }
    if (segments.length > 1 && segments[1] == 'program') {
      return {'program': await _podcastProgram(_text(input, 'id'))};
    }
    if (segments.length > 1 && segments[1] == 'url') {
      final program = await _podcastProgram(_text(input, 'id'));
      final audioId = program['audioId'];
      if (audioId == null) _fail(422, 'PROGRAM_UNAVAILABLE', '节目音轨暂不可用。');
      final links = await client.songUrls([audioId as String]);
      final link = links.isEmpty ? null : links.first as Map;
      final url = link?['url'];
      final trial = link?['freeTrialInfo'];
      if (url is! String || url.isEmpty || (trial != null && trial != 'null')) {
        _fail(422, 'PROGRAM_UNAVAILABLE', '当前网易云账号无法完整播放此节目。');
      }
      return {'url': url, 'audioId': audioId};
    }
    _fail(404, 'NOT_FOUND', '接口不存在。');
  }

  // ---- 收听上报 ----

  List<Map<String, dynamic>> get _listeningRows {
    final raw = prefs.getString(_listeningKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveListening(List<Map<String, dynamic>> rows) =>
      prefs.setString(_listeningKey, jsonEncode(rows.take(200).toList()));

  Future<dynamic> _listening(
    String method,
    List<String> segments,
    Map<String, dynamic> input,
  ) async {
    if (method == 'GET') {
      return {
        'items': _listeningRows
            .map(
              (row) => {
                'playId': row['playId'],
                'songId': row['songId'],
                'listenedMs': row['listenedMs'] ?? 0,
                'finished': row['finished'] == true,
                'reason': row['reason'],
              },
            )
            .toList(),
      };
    }
    final start = segments.length > 1 && segments[1] == 'start';
    final rows = _listeningRows;
    final playId = '${input['playId'] ?? ''}';
    if (playId.isEmpty) _fail(400, 'INVALID_PLAY_ID', '收听实例无效。');
    final existing = rows.indexWhere((row) => row['playId'] == playId);
    if (start) {
      final songId = _text(input, 'songId');
      final durationMs = _int(input, 'durationMs', 0, 1, 86400000);
      if (existing >= 0) {
        final row = rows[existing];
        if (row['songId'] != songId || row['durationMs'] != durationMs) {
          _fail(409, 'LISTENING_CONFLICT', '收听实例参数不一致。');
        }
        return _summary(row);
      }
      final snapshot = _read('netEase');
      final state = snapshot?.state ?? const <String, dynamic>{};
      final items = (state['items'] as List? ?? []).cast<Map>();
      if (snapshot?.generation != input['generation'] ||
          state['origin'] == 'podcast' ||
          !items.any(
            (item) => item['id'] == songId && item['kind'] != 'podcast',
          )) {
        _fail(409, 'LISTENING_QUEUE_CHANGED', '歌曲已不在当前网易云队列。');
      }
      final row = <String, dynamic>{
        'playId': playId,
        'songId': songId,
        'generation': input['generation'],
        'origin': state['origin'],
        'sourceId': state['playlistId'],
        'durationMs': durationMs,
        'listenedMs': 0,
        'finished': false,
        'startState': 'pending',
        'playState': 'pending',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      };
      rows.insert(0, row);
      await _saveListening(rows);
      return _summary(row);
    }
    if (existing < 0) _fail(404, 'LISTENING_NOT_FOUND', '收听实例不存在。');
    final row = rows[existing];
    if (row['finished'] == true) return _summary(row);
    final listened = _int(input, 'listenedMs', 0, 0, 86400000);
    final finished = input['finished'] == true;
    if (finished && input['reason'] == null) {
      _fail(400, 'LISTENING_REASON_REQUIRED', '结束收听需要原因。');
    }
    row['listenedMs'] = max(
      (row['listenedMs'] as num?)?.toInt() ?? 0,
      listened,
    );
    if (finished) {
      row['finished'] = true;
      row['reason'] = '${input['reason']}';
    }
    await _saveListening(rows);
    if (finished) unawaited(_dispatch(row));
    return _summary(row);
  }

  Map<String, dynamic> _summary(Map<String, dynamic> row) => {
    'playId': row['playId'],
    'songId': row['songId'],
    'listenedMs': row['listenedMs'] ?? 0,
    'finished': row['finished'] == true,
    'reason': row['reason'],
    'startState': row['startState'],
    'playState': row['playState'],
  };

  /// 只发送真实发生的收听：开始一次、结束一次，失败不重试、不补发。
  Future<void> _dispatch(Map<String, dynamic> row) async {
    final listened = (row['listenedMs'] as num?)?.toInt() ?? 0;
    if (listened < 1000 || !client.loggedIn) return;
    try {
      if (row['startState'] == 'pending') {
        await client.feedback(
          songId: '${row['songId']}',
          action: 'startplay',
          origin: '${row['origin'] ?? ''}',
          sourceId: row['sourceId']?.toString(),
        );
      }
      await client.feedback(
        songId: '${row['songId']}',
        action: 'play',
        origin: '${row['origin'] ?? ''}',
        sourceId: row['sourceId']?.toString(),
        seconds: listened ~/ 1000,
        completed: row['reason'] == 'completed',
      );
    } catch (_) {
      // 收听上报失败不影响播放，也不自动重发。
    }
  }

  // ---- 队列 ----

  _Snapshot? _read(String mode) {
    final raw = prefs.getString(_queueKeyOf(mode));
    if (raw == null) return null;
    try {
      final json = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return _Snapshot(
        '${json['generation']}',
        (json['revision'] as num).toInt(),
        (json['state'] as Map).cast<String, dynamic>(),
        (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  Future<_Snapshot> _write(
    Map<String, dynamic> state,
    String generation,
    int revision, {
    String mode = 'netease',
  }) async {
    final snapshot = _Snapshot(
      generation,
      revision,
      state,
      DateTime.now().millisecondsSinceEpoch,
    );
    await prefs.setString(_queueKeyOf(mode), jsonEncode(snapshot.json));
    return snapshot;
  }

  Map<String, dynamic> _present(_Snapshot snapshot) {
    // original 只在心动模式内部用于恢复，不下发；推荐状态界面会用到。
    final state = Map<String, dynamic>.from(snapshot.state)..remove('original');
    if ((state['playing'] as bool?) == true) state['playing'] = false;
    return {
      'generation': snapshot.generation,
      'revision': snapshot.revision,
      'state': state,
      'updatedAt': snapshot.updatedAt,
      'restoredPaused': true,
    };
  }

  Future<_Snapshot> _replace(Map<String, dynamic> state) async {
    _validate(state);
    final previous = _read('netEase');
    return _write(state, _id(), (previous?.revision ?? 0) + 1);
  }

  void _validate(Map<String, dynamic> state, [String mode = 'netease']) {
    if (mode == 'bilibili') {
      final items = (state['items'] as List? ?? []).cast<Map>();
      final index = (state['index'] as num?)?.toInt() ?? 0;
      if (items.isNotEmpty && index >= items.length) {
        _fail(400, 'INVALID_QUEUE_INDEX', '播放位置不在队列内。');
      }
      if (items.length > 10000) _fail(413, 'QUEUE_TOO_LARGE', '队列最多 10000 首。');
      for (final item in items) {
        if (item['mode'] != null && item['mode'] != 'bilibili') {
          _fail(400, 'MIXED_QUEUE', '不同音乐模式不能混合队列。');
        }
        if (!RegExp(r'^BV[0-9A-Za-z]{10}:\d+$').hasMatch('${item['id']}')) {
          _fail(400, 'INVALID_MUSIC_ID', 'B 站歌曲 ID 无效。');
        }
      }
      return;
    }
    final items = (state['items'] as List? ?? []).cast<Map>();
    if (state['origin'] == 'podcast' && state['radioId'] == null) {
      _fail(400, 'INVALID_PODCAST_QUEUE', '节目队列必须指定网易云播客。');
    }
    final index = (state['index'] as num?)?.toInt() ?? 0;
    if (items.isNotEmpty && index >= items.length) {
      _fail(400, 'INVALID_QUEUE_INDEX', '播放位置不在队列内。');
    }
    if (items.length > 10000) _fail(413, 'QUEUE_TOO_LARGE', '队列最多 10000 首。');
    for (final item in items) {
      if (item['mode'] != null && item['mode'] != 'netease') {
        _fail(400, 'MIXED_QUEUE', '不同音乐模式不能混合队列。');
      }
      if ((item['kind'] == 'podcast') != (state['origin'] == 'podcast')) {
        _fail(400, 'MIXED_CONTENT_QUEUE', '节目和歌曲不能混合队列。');
      }
      if (!RegExp(r'^\d{1,20}$').hasMatch('${item['id']}')) {
        _fail(400, 'INVALID_MUSIC_ID', '网易云歌曲 ID 无效。');
      }
    }
  }

  /// 兼容插播资源包装：只把明确的歌曲对象当成候选。
  List<Map<String, dynamic>> _songs(Object? body) {
    final result = <String, Map<String, dynamic>>{};
    var visited = 0;
    void visit(Object? value, int depth) {
      if (depth > 8 || visited++ > 20000 || value == null) return;
      if (value is List) {
        for (final item in value) {
          visit(item, depth + 1);
        }
        return;
      }
      if (value is! Map) return;
      final candidate =
          value['songId'] ??
          (value['resourceType'] == 'song' ? value['resourceId'] : null) ??
          ((value['name'] != null || value['title'] != null)
              ? value['id']
              : null);
      if (candidate != null && RegExp(r'^\d{1,20}$').hasMatch('$candidate')) {
        result['$candidate'] = {
          'id': '$candidate',
          'mode': 'netease',
          'title': '${value['name'] ?? value['title'] ?? ''}'.substring(
            0,
            min(500, '${value['name'] ?? value['title'] ?? ''}'.length),
          ),
        };
      }
      for (final key in [
        'songs',
        'data',
        'resources',
        'resourceList',
        'song',
        'musicInfo',
        'songInfo',
        'resource',
        'items',
        'list',
      ]) {
        visit(value[key], depth + 1);
      }
      final content = value['resourceContent'];
      if (content is String && content.length < 256000) {
        try {
          visit(jsonDecode(content), depth + 1);
        } catch (_) {}
      }
    }

    visit(body, 0);
    return result.values.toList();
  }

  Future<dynamic> _queues(
    List<String> segments,
    Map<String, dynamic> input,
  ) async {
    final name = segments.skip(1).join('/');
    final manual = input['manual'] == true;
    switch (name) {
      case 'search':
        return _present(
          await _replace({
            'items': [
              {'id': _text(input, 'songId'), 'mode': 'netease'},
            ],
            'index': 0,
            'positionMs': 0,
            'playing': false,
            'shuffle': false,
            'repeat': 'off',
            'origin': 'search',
            'seedId': _text(input, 'songId'),
          }),
        );
      case 'daily':
        final songId = _text(input, 'songId');
        final body = await client.recommendSongs();
        final data = (body['data'] as Map?) ?? body;
        final daily = (data['dailySongs'] as List?) ?? const [];
        final items = <Map<String, dynamic>>[];
        final known = <String>{};
        for (final song in daily) {
          final id = '${song['id'] ?? ''}';
          if (RegExp(r'^\d{1,20}$').hasMatch(id) && known.add(id)) {
            items.add({
              'id': id,
              'mode': 'netease',
              'title': '${song['name'] ?? ''}',
            });
          }
        }
        final index = items.indexWhere((item) => item['id'] == songId);
        if (index < 0) {
          _fail(409, 'SONG_NOT_IN_DAILY', '每日推荐已更新，所选歌曲不在今天的列表中，请刷新后重试。');
        }
        return _present(
          await _replace({
            'items': items,
            'index': index,
            'positionMs': 0,
            'playing': false,
            'shuffle': false,
            'repeat': 'off',
            'origin': 'manual',
          }),
        );
      case 'fm':
        final items = _songs(await client.personalFm());
        if (items.isEmpty) _fail(422, 'EMPTY_FM', '私人FM暂未返回歌曲，请稍后重试。');
        return _present(
          await _replace({
            'items': items,
            'index': 0,
            'positionMs': 0,
            'playing': false,
            'shuffle': false,
            'repeat': 'off',
            'origin': 'fm',
            'recommendationStatus': 'complete',
          }),
        );
      case 'collection':
        final kind = '${input['kind']}';
        final collectionId = _text(input, 'collectionId');
        List<Map<String, dynamic>> items;
        if (kind == 'album') {
          items = _songs(await client.album(collectionId));
        } else if (kind == 'artist') {
          // 歌手主页的热门歌曲列表：最多取前 500 首；找不到所选歌曲时从头播放。
          items = [];
          final known = <String>{};
          for (var offset = 0; offset < 500; offset += 100) {
            final page = await client.artistSongs(
              collectionId,
              limit: 100,
              offset: offset,
            );
            final songs = _songs(page);
            for (final item in songs) {
              if (known.add('${item['id']}')) items.add(item);
            }
            if (songs.isEmpty || page['more'] != true) break;
          }
        } else {
          final body = await client.playlistDetail(collectionId);
          final tracks = (body['playlist'] as Map?)?['trackIds'] as List?;
          if (tracks == null)
            _fail(502, 'INVALID_PLAYLIST_RESPONSE', '歌单曲目列表不可用。');
          if (tracks.length > 10000)
            _fail(413, 'QUEUE_TOO_LARGE', '歌单超过 10000 首，请选择较小歌单。');
          items = [
            for (final track in tracks)
              {'id': '${track['id']}', 'mode': 'netease'},
          ];
        }
        if (items.isEmpty) _fail(422, 'EMPTY_COLLECTION', '此列表没有可播放曲目。');
        final songId = input['songId']?.toString();
        final index = songId == null
            ? 0
            : items.indexWhere((item) => item['id'] == songId);
        if (index < 0 && kind != 'artist') {
          _fail(400, 'SONG_NOT_IN_COLLECTION', '所选歌曲不在此列表中。');
        }
        return _present(
          await _replace({
            'items': items,
            'index': index < 0 ? 0 : index,
            'positionMs': 0,
            'playing': false,
            'shuffle': false,
            'repeat': 'off',
            'origin': kind == 'artist' ? 'manual' : kind,
            if (kind == 'playlist') 'playlistId': collectionId,
          }),
        );
      case 'podcast':
        final radioId = _text(input, 'radioId');
        final programId = _text(input, 'programId');
        final offset = _int(input, 'offset', 0, 0, 100000);
        final page = await _podcastPrograms(radioId, (offset ~/ 50) * 50, 50);
        final items = (page['items'] as List).cast<Map>();
        final selected = items.indexWhere((item) => item['id'] == programId);
        if (selected < 0) _fail(409, 'PROGRAM_PAGE_CHANGED', '节目列表已变化，请刷新后重试。');
        return _present(
          await _replace({
            'items': [
              for (final item in items.skip(selected))
                {
                  'id': '${item['id']}',
                  'mode': 'netease',
                  'kind': 'podcast',
                  'title': item['title'],
                },
            ],
            'index': 0,
            'positionMs': 0,
            'playing': false,
            'shuffle': false,
            'repeat': 'off',
            'origin': 'podcast',
            'radioId': radioId,
            'nextOffset': page['nextOffset'],
          }),
        );
      case 'podcast/extend':
        return _extendPodcast('${input['generation']}');
      case 'fm/extend':
        return _extendFm('${input['generation']}', manual);
      case 'intelligence':
        return _intelligence(
          enabled: input['enabled'] == true,
          playlistId: input['playlistId']?.toString(),
          songId: input['songId']?.toString(),
        );
      case 'intelligence/extend':
        return _extendIntelligence('${input['generation']}', manual);
      case 'extend':
        return _extendSearch('${input['generation']}', input['retry'] == true);
    }
    _fail(404, 'NOT_FOUND', '接口不存在。');
  }

  Future<dynamic> _extendFm(String generation, bool manual) async {
    final snapshot = _read('netEase');
    if (snapshot == null || snapshot.generation != generation) {
      _fail(409, 'QUEUE_CHANGED', '已切换队列。');
    }
    final state = Map<String, dynamic>.from(snapshot.state);
    if (state['origin'] != 'fm' || state['intelligence'] == true) {
      _fail(409, 'NOT_FM_QUEUE', '当前不是私人FM队列。');
    }
    final items = (state['items'] as List).cast<Map>();
    final index = (state['index'] as num?)?.toInt() ?? 0;
    if (items.length >= 10000 || (!manual && items.length - index - 1 > 2)) {
      return _present(snapshot);
    }
    final attempts = Map<String, dynamic>.from(
      (state['attempts'] as Map?) ?? const {},
    );
    final anchor = '${items.last['id']}';
    if (((attempts[anchor] as num?)?.toInt() ?? 0) >= (manual ? 3 : 1)) {
      return _present(snapshot);
    }
    attempts[anchor] = ((attempts[anchor] as num?)?.toInt() ?? 0) + 1;
    var status = 'complete';
    List<Map<String, dynamic>> candidates = [];
    try {
      candidates = _songs(await client.personalFm());
    } catch (_) {
      status = 'failed';
    }
    final known = items.map((item) => '${item['id']}').toSet();
    final fresh = [
      for (final item in candidates)
        if (known.add(item['id'] as String)) item,
    ];
    state['items'] = [...items, ...fresh];
    state['attempts'] = attempts;
    state['recommendationStatus'] = status == 'failed'
        ? 'failed'
        : fresh.isEmpty
        ? 'exhausted'
        : 'complete';
    return _present(await _write(state, generation, snapshot.revision + 1));
  }

  Future<dynamic> _extendSearch(String generation, bool retry) async {
    final snapshot = _read('netEase');
    if (snapshot == null || snapshot.generation != generation) {
      _fail(409, 'QUEUE_CHANGED', '已切换队列。');
    }
    final state = Map<String, dynamic>.from(snapshot.state);
    if (state['origin'] != 'search' || state['intelligence'] == true) {
      _fail(409, 'NOT_RECOMMENDATION_QUEUE', '当前不是搜索推荐队列。');
    }
    final items = (state['items'] as List).cast<Map>();
    final index = (state['index'] as num?)?.toInt() ?? 0;
    if (items.length - index - 1 > 2) return _present(snapshot);
    final attempts = Map<String, dynamic>.from(
      (state['attempts'] as Map?) ?? const {},
    );
    final seed = attempts.isEmpty
        ? '${state['seedId']}'
        : '${items.last['id']}';
    if (((attempts[seed] as num?)?.toInt() ?? 0) >= (retry ? 3 : 1)) {
      return _present(snapshot);
    }
    attempts[seed] = ((attempts[seed] as num?)?.toInt() ?? 0) + 1;
    var status = 'complete';
    List<Map<String, dynamic>> candidates = [];
    try {
      candidates = _songs(await client.simiSong(seed));
      final existing = items.map((item) => '${item['id']}').toSet();
      if (!candidates.any((item) => !existing.contains(item['id']))) {
        candidates.addAll(_songs(await client.songSimiGet(seed)));
      }
    } catch (_) {
      status = 'failed';
    }
    final known = items.map((item) => '${item['id']}').toSet();
    final fresh = [
      for (final item in candidates)
        if (known.add(item['id'] as String)) item,
    ];
    state['items'] = [...items, ...fresh];
    state['attempts'] = attempts;
    state['recommendationStatus'] = fresh.isNotEmpty
        ? status
        : status == 'failed'
        ? 'failed'
        : 'exhausted';
    return _present(await _write(state, generation, snapshot.revision + 1));
  }

  Future<dynamic> _extendPodcast(String generation) async {
    final snapshot = _read('netEase');
    if (snapshot == null || snapshot.generation != generation) {
      _fail(409, 'QUEUE_CHANGED', '已切换队列。');
    }
    final state = Map<String, dynamic>.from(snapshot.state);
    if (state['origin'] != 'podcast' || state['radioId'] == null) {
      _fail(409, 'NOT_PODCAST_QUEUE', '当前不是节目队列。');
    }
    final nextOffset = state['nextOffset'];
    final items = (state['items'] as List).cast<Map>();
    if (nextOffset == null || items.length >= 10000) return _present(snapshot);
    final page = await _podcastPrograms(
      '${state['radioId']}',
      (nextOffset as num).toInt(),
      50,
    );
    final known = items.map((item) => '${item['id']}').toSet();
    final fresh = <Map<String, dynamic>>[];
    for (final item in (page['items'] as List).cast<Map>()) {
      if (known.add('${item['id']}')) {
        fresh.add({
          'id': '${item['id']}',
          'mode': 'netease',
          'kind': 'podcast',
          'title': item['title'],
        });
      }
    }
    final pageNext = page['nextOffset'];
    state['items'] = [...items, ...fresh];
    state['nextOffset'] =
        fresh.isNotEmpty &&
            pageNext != null &&
            (pageNext as num).toInt() > (nextOffset).toInt()
        ? pageNext
        : null;
    return _present(await _write(state, generation, snapshot.revision + 1));
  }

  Future<dynamic> _intelligence({
    required bool enabled,
    String? playlistId,
    String? songId,
  }) async {
    final previous = _read('netEase');
    if (!enabled) {
      if (previous?.state['intelligence'] != true ||
          previous?.state['original'] == null) {
        return previous == null ? null : _present(previous);
      }
      final original = Map<String, dynamic>.from(
        (previous!.state['original'] as Map).cast<String, dynamic>(),
      )..['playing'] = false;
      return _present(await _replace(original));
    }
    if (previous?.state['intelligence'] == true) return _present(previous!);
    final pid = playlistId ?? (await _likedPlaylist())['id'] as String;
    final detail = await client.playlistDetail(pid);
    final tracks = (detail['playlist'] as Map?)?['trackIds'] as List?;
    if (tracks == null) _fail(502, 'INVALID_PLAYLIST_RESPONSE', '歌单曲目列表不可用。');
    final ids = tracks.map((item) => '${item['id']}').toList();
    if (ids.isEmpty) _fail(422, 'EMPTY_LIKED_PLAYLIST', '歌单为空，请先在网易云喜欢一些歌曲。');
    final items = (previous?.state['items'] as List? ?? []).cast<Map>();
    final index = (previous?.state['index'] as num?)?.toInt() ?? 0;
    final current = index < items.length && items[index]['kind'] != 'podcast'
        ? '${items[index]['id']}'
        : null;
    final seed =
        songId ??
        (current != null && ids.contains(current) ? current : ids.first);
    if (!ids.contains(seed))
      _fail(400, 'SONG_NOT_IN_COLLECTION', '心动起始歌曲不在指定歌单内。');
    final result = await client.intelligenceList(id: seed, pid: pid, sid: seed);
    final queue = [
      {'id': seed, 'mode': 'netease'},
      for (final item in _songs(result))
        if (item['id'] != seed) item,
    ];
    final original = previous != null
        ? Map<String, dynamic>.from(previous.state)
        : <String, dynamic>{
            'items': [
              {'id': seed, 'mode': 'netease'},
            ],
            'index': 0,
            'positionMs': 0,
            'playing': false,
            'shuffle': false,
            'repeat': 'off',
            'origin': 'playlist',
            'playlistId': pid,
          };
    return _present(
      await _replace({
        ...original,
        'items': queue,
        'index': 0,
        'positionMs': current == seed ? original['positionMs'] : 0,
        'playing': false,
        'shuffle': false,
        'repeat': 'off',
        'origin': 'intelligence',
        'intelligence': true,
        'playlistId': pid,
        'seedId': seed,
        'attempts': <String, dynamic>{},
        'recommendationStatus': queue.length > 1 ? 'complete' : 'exhausted',
        'original': original,
      }),
    );
  }

  Future<dynamic> _extendIntelligence(String generation, bool manual) async {
    final snapshot = _read('netEase');
    if (snapshot == null || snapshot.generation != generation) {
      _fail(409, 'QUEUE_CHANGED', '已切换队列。');
    }
    final state = Map<String, dynamic>.from(snapshot.state);
    if (state['intelligence'] != true || state['origin'] != 'intelligence') {
      _fail(409, 'NOT_INTELLIGENCE_QUEUE', '当前不是心动队列。');
    }
    final items = (state['items'] as List).cast<Map>();
    final index = (state['index'] as num?)?.toInt() ?? 0;
    if (items.length >= 10000 || (!manual && items.length - index - 1 > 5)) {
      return _present(snapshot);
    }
    final attempts = Map<String, dynamic>.from(
      (state['attempts'] as Map?) ?? const {},
    );
    final anchor = '${items.last['id']}';
    if (((attempts[anchor] as num?)?.toInt() ?? 0) >= (manual ? 3 : 1)) {
      return _present(snapshot);
    }
    attempts[anchor] = ((attempts[anchor] as num?)?.toInt() ?? 0) + 1;
    var status = 'complete';
    List<Map<String, dynamic>> candidates = [];
    try {
      candidates = _songs(
        await client.intelligenceList(
          id: anchor,
          pid: '${state['playlistId']}',
          sid: '${state['seedId']}',
        ),
      );
    } catch (_) {
      status = 'failed';
    }
    final known = items.map((item) => '${item['id']}').toSet();
    final fresh = [
      for (final item in candidates)
        if (known.add(item['id'] as String)) item,
    ];
    state['items'] = [...items, ...fresh];
    state['attempts'] = attempts;
    state['recommendationStatus'] = status == 'failed'
        ? 'failed'
        : fresh.isEmpty
        ? 'exhausted'
        : 'complete';
    return _present(await _write(state, generation, snapshot.revision + 1));
  }

  // ---- 播放状态 ----

  Future<dynamic> _playback(
    String method,
    List<String> segments,
    Map<String, dynamic> input,
  ) async {
    final action = segments.length > 2 ? segments[2] : '';
    final mode = segments.length > 1 ? segments[1] : 'netease';
    final snapshot = _read(mode);
    if (method == 'GET') return snapshot == null ? null : _present(snapshot);
    if (action == 'progress') {
      if (snapshot == null) _fail(409, 'QUEUE_CHANGED', '队列已更新或尚未建立。');
      final expected = (input['expectedRevision'] as num?)?.toInt();
      if (expected != null && expected != snapshot.revision) {
        _fail(409, 'QUEUE_CHANGED', '队列已更新，请刷新后重试。');
      }
      final state = Map<String, dynamic>.from(snapshot.state);
      for (final key in [
        'index',
        'positionMs',
        'playing',
        'shuffle',
        'repeat',
      ]) {
        if (input.containsKey(key)) state[key] = input[key];
      }
      final saved = await _write(
        state,
        snapshot.generation,
        snapshot.revision + 1,
        mode: mode,
      );
      return {
        'generation': saved.generation,
        'revision': saved.revision,
        'updatedAt': saved.updatedAt,
      };
    }
    if (method != 'PUT' && method != 'POST')
      _fail(405, 'METHOD_NOT_ALLOWED', '请求方式无效。');
    if (action == 'start' && mode == 'bilibili') {
      final context = (input['context'] as Map?)?.cast<String, dynamic>();
      final selected = '${input['selectedId'] ?? ''}';
      if (context == null || selected.isEmpty) {
        _fail(400, 'INVALID_QUEUE', '播放队列参数无效。');
      }
      final built = await bili.queueFor(context, selected);
      final state = {
        'items': built.items,
        'index': built.index,
        'positionMs': 0,
        'playing': false,
        'shuffle': snapshot?.state['shuffle'] == true,
        'repeat': snapshot?.state['repeat'] ?? 'off',
        'origin': 'manual',
      };
      _validate(state, mode);
      return _present(
        await _write(state, _id(), (snapshot?.revision ?? 0) + 1, mode: mode),
      );
    }
    if (action == 'remove') {
      if (snapshot == null) _fail(409, 'QUEUE_CHANGED', '队列已更新或尚未建立。');
      final expected = (input['expectedRevision'] as num?)?.toInt();
      if (expected != null && expected != snapshot.revision) {
        _fail(409, 'QUEUE_CHANGED', '队列已更新，请刷新后重试。');
      }
      final state = Map<String, dynamic>.from(snapshot.state);
      final items = (state['items'] as List).toList();
      var index = (state['index'] as num?)?.toInt() ?? 0;
      if (input['upcoming'] == true) {
        items.removeRange(index + 1, items.length);
      } else {
        final at = (input['index'] as num?)?.toInt() ?? -1;
        if (at < 0 || at >= items.length)
          _fail(400, 'INVALID_QUEUE_INDEX', '播放位置不在队列内。');
        if (at == index) _fail(400, 'CURRENT_TRACK', '不能移除正在播放的歌曲。');
        items.removeAt(at);
        if (at < index) index--;
      }
      state['items'] = items;
      state['index'] = index;
      _validate(state, mode);
      return _present(
        await _write(
          state,
          snapshot.generation,
          snapshot.revision + 1,
          mode: mode,
        ),
      );
    }
    if (action == 'insert') {
      if (snapshot == null) _fail(409, 'QUEUE_CHANGED', '队列已更新或尚未建立。');
      final expected = (input['expectedRevision'] as num?)?.toInt();
      if (expected != null && expected != snapshot.revision) {
        _fail(409, 'QUEUE_CHANGED', '队列已更新，请刷新后重试。');
      }
      final item = (input['item'] as Map?)?.cast<String, dynamic>();
      if (item == null) _fail(400, 'INVALID_ITEM', '插入曲目无效。');
      final state = Map<String, dynamic>.from(snapshot.state);
      final items = (state['items'] as List).toList();
      final index = (state['index'] as num?)?.toInt() ?? 0;
      items.insert(input['next'] == true ? index + 1 : items.length, item);
      state['items'] = items;
      _validate(state, mode);
      return _present(
        await _write(
          state,
          snapshot.generation,
          snapshot.revision + 1,
          mode: mode,
        ),
      );
    }
    // PUT /playback/netease：整份保存队列。
    final incoming = (input['state'] as Map?)?.cast<String, dynamic>();
    if (incoming == null) _fail(400, 'INVALID_STATE', '队列状态无效。');
    _validate(incoming, mode);
    final expected = (input['expectedRevision'] as num?)?.toInt();
    if (expected != null && snapshot != null && expected != snapshot.revision) {
      _fail(409, 'QUEUE_CHANGED', '队列已更新，请刷新后重试。');
    }
    if (incoming['origin'] == 'intelligence' &&
        snapshot?.state['intelligence'] != true) {
      _fail(400, 'INTELLIGENCE_NOT_ENABLED', '请先使用心动模式开关。');
    }
    final changed =
        snapshot != null &&
        (snapshot.state['origin'] != incoming['origin'] ||
            jsonEncode(
                  (snapshot.state['items'] as List? ?? [])
                      .map((item) => [item['kind'], item['id']])
                      .toList(),
                ) !=
                jsonEncode(
                  (incoming['items'] as List? ?? [])
                      .map((item) => [item['kind'], item['id']])
                      .toList(),
                ));
    final state = Map<String, dynamic>.from(incoming);
    if (snapshot?.state['intelligence'] == true &&
        incoming['origin'] == 'intelligence') {
      state['intelligence'] = true;
      state['original'] = snapshot!.state['original'];
      state['recommendationStatus'] = snapshot.state['recommendationStatus'];
    }
    if (snapshot?.state['origin'] == 'fm' && incoming['origin'] == 'fm') {
      state['recommendationStatus'] = snapshot!.state['recommendationStatus'];
    }
    state['attempts'] = changed || snapshot == null
        ? <String, dynamic>{}
        : snapshot.state['attempts'];
    final saved = await _write(
      state,
      changed || snapshot == null ? _id() : snapshot.generation,
      (snapshot?.revision ?? 0) + 1,
      mode: mode,
    );
    return _present(saved);
  }
}
