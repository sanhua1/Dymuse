// 只读探测：不带任何登录信息（游客）调用客户端用到的网易云接口，打印返回的业务码和数据量，
// 用来确认哪些功能不登录也能用。运行：dart run tool/anon_probe.dart
import 'dart:convert';
import 'package:dymuse/netease/client.dart';

int _n(dynamic v) => v is List ? v.length : (v is Map ? v.length : 0);

Future<void> main() async {
  final c = NeteaseClient();
  Future<Map<String, dynamic>?> probe(
    String name,
    Future<Map<String, dynamic>> Function() call, [
    String Function(Map<String, dynamic>)? note,
  ]) async {
    try {
      final r = await call();
      print(
        'OK   ${name.padRight(22)} code=${r['code']} ${note?.call(r) ?? ''}',
      );
      return r;
    } catch (e) {
      print('FAIL ${name.padRight(22)} $e');
      return null;
    }
  }

  final search = await probe(
    'search(cloudsearch)',
    () => c.search(keywords: '周杰伦'),
    (r) => 'songs=${_n((r['result'] as Map?)?['songs'])}',
  );
  final song =
      (((search?['result'] as Map?)?['songs']) as List?)?.first as Map?;
  final songId = '${song?['id'] ?? 66842}';
  final albumId = '${(song?['al'] as Map?)?['id'] ?? 32311}';
  final artistId = '${((song?['ar'] as List?)?.first as Map?)?['id'] ?? 6452}';
  print('  样本: song=$songId album=$albumId artist=$artistId');

  await probe(
    'search(combined)',
    () => c.search(keywords: '周杰伦', combined: true),
    (r) => 'keys=${(r['result'] as Map?)?.keys.take(6).toList()}',
  );
  await probe(
    'songDetail',
    () => c.songDetail([songId]),
    (r) => 'songs=${_n(r['songs'])}',
  );
  await probe(
    'musicDetail',
    () => c.musicDetail(songId),
    (r) => 'has data=${r['data'] != null}',
  );
  await probe(
    'songUrls(lossless)',
    () async {
      final data = await c.songUrls([songId], level: 'lossless');
      return {'code': 200, 'data': data};
    },
    (r) {
      final d = (r['data'] as List).first as Map;
      return 'url=${d['url'] != null} level=${d['level']} br=${d['br']} trial=${d['freeTrialInfo'] != null} code=${d['code']}';
    },
  );
  await probe(
    'lyric',
    () => c.lyric(songId),
    (r) => 'lrc=${((r['lrc'] as Map?)?['lyric'] as String?)?.length ?? 0}字',
  );
  await probe(
    'album',
    () => c.album(albumId),
    (r) => 'songs=${_n(r['songs'])}',
  );
  await probe(
    'artistSongs',
    () => c.artistSongs(artistId, limit: 5, offset: 0),
    (r) => 'songs=${_n(r['songs'])}',
  );
  await probe(
    'artistAlbums',
    () => c.artistAlbums(artistId, limit: 5, offset: 0),
    (r) => 'albums=${_n(r['hotAlbums'])}',
  );
  final top = await probe(
    'toplist',
    () => c.toplist(),
    (r) => 'lists=${_n(r['list'])}',
  );
  final listId =
      '${((top?['list'] as List?)?.first as Map?)?['id'] ?? 3778678}';
  await probe(
    'playlistDetail',
    () => c.playlistDetail(listId),
    (r) =>
        'tracks=${_n((r['playlist'] as Map?)?['tracks'])} trackIds=${_n((r['playlist'] as Map?)?['trackIds'])}',
  );
  await probe(
    'topPlaylist',
    () => c.topPlaylist(),
    (r) => 'lists=${_n(r['playlists'])}',
  );
  await probe(
    'playlistCatlist',
    () => c.playlistCatlist(),
    (r) => 'cats=${_n(r['sub'])}',
  );
  await probe(
    'simiSong',
    () => c.simiSong(songId),
    (r) => 'songs=${_n(r['songs'])}',
  );
  await probe(
    'songSimiGet',
    () => c.songSimiGet(songId),
    (r) => 'keys=${(r['data'] as Map?)?.keys.toList()}',
  );
  // 个人相关
  await probe(
    'account',
    () => c.account(),
    (r) => 'profile=${r['profile'] != null} account=${r['account'] != null}',
  );
  await probe(
    'recommendSongs',
    () => c.recommendSongs(),
    (r) =>
        'daily=${_n((r['data'] as Map?)?['dailySongs'])} msg=${r['message'] ?? r['msg']}',
  );
  await probe(
    'personalizedPlaylists',
    () => c.personalizedPlaylists(),
    (r) => 'lists=${_n(r['recommend'])}（游客的“推荐”用它）',
  );
  await probe(
    'recommendResource',
    () => c.recommendResource(),
    (r) => 'lists=${_n(r['recommend'])} msg=${r['message'] ?? r['msg']}',
  );
  await probe(
    'personalFm',
    () => c.personalFm(),
    (r) => 'songs=${_n(r['data'])} msg=${r['message'] ?? r['msg']}',
  );
  await probe(
    'intelligenceList',
    () => c.intelligenceList(id: songId, pid: listId),
    (r) => 'items=${_n(r['data'])} msg=${r['message'] ?? r['msg']}',
  );
  await probe(
    'userPlaylist(uid 1)',
    () => c.userPlaylist('1', limit: 3, offset: 0),
    (r) => 'lists=${_n(r['playlist'])}',
  );
  await probe(
    'likelist(uid 1)',
    () => c.likelist('1'),
    (r) => 'ids=${_n(r['ids'])} msg=${r['message'] ?? r['msg']}',
  );
  await probe(
    'djSublist',
    () => c.djSublist(),
    (r) => 'radios=${_n(r['djRadios'])} msg=${r['message'] ?? r['msg']}',
  );
  print(jsonEncode({'cookieKeys': c.cookie.keys.toList()}));
}
