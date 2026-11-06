import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show SelectionArea;
import 'package:flutter/services.dart';
import '../core/api_client.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';
import '../playback/playback_controller.dart';
import '../platform/desktop_window.dart';
import 'bilibili_jump.dart';
import 'catalog.dart';
import 'song_actions.dart';
import 'search_controls.dart';
import 'discovery_controls.dart';
import 'intelligence_page.dart';
import 'login_required.dart';
import 'playlist_editor.dart';
import 'subscription_actions.dart';

/// 每种模式保留独立查询、页面与滚动位置。
class BrowseState extends ChangeNotifier {
  BrowseState(this.mode, this.catalog)
    : section = mode == MusicMode.netease ? 'discover' : 'subscriptions' {
    catalog.addListener(_catalogChanged);
    _playlistRevision = catalog.playlistRevision;
  }
  final MusicMode mode;
  final Catalog catalog;
  String section, query = '';
  SearchCategory searchCategory = SearchCategory.all;
  bool artistAlbums = false;

  /// B 站搜索范围：false 为全 B 站，true 为只搜我的订阅（按原视频名）。
  bool searchSubscriptions = false;

  /// 订阅页的显示方式：列表（默认）或大封面网格。
  bool subscriptionList = true;
  void toggleSubscriptionLayout() {
    subscriptionList = !subscriptionList;
    notifyListeners();
  }

  DiscoverSection discovery = DiscoverSection.recommended;
  String playlistCategory = '全部', playlistOrder = 'hot';

  /// 发现标签与筛选只改浏览状态，不改变当前播放。
  Future<void> selectDiscovery(
    DiscoverSection target, {
    String? category,
    String? order,
  }) async {
    discovery = target;
    playlistCategory = category ?? playlistCategory;
    playlistOrder = order ?? playlistOrder;
    await navigate('discover');
  }

  late int _playlistRevision;
  final _searchPages =
      <SearchCategory, ({CatalogPage page, double position})>{};
  final _parents = <Collection>[];
  Collection? collection;

  /// 浏览层级深度（进入集合 +1，集合里再进入 +1）；外壳据此决定页面切换动画方向。
  int get depth => drilled ? _parents.length + 1 : 0;

  /// 搜索前的浏览位置。关闭搜索时原样恢复（含已进入的集合和滚动位置），不重新请求。
  ({
    String section,
    String query,
    Collection? collection,
    List<Collection> parents,
    CatalogPage page,
    bool loaded,
    bool artistAlbums,
    double offset,
  })?
  _beforeSearch;

  void rememberBeforeSearch() {
    if (section == 'search') return;
    _beforeSearch = (
      section: section,
      query: query,
      collection: collection,
      parents: [..._parents],
      page: page,
      loaded: loaded && error == null,
      artistAlbums: artistAlbums,
      offset: scroll.hasClients ? scroll.offset : 0,
    );
  }

  /// 恢复搜索前的页面；没有可恢复的内容时返回 false，由调用方重新打开。
  bool restoreBeforeSearch() {
    final saved = _beforeSearch;
    _beforeSearch = null;
    if (saved == null || !saved.loaded) return false;
    ++_ticket;
    section = saved.section;
    query = saved.query;
    collection = saved.collection;
    _parents
      ..clear()
      ..addAll(saved.parents);
    page = saved.page;
    artistAlbums = saved.artistAlbums;
    loaded = true;
    loading = false;
    error = null;
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed && scroll.hasClients) {
        scroll.jumpTo(saved.offset.clamp(0, scroll.position.maxScrollExtent));
      }
    });
    return true;
  }

  /// 是否进入了某个集合的内部（歌单、专辑、艺人、播客等），决定“返回”是否有意义。
  /// “我喜欢”加载后也会带上来源歌单，但它是资料库入口本身，不算进入集合。
  bool get drilled => collection != null && section != 'favorites';
  CatalogPage page = const CatalogPage();
  bool loading = false, loaded = false;
  bool _retryMore = false;
  String? error;
  int _ticket = 0;
  bool _disposed = false;
  final scroll = ScrollController();

  /// 收藏成功只使“我的歌单”失效，不刷新播放或其他浏览列表。
  int _syncRevision = 0;
  void _catalogChanged() {
    if (_syncRevision != catalog.syncRevision) {
      _syncRevision = catalog.syncRevision;
      if (mode == MusicMode.bilibili &&
          const {'subscriptions', 'favorites', 'playlists'}.contains(section)) {
        load();
      }
    }
    if (_playlistRevision == catalog.playlistRevision) return;
    _playlistRevision = catalog.playlistRevision;
    if (mode == MusicMode.netease &&
        section == 'playlists' &&
        collection == null) {
      load();
    }
  }

  void _saveSearch() {
    if (section == 'search' && collection == null && loaded && error == null) {
      _searchPages[searchCategory] = (
        page: page,
        position: scroll.hasClients ? scroll.offset : 0,
      );
    }
  }

  /// 每类独立保留结果和滚动；新请求票号使之前的回包失效。
  Future<void> selectSearch(SearchCategory category) async {
    _saveSearch();
    searchCategory = category;
    collection = null;
    _parents.clear();
    final cached = _searchPages[category];
    ++_ticket;
    loading = false;
    error = null;
    loaded = cached != null;
    if (cached != null) {
      page = cached.page;
      notifyListeners();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed && searchCategory == category && scroll.hasClients) {
          scroll.jumpTo(
            cached.position.clamp(0, scroll.position.maxScrollExtent),
          );
        }
      });
    } else {
      if (scroll.hasClients) scroll.jumpTo(0);
      await load();
    }
  }

  Future<void> openCollection(Collection item) async {
    _saveSearch();
    if (collection != null) _parents.add(collection!);
    collection = item;
    artistAlbums = false;
    loaded = false;
    if (scroll.hasClients) scroll.jumpTo(0);
    await load();
  }

  Future<void> back() async {
    if (_parents.isNotEmpty) {
      collection = _parents.removeLast();
      artistAlbums = collection!.kind == 'artist';
      loaded = false;
      await load();
    } else if (section == 'search') {
      await selectSearch(searchCategory);
    } else {
      await navigate(section);
    }
  }

  Future<void> selectSearchScope(bool subscriptions) async {
    if (subscriptions == searchSubscriptions) return;
    searchSubscriptions = subscriptions;
    ++_ticket;
    loading = false;
    error = null;
    loaded = false;
    if (scroll.hasClients) scroll.jumpTo(0);
    await load();
  }

  Future<void> selectArtist(bool albums) async {
    artistAlbums = albums;
    loaded = false;
    if (scroll.hasClients) scroll.jumpTo(0);
    await load();
  }

  String get title =>
      collection?.title ??
      (query.isNotEmpty
          ? '搜索结果'
          : {
                  'discover': '现在就听',
                  'songs': '每日推荐',
                  'subscriptions': '我的订阅',
                  'library': '资料库',
                  'albums': '专辑',
                  'artists': '艺人',
                  'favorites': '我喜欢',
                  'intelligence': '心动模式',
                  'playlists': mode == MusicMode.netease ? '我的歌单' : '歌单',
                  'podcasts': '播客',
                  'podcastsCreated': '播客',
                  'search': '搜索',
                }[section] ??
                '音乐');
  Json get queueContext => {
    'kind':
        collection?.kind ??
        (section == 'favorites'
            ? 'favorites'
            : mode == MusicMode.netease && section == 'songs' && query.isEmpty
            ? 'daily'
            : 'tracks'),
    if (collection != null) 'id': collection!.id,
    if (query.isNotEmpty) 'q': query,
    if (mode == MusicMode.bilibili && query.isNotEmpty && searchSubscriptions)
      'scope': 'subscriptions',
  };
  Future<void> navigate(
    String next, {
    String text = '',
    Collection? target,
  }) async {
    _parents.clear();
    if (next == 'search' && (section != next || text != query)) {
      _searchPages.clear();
      searchCategory = SearchCategory.all;
    }
    if (next == 'search' && target == null) _searchPages.clear();
    section = next;
    query = text;
    collection = target;
    loaded = false;
    if (scroll.hasClients) scroll.jumpTo(0);
    if (next == 'intelligence') {
      ++_ticket;
      loading = false;
      loaded = true;
      error = null;
      notifyListeners();
      return;
    }
    await load();
  }

  /// 页尾预取由滚动和布局共同触发，失败后只接受显式重试。
  void loadNearEnd() {
    if (_disposed ||
        loading ||
        !loaded ||
        error != null ||
        page.nextOffset == null ||
        !scroll.hasClients) {
      return;
    }
    if (scroll.position.extentAfter < 480) load(more: true);
  }

  Future<void> retry() => load(more: _retryMore);

  /// 游客打开“我喜欢 / 我的歌单 / 播客”这类依赖网易云账号的页面：不请求，显示登录提示。
  bool get needsLogin =>
      catalog.api.guest &&
      mode == MusicMode.netease &&
      collection == null &&
      (section == 'favorites' ||
          section == 'playlists' ||
          section.startsWith('podcasts'));

  Future<void> load({bool more = false}) async {
    if (_disposed || (more && (loading || page.nextOffset == null))) return;
    if (needsLogin) {
      ++_ticket;
      loading = false;
      loaded = false;
      error = null;
      page = const CatalogPage();
      notifyListeners();
      return;
    }
    final ticket = ++_ticket;
    loading = true;
    error = null;
    _retryMore = more;
    notifyListeners();
    var cached = false;
    try {
      final offset = more ? page.nextOffset! : 0;
      Future<CatalogPage> fetch() => catalog.browse(
        mode,
        section,
        query: query,
        offset: offset,
        collection: collection,
        searchCategory: searchCategory,
        searchSubscriptions: searchSubscriptions,
        artistAlbums: artistAlbums,
        discovery: discovery,
        playlistCategory: playlistCategory,
        playlistOrder: playlistOrder,
      );
      // 首屏先用磁盘上的请求缓存立即显示，再从网络刷新；网络失败时保留缓存内容。
      if (!more) {
        try {
          final saved = await runZoned(fetch, zoneValues: {cacheOnly: true});
          if (_disposed || ticket != _ticket) return;
          page = saved;
          collection = saved.source ?? collection;
          loaded = cached = true;
          notifyListeners();
        } catch (_) {
          // 没有缓存或缓存不完整，等网络结果。
        }
      }
      final result = await runZoned(fetch, zoneValues: {cacheWrite: true});
      if (_disposed || ticket != _ticket) return;
      final knownTracks = page.tracks
          .map((track) => '${track.mode.name}:${track.id}')
          .toSet();
      final knownCollections = page.collections
          .map((item) => '${item.kind}:${item.id}')
          .toSet();
      final freshTracks = result.tracks
          .where((track) => knownTracks.add('${track.mode.name}:${track.id}'))
          .toList();
      final freshCollections = result.collections
          .where((item) => knownCollections.add('${item.kind}:${item.id}'))
          .toList();
      final next =
          result.nextOffset != null &&
              result.nextOffset! > offset &&
              (!more || freshTracks.isNotEmpty || freshCollections.isNotEmpty)
          ? result.nextOffset
          : null;
      page = more
          ? CatalogPage(
              tracks: [...page.tracks, ...freshTracks],
              collections: [...page.collections, ...freshCollections],
              total: result.total,
              nextOffset: next,
              source: result.source ?? page.source,
            )
          : CatalogPage(
              tracks: result.tracks,
              collections: result.collections,
              total: result.total,
              nextOffset: next,
              source: result.source,
              blocks: result.blocks,
            );
      collection = result.source ?? collection;
      loaded = true;
    } catch (e) {
      if (!_disposed && ticket == _ticket && !cached) error = readableError(e);
    } finally {
      if (!_disposed && ticket == _ticket) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_ticket;
    catalog.removeListener(_catalogChanged);
    scroll.dispose();
    super.dispose();
  }
}

class BrowsePage extends StatelessWidget {
  const BrowsePage({
    super.key,
    required this.browser,
    required this.playback,
    required this.onSettings,
    required this.onExpand,
    this.window,
    this.showBack = true,
  });
  final BrowseState browser;
  final PlaybackController playback;
  final VoidCallback onSettings, onExpand;
  final DesktopWindow? window;

  /// iPhone 由外壳顶部统一提供返回按钮，页面内不再重复。
  final bool showBack;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: browser,
    builder: (_, _) {
      // iPhone 窄屏使用更小的页边距；桌面保持原值。
      final g = DymuseTokens.mobile ? 20.0 : 32.0;
      final rowInset = DymuseTokens.mobile ? 10.0 : 24.0;
      final discoverRoot =
          browser.mode == MusicMode.netease &&
          browser.section == 'discover' &&
          browser.collection == null;
      Widget discoveryControls() => DiscoveryControls(
        catalog: browser.catalog,
        selected: browser.discovery,
        category: browser.playlistCategory,
        onSelect: browser.selectDiscovery,
        onCategory: (value) =>
            browser.selectDiscovery(DiscoverSection.playlists, category: value),
      );
      if (discoverRoot && browser.discovery == DiscoverSection.fm) {
        // 页眉交给列表作为第一项，随内容一起上滑，与推荐排行榜、歌单广场一致。
        return IntelligencePage(
          key: const ValueKey('private-fm-page'),
          playback: playback,
          onExpand: onExpand,
          privateFm: true,
          header: Padding(
            padding: EdgeInsets.fromLTRB(g, DymuseTokens.mobile ? 4 : 24, g, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('现在就听', style: DymuseTokens.heading),
                discoveryControls(),
              ],
            ),
          ),
        );
      }
      final page = browser.loaded ? browser.page : const CatalogPage();
      final empty =
          page.tracks.isEmpty &&
          page.collections.isEmpty &&
          page.blocks.isEmpty;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => browser.loadNearEnd(),
      );
      return NotificationListener<ScrollNotification>(
        onNotification: (_) {
          browser.loadNearEnd();
          return false;
        },
        child: CustomScrollView(
          controller: browser.scroll,
          slivers: [
            // iPhone 内容延伸到悬浮顶栏下方，开头留出顶栏高度；其他平台为 0。
            SliverPadding(
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  g,
                  DymuseTokens.mobile ? 4 : 24,
                  g,
                  24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showBack && browser.drilled)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: DymuseTokens.liquid
                            ? Align(
                                alignment: Alignment.centerLeft,
                                child: GlassPillButton(
                                  label: '返回列表',
                                  text: '返回',
                                  icon: CupertinoIcons.chevron_left,
                                  onPressed: browser.back,
                                ),
                              )
                            : ActionButton(
                                label: '返回列表',
                                onPressed: browser.back,
                                child: const Text('‹ 返回列表'),
                              ),
                      ),
                    // Apple 平台的音乐模式只在模式切换处标示；Windows 保留页眉小标。
                    if (!DymuseTokens.liquid) ...[
                      Text(
                        browser.mode.label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: DymuseTokens.tint(context),
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 7),
                    ],
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            browser.title,
                            style: DymuseTokens.heading,
                          ),
                        ),
                        ActionButton(
                          label: '刷新',
                          icon: CupertinoIcons.arrow_clockwise,
                          onPressed: browser.loading ? null : browser.load,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (discoverRoot) discoveryControls(),
                    if (browser.mode == MusicMode.bilibili &&
                        browser.section == 'playlists')
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Builder(
                          builder: (context) {
                            final create = browser.collection == null;
                            Future<void> open() async {
                              final changed = await Navigator.of(context)
                                  .push<bool>(
                                    CupertinoPageRoute(
                                      builder: (_) => PlaylistEditorPage(
                                        catalog: browser.catalog,
                                        playlist: browser.collection,
                                        window: window,
                                      ),
                                    ),
                                  );
                              if (changed == true && context.mounted) {
                                await browser.navigate('playlists');
                              }
                            }

                            return DymuseTokens.liquid
                                ? Align(
                                    alignment: Alignment.centerLeft,
                                    child: GlassPillButton(
                                      label: create ? '新建歌单' : '编辑歌单',
                                      icon: create
                                          ? CupertinoIcons.plus
                                          : CupertinoIcons.pencil,
                                      onPressed: open,
                                    ),
                                  )
                                : ActionButton(
                                    label: create ? '新建歌单' : '编辑歌单',
                                    icon: create
                                        ? CupertinoIcons.plus
                                        : CupertinoIcons.pencil,
                                    onPressed: open,
                                  );
                          },
                        ),
                      ),
                    if (browser.mode == MusicMode.bilibili &&
                        browser.section == 'subscriptions')
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: _subscriptionButtons(context),
                      ),
                    if (browser.mode == MusicMode.netease &&
                        browser.section == 'search' &&
                        browser.collection == null)
                      SearchScopes(
                        selected: browser.searchCategory,
                        onSelect: browser.selectSearch,
                      ),
                    if (browser.mode == MusicMode.bilibili &&
                        browser.section == 'search' &&
                        browser.collection == null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: DymuseTokens.liquid
                            ? GlassChoiceRow<bool>(
                                values: const [false, true],
                                selected: browser.searchSubscriptions,
                                labelOf: (subs) => subs ? '我的订阅' : '全 B 站',
                                onSelect: browser.selectSearchScope,
                              )
                            : CupertinoSlidingSegmentedControl<bool>(
                                groupValue: browser.searchSubscriptions,
                                children: const {
                                  false: Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Text('全 B 站'),
                                  ),
                                  true: Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Text('我的订阅'),
                                  ),
                                },
                                onValueChanged: (value) {
                                  if (value != null) {
                                    browser.selectSearchScope(value);
                                  }
                                },
                              ),
                      ),
                    if (browser.mode == MusicMode.netease &&
                        browser.collection?.kind == 'artist')
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: DymuseTokens.liquid
                            ? GlassChoiceRow<bool>(
                                values: const [false, true],
                                selected: browser.artistAlbums,
                                labelOf: (albums) => albums ? '专辑' : '歌曲',
                                onSelect: browser.selectArtist,
                              )
                            : CupertinoSlidingSegmentedControl<bool>(
                                groupValue: browser.artistAlbums,
                                children: const {
                                  false: Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Text('歌曲'),
                                  ),
                                  true: Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Text('专辑'),
                                  ),
                                },
                                onValueChanged: (value) {
                                  if (value != null) {
                                    browser.selectArtist(value);
                                  }
                                },
                              ),
                      ),
                    if (browser.mode == MusicMode.netease &&
                        browser.collection?.canSubscribe == true)
                      PlaylistSubscriptionButton(
                        catalog: browser.catalog,
                        collection: browser.collection!,
                      ),
                    if (browser.section.startsWith('podcasts') &&
                        browser.collection == null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: DymuseTokens.liquid
                            ? GlassChoiceRow<String>(
                                values: const ['podcasts', 'podcastsCreated'],
                                selected: browser.section,
                                labelOf: (value) =>
                                    value == 'podcasts' ? '我订阅的' : '我创建的',
                                onSelect: browser.navigate,
                              )
                            : CupertinoSlidingSegmentedControl<String>(
                                groupValue: browser.section,
                                children: const {
                                  'podcasts': Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Text('我订阅的'),
                                  ),
                                  'podcastsCreated': Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Text('我创建的'),
                                  ),
                                },
                                onValueChanged: (value) {
                                  if (value != null) browser.navigate(value);
                                },
                              ),
                      ),
                    // 现在就听页不再显示说明小字；Windows 保持原样。
                    if (!(DymuseTokens.liquid && discoverRoot))
                      Text(
                        browser.query.isNotEmpty && browser.collection == null
                            ? '“${browser.query}”${(browser.searchCategory == SearchCategory.all && browser.mode == MusicMode.netease) || (browser.mode == MusicMode.bilibili && !browser.searchSubscriptions) ? '' : ' · ${page.total} 个结果'}'
                            : browser.collection?.subtitle ??
                                  (browser.section == 'discover' &&
                                          browser.discovery ==
                                              DiscoverSection.recommended
                                      ? ''
                                      : '${page.total} ${browser.section.startsWith('podcasts') ? (browser.collection == null ? '个播客' : '期节目') : (page.collections.isNotEmpty ? '个项目' : '首歌曲')}'),
                        style: DymuseTokens.body.copyWith(
                          color: DymuseTokens.secondary(context),
                        ),
                      ),
                    if (page.tracks.isNotEmpty) ...[
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          if (DymuseTokens.liquid)
                            GlassPlayButton(
                              onPressed: () =>
                                  _play(page.tracks.first, wholeList: true),
                            )
                          else
                            ActionButton(
                              label: '播放',
                              filled: true,
                              onPressed: () =>
                                  _play(page.tracks.first, wholeList: true),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(CupertinoIcons.play_fill, size: 15),
                                  SizedBox(width: 8),
                                  Text('播放'),
                                ],
                              ),
                            ),
                          if (browser.mode == MusicMode.bilibili &&
                              browser.collection?.kind == 'source') ...[
                            const SizedBox(width: 12),
                            _subscribeButton(context),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (browser.needsLogin)
              SliverFillRemaining(
                hasScrollBody: false,
                child: LoginRequiredView(
                  api: browser.catalog.api,
                  title: switch (browser.section) {
                    'favorites' => '我喜欢',
                    'playlists' => '我的歌单',
                    _ => '播客',
                  },
                ),
              ),
            if (browser.loading && !browser.loaded && !browser.needsLogin)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CupertinoActivityIndicator()),
              ),
            if (browser.error != null && !browser.loaded && !browser.needsLogin)
              SliverFillRemaining(
                hasScrollBody: false,
                child: StatusMessage(
                  title: '暂时无法载入',
                  message: browser.error!,
                  icon: CupertinoIcons.exclamationmark_circle,
                  action: Wrap(
                    spacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      ActionButton(label: '重试', onPressed: browser.retry),
                      if (browser.mode == MusicMode.netease)
                        ActionButton(label: '账号设置', onPressed: onSettings),
                    ],
                  ),
                ),
              ),
            if (empty &&
                !browser.loading &&
                browser.error == null &&
                !browser.needsLogin)
              SliverFillRemaining(
                hasScrollBody: false,
                child: StatusMessage(
                  title: browser.section == 'search' && browser.query.isNotEmpty
                      ? '没有找到结果'
                      : browser.section.startsWith('podcasts')
                      ? '这里还没有播客或节目'
                      : browser.section == 'search' && browser.query.isEmpty
                      ? '找到想听的音乐'
                      : '这里还没有音乐',
                  message: browser.section == 'search' && browser.query.isEmpty
                      ? '在上方输入关键词，按回车或点击搜索。'
                      : browser.section == 'search' && browser.query.isNotEmpty
                      ? '试试其他关键词或切换搜索分类。'
                      : browser.section.startsWith('podcasts')
                      ? '这里显示当前网易云账号订阅的播客及创建的已发布电台。'
                      : browser.mode == MusicMode.bilibili
                      ? (browser.section == 'subscriptions'
                            ? '点上方“添加订阅”，粘贴合集、系列、收藏夹、UP 主主页或视频的链接。'
                            : browser.section == 'library'
                            ? '资料库暂时为空。'
                            : '在搜索里找到喜欢的视频，点红心或加入歌单。')
                      : '绑定网易云账号后刷新，或试试搜索。',
                ),
              ),
            if (page.collections.isNotEmpty &&
                browser.mode == MusicMode.bilibili &&
                browser.section == 'subscriptions' &&
                browser.collection == null &&
                browser.subscriptionList)
              SliverList.builder(
                itemCount: page.collections.length,
                itemBuilder: (context, index) =>
                    _subscriptionRow(context, page.collections[index], g),
              )
            else if (page.collections.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: g),
                sliver: SliverLayoutBuilder(
                  builder: (_, constraints) {
                    final count = (constraints.crossAxisExtent / 190)
                        .floor()
                        .clamp(2, 6);
                    final scale =
                        MediaQuery.textScalerOf(context).scale(14) / 14;
                    return SliverGrid.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: count,
                        crossAxisSpacing: 22,
                        mainAxisSpacing: 22,
                        mainAxisExtent:
                            (constraints.crossAxisExtent - (count - 1) * 22) /
                                count +
                            70 * scale,
                      ),
                      itemCount: page.collections.length,
                      itemBuilder: (_, index) =>
                          _collection(context, page.collections[index]),
                    );
                  },
                ),
              ),
            for (final block in page.blocks) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(g, 12, g, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          block.category.label,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      ActionButton(
                        label: '查看全部${block.category.label}',
                        onPressed: () => browser.selectSearch(block.category),
                        child: const Text('查看全部'),
                      ),
                    ],
                  ),
                ),
              ),
              if (block.page.tracks.isNotEmpty)
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: rowInset),
                  sliver: SliverList.builder(
                    itemCount: block.page.tracks.length.clamp(0, 5),
                    itemBuilder: (_, index) => TrackRow(
                      track: block.page.tracks[index],
                      index: index,
                      api: browser.catalog.api,
                      playback: playback,
                      onPlay: () => _play(block.page.tracks[index]),
                      onActivate: () => _activate(block.page.tracks[index]),
                      onFavorite: (liked) =>
                          _favorite(context, block.page.tracks[index], liked),
                      onOpenCollection: browser.openCollection,
                    ),
                  ),
                ),
              if (block.page.collections.isNotEmpty)
                SliverToBoxAdapter(
                  child: SizedBox(
                    height:
                        260 +
                        (MediaQuery.textScalerOf(context).scale(14) - 14) * 3,
                    child: ListView.separated(
                      padding: EdgeInsets.symmetric(horizontal: g),
                      scrollDirection: Axis.horizontal,
                      itemCount: block.page.collections.length.clamp(0, 6),
                      separatorBuilder: (_, _) => const SizedBox(width: 20),
                      itemBuilder: (_, index) => SizedBox(
                        width: 170,
                        child: _collection(
                          context,
                          block.page.collections[index],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
            if (page.tracks.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: rowInset),
                sliver: SliverList.builder(
                  itemCount: page.tracks.length,
                  itemBuilder: (_, index) => TrackRow(
                    track: page.tracks[index],
                    index: index,
                    api: browser.catalog.api,
                    playback: playback,
                    onPlay: () => _play(page.tracks[index]),
                    onActivate: () => _activate(page.tracks[index]),
                    onFavorite: (liked) =>
                        _favorite(context, page.tracks[index], liked),
                    favorite:
                        page.tracks[index].favorite ||
                        browser.section == 'favorites',
                    onOpenCollection: browser.openCollection,
                  ),
                ),
              ),
            if (!empty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      if (browser.error != null)
                        Text(
                          browser.error!,
                          style: TextStyle(color: DymuseTokens.tint(context)),
                        ),
                      if (browser.loading) const CupertinoActivityIndicator(),
                      if (browser.error != null)
                        ActionButton(
                          label: '重试',
                          onPressed: browser.loading ? null : browser.retry,
                        ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            // macOS 底部悬浮播放条下方留白；其他平台为 0。
            SliverPadding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom,
              ),
            ),
          ],
        ),
      );
    },
  );

  /// 歌手主页里点单曲按该歌曲推荐后续音乐；点“播放”按钮（[wholeList]）则以歌手的歌曲列表为队列。
  void _play(Track track, {bool wholeList = false}) {
    if (!track.available) return;
    playback.start(
      track,
      context: browser.queueContext,
      collection:
          browser.mode == MusicMode.netease &&
              browser.collection?.kind == 'artist' &&
              !wholeList
          ? null
          : browser.collection,
    );
  }

  /// 点击当前歌曲只展开播放器，不重建队列或重置进度。
  void _activate(Track track) {
    if (playback.track?.id == track.id &&
        playback.track?.kind == track.kind &&
        playback.mode == track.mode) {
      onExpand();
    } else {
      _play(track);
    }
  }

  Future<void> _favorite(BuildContext context, Track track, bool liked) async {
    final active = !liked;
    try {
      await browser.catalog.changeFavorite(track, value: active);
      if (context.mounted &&
          (browser.section == 'favorites' ||
              browser.collection?.isLiked == true)) {
        await browser.load();
      }
    } catch (e) {
      if (context.mounted) {
        await showCupertinoDialog<void>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('操作未完成'),
            content: Text(readableError(e)),
            actions: [
              CupertinoDialogAction(
                child: const Text('好'),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      }
    }
  }

  /// B 站订阅页的管理按钮：列表页可添加；进入某个订阅后可刷新、编辑、删除。
  Widget _subscriptionButtons(BuildContext context) {
    final actions = SubscriptionActions(browser.catalog.api);
    final item = browser.collection;
    Widget button(
      String label,
      IconData icon,
      Future<void> Function() onPressed, {
      bool iconOnly = false,
    }) => DymuseTokens.liquid
        ? GlassPillButton(
            label: label,
            text: iconOnly ? '' : null,
            icon: icon,
            onPressed: onPressed,
          )
        : ActionButton(label: label, icon: icon, onPressed: onPressed);
    Future<void> toList(Future<bool> Function() run) async {
      if (await run() && context.mounted) {
        await browser.navigate('subscriptions');
      }
    }

    final buttons = Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        if (item == null)
          button(
            '添加订阅',
            CupertinoIcons.plus,
            () => toList(() => actions.add(context)),
          )
        else ...[
          button('刷新订阅', CupertinoIcons.arrow_clockwise, () async {
            if (await actions.refresh(context, item)) await browser.load();
          }),
          button(
            '编辑',
            CupertinoIcons.pencil,
            () => toList(() => actions.edit(context, item)),
          ),
          button(
            '删除',
            CupertinoIcons.delete,
            () => toList(() => actions.delete(context, item)),
          ),
        ],
      ],
    );
    if (item != null) return buttons;
    // 列表页：显示方式切换放在“添加订阅”同一行的最右侧。
    final list = browser.subscriptionList;
    return Row(
      children: [
        Expanded(child: buttons),
        const SizedBox(width: 10),
        button(
          list ? '切换为大封面' : '切换为列表',
          list ? CupertinoIcons.square_grid_2x2 : CupertinoIcons.list_bullet,
          () async => browser.toggleSubscriptionLayout(),
          iconOnly: true,
        ),
      ],
    );
  }

  /// 来源页的“订阅 / 已订阅”：与播放按钮并排；订阅时复用“添加订阅”窗口，已填好链接。
  Widget _subscribeButton(BuildContext context) {
    final source = browser.collection!;
    final done = source.subscribed;
    Future<void> subscribe() async {
      final added = await SubscriptionActions(
        browser.catalog.api,
      ).add(context, input: source.id, name: source.title);
      if (added) await browser.load();
    }

    return DymuseTokens.liquid
        ? GlassPillButton(
            label: done ? '已订阅' : '订阅',
            icon: done ? CupertinoIcons.checkmark : CupertinoIcons.plus,
            selected: done,
            onPressed: done ? null : subscribe,
          )
        : ActionButton(
            label: done ? '已订阅' : '订阅',
            icon: done ? CupertinoIcons.checkmark : CupertinoIcons.plus,
            onPressed: done ? null : subscribe,
          );
  }

  /// 长按订阅弹出的玻璃菜单：刷新、编辑、删除，不必先点进去。
  List<GlassMenuEntry> _subscriptionEntries(
    BuildContext context,
    Collection item,
  ) {
    final actions = SubscriptionActions(browser.catalog.api);
    Future<void> run(Future<bool> Function() action) async {
      if (await action() && context.mounted) {
        await browser.navigate('subscriptions');
      }
    }

    return [
      GlassMenuEntry(
        '刷新',
        () => run(() => actions.refresh(context, item)),
        icon: CupertinoIcons.arrow_clockwise,
      ),
      GlassMenuEntry(
        '编辑',
        () => run(() => actions.edit(context, item)),
        icon: CupertinoIcons.pencil,
      ),
      GlassMenuEntry(
        '删除',
        () => run(() => actions.delete(context, item)),
        icon: CupertinoIcons.delete,
        destructive: true,
      ),
    ];
  }

  /// 订阅的列表行：左侧封面，信息与歌曲行一致（标题、副标题）。
  Widget _subscriptionRow(
    BuildContext context,
    Collection item,
    double inset,
  ) => Semantics(
    button: true,
    label: item.title,
    child: GlassPopupMenu(
      entries: _subscriptionEntries(context, item),
      builder: (context, open) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => browser.openCollection(item),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: inset, vertical: 6),
          child: Row(
            children: [
              RemoteArtwork(
                api: browser.catalog.api,
                url: item.cover,
                seed: item.title,
                size: 52,
                radius: 8,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DymuseTokens.caption.copyWith(
                        color: DymuseTokens.secondary(context),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  /// 订阅可长按弹出玻璃菜单，其余集合直接是图块。
  Widget _collection(BuildContext context, Collection item) =>
      item.kind == 'subscription'
      ? GlassPopupMenu(
          entries: _subscriptionEntries(context, item),
          builder: (context, open) => _collectionTile(context, item),
        )
      : _collectionTile(context, item);

  Widget _collectionTile(BuildContext context, Collection item) => Semantics(
    button: true,
    label: item.title,
    child: GestureDetector(
      onTap: () => browser.openCollection(item),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: FocusableActionDetector(
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                browser.openCollection(item);
                return null;
              },
            ),
          },
          child: LayoutBuilder(
            builder: (_, constraints) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RemoteArtwork(
                  api: browser.catalog.api,
                  url: item.cover,
                  seed: item.title,
                  size: constraints.maxWidth,
                  radius: item.kind == 'artist'
                      ? constraints.maxWidth / 2
                      : DymuseTokens.radius.artwork,
                ),
                const SizedBox(height: 11),
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DymuseTokens.caption.copyWith(
                    color: DymuseTokens.secondary(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class TrackRow extends StatefulWidget {
  const TrackRow({
    super.key,
    required this.track,
    required this.index,
    required this.api,
    required this.playback,
    required this.onPlay,
    required this.onActivate,
    required this.onFavorite,
    this.favorite = false,
    this.onOpenCollection,
  });

  /// 打开歌曲所属的来源（B 站：合集、多 P 视频、UP 主投稿）；不支持的列表不传。
  final ValueChanged<Collection>? onOpenCollection;
  final Track track;
  final int index;
  final ApiClient api;
  final PlaybackController playback;
  final VoidCallback onPlay, onActivate;
  final ValueChanged<bool> onFavorite;
  final bool favorite;
  @override
  State<TrackRow> createState() => _TrackRowState();

  /// macOS 列表单选：单击选中、双击或回车播放，与“音乐” App 一致。
  static final selection = ValueNotifier<String?>(null);

  /// “前往当前歌曲”（⌘L）：正在播放且已构建的行滚动到可见并选中自己。
  static final reveal = ValueNotifier(0);
  static bool revealed = false;
}

class _TrackRowState extends State<TrackRow> {
  bool hover = false, focus = false;
  DateTime? _lastTap;
  final _menuController = GlassPopupController();
  String get _key =>
      '${widget.track.mode.name}:${widget.track.kind}:${widget.track.id}:${widget.index}';

  @override
  void initState() {
    super.initState();
    TrackRow.reveal.addListener(_reveal);
  }

  @override
  void dispose() {
    TrackRow.reveal.removeListener(_reveal);
    super.dispose();
  }

  void _reveal() {
    final current = widget.playback.track;
    if (!mounted ||
        TrackRow.revealed ||
        current?.id != widget.track.id ||
        current?.kind != widget.track.kind ||
        widget.playback.mode != widget.track.mode) {
      return;
    }
    TrackRow.revealed = true;
    TrackRow.selection.value = _key;
    Scrollable.ensureVisible(
      context,
      alignment: .4,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : DymuseTokens.motion,
    );
  }

  /// Windows 单击即播放；macOS 第一次单击选中，双击间隔内再次单击播放。
  void _tap() {
    if (!DymuseTokens.macOS) return widget.onActivate();
    final now = DateTime.now();
    final last = _lastTap;
    _lastTap = now;
    TrackRow.selection.value = _key;
    if (last != null && now.difference(last) <= kDoubleTapTimeout) {
      _lastTap = null;
      widget.onPlay();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.playback, widget.playback.catalog]),
    builder: (_, _) {
      final track = widget.track;
      final active =
          widget.playback.track?.id == track.id &&
          widget.playback.track?.kind == track.kind &&
          widget.playback.mode == track.mode;
      final mac = DymuseTokens.macOS;
      final ios = DymuseTokens.mobile;
      return ValueListenableBuilder(
        valueListenable: TrackRow.selection,
        builder: (context, selectedKey, _) {
          final selected = mac && selectedKey == _key;
          return MouseRegion(
            onEnter: (_) => setState(() => hover = true),
            onExit: (_) => setState(() => hover = false),
            child: FocusableActionDetector(
              onShowFocusHighlight: (value) => setState(() => focus = value),
              actions: {
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) {
                    mac ? widget.onPlay() : widget.onActivate();
                    return null;
                  },
                ),
              },
              child: Semantics(
                button: true,
                label: '${track.title}，${track.artist}，播放',
                selected: active,
                onTap: mac ? widget.onPlay : null,
                child: GestureDetector(
                  excludeFromSemantics: mac,
                  onTap: _tap,
                  onSecondaryTap: () {
                    if (mac) TrackRow.selection.value = _key;
                    _loadFavoriteState();
                    _menuController.open();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      // macOS：选中为中性底色，正在播放只换图标；Windows 保持原样式。
                      color: mac
                          ? selected
                                ? (DymuseTokens.dark(context)
                                      ? const Color(0x24FFFFFF)
                                      : const Color(0x14000000))
                                : hover
                                ? (DymuseTokens.dark(context)
                                      ? const Color(0x14FFFFFF)
                                      : const Color(0x0D000000))
                                : null
                          : active
                          ? DymuseTokens.tint(context).withValues(alpha: .08)
                          : hover
                          ? DymuseTokens.surface(context)
                          : null,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: focus
                            ? DymuseTokens.tint(context)
                            : mac && hover
                            ? (DymuseTokens.dark(context)
                                  ? const Color(0x1FFFFFFF)
                                  : const Color(0x14000000))
                            : const Color(0x00000000),
                      ),
                    ),
                    child: Row(
                      children: [
                        if (!ios) ...[
                          SizedBox(
                            width: 36,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 180),
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              transitionBuilder: (child, animation) =>
                                  FadeTransition(
                                    opacity: animation,
                                    child: ScaleTransition(
                                      scale: Tween(
                                        begin: .7,
                                        end: 1.0,
                                      ).animate(animation),
                                      child: child,
                                    ),
                                  ),
                              child: KeyedSubtree(
                                key: ValueKey(hover || active),
                                child: mac && active
                                    ? ValueListenableBuilder(
                                        valueListenable:
                                            widget.playback.engine.playing,
                                        builder: (context, playing, _) => hover
                                            ? GlassSquareButton(
                                                label: playing ? '暂停' : '播放',
                                                icon: playing
                                                    ? CupertinoIcons.pause_fill
                                                    : CupertinoIcons.play_fill,
                                                onPressed:
                                                    widget.playback.toggle,
                                              )
                                            : Icon(
                                                playing
                                                    ? CupertinoIcons
                                                          .speaker_2_fill
                                                    : CupertinoIcons
                                                          .speaker_fill,
                                                size: 15,
                                                color: DymuseTokens.tint(
                                                  context,
                                                ),
                                              ),
                                      )
                                    : hover || active
                                    ? mac
                                          ? GlassSquareButton(
                                              label: '播放 ${track.title}',
                                              icon: CupertinoIcons.play_fill,
                                              onPressed: widget.onPlay,
                                            )
                                          : ActionButton(
                                              label: '播放 ${track.title}',
                                              icon: CupertinoIcons.play_fill,
                                              compact: true,
                                              onPressed: widget.onPlay,
                                            )
                                    : Text(
                                        '${widget.index + 1}',
                                        textAlign: TextAlign.center,
                                        style: DymuseTokens.caption.copyWith(
                                          color: DymuseTokens.secondary(
                                            context,
                                          ),
                                        ),
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        RemoteArtwork(
                          api: widget.api,
                          url: track.cover,
                          seed: track.album,
                          size: 44,
                          radius: 7,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          flex: 5,
                          child: GestureDetector(
                            excludeFromSemantics: mac,
                            onTap: _tap,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: active
                                        ? DymuseTokens.tint(context)
                                        : null,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  track.artist.isEmpty ? '未知艺人' : track.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: DymuseTokens.caption.copyWith(
                                    color: DymuseTokens.secondary(context),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (MediaQuery.sizeOf(context).width >= 1080)
                          Expanded(
                            flex: 3,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Text(
                                track.album,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: DymuseTokens.caption.copyWith(
                                  color: DymuseTokens.secondary(context),
                                ),
                              ),
                            ),
                          ),
                        if (!ios)
                          SizedBox(
                            width: 48,
                            child: Text(
                              timeLabel(
                                Duration(
                                  milliseconds: (track.duration * 1000).round(),
                                ),
                              ),
                              style: DymuseTokens.caption.copyWith(
                                color: DymuseTokens.secondary(context),
                              ),
                            ),
                          ),
                        GlassPopupMenu(
                          controller: _menuController,
                          entries: _entries(context),
                          onOpen: _loadFavoriteState,
                          builder: (context, open) => Semantics(
                            button: true,
                            label: '歌曲操作',
                            excludeSemantics: true,
                            onTap: open,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: open,
                              child: SizedBox(
                                width: 44,
                                height: 44,
                                child: Icon(
                                  CupertinoIcons.ellipsis,
                                  size: 18,
                                  color: DymuseTokens.secondary(context),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );

  /// 打开菜单时顺手确认喜欢状态（网易云），失败不打断。
  void _loadFavoriteState() {
    if (widget.track.mode == MusicMode.netease &&
        !widget.track.isPodcast &&
        !widget.api.guest) {
      unawaited(
        widget.playback.catalog.loadFavorite(widget.track).catchError((_) {}),
      );
    }
  }

  /// 歌曲的“更多”菜单项（液态玻璃菜单）。
  List<GlassMenuEntry> _entries(BuildContext context) {
    final hostContext = context;
    final favorite =
        widget.playback.catalog.favoriteValue(widget.track) ?? widget.favorite;
    final queueable =
        widget.playback.snapshot != null &&
        widget.track.isPodcast ==
            (widget.playback.state['origin'] == 'podcast');
    return [
      GlassMenuEntry('播放', widget.onPlay, icon: CupertinoIcons.play_fill),
      if (queueable)
        GlassMenuEntry(
          '下一首播放',
          () => widget.playback.insert(widget.track),
          icon: CupertinoIcons.text_insert,
        ),
      if (queueable)
        GlassMenuEntry(
          '稍后播放',
          () => widget.playback.insert(widget.track, next: false),
          icon: CupertinoIcons.text_append,
        ),
      if (!widget.track.isPodcast)
        GlassMenuEntry('添加到歌单', () async {
          if (widget.track.mode == MusicMode.netease &&
              hostContext.mounted &&
              !await ensureLoggedIn(hostContext, widget.api)) {
            return;
          }
          if (hostContext.mounted) {
            showPlaylistPicker(
              hostContext,
              widget.playback.catalog,
              widget.track,
            );
          }
        }, icon: CupertinoIcons.music_note_list),
      if (!widget.track.isPodcast)
        GlassMenuEntry(
          favorite ? '取消喜欢' : '喜欢这首歌',
          () async {
            if (widget.track.mode == MusicMode.netease &&
                hostContext.mounted &&
                !await ensureLoggedIn(hostContext, widget.api)) {
              return;
            }
            widget.onFavorite(favorite);
          },
          icon: favorite ? CupertinoIcons.heart_slash : CupertinoIcons.heart,
        ),
      if (widget.track.mode == MusicMode.bilibili &&
          widget.onOpenCollection != null)
        GlassMenuEntry('跳转到…', () {
          if (hostContext.mounted) _jumpToSource(hostContext);
        }, icon: CupertinoIcons.arrow_turn_down_right),
      if (widget.track.mode == MusicMode.netease &&
          !widget.track.isPodcast &&
          widget.onOpenCollection != null &&
          _neteaseTargets.isNotEmpty)
        GlassMenuEntry('跳转到…', () {
          if (hostContext.mounted) _jumpToNetease(hostContext);
        }, icon: CupertinoIcons.arrow_turn_down_right),
      if (widget.track.mode == MusicMode.bilibili &&
          (widget.track.rawTitle ?? '').isNotEmpty)
        GlassMenuEntry('查看原视频名', () {
          if (hostContext.mounted) {
            _showRawTitle(hostContext, widget.track.rawTitle!);
          }
        }, icon: CupertinoIcons.doc_text),
    ];
  }

  /// 网易云歌曲可跳转的页面：专辑，以及每位歌手的主页。
  List<(String, Collection)> get _neteaseTargets {
    final track = widget.track;
    return [
      if (track.albumTarget != null)
        ('专辑 · ${track.album}', track.albumTarget!),
      for (final a in track.artists)
        ('歌手 · ${a.name}', Collection(a.id, a.name, '歌手', null, 'artist')),
    ];
  }

  Future<void> _jumpToNetease(BuildContext context) async {
    final targets = _neteaseTargets;
    if (targets.isEmpty) return;
    final picked = targets.length == 1
        ? targets.first.$2
        : await showChoiceSheet<Collection>(
            context,
            title: '跳转到',
            choices: targets,
          );
    if (picked != null) widget.onOpenCollection?.call(picked);
  }

  /// 查出这个视频所属的合集、多 P 视频、UP 主投稿，选一个进入（进入后可添加订阅）。
  Future<void> _jumpToSource(BuildContext context) => BilibiliJump.open(
    context,
    api: widget.api,
    track: widget.track,
    onOpen: (target) => widget.onOpenCollection?.call(target),
  );

  /// 完整的原视频标题：可选中，也可一键复制。
  static Future<void> _showRawTitle(BuildContext context, String title) =>
      showCupertinoDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialog) => CupertinoAlertDialog(
          title: const Text('原视频名'),
          content: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: SelectionArea(
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: title));
                if (dialog.mounted) Navigator.pop(dialog);
              },
              child: const Text('复制'),
            ),
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
}
