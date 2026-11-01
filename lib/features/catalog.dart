import 'package:flutter/foundation.dart';
import '../core/api_client.dart';

enum MusicMode { netease, bilibili }

enum DiscoverSection {
  recommended('推荐'),
  fm('私人 FM'),
  charts('排行榜'),
  playlists('歌单广场');

  const DiscoverSection(this.label);
  final String label;
}

enum SearchCategory {
  all('综合', 1018),
  songs('单曲', 1),
  playlists('歌单', 1000),
  podcasts('播客', 1009),
  albums('专辑', 10),
  artists('歌手', 100);

  const SearchCategory(this.label, this.type);
  final String label;
  final int type;
}

extension MusicModeLabel on MusicMode {
  String get label => this == MusicMode.netease ? '网易云音乐' : '哔哩哔哩';
}

/// 统一展示字段，身份始终携带所属曲库。
class Track {
  const Track({
    required this.id,
    required this.mode,
    required this.title,
    this.artist = '',
    this.album = '',
    this.cover,
    this.duration = 0,
    this.favorite = false,
    this.available = true,
    this.isPodcast = false,
    this.radioId,
    this.programOffset = 0,
    this.artists = const [],
    this.albumId,
    this.rawTitle,
  });
  final String id, title, artist, album;

  /// B 站视频的原标题（`title` 是识别后的歌名）。
  final String? rawTitle;

  /// 可跳转的艺人（id 与名称）；B 站歌曲没有艺人页，列表为空。
  final List<({String id, String name})> artists;
  final String? albumId;

  /// 播放器中的“艺人/专辑/节目所属播客”跳转目标；缺 id 时不可点击。
  Collection? get artistTarget => artists.isEmpty
      ? null
      : Collection(artists.first.id, artists.first.name, '歌手', null, 'artist');
  Collection? get albumTarget => isPodcast
      ? (radioId == null
            ? null
            : Collection(radioId!, album, artist, null, 'podcast'))
      : albumId == null
      ? null
      : Collection(albumId!, album, artist, null, 'album');
  final MusicMode mode;
  final String? cover;
  final double duration;
  final bool favorite, available;
  final bool isPodcast;
  final String? radioId;
  final int programOffset;
  String get kind => isPodcast ? 'podcast' : 'song';
  factory Track.podcast(Json value) => Track(
    id: value['id'].toString(),
    mode: MusicMode.netease,
    title: value['title']?.toString() ?? '未命名节目',
    artist: value['artist']?.toString() ?? '',
    album: value['album']?.toString() ?? '',
    cover: value['cover'] as String?,
    duration: (value['duration'] as num? ?? 0).toDouble(),
    isPodcast: true,
    radioId: value['radioId']?.toString(),
    programOffset: (value['offset'] as num? ?? 0).toInt(),
  );
  factory Track.bilibili(Json value) => Track(
    id: value['id'].toString(),
    mode: MusicMode.bilibili,
    title: value['title']?.toString() ?? '未命名歌曲',
    artist: (value['artists'] as List? ?? []).join(' / '),
    album: value['album']?.toString() ?? '',
    cover: value['coverUrl'] as String?,
    duration: (value['duration'] as num? ?? 0).toDouble(),
    favorite: value['favorite'] == true,
    available: value['available'] != false,
    rawTitle: value['rawTitle']?.toString(),
  );
  factory Track.netease(Json value, {bool favorite = false}) {
    final album = value['al'] ?? value['album'] ?? {};
    final artists = value['ar'] ?? value['artists'] ?? [];
    return Track(
      id: value['id'].toString(),
      mode: MusicMode.netease,
      title: value['name']?.toString() ?? '未命名歌曲',
      artist: (artists as List).map((a) => a['name']).join(' / '),
      artists: [
        for (final a in artists)
          if (a is Map && a['id'] != null && '${a['id']}' != '0')
            (id: '${a['id']}', name: '${a['name'] ?? ''}'),
      ],
      albumId: album is Map && album['id'] != null && '${album['id']}' != '0'
          ? '${album['id']}'
          : null,
      album: album['name']?.toString() ?? '',
      cover: album['picUrl']?.toString(),
      duration: (value['dt'] as num? ?? value['duration'] as num? ?? 0) / 1000,
      favorite: favorite,
      available: value['unavailable'] != true,
    );
  }
}

class Collection {
  const Collection(
    this.id,
    this.title,
    this.subtitle,
    this.cover,
    this.kind, {
    this.isLiked = false,
    this.canSubscribe = false,
    this.subscribed = false,
  });
  final String id, title, subtitle, kind;
  final String? cover;
  final bool isLiked;
  final bool canSubscribe, subscribed;
}

/// 综合保留上游分块顺序，不把不同内容合成歌曲列表。
class SearchBlock {
  const SearchBlock(this.category, this.page);
  final SearchCategory category;
  final CatalogPage page;
}

class CatalogPage {
  const CatalogPage({
    this.tracks = const [],
    this.collections = const [],
    this.total = 0,
    this.nextOffset,
    this.source,
    this.blocks = const [],
  });
  final List<Track> tracks;
  final List<Collection> collections;
  final int total;
  final int? nextOffset;
  final Collection? source;
  final List<SearchBlock> blocks;
}

/// 页面查询与播放队列分开，分页只影响浏览。
class Catalog extends ChangeNotifier {
  Catalog(this.api);
  final ApiClient api;
  final Map<String, Track> _tracks = {};
  final Map<String, bool> _favorites = {};
  final Set<String> _favoriteWrites = {};
  final Map<String, bool> _subscriptions = {};
  final Set<String> _subscriptionWrites = {};
  int playlistRevision = 0;

  /// 同步改变了本机的红心/歌单/订阅后加一，浏览页据此重新载入。
  int syncRevision = 0;
  void syncApplied() {
    syncRevision++;
    _favorites.clear();
    notifyListeners();
  }

  Set<String>? _likedIds;
  Future<Set<String>>? _likedJob;
  String? _favoriteSession;
  int _favoriteEpoch = 0;
  String _key(Track track) => '${track.mode.name}:${track.kind}:${track.id}';
  void _prepareFavorites() {
    if (_favoriteSession == api.token) return;
    _favoriteSession = api.token;
    _favoriteEpoch++;
    _favorites.clear();
    _favoriteWrites.clear();
    _likedIds = null;
    _likedJob = null;
    _subscriptions.clear();
    _subscriptionWrites.clear();
  }

  bool? favoriteValue(Track track) {
    _prepareFavorites();
    return _favorites[_key(track)] ?? (track.favorite ? true : null);
  }

  bool favoriteBusy(Track track) {
    _prepareFavorites();
    return _favoriteWrites.contains(_key(track));
  }

  void remember(Iterable<Track> tracks, String? session) {
    if (session != api.token) return;
    _prepareFavorites();
    for (final track in tracks) {
      _tracks['${track.mode.name}:${track.kind}:${track.id}'] = track;
      if (!track.isPodcast &&
          (track.mode == MusicMode.bilibili || track.favorite)) {
        _favorites.putIfAbsent(_key(track), () => track.favorite);
      }
    }
  }

  Track? cached(MusicMode mode, String id, {bool isPodcast = false}) =>
      _tracks['${mode.name}:${isPodcast ? 'podcast' : 'song'}:$id'];
  void reset() {
    _tracks.clear();
    _favorites.clear();
    _favoriteWrites.clear();
    _likedIds = null;
    _likedJob = null;
    _favoriteEpoch++;
    _favoriteSession = api.token;
    _subscriptions.clear();
    _subscriptionWrites.clear();
    notifyListeners();
  }

  bool subscribed(Collection item) {
    _prepareFavorites();
    return _subscriptions[item.id] ?? item.subscribed;
  }

  bool subscriptionBusy(Collection item) {
    _prepareFavorites();
    return _subscriptionWrites.contains(item.id);
  }

  /// 收藏只更新歌单归属列表，失败保留原值，不触碰播放队列。
  Future<void> changeSubscription(Collection item) async {
    _prepareFavorites();
    if (!item.canSubscribe || !_subscriptionWrites.add(item.id)) return;
    final session = api.token, epoch = _favoriteEpoch;
    final target = !subscribed(item);
    notifyListeners();
    try {
      final data = await api.post(
        '/netease/playlists/${item.id}/subscription',
        {'subscribed': target},
      );
      if (data['subscribed'] != target) {
        throw const ApiException('PLAYLIST_SUBSCRIBE_FAILED', '服务器未确认收藏状态。');
      }
      if (session != api.token || epoch != _favoriteEpoch) return;
      _subscriptions[item.id] = target;
      playlistRevision++;
    } finally {
      if (session == api.token && epoch == _favoriteEpoch) {
        _subscriptionWrites.remove(item.id);
        notifyListeners();
      }
    }
  }

  /// 分类各自分页；综合只请求一次，按上游 order 选择受支持分块。
  Future<CatalogPage> search(
    String query,
    SearchCategory category,
    int offset,
  ) async {
    if (query.isEmpty) return const CatalogPage();
    final session = api.token;
    final combined = category == SearchCategory.all;
    final data =
        await api.get(
              combined ? '/netease/search/combined' : '/netease/search',
              {
                'keywords': query,
                'limit': combined ? 10 : 50,
                if (!combined) 'offset': offset,
                if (!combined) 'type': category.type,
              },
            )
            as Json;
    if (data['code'] != null && data['code'] != 200 || data['result'] is! Map) {
      throw const ApiException('SEARCH_UNAVAILABLE', '搜索结果暂不可用，请重试或切换分类。');
    }
    final result = Map<String, dynamic>.from(data['result'] as Map);
    if (!combined) {
      final page = _searchPage(result, category, offset);
      remember(page.tracks, session);
      return page;
    }
    const blocks = {
      'song': SearchCategory.songs,
      'playList': SearchCategory.playlists,
      'djRadio': SearchCategory.podcasts,
      'album': SearchCategory.albums,
      'artist': SearchCategory.artists,
    };
    final sections = <SearchBlock>[];
    final seen = <SearchCategory>{};
    final Iterable<dynamic> order = result['order'] is List
        ? result['order'] as List
        : blocks.keys;
    for (final key in order) {
      final kind = blocks[key], value = result[key];
      if (kind == null || value is! Map || !seen.add(kind)) continue;
      final page = _searchPage(
        Map<String, dynamic>.from(value),
        kind,
        0,
        preview: true,
      );
      if (page.tracks.isEmpty && page.collections.isEmpty) continue;
      remember(page.tracks, session);
      sections.add(SearchBlock(kind, page));
    }
    return CatalogPage(blocks: sections, total: sections.length);
  }

  CatalogPage _searchPage(
    Json result,
    SearchCategory category,
    int offset, {
    bool preview = false,
  }) {
    final (field, count) = switch (category) {
      SearchCategory.songs => ('songs', 'songCount'),
      SearchCategory.playlists => (
        preview ? 'playLists' : 'playlists',
        'playlistCount',
      ),
      SearchCategory.podcasts => ('djRadios', 'djRadiosCount'),
      SearchCategory.albums => ('albums', 'albumCount'),
      SearchCategory.artists => ('artists', 'artistCount'),
      SearchCategory.all => throw StateError('综合不能按单类解析'),
    };
    final raw = (result[field] as List? ?? []).cast<Json>();
    final total = (result[count] as num?)?.toInt() ?? offset + raw.length;
    return CatalogPage(
      tracks: category == SearchCategory.songs
          ? raw.map(Track.netease).toList()
          : const [],
      collections: category == SearchCategory.songs
          ? const []
          : raw.map((item) => _searchCollection(item, category)).toList(),
      total: total,
      nextOffset:
          !preview &&
              raw.isNotEmpty &&
              (offset + raw.length < total ||
                  result['hasMore'] == true ||
                  result['more'] == true)
          ? offset + raw.length
          : null,
    );
  }

  Collection _searchCollection(Json item, SearchCategory category) {
    final kind = switch (category) {
      SearchCategory.playlists => 'playlist',
      SearchCategory.podcasts => 'podcast',
      SearchCategory.albums => 'album',
      SearchCategory.artists => 'artist',
      _ => throw StateError('非集合搜索类型'),
    };
    final subtitle = switch (category) {
      SearchCategory.playlists =>
        '${item['trackCount'] ?? '—'} 首 · ${item['creator']?['nickname'] ?? ''}',
      SearchCategory.podcasts =>
        '${item['programCount'] ?? '—'} 期 · ${item['dj']?['nickname'] ?? ''}',
      SearchCategory.albums =>
        (item['artists'] as List? ??
                [if (item['artist'] != null) item['artist']])
            .map((a) => a['name'])
            .join(' / '),
      _ => '歌手',
    };
    return Collection(
      item['id'].toString(),
      item['name']?.toString() ?? '未命名',
      subtitle,
      (item['coverImgUrl'] ?? item['picUrl'] ?? item['img1v1Url']) as String?,
      kind,
    );
  }

  /// 歌曲喜欢状态共享缓存；喜欢歌单已确认的值优先，节目不调用歌曲接口。
  Future<void> loadFavorite(Track track) async {
    _prepareFavorites();
    if (track.isPodcast || _favorites.containsKey(_key(track))) return;
    if (track.mode == MusicMode.netease && api.guest) return;
    final session = api.token, epoch = _favoriteEpoch;
    try {
      bool value;
      if (track.mode == MusicMode.bilibili) {
        final data = await api.get('/bilibili/tracks/${track.id}') as Json;
        value = data['favorite'] == true;
      } else {
        _likedJob ??= api.get('/netease/likelist').then((data) {
          if (data['ids'] is! List) {
            throw const ApiException('FAVORITES_UNAVAILABLE', '无法读取喜欢状态。');
          }
          return (data['ids'] as List).map((id) => id.toString()).toSet();
        });
        final ids = _likedIds ?? await _likedJob!;
        if (session != api.token || epoch != _favoriteEpoch) return;
        _likedIds ??= ids;
        value = _likedIds!.contains(track.id);
      }
      if (session != api.token || epoch != _favoriteEpoch) return;
      _favorites.putIfAbsent(_key(track), () => value);
      notifyListeners();
    } catch (_) {
      if (session == api.token && epoch == _favoriteEpoch) _likedJob = null;
      rethrow;
    }
  }

  /// 点击立即反馈；同一首歌串行写入，失败回退，旧会话回包不污染新账号。
  Future<void> changeFavorite(Track track, {bool? value}) async {
    _prepareFavorites();
    final key = _key(track), session = api.token, epoch = _favoriteEpoch;
    if (track.isPodcast || !_favoriteWrites.add(key)) return;
    bool? previous;
    notifyListeners();
    try {
      if (value == null) await loadFavorite(track);
      if (session != api.token || epoch != _favoriteEpoch) return;
      previous = _favorites[key] ?? (value == null ? track.favorite : !value);
      final target = value ?? !previous;
      _favorites[key] = target;
      notifyListeners();
      final data = track.mode == MusicMode.bilibili
          ? await api.put('/bilibili/tracks/${track.id}/favorite', {
              'favorite': target,
            })
          : await api.post('/netease/like', {'id': track.id, 'like': target});
      if (track.mode == MusicMode.netease && data['code'] != 200 ||
          track.mode == MusicMode.bilibili && data['favorite'] != target) {
        throw const ApiException('FAVORITE_UPDATE_FAILED', '服务器未确认喜欢状态，请稍后重试。');
      }
      if (session != api.token || epoch != _favoriteEpoch) return;
      if (target) {
        _likedIds?.add(track.id);
      } else {
        _likedIds?.remove(track.id);
      }
    } catch (_) {
      if (session == api.token && epoch == _favoriteEpoch && previous != null) {
        _favorites[key] = previous;
      }
      rethrow;
    } finally {
      if (session == api.token && epoch == _favoriteEpoch) {
        _favoriteWrites.remove(key);
        notifyListeners();
      }
    }
  }

  /// 网易云只列本人普通歌单；私人歌单分页完全限定在当前账号。
  Future<CatalogPage> editablePlaylists(MusicMode mode, int offset) async {
    final local = mode == MusicMode.bilibili;
    final data =
        await api.get(
              local ? '/bilibili/playlists' : '/netease/playlists/editable',
              {'offset': offset, 'limit': 50},
            )
            as Json;
    final items = (data['items'] as List? ?? []).cast<Json>();
    return CatalogPage(
      collections: items
          .map(
            (item) => Collection(
              item['id'].toString(),
              item['name'].toString(),
              '${item['total'] ?? item['trackCount'] ?? 0} 首歌曲',
              item['coverUrl'] as String?,
              'playlist',
            ),
          )
          .toList(),
      total: (data['total'] as num? ?? offset + items.length).toInt(),
      nextOffset: local
          ? _next(offset, items.length, (data['total'] as num).toInt())
          : (data['nextOffset'] as num?)?.toInt(),
    );
  }

  Future<bool> addToPlaylist(Track track, String playlistId) async {
    if (track.isPodcast) {
      throw const ApiException('UNSUPPORTED_CONTENT', '节目不能加入歌曲歌单。');
    }
    final data =
        await api.post(
              '/${track.mode == MusicMode.bilibili ? 'bilibili' : 'netease'}/playlists/$playlistId/tracks',
              {'trackId': track.id},
            )
            as Json;
    if (data['added'] is! bool) {
      throw const ApiException('PLAYLIST_UPDATE_FAILED', '服务器未确认添加结果。');
    }
    return data['added'] as bool;
  }

  Future<Collection> createPlaylist(MusicMode mode, String name) async {
    final local = mode == MusicMode.bilibili;
    final data =
        await api.post(
              local ? '/bilibili/playlists' : '/netease/playlist/create',
              local
                  ? {'name': name, 'description': '', 'trackIds': <String>[]}
                  : {'name': name, 'privacy': '10'},
            )
            as Json;
    final id = local ? data['id'] : data['playlist']?['id'];
    if (id == null || !local && data['code'] != 200) {
      throw const ApiException('PLAYLIST_CREATE_FAILED', '服务器未确认歌单创建结果。');
    }
    return Collection(id.toString(), name, '0 首歌曲', null, 'playlist');
  }

  /// 批量补齐心动队列展示信息，缓存仍绑定当前登录会话。
  Future<void> hydrate(Iterable<String> ids) async {
    final session = api.token;
    final missing = ids
        .where((id) => cached(MusicMode.netease, id) == null)
        .take(100)
        .toList();
    if (missing.isEmpty) return;
    final data =
        await api.get('/netease/song/detail', {'ids': missing.join(',')})
            as Json;
    remember(
      (data['songs'] as List? ?? []).map((item) => Track.netease(item as Json)),
      session,
    );
  }

  /// 游标按服务端实际消费的条目推进，不用可显示歌曲数推算偏移。
  int? _next(int offset, int received, int total) =>
      received > 0 && offset + received < total ? offset + received : null;

  Future<Track> detail(
    MusicMode mode,
    String id, {
    bool isPodcast = false,
  }) async {
    final session = api.token;
    // 节目详情按节目身份查询，音轨映射留在服务端处理。
    if (mode == MusicMode.netease && isPodcast) {
      final data =
          await api.get('/netease/podcasts/program', {'id': id}) as Json;
      final track = Track.podcast(data['program'] as Json);
      remember([track], session);
      return track;
    }
    if (mode == MusicMode.bilibili) {
      final track = Track.bilibili(
        await api.get('/bilibili/tracks/$id') as Json,
      );
      remember([track], session);
      return track;
    }
    final data = await api.get('/netease/song/detail', {'ids': id}) as Json;
    final songs = data['songs'] as List? ?? [];
    if (songs.isEmpty) {
      throw const ApiException('TRACK_UNAVAILABLE', '这首歌曲暂不可用。');
    }
    final track = Track.netease(songs.first as Json);
    remember([track], session);
    return track;
  }

  /// B 站模式：订阅、红心、本地歌单与搜索；“资料库”暂时为空。
  Future<CatalogPage> _browseBilibili(
    String section,
    String query,
    int offset,
    Collection? collection,
    String? session,
    bool searchSubscriptions,
  ) async {
    final args = <String, dynamic>{'offset': offset, 'limit': 100};
    Future<CatalogPage> tracks(
      String path, [
      Json? extra,
      void Function(Json data)? onData,
    ]) async {
      final data = await api.get(path, {...args, ...?extra}) as Json;
      onData?.call(data);
      final raw = (data['items'] as List? ?? []).cast<Json>();
      final list = raw.map(Track.bilibili).toList();
      remember(list, session);
      final total = (data['total'] as num? ?? list.length).toInt();
      return CatalogPage(
        tracks: list,
        total: total,
        nextOffset: _next(offset, raw.length, total),
      );
    }

    Future<CatalogPage> collections(String path, String kind) async {
      final data = await api.get(path, args) as Json;
      final raw = (data['items'] as List? ?? []).cast<Json>();
      final total = (data['total'] as num? ?? raw.length).toInt();
      return CatalogPage(
        total: total,
        nextOffset: _next(offset, raw.length, total),
        collections: [
          for (final item in raw)
            Collection(
              item['id'].toString(),
              item['name'].toString(),
              kind == 'subscription'
                  ? '${item['typeLabel']} · ${item['trackCount']} 首'
                  : '${item['trackCount'] ?? 0} 首歌曲',
              item['coverUrl'] as String?,
              kind,
            ),
        ],
      );
    }

    // 从搜索结果跳转到来源时 query 仍在，来源页要排在搜索之前判断。
    if (collection?.kind == 'source') {
      final current = collection!;
      Json meta = const {};
      final page = await tracks('/bilibili/sources/preview', {
        'input': current.id,
      }, (data) => meta = data);
      return CatalogPage(
        tracks: page.tracks,
        total: page.total,
        nextOffset: page.nextOffset,
        source: Collection(
          current.id,
          '${meta['name'] ?? current.title}',
          '${meta['typeLabel'] ?? current.subtitle.split(' · ').first} · ${page.total} 首',
          (meta['cover'] as String?)?.isNotEmpty == true
              ? meta['cover'] as String
              : current.cover,
          'source',
          canSubscribe: true,
          subscribed: meta['subscribedId'] != null,
        ),
      );
    }
    if (query.isNotEmpty) {
      return tracks('/bilibili/tracks', {
        'q': query,
        if (searchSubscriptions) 'scope': 'subscriptions',
      });
    }
    if (collection?.kind == 'playlist') {
      return tracks('/bilibili/playlists/${collection!.id}');
    }
    if (collection?.kind == 'subscription') {
      final current = collection!;
      final page = await tracks('/bilibili/subscriptions/${current.id}/tracks');
      // 刷新或翻页后，页头的“类型 · N 首”要用最新数量，不能沿用进入时的旧值。
      final label = current.subtitle.split(' · ').first;
      return CatalogPage(
        tracks: page.tracks,
        total: page.total,
        nextOffset: page.nextOffset,
        source: Collection(
          current.id,
          current.title,
          '$label · ${page.total} 首',
          current.cover,
          current.kind,
        ),
      );
    }
    switch (section) {
      case 'favorites':
        return tracks('/bilibili/favorites');
      case 'subscriptions':
        return collections('/bilibili/subscriptions', 'subscription');
      case 'playlists':
        return collections('/bilibili/playlists', 'playlist');
    }
    return const CatalogPage();
  }

  Future<CatalogPage> browse(
    MusicMode mode,
    String section, {
    String query = '',
    int offset = 0,
    Collection? collection,
    SearchCategory searchCategory = SearchCategory.songs,
    bool artistAlbums = false,
    DiscoverSection discovery = DiscoverSection.recommended,
    String playlistCategory = '全部',
    String playlistOrder = 'hot',
    bool searchSubscriptions = false,
  }) async {
    final session = api.token;
    if (mode == MusicMode.bilibili) {
      return _browseBilibili(
        section,
        query,
        offset,
        collection,
        session,
        searchSubscriptions,
      );
    }
    // 播客与歌曲分开浏览，分页沿用统一的显式游标。
    if (section == 'podcasts' ||
        section == 'podcastsCreated' ||
        collection?.kind == 'podcast') {
      final programs = collection?.kind == 'podcast';
      final data =
          await api.get(
                programs ? '/netease/podcasts/programs' : '/netease/podcasts',
                {
                  'offset': offset,
                  'limit': 50,
                  if (programs) 'radioId': collection!.id,
                  if (!programs)
                    'kind': section == 'podcastsCreated'
                        ? 'created'
                        : 'subscribed',
                },
              )
              as Json;
      final items = (data['items'] as List? ?? []).cast<Json>();
      final tracks = programs ? items.map(Track.podcast).toList() : <Track>[];
      remember(tracks, session);
      return CatalogPage(
        tracks: tracks,
        collections: programs
            ? []
            : items
                  .map(
                    (item) => Collection(
                      item['id'].toString(),
                      item['title'].toString(),
                      '${item['artist']} · ${item['programCount']} 期节目',
                      item['cover'] as String?,
                      'podcast',
                    ),
                  )
                  .toList(),
        total: (data['total'] as num).toInt(),
        nextOffset: (data['nextOffset'] as num?)?.toInt(),
      );
    }
    // 喜欢页与普通歌单共用有序分页和完整歌单播放上下文。
    if (section == 'favorites' && (collection == null || offset == 0)) {
      final data = await api.get('/netease/liked/playlist') as Json;
      final item = data['playlist'] as Json;
      collection = Collection(
        item['id'].toString(),
        '我喜欢的音乐',
        '${item['trackCount']} 首歌曲',
        item['coverUrl'] as String?,
        'playlist',
        isLiked: true,
      );
    }
    if (collection != null) {
      if (collection.kind == 'playlist') {
        final data =
            await api.get('/netease/playlist/page', {
                  'id': collection.id,
                  'offset': offset,
                  'limit': 100,
                })
                as Json;
        final metadata = data['playlist'] as Json;
        final liked = collection.isLiked || metadata['isLiked'] == true;
        final tracks = (data['items'] as List? ?? [])
            .map((s) => Track.netease(s as Json, favorite: liked))
            .toList();
        remember(tracks, session);
        return CatalogPage(
          tracks: tracks,
          total: (data['total'] as num).toInt(),
          nextOffset: (data['nextOffset'] as num?)?.toInt(),
          source: Collection(
            collection.id,
            liked ? '我喜欢的音乐' : metadata['name'].toString(),
            '${data['total']} 首歌曲',
            metadata['coverUrl'] as String?,
            'playlist',
            isLiked: liked,
            canSubscribe: metadata['canSubscribe'] == true,
            subscribed: metadata['subscribed'] == true,
          ),
        );
      }
      if (collection.kind == 'artist') {
        final data =
            await api.get(
                  artistAlbums
                      ? '/netease/artist/album'
                      : '/netease/artist/songs',
                  {'id': collection.id, 'offset': offset, 'limit': 50},
                )
                as Json;
        final raw = (data[artistAlbums ? 'hotAlbums' : 'songs'] as List? ?? [])
            .cast<Json>();
        final tracks = artistAlbums
            ? <Track>[]
            : raw.map(Track.netease).toList();
        remember(tracks, session);
        final total = (data['total'] as num?)?.toInt() ?? offset + raw.length;
        return CatalogPage(
          tracks: tracks,
          collections: artistAlbums
              ? raw
                    .map(
                      (item) => _searchCollection(item, SearchCategory.albums),
                    )
                    .toList()
              : const [],
          total: total,
          nextOffset:
              raw.isNotEmpty &&
                  (data['more'] == true || offset + raw.length < total)
              ? offset + raw.length
              : null,
        );
      }
      final data =
          await api.get('/netease/album', {'id': collection.id}) as Json;
      final tracks = (data['songs'] as List? ?? [])
          .map((s) => Track.netease(s as Json))
          .toList();
      remember(tracks, session);
      return CatalogPage(
        tracks: tracks,
        total: (data['total'] as num? ?? tracks.length).toInt(),
      );
    }
    if (query.isNotEmpty || section == 'search') {
      return search(query, searchCategory, offset);
    }
    // 发现只负责浏览；FM由实际推荐队列页呈现，进入标签不取歌或换队列。
    if (section == 'discover' && discovery != DiscoverSection.recommended) {
      if (discovery == DiscoverSection.fm) return const CatalogPage();
      final charts = discovery == DiscoverSection.charts;
      final data =
          await api.get(
                charts ? '/netease/toplist' : '/netease/top/playlist',
                charts
                    ? null
                    : {
                        'cat': playlistCategory,
                        'order': playlistOrder,
                        'offset': offset,
                        'limit': 50,
                      },
              )
              as Json;
      final raw = data[charts ? 'list' : 'playlists'];
      if (raw is! List || data['code'] != null && data['code'] != 200) {
        throw const ApiException('DISCOVERY_UNAVAILABLE', '暂时无法读取发现内容，请重试。');
      }
      final items = raw.cast<Json>();
      return CatalogPage(
        collections: items
            .map(
              (item) => Collection(
                item['id'].toString(),
                item['name']?.toString() ?? '未命名歌单',
                charts
                    ? item['updateFrequency']?.toString() ?? '网易云排行榜'
                    : '${item['trackCount'] ?? '—'} 首歌曲',
                (item['coverImgUrl'] ?? item['picUrl']) as String?,
                'playlist',
              ),
            )
            .toList(),
        total: (data['total'] as num?)?.toInt() ?? items.length,
        nextOffset:
            !charts &&
                items.isNotEmpty &&
                (data['more'] == true ||
                    offset + items.length <
                        ((data['total'] as num?)?.toInt() ?? items.length))
            ? offset + items.length
            : null,
      );
    }
    if (section == 'songs') {
      final data = await api.get('/netease/recommend/songs') as Json;
      final body = data['data'] as Json? ?? data;
      final tracks = (body['dailySongs'] as List? ?? [])
          .map((s) => Track.netease(s as Json))
          .toList();
      remember(tracks, session);
      return CatalogPage(tracks: tracks, total: tracks.length);
    }
    final personal = section == 'playlists';
    final data =
        await api.get(
              personal
                  ? '/netease/user/playlist'
                  : '/netease/recommend/resource',
              personal ? {'offset': offset, 'limit': 50} : null,
            )
            as Json;
    final items = (data[personal ? 'playlist' : 'recommend'] as List? ?? [])
        .cast<Json>();
    return CatalogPage(
      nextOffset: data['more'] == true && items.isNotEmpty
          ? offset + items.length
          : null,
      total: (data['more'] == true
          ? offset + items.length + 1
          : offset + items.length),
      collections: items
          .map(
            (c) => Collection(
              c['id'].toString(),
              c['name'].toString(),
              '${c['trackCount'] ?? c['songCount'] ?? '—'} 首歌曲',
              (c['picUrl'] ?? c['coverImgUrl']) as String?,
              'playlist',
            ),
          )
          .toList(),
    );
  }
}
