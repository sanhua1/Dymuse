import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import '../core/session.dart';
import '../design_system/components.dart';
import '../design_system/sheet.dart';
import '../design_system/tokens.dart';
import '../features/browse_page.dart';
import '../features/catalog.dart';
import '../features/intelligence_page.dart';
import '../features/settings_page.dart';
import '../platform/now_playing.dart';
import '../playback/playback_controller.dart';
import '../playback/phone_player.dart';

/// iPhone 外壳：参照 Apple Music（iOS 26）——
/// 底部玻璃 Tab 栏与独立的搜索圆钮，Tab 栏上方悬浮迷你播放器，
/// 点按迷你播放器以 Sheet 打开完整播放页。业务状态、页面和播放控制与桌面共用。
/// 网易云 Tab：现在就听 / 每日推荐 / 我喜欢 / 资料库（我的歌单、播客）；
/// 心动模式是顶部的全局按钮。哔哩哔哩 Tab：我的订阅 / 我喜欢 / 歌单 / 资料库；
/// 顶部的模式按钮在两种模式之间切换。
class MobileShell extends StatefulWidget {
  const MobileShell({
    super.key,
    required this.session,
    required this.catalog,
    required this.playback,
    required this.appearance,
  });
  final Session session;
  final Catalog catalog;
  final PlaybackController playback;
  final Appearance appearance;
  @override
  State<MobileShell> createState() => _MobileShellState();
}

/// Tab 定义；[section] 为空表示“资料库”列表页。
class _TabSpec {
  const _TabSpec(this.section, this.label, this.icon, [this.activeIcon]);
  final String? section;
  final String label;
  final IconData icon;
  final IconData? activeIcon;
}

const _neteaseTabs = [
  _TabSpec(
    'discover',
    '现在就听',
    CupertinoIcons.play_circle,
    CupertinoIcons.play_circle_fill,
  ),
  _TabSpec('songs', '每日推荐', CupertinoIcons.calendar_today),
  _TabSpec('favorites', '我喜欢', CupertinoIcons.heart, CupertinoIcons.heart_fill),
  _TabSpec(
    null,
    '资料库',
    CupertinoIcons.music_albums,
    CupertinoIcons.music_albums_fill,
  ),
];

const _bilibiliTabs = [
  _TabSpec(
    'subscriptions',
    '我的订阅',
    CupertinoIcons.rectangle_stack,
    CupertinoIcons.rectangle_stack_fill,
  ),
  _TabSpec('favorites', '我喜欢', CupertinoIcons.heart, CupertinoIcons.heart_fill),
  _TabSpec('playlists', '歌单', CupertinoIcons.music_note_list),
  _TabSpec('library', '资料库', CupertinoIcons.collections),
];

class _MobileShellState extends State<MobileShell>
    with SingleTickerProviderStateMixin {
  // Tab 栏高度与迷你播放器高度，用于给列表底部留白；顶栏高度用于顶部留白。
  static const _topBar = _TopBar.height;
  static const _tabBar = 64.0, _tabPadding = 20.0, _mini = 64.0, _gap = 8.0;

  // 迷你播放器与 Tab 栏同高同圆角（半圆端点），封面圆心与端点圆心重合。
  // 进度条夹在两者之间，上下各留 [_progressGap]：播放器画在 Tab 栏上方留白里压下 6，
  // Tab 栏玻璃距其组件顶部 [_tabPadding]，据此算出两者之间要留的高度。
  static const _progressGap = 8.0, _progressBar = 4.0, _miniOverlap = 6.0;
  static const _progressZone =
      _progressGap * 2 + _progressBar - (_tabPadding - _miniOverlap);
  late final browsers = {
    for (final mode in MusicMode.values)
      mode: BrowseState(mode, widget.catalog),
  };
  final search = TextEditingController();
  final searchFocus = FocusNode();
  late MusicMode mode = widget.playback.mode;
  bool switching = false;

  /// 返回手势进度（0～1）与“旧页面正在滑出”，顶部返回按钮据此淡出而不是突然消失。
  final _pull = ValueNotifier<double>(0);
  final _leaving = ValueNotifier<bool>(false);

  /// 返回按钮的“材质化”程度：1 完整显示，0 完全消失。玻璃背板必须经由
  /// 着色器自身的可见度淡出（直接套 Opacity 会让玻璃整块立刻消失，只剩文字渐隐）。
  late final _backFade = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 1),
  );
  double _backOpacity() {
    final pull = _pull.value.clamp(0.0, 1.0), leaving = _leaving.value;
    if (!canBack && !leaving) return 1;
    return _staysOnBack(leaving) ? 1.0 : 1 - pull;
  }

  /// 返回后上一级是否还有返回按钮。提交返回的那一刻页面还没切换，
  /// 趁此时记下结果；之后页面一换 canBack 会变，不能再现读，否则按钮会闪一下。
  bool _stays = false;
  bool _wasLeaving = false;
  bool _staysOnBack(bool leaving) {
    if (leaving && !_wasLeaving) _stays = browser.depth > 1;
    _wasLeaving = leaving;
    return leaving ? _stays : browser.depth > 1;
  }

  void _syncBackFade() {
    final value = _backOpacity();
    if ((_backFade.value - value).abs() > .001) _backFade.value = value;
  }

  int tab = 0;
  String? librarySection;
  bool searching = false, intelligence = false;

  /// 打开搜索前是否在心动模式，关闭搜索时一并恢复。
  bool _intelligenceBeforeSearch = false;

  /// 上一次构建时的页面位置，用来推断页面切换动画的方向。
  ({MusicMode mode, int tab, String? section, int depth, bool search, bool fm})?
  _lastPage;
  int _direction = 0;
  BrowseState get browser => browsers[mode]!;
  PlaybackController get playback => widget.playback;
  bool get netease => mode == MusicMode.netease;
  List<_TabSpec> get tabs => netease ? _neteaseTabs : _bilibiliTabs;
  bool get onLibraryTab => tabs[tab].section == null;

  /// 搜索栏展开后稍等动画结束才切到搜索页，这之前仍显示原页面。
  bool get showingSearch => searching && browser.section == 'search';

  /// 顶部返回按钮：资料库二级页或各页面（含搜索结果）里进入的集合；
  /// 资料库根页不受其他页浏览状态影响。
  bool get canBack =>
      !intelligence &&
      (showingSearch || !onLibraryTab
          ? browser.drilled
          : librarySection != null);
  bool get backToLibrary => !showingSearch && onLibraryTab && !browser.drilled;

  /// 返回手势：除了顶部返回按钮能返回的页面，搜索结果的根页面也能右滑退出搜索，
  /// 效果等同点左下角的圆钮（回到搜索前的页面）。
  bool get canSwipeBack => canBack || (showingSearch && !intelligence);

  void swipeBack() {
    if (canBack) {
      back();
    } else if (showingSearch) {
      toggleSearch(false);
    }
  }

  /// 左右滑动切换 Tab：只在各 Tab 的根页面，搜索与心动模式下不切换。
  bool get canSwipeTabs => !searching && !intelligence && !canBack;
  void swipeTab(int step) {
    final next = tab + step;
    if (next >= 0 && next < tabs.length) selectTab(next);
  }

  @override
  void initState() {
    super.initState();
    _pull.addListener(_syncBackFade);
    _leaving.addListener(_syncBackFade);
    unawaited(browser.load());
  }

  @override
  void dispose() {
    for (final browser in browsers.values) {
      browser.dispose();
    }
    _pull.removeListener(_syncBackFade);
    _leaving.removeListener(_syncBackFade);
    _backFade.dispose();
    _pull.dispose();
    _leaving.dispose();
    search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  /// 切换音乐模式：保存旧模式进度并恢复目标模式，页面回到该模式第一个 Tab。
  Future<void> switchMode(MusicMode target) async {
    if (target == mode || switching) return;
    setState(() => switching = true);
    searchFocus.unfocus();
    await playback.switchMode(target);
    if (!mounted) return;
    setState(() {
      mode = playback.mode;
      tab = 0;
      librarySection = null;
      searching = false;
      intelligence = false;
      search.clear();
      switching = false;
    });
    if (!browser.loaded) unawaited(_openCurrent());
  }

  void selectTab(int value) {
    final section = tabs[value].section;
    final again = value == tab && !searching && !intelligence;
    setState(() {
      tab = value;
      searching = false;
      intelligence = false;
      librarySection = null;
    });
    searchFocus.unfocus();
    if (section != null) {
      if (again && !browser.drilled) return;
      unawaited(_open(section));
    }
  }

  /// 回到当前 Tab（或资料库二级页）对应的内容。
  Future<void> _openCurrent() async {
    final section = tabs[tab].section ?? librarySection;
    if (section != null) await _open(section);
  }

  /// 心动模式是全局入口：再次点按回到进入前的页面。
  void toggleIntelligence() {
    if (intelligence) {
      setState(() => intelligence = false);
      unawaited(_openCurrent());
    } else {
      setState(() {
        intelligence = true;
        searching = false;
      });
      searchFocus.unfocus();
      unawaited(_open('intelligence'));
    }
  }

  Future<void> _open(String section) async {
    await browser.navigate(section);
    if (mode == MusicMode.netease && section == 'intelligence') {
      unawaited(playback.startIntelligence());
    }
  }

  void openLibrary(String section) {
    setState(() => librarySection = section);
    unawaited(_open(section));
  }

  /// 先退出集合；已在资料库的二级页根部时回到资料库列表。
  void back() {
    if (browser.drilled) {
      unawaited(browser.back());
    } else if (onLibraryTab) {
      setState(() => librarySection = null);
    }
  }

  /// 打开搜索时记下原页面（含已进入的歌单和滚动位置），关闭（左侧圆钮或 ×）时原样恢复。
  /// 搜索栏展开动画期间不切换页面内容，避免与动画争抢同一帧；输入法也在动画后再弹出。
  void toggleSearch(bool active) {
    if (active == searching) return;
    if (active) {
      _intelligenceBeforeSearch = intelligence;
      browser.rememberBeforeSearch();
    }
    setState(() {
      searching = active;
      if (active) intelligence = false;
    });
    if (active) {
      // 只在用户展开搜索时聚焦；库自带的 autoFocusOnExpand 会在迷你播放器出现、
      // 搜索栏重建时再次聚焦，导致在搜索结果里点歌也弹出输入法。
      // 收起状态下库也会隐形地建一份同样的输入框（共用这个 FocusNode），展开过程中
      // 输入框会换位置重建。动画中途聚焦会连到即将销毁的那一份，新输入框接不上输入法，
      // 结果不弹键盘、打字无效（偶发）。所以等展开动画结束后再聚焦，已有焦点就先断开重连。
      Future.delayed(const Duration(milliseconds: 380), () {
        if (!mounted || !searching) return;
        if (browser.section != 'search' || search.text.isEmpty) {
          if (searchFocus.hasFocus) searchFocus.unfocus();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && searching) searchFocus.requestFocus();
          });
        }
        // 已经提交过搜索（submitSearch 已切到搜索页）时不再覆盖。
        if (browser.section != 'search') {
          unawaited(browser.navigate('search', text: search.text.trim()));
        }
      });
    } else {
      searchFocus.unfocus();
      search.clear();
      final wasIntelligence = _intelligenceBeforeSearch;
      _intelligenceBeforeSearch = false;
      if (wasIntelligence) setState(() => intelligence = true);
      // 展开动画还没结束就关闭时，页面根本没切到搜索，原样保留即可。
      if (browser.section != 'search') return;
      if (wasIntelligence) {
        // 只恢复页面，不重新开启心动模式播放。
        unawaited(browser.navigate('intelligence'));
      } else if (!browser.restoreBeforeSearch()) {
        unawaited(_openCurrent());
      }
    }
  }

  void submitSearch(String text) {
    setState(() => searching = true);
    searchFocus.unfocus();
    unawaited(browser.navigate('search', text: text.trim()));
  }

  /// 页面切换方向：进入为 1（从右侧滑入），返回为 -1，切 Tab 按 Tab 顺序，其余淡入。
  String _pageKey() {
    final page = (
      mode: mode,
      tab: tab,
      section: librarySection,
      depth: browser.depth,
      search: showingSearch,
      fm: intelligence,
    );
    final last = _lastPage;
    if (last != null && last != page) {
      _direction =
          last.mode != page.mode ||
              last.search != page.search ||
              last.fm != page.fm
          ? 0
          : last.tab != page.tab
          ? (page.tab - last.tab).sign
          : last.section != page.section
          ? (page.section == null ? -1 : 1)
          : (page.depth - last.depth).sign;
    }
    _lastPage = page;
    return '$page';
  }

  /// 艺人/专辑/播客链接：收起播放页，在“现在就听”下打开对应页面。
  void openCollection(Collection target) {
    setState(() {
      tab = 0;
      searching = false;
      intelligence = false;
      librarySection = null;
    });
    unawaited(browser.openCollection(target));
  }

  Future<void> openPlayer() => showDymuseSheet<void>(
    context: context,
    builder: (sheet) => PhonePlayer(
      controller: playback,
      onClose: () => Navigator.of(sheet).pop(),
      onOpenCollection: (target) {
        Navigator.of(sheet).pop();
        openCollection(target);
      },
    ),
  );

  Future<void> openSettings() async {
    await showDymuseSheet<void>(
      context: context,
      builder: (sheet) => _SettingsSheet(
        session: widget.session,
        appearance: widget.appearance,
        playback: widget.playback,
        onDone: () => Navigator.of(sheet).pop(),
      ),
    );
    // 设置里改的“迷你播放器进度条”，回到主页后才开始过渡。
    widget.appearance.commitMiniProgress();
  }

  /// 顶部返回按钮。返回手势中随进度淡出：
  /// 上一级页面也有返回按钮时保持不变；没有时一路淡到透明，不会在松手时突然消失。
  Widget _backLeading() => ListenableBuilder(
    listenable: Listenable.merge([_pull, _leaving]),
    builder: (context, _) {
      final pull = _pull.value.clamp(0.0, 1.0), leaving = _leaving.value;
      if (!canBack && !leaving) return const SizedBox.shrink();
      if (canBack) _backLabel = backToLibrary ? '资料库' : '返回';
      // 手势期间看当前页是否还有上一级返回；松手后（页面已换）看新页面是否还有返回。
      // 页面切换后 canBack 才变，渲染后再对一次进度。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncBackFade();
      });
      return IgnorePointer(
        ignoring: pull > 0,
        child: glass.GlassMaterializeTransition(
          animation: _backFade,
          scaleFrom: 1,
          contentSigma: 0,
          child: _BackButton(label: _backLabel, onPressed: back),
        ),
      );
    },
  );
  String _backLabel = '返回';

  @override
  Widget build(BuildContext context) {
    // 顶部返回按钮取决于浏览状态（是否进入集合），因此同时监听两种模式的浏览状态。
    final shell = ListenableBuilder(
      listenable: Listenable.merge([
        playback,
        widget.appearance,
        sheetCovering,
        ...browsers.values,
      ]),
      builder: (context, _) {
        final covered = sheetCovering.value;
        final showMini = playback.track != null;
        // 内容在悬浮 Tab 栏与迷你播放器下方滚动，末尾留出它们的高度。
        final progressOn = widget.appearance.miniProgressShown;
        final reserve =
            _tabBar +
            _tabPadding +
            (showMini ? _mini + _gap + _progressZone : 0) +
            12;
        return ColoredBox(
          color: DymuseTokens.background(context),
          child: Stack(
            children: [
              // 内容延伸到顶栏下方，滚动时在顶栏后面渐进模糊（iOS 26 滚动边缘效果），
              // 而不是在顶栏下沿被纯色截断。
              Positioned.fill(
                child: glass.GlassScrollEdgeEffect(
                  // Android 的 GPU 吃不消全屏实时模糊，改用渐变遮罩。
                  style: DymuseTokens.android
                      ? glass.GlassScrollEdgeStyle.soft
                      : glass.GlassScrollEdgeStyle.blur,
                  topFadeHeight: covered
                      ? 0
                      : MediaQuery.paddingOf(context).top + _topBar + 16,
                  fadeBottom: false,
                  child: _PageGestures(
                    pageKey: _pageKey(),
                    direction: _direction,
                    canBack: canSwipeBack,
                    onBack: swipeBack,
                    canSwipe: canSwipeTabs,
                    onSwipe: swipeTab,
                    pull: _pull,
                    leaving: _leaving,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: reserve),
                      duration: DymuseTokens.motion,
                      curve: Curves.easeOutCubic,
                      builder: (context, value, child) => _ReservePadding(
                        top: _topBar,
                        bottom: value,
                        child: child!,
                      ),
                      child: _content(),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: _TopBar(
                    leading: _backLeading(),
                    intelligence: netease ? intelligence : null,
                    onIntelligence: toggleIntelligence,
                    modeLabel: mode.label,
                    modes: [
                      for (final item in MusicMode.values)
                        GlassMenuEntry(
                          item.label,
                          () => switchMode(item),
                          checked: item == mode,
                        ),
                    ],
                    onSettings: openSettings,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Center(
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    // 迷你播放器不用库的 bottomAccessory，放在 Tab 栏上方：
                    // 1. 带 bottomAccessory 时库的外层容器高度不含键盘抬升，抬到容器外的
                    //    搜索栏和 × 收不到点按；
                    // 2. bottomAccessory 有无会改变库的组件结构，切换时搜索框被重建、
                    //    焦点丢失，输入法刚弹出就收回（点搜索框没反应）。
                    // Tab 栏结构因此始终不变；输入法弹出时只隐藏迷你播放器。
                    // 单独用 Builder 读键盘高度，键盘动画时只重建底部这一块。
                    child: Builder(
                      builder: (context) {
                        final keyboard =
                            MediaQuery.viewInsetsOf(context).bottom > 0;
                        final mini = showMini && !(searching && keyboard);
                        final progress = mini && progressOn;
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                KeyedSubtree(
                                  key: const ValueKey('mini'),
                                  child: mini
                                      ? Transform.translate(
                                          // 与库的排布一致：压进 Tab 栏上方留白。
                                          offset: const Offset(0, _miniOverlap),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: _tabPadding,
                                            ),
                                            child: _MiniBar(
                                              controller: playback,
                                              onOpen: openPlayer,
                                            ),
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                                // 进度条出现时把播放器向上推开，为它腾出位置。
                                AnimatedContainer(
                                  duration: DymuseTokens.motion,
                                  curve: Curves.easeOutCubic,
                                  height: progress ? _progressZone : 0,
                                ),
                                KeyedSubtree(
                                  key: const ValueKey('tabs'),
                                  // 标签文字只允许略微放大（与 Apple 对 Tab 栏的做法一致），
                                  // 放得再大也保证四个标签与搜索按钮同一行放得下、不互相挤压。
                                  child: MediaQuery.withClampedTextScaling(
                                    maxScaleFactor: 1.1,
                                    child: glass.GlassTabBar.searchable(
                                      tabs: [
                                        for (final spec in tabs)
                                          glass.GlassTab(
                                            icon: Icon(spec.icon),
                                            activeIcon: Icon(
                                              spec.activeIcon ?? spec.icon,
                                            ),
                                            label: spec.label,
                                          ),
                                      ],
                                      selectedIndex: tab,
                                      onTabSelected: selectTab,
                                      labelFontSize: tabs.length > 2 ? 10 : 11,
                                      isSearchActive: searching,
                                      selectedIconColor: DymuseTokens.tint(
                                        context,
                                      ),
                                      selectedLabelColor: DymuseTokens.tint(
                                        context,
                                      ),
                                      searchConfig: glass.GlassSearchBarConfig(
                                        onSearchToggle: toggleSearch,
                                        hintText: '搜索',
                                        controller: search,
                                        focusNode: searchFocus,
                                        textInputAction: TextInputAction.search,
                                        onSubmitted: submitSearch,
                                        autoFocusOnExpand: false,
                                        // 库默认的 × 只收起输入法；这里让它关闭搜索并回到原页面。
                                        onCancelTap: () => toggleSearch(false),
                                        cancelButtonSemanticLabel: '关闭搜索',
                                      ),
                                      quality: DymuseTokens.glassQuality,
                                      // 与其他玻璃面板一致：无模糊，垫半透明底色保证可读。
                                      settings: DymuseTokens.android
                                          ? glass.LiquidGlassSettings(
                                              blur: 0,
                                              thickness: 18,
                                              glassColor:
                                                  DymuseTokens.background(
                                                    context,
                                                  ).withValues(alpha: .96),
                                            )
                                          : null,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            // 进度条：左右对齐到两端半圆的圆心，上下与播放器、Tab 栏等距。
                            Positioned(
                              left: _tabPadding + _mini / 2,
                              right: _tabPadding + _mini / 2,
                              top: _mini + _miniOverlap + _progressGap - 6,
                              height: 16,
                              child: IgnorePointer(
                                ignoring: !progress,
                                child: AnimatedOpacity(
                                  duration: DymuseTokens.motion,
                                  curve: Curves.easeOut,
                                  opacity: progress ? 1 : 0,
                                  child: _MiniProgress(controller: playback),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (!DymuseTokens.android) return shell;
    // Android 返回键：先逐级退出集合与搜索；已在根页面时把应用移到后台，
    // 而不是结束 Activity（那会连同音乐一起停掉）。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (canSwipeBack) {
          swipeBack();
        } else if (searching) {
          toggleSearch(false);
        } else {
          unawaited(NowPlaying.moveToBack());
        }
      },
      child: shell,
    );
  }

  Widget _content() {
    if (!showingSearch && intelligence) {
      return IntelligencePage(playback: playback, onExpand: openPlayer);
    }
    if (!showingSearch && onLibraryTab && librarySection == null) {
      return _LibraryList(onOpen: openLibrary);
    }
    return BrowsePage(
      key: ValueKey('$mode'),
      browser: browser,
      playback: playback,
      onSettings: openSettings,
      onExpand: openPlayer,
      showBack: false,
    );
  }
}

/// 页面顶部一行：最左是全局的“心动模式”（仅网易云），其后是返回按钮（二级页），
/// 右侧为音乐模式切换与账号入口；页面标题由内容页自己绘制。
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.onSettings,
    required this.onIntelligence,
    required this.modeLabel,
    required this.modes,
    this.intelligence,
    this.leading,
  });
  final Widget? leading;
  final String modeLabel;
  final List<GlassMenuEntry> modes;

  /// null 表示当前模式没有心动模式；否则表示是否正在心动模式页。
  final bool? intelligence;
  final VoidCallback onSettings, onIntelligence;
  static const height = 52.0;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          if (intelligence != null) ...[
            _GlassPill(
              label: intelligence! ? '退出心动模式' : '心动模式',
              circle: true,
              onPressed: onIntelligence,
              child: Icon(
                intelligence!
                    ? CupertinoIcons.heart_circle_fill
                    : CupertinoIcons.heart_circle,
                size: 24,
                color: intelligence! ? DymuseTokens.tint(context) : null,
              ),
            ),
            const SizedBox(width: 8),
          ],
          ?leading,
          // 右侧按钮组始终贴右：Expanded 占满剩余宽度后靠右对齐。以前 Spacer 与
          // Flexible 平分剩余宽度，模式名长短不同时按钮组会离开右边缘。
          // 窄屏（如 iPhone SE）按钮多时模式按钮等比缩小，不溢出。
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: GlassPopupMenu(
                  entries: modes,
                  width: 190,
                  glassTrigger: true,
                  builder: (context, open) => _GlassPill(
                    label: '切换音乐来源，当前$modeLabel',
                    onPressed: open,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          modeLabel,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(CupertinoIcons.chevron_down, size: 12),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _GlassPill(
            label: '账号与设置',
            circle: true,
            onPressed: onSettings,
            child: const Icon(CupertinoIcons.person_crop_circle, size: 22),
          ),
        ],
      ),
    ),
  );
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => _GlassPill(
    label: label == '返回' ? '返回上一页' : '返回$label',
    onPressed: onPressed,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(CupertinoIcons.chevron_left, size: 15),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

/// 顶部的玻璃胶囊/圆形按钮，点按目标不小于 44 点。
class _GlassPill extends StatelessWidget {
  const _GlassPill({
    required this.label,
    required this.child,
    required this.onPressed,
    this.circle = false,
  });
  final String label;
  final Widget child;
  final VoidCallback? onPressed;
  final bool circle;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    onTap: onPressed,
    child: CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: const Size(44, 44),
      onPressed: onPressed,
      child: GlassPanel(
        radius: 18,
        padding: EdgeInsets.symmetric(horizontal: circle ? 0 : 14),
        child: SizedBox(
          height: 36,
          width: circle ? 36 : null,
          child: IconTheme(
            data: IconThemeData(color: DymuseTokens.ink(context)),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: DymuseTokens.ink(context)),
              child: Center(widthFactor: circle ? null : 1, child: child),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 资料库 Tab：把原桌面侧栏里的资料库入口收成一张 iOS 分组列表。
class _LibraryList extends StatelessWidget {
  const _LibraryList({required this.onOpen});
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    // 每日推荐、我喜欢、心动模式已移到 Tab 与顶部全局按钮。
    const entries = [
      ('playlists', '我的歌单', CupertinoIcons.music_note_list),
      ('podcasts', '播客', CupertinoIcons.mic_fill),
    ];
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            4 + MediaQuery.paddingOf(context).top,
            20,
            MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            const Text('资料库', style: DymuseTokens.heading),
            const SizedBox(height: 16),
            for (final (section, label, icon) in entries)
              _LibraryRow(
                label: label,
                icon: icon,
                onPressed: () => onOpen(section),
              ),
          ],
        ),
      ),
    );
  }
}

class _LibraryRow extends StatelessWidget {
  const _LibraryRow({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    onTap: onPressed,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: DymuseTokens.line(context), width: .5),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              child: Icon(icon, size: 22, color: DymuseTokens.tint(context)),
            ),
            const SizedBox(width: 6),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 17))),
            Icon(
              CupertinoIcons.chevron_right,
              size: 14,
              color: DymuseTokens.secondary(context),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 迷你播放器：Tab 栏上方的玻璃胶囊（iOS 26 `tabViewBottomAccessory`）。
class _MiniBar extends StatelessWidget {
  const _MiniBar({required this.controller, required this.onOpen});
  final PlaybackController controller;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final track = controller.track;
      return Semantics(
        button: true,
        label: '打开正在播放：${track?.title ?? ''}',
        excludeSemantics: true,
        onTap: onOpen,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onOpen,
          // 与 Tab 栏同高（64）同圆角（32，两端是半圆），并使用与 Tab 栏相同的玻璃参数；
          // 封面圆心（距左 10 + 半径 22）正好落在左端半圆的圆心上。
          child: GlassPanel(
            radius: 32,
            settings: kBarGlassSettings,
            child: SizedBox(
              height: 64,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
                child: Row(
                  children: [
                    RemoteArtwork(
                      api: controller.api,
                      url: track?.cover,
                      seed: track?.album ?? 'Dymuse',
                      size: 44,
                      radius: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track?.title ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (controller.error != null)
                            Text(
                              controller.error!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: DymuseTokens.tint(context),
                              ),
                            )
                          else if ((track?.artist ?? '').isNotEmpty)
                            Text(
                              track!.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DymuseTokens.caption.copyWith(
                                color: DymuseTokens.secondary(context),
                              ),
                            ),
                        ],
                      ),
                    ),
                    _MiniButton(
                      label: '上一首',
                      icon: CupertinoIcons.backward_fill,
                      onPressed: controller.previous,
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: controller.engine.playing,
                      builder: (_, playing, _) =>
                          controller.loading && controller.current == null
                          ? const SizedBox(
                              width: 40,
                              child: CupertinoActivityIndicator(),
                            )
                          : _MiniButton(
                              label: playing ? '暂停' : '播放',
                              icon: playing
                                  ? CupertinoIcons.pause_fill
                                  : CupertinoIcons.play_fill,
                              onPressed: controller.toggle,
                            ),
                    ),
                    _MiniButton(
                      label: '下一首',
                      icon: CupertinoIcons.forward_fill,
                      onPressed: () => controller.next(),
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
}

/// 迷你播放器下方的液态玻璃进度条：玻璃凹槽里填充强调色，点按或拖动即可跳转。
class _MiniProgress extends StatefulWidget {
  const _MiniProgress({required this.controller});
  final PlaybackController controller;
  @override
  State<_MiniProgress> createState() => _MiniProgressState();
}

class _MiniProgressState extends State<_MiniProgress> {
  double? dragging;

  void _seekTo(double fraction) {
    final total = widget.controller.engine.duration.value;
    if (total <= Duration.zero) return;
    unawaited(widget.controller.seek(total * fraction.clamp(0.0, 1.0)));
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.controller.engine;
    final tint = DymuseTokens.tint(context);
    return ListenableBuilder(
      listenable: Listenable.merge([engine.position, engine.duration]),
      builder: (context, _) {
        final total = engine.duration.value;
        final position = engine.position.value;
        final progress =
            dragging ??
            (total <= Duration.zero
                ? 0.0
                : (position.inMilliseconds / total.inMilliseconds).clamp(
                    0.0,
                    1.0,
                  ));
        return Semantics(
          label: '播放进度',
          slider: true,
          value: timeLabel(position),
          increasedValue: timeLabel(position + const Duration(seconds: 10)),
          decreasedValue: timeLabel(position - const Duration(seconds: 10)),
          onIncrease: () =>
              widget.controller.seek(position + const Duration(seconds: 10)),
          onDecrease: () =>
              widget.controller.seek(position - const Duration(seconds: 10)),
          child: SizedBox(
            height: 16,
            child: Padding(
              padding: EdgeInsets.zero,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  double at(Offset local) =>
                      (local.dx / constraints.maxWidth).clamp(0.0, 1.0);
                  final active = dragging != null;
                  final ink = DymuseTokens.ink(context);
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) => _seekTo(at(details.localPosition)),
                    onHorizontalDragStart: (details) =>
                        setState(() => dragging = at(details.localPosition)),
                    onHorizontalDragUpdate: (details) =>
                        setState(() => dragging = at(details.localPosition)),
                    onHorizontalDragEnd: (_) {
                      final target = dragging;
                      setState(() => dragging = null);
                      if (target != null) _seekTo(target);
                    },
                    onHorizontalDragCancel: () =>
                        setState(() => dragging = null),
                    child: Align(
                      alignment: Alignment.center,
                      child: Padding(
                        padding: EdgeInsets.zero,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          curve: Curves.easeOut,
                          height: active ? 8 : 4,
                          decoration: BoxDecoration(
                            color: ink.withValues(alpha: .16),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: progress,
                              heightFactor: 1,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: tint,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    onTap: onPressed,
    child: CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: const Size(44, 44),
      onPressed: onPressed,
      child: Icon(icon, size: 22, color: DymuseTokens.ink(context)),
    ),
  );
}

/// 设置 Sheet：沿用桌面设置页内容，顶部加“完成”。
class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet({
    required this.session,
    required this.appearance,
    required this.playback,
    required this.onDone,
  });
  final Session session;
  final Appearance appearance;
  final PlaybackController playback;
  final VoidCallback onDone;
  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return ColoredBox(
      color: DymuseTokens.background(context),
      child: Stack(
        children: [
          // 与主页一致：内容延伸到顶栏下方，上滑时在玻璃顶栏后渐进模糊。
          Positioned.fill(
            child: glass.GlassScrollEdgeEffect(
              style: DymuseTokens.android
                  ? glass.GlassScrollEdgeStyle.soft
                  : glass.GlassScrollEdgeStyle.blur,
              topFadeHeight: top + _TopBar.height + 16,
              fadeBottom: false,
              // 模糊半径大时着色器按固定步长取样，细笔画会采成重影、反而看得清；
              // 半径压低到取样连续的范围，再叠一层渐隐的底色，顶部的字就彻底看不清了。
              maxSigma: 5,
              child: SettingsPage(
                key: ValueKey(session.username),
                session: session,
                appearance: appearance,
                playback: playback,
                topInset: top + _TopBar.height - 20,
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            height: top + _TopBar.height + 16,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      DymuseTokens.background(context).withValues(alpha: .92),
                      DymuseTokens.background(context).withValues(alpha: .6),
                      DymuseTokens.background(context).withValues(alpha: 0),
                    ],
                    stops: const [0, .55, 1],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: _TopBar.height,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _GlassPill(
                      label: '完成',
                      onPressed: onDone,
                      child: Text(
                        '完成',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: DymuseTokens.tint(context),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 给内容底部加上悬浮 Tab 栏与迷你播放器的高度。单独成组件：键盘弹出的每一帧
/// viewInsets 都会变，只有这里依赖完整 MediaQuery，外壳和页面不必逐帧重建。
class _ReservePadding extends StatelessWidget {
  const _ReservePadding({
    required this.top,
    required this.bottom,
    required this.child,
  });
  final double top, bottom;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        padding: media.padding.copyWith(
          top: media.padding.top + top,
          bottom: media.padding.bottom + bottom,
        ),
      ),
      child: child,
    );
  }
}

/// 页面手势与切换动画。浏览层级由 BrowseState 管理而不是 Navigator 路由，
/// 所以系统的返回手势和推入动画在这里补上：
/// - 从左缘右滑返回：页面跟手移动，松手超过阈值即返回，上一页从左侧滑入；
/// - 在 Tab 根页面左右滑动切换 Tab，页面带阻尼跟手；
/// - 页面变化时按方向滑入并淡入（返回从左、进入从右、切 Tab 按顺序）。
/// 横向滚动的轮播等子组件在手势竞争中优先，不受影响。
class _PageGestures extends StatefulWidget {
  const _PageGestures({
    required this.pageKey,
    required this.direction,
    required this.canBack,
    required this.onBack,
    required this.canSwipe,
    required this.onSwipe,
    required this.pull,
    required this.leaving,
    required this.child,
  });
  final ValueNotifier<double> pull;
  final ValueNotifier<bool> leaving;
  final String pageKey;
  final int direction;
  final bool canBack, canSwipe;
  final VoidCallback onBack;
  final ValueChanged<int> onSwipe;
  final Widget child;
  @override
  State<_PageGestures> createState() => _PageGesturesState();
}

class _PageGesturesState extends State<_PageGestures>
    with TickerProviderStateMixin {
  // 拖动在越过触摸阈值后才被识别，用按下时的位置判断是否从左缘开始（见 dragStartBehavior）。
  static const _edge = 36.0;

  /// 返回时下层页面的视差位移（占屏宽的比例），与 iOS 导航栏一致。
  static const _parallax = .3;

  /// 临界阻尼弹簧：松手后顺着手指的速度滑出或弹回，没有生硬的缓动曲线。
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 260,
    damping: 32.2,
  );
  static const _tolerance = Tolerance(distance: .0008, velocity: .01);

  late final _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: 1,
  );
  late final _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  /// 返回手势的弹簧动画，取值为已滑出屏幕的比例（0～1）。
  late final _slide = AnimationController.unbounded(vsync: this);
  final _boundary = GlobalKey();
  int _from = 0;
  double _drag = 0, _settleFrom = 0;

  /// null：没有在拖动；true：左缘返回；false：切换 Tab。
  bool? _back;

  /// 松手后的返回动画：[_snapshot] 是被滑走的旧页面截图，真正的页面已换成上一级。
  ui.Image? _snapshot;
  bool _committed = false, _cancelling = false;

  @override
  void initState() {
    super.initState();
    _slide.addListener(() {
      if (_committed || _cancelling) {
        widget.pull.value = _slide.value.clamp(0.0, 1.0);
      }
    });
    _slide.addStatusListener((status) {
      if (status != AnimationStatus.completed &&
          status != AnimationStatus.dismissed) {
        return;
      }
      if (_snapshot == null && !_cancelling) return;
      setState(() {
        _snapshot?.dispose();
        _snapshot = null;
        _committed = _cancelling = false;
        _slide.value = 0;
      });
      widget.pull.value = 0;
      widget.leaving.value = false;
    });
  }

  @override
  void didUpdateWidget(covariant _PageGestures oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pageKey == oldWidget.pageKey) return;
    _from = widget.direction;
    _drag = 0;
    _settle.value = 0;
    if (_committed) {
      // 返回手势：上一级页面已经就位，旧页面的截图继续滑出，不再叠加进入动画。
      _from = 0;
      _enter.value = 1;
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _enter.value = 1;
    } else {
      _enter.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _settle.dispose();
    _slide.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  double get _width => MediaQuery.sizeOf(context).width;

  void _start(DragStartDetails details) {
    // 上一次的返回动画还没结束时直接接管。
    if (_snapshot != null || _cancelling) {
      _slide.stop();
      _snapshot?.dispose();
      _snapshot = null;
      _committed = _cancelling = false;
      _slide.value = 0;
      widget.pull.value = 0;
      widget.leaving.value = false;
    }
    _settle.value = 0;
    _drag = 0;
    _back = widget.canBack && details.localPosition.dx < _edge
        ? true
        : widget.canSwipe
        ? false
        : null;
  }

  void _update(DragUpdateDetails details) {
    if (_back == null) return;
    setState(() {
      _drag += details.delta.dx;
      if (_back!) _drag = _drag.clamp(0, _width);
    });
    if (_back!) widget.pull.value = _width == 0 ? 0 : _drag / _width;
  }

  void _animateSlide(double from, double to, double velocity) {
    _slide.value = from;
    if (MediaQuery.disableAnimationsOf(context)) {
      _slide.value = to;
      return;
    }
    _slide.animateWith(
      SpringSimulation(_spring, from, to, velocity, tolerance: _tolerance),
    );
  }

  void _end(DragEndDetails details) {
    final back = _back;
    _back = null;
    if (back == null) return;
    final velocity = details.velocity.pixelsPerSecond.dx;
    if (back) {
      final progress = _width == 0 ? 0.0 : _drag / _width;
      final speed = _width == 0 ? 0.0 : velocity / _width;
      // 按松手后的惯性预估落点：拖过一半，或向右甩得够快，就返回。
      final commit =
          progress + speed * .2 > .5 || (progress > .04 && speed > 1.2);
      if (commit) {
        _commitBack(progress, speed);
      } else {
        _cancelBack(progress, speed);
      }
      return;
    }
    if (_drag.abs() > 60 || (_drag.abs() > 16 && velocity.abs() > 400)) {
      final step = (_drag != 0 ? _drag : -velocity) < 0 ? 1 : -1;
      widget.onSwipe(step);
      return;
    }
    _cancel();
  }

  /// 返回：先截下正被拖着的旧页面，再切到上一级，旧页面的截图带着速度滑出屏幕。
  void _commitBack(double progress, double speed) {
    ui.Image? shot;
    try {
      final boundary =
          _boundary.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      shot = boundary?.toImageSync(
        pixelRatio: View.of(context).devicePixelRatio,
      );
    } catch (_) {
      shot = null;
    }
    final before = widget.pageKey;
    setState(() {
      _snapshot = shot;
      _committed = shot != null;
      _drag = 0;
    });
    widget.leaving.value = shot != null;
    widget.onBack();
    _animateSlide(progress, 1, speed);
    // 页面没有变化（例如正在加载）时当作取消，把页面弹回。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.pageKey != before || _snapshot == null) return;
      _slide.stop();
      _snapshot?.dispose();
      setState(() {
        _snapshot = null;
        _committed = false;
        _cancelling = true;
      });
      widget.leaving.value = false;
      _animateSlide(_slide.value, 0, 0);
    });
  }

  void _cancelBack(double progress, double speed) {
    if (progress == 0) {
      setState(() => _drag = 0);
      widget.pull.value = 0;
      return;
    }
    setState(() {
      _drag = 0;
      _cancelling = true;
    });
    _animateSlide(progress, 0, speed);
  }

  /// 抬手后等一帧：正常情况下拖动回调已经处理完；没有的话按取消收尾。
  void _ensureReleased() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (_back != null || _drag != 0) && !_committed) _cancel();
    });
  }

  void _cancel() {
    final back = _back;
    _back = null;
    if (back == true && _width > 0) {
      _cancelBack(_drag / _width, 0);
      return;
    }
    if (_drag == 0) return;
    _settleFrom = _offset();
    _drag = 0;
    _settle.forward(from: 0);
  }

  /// 切 Tab 带阻尼，最多移动约四分之一屏。
  double _offset() {
    final limit = _width * .25;
    return limit * (1 - exp(-_drag.abs() / limit)) * _drag.sign;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // 兜底：手指抬起后拖动状态仍未结束（结束回调丢失）时，按取消处理，把页面弹回。
      onPointerUp: (_) => _ensureReleased(),
      onPointerCancel: (_) => _ensureReleased(),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        dragStartBehavior: DragStartBehavior.down,
        // 回调始终存在：拖动中途 canBack 变化（例如列表加载完）时，不能丢掉结束回调，否则页面会停在半路。
        onHorizontalDragStart: _start,
        onHorizontalDragUpdate: _update,
        onHorizontalDragEnd: _end,
        onHorizontalDragCancel: _cancel,
        child: AnimatedBuilder(
          animation: Listenable.merge([_enter, _settle, _slide]),
          child: RepaintBoundary(key: _boundary, child: widget.child),
          builder: (context, child) {
            final width = _width;
            final t = Curves.easeOutCubic.transform(_enter.value);
            final settling =
                _settle.isAnimating || _settle.value > 0 && _settle.value < 1;
            final sliding = _committed ? _slide.value : 0.0;
            final returning = _cancelling ? _slide.value : 0.0;
            double dx;
            if (_committed) {
              // 上一级页面从左侧 30% 处随旧页面滑出而归位。
              dx = -_parallax * width * (1 - sliding.clamp(0.0, 1.0));
            } else if (_cancelling) {
              dx = returning * width;
            } else if (_back == true) {
              dx = _drag;
            } else {
              dx =
                  (1 - t) * _from * width * .3 +
                  (_back != null
                      ? _offset()
                      : settling
                      ? _settleFrom *
                            (1 - Curves.easeOut.transform(_settle.value))
                      : 0);
            }
            // 旧页面前沿（被拖着的页面或截图）的横向位置，用来画边缘阴影。
            final edge = _committed
                ? sliding * width
                : (_cancelling || _back == true)
                ? dx
                : null;
            // 结构保持不变（始终包一层位移与透明度），否则插入/移除包装会重建页面、丢失滚动位置。
            return Stack(
              fit: StackFit.passthrough,
              children: [
                Opacity(
                  opacity: _enter.value >= 1 ? 1.0 : .35 + .65 * t,
                  child: Transform.translate(
                    offset: Offset(dx, 0),
                    child: child,
                  ),
                ),
                if (_committed)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ColoredBox(
                        color: CupertinoColors.black.withValues(
                          alpha: .1 * (1 - sliding.clamp(0.0, 1.0)),
                        ),
                      ),
                    ),
                  ),
                if (_committed && _snapshot != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Transform.translate(
                        offset: Offset(sliding * width, 0),
                        child: ColoredBox(
                          color: DymuseTokens.background(context),
                          child: RawImage(
                            image: _snapshot,
                            fit: BoxFit.fill,
                            width: width,
                            height: double.infinity,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (edge != null && edge > 0)
                  Positioned(
                    left: edge - 14,
                    top: 0,
                    bottom: 0,
                    width: 14,
                    child: const IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0x00000000), Color(0x22000000)],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
