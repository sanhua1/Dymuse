import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../core/session.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';
import '../features/browse_page.dart';
import '../features/catalog.dart';
import '../features/intelligence_page.dart';
import '../features/settings_page.dart';
import '../features/search_controls.dart';
import '../platform/desktop_window.dart';
import '../playback/playback_controller.dart';
import '../playback/player_view.dart';

class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.session,
    required this.catalog,
    required this.playback,
    required this.appearance,
    required this.window,
  });
  final Session session;
  final Catalog catalog;
  final PlaybackController playback;
  final Appearance appearance;
  final DesktopWindow window;
  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  late final browsers = {
    for (final mode in MusicMode.values)
      mode: BrowseState(mode, widget.catalog),
  };
  final search = TextEditingController();
  final searchFocus = FocusNode();
  late MusicMode mode = widget.playback.mode;
  bool settings = false, queue = false, expanded = false, switching = false;
  BrowseState get browser => browsers[mode]!;
  @override
  void initState() {
    super.initState();
    unawaited(browser.load());
  }

  @override
  void dispose() {
    for (final browser in browsers.values) {
      browser.dispose();
    }
    search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  /// 切换导航与引擎使用同一入口，保存旧模式并暂停恢复。
  Future<void> switchMode(MusicMode target) async {
    if (target == mode || switching) return;
    setState(() => switching = true);
    await widget.playback.switchMode(target);
    if (!mounted) return;
    setState(() {
      mode = widget.playback.mode;
      settings = false;
      expanded = false;
      search.text = browser.query;
      switching = false;
    });
    if (!browser.loaded) unawaited(browser.load());
  }

  void navigate(String section) {
    setState(() {
      settings = false;
      search.clear();
    });
    unawaited(browser.navigate(section));
    if (mode == MusicMode.netease && section == 'intelligence') {
      unawaited(widget.playback.startIntelligence());
    }
  }

  /// 播放器中的艺人/专辑链接：收起播放器并在当前模式打开对应页面。
  void openCollection(Collection target) {
    setState(() {
      settings = false;
      expanded = false;
    });
    unawaited(browser.openCollection(target));
  }

  void submitSearch(String text) {
    setState(() {
      settings = false;
      expanded = false;
    });
    unawaited(browser.navigate('search', text: text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.sizeOf(context).width < DymuseTokens.compactBreakpoint;
    final sidebarWidth = compact ? 80.0 : DymuseTokens.sidebar;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            searchFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.escape): () => setState(() {
          expanded = false;
          queue = false;
        }),
        const SingleActivator(LogicalKeyboardKey.f11):
            widget.window.toggleFullScreen,
        const SingleActivator(
          LogicalKeyboardKey.arrowRight,
          control: true,
        ): () =>
            widget.playback.next(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true):
            widget.playback.previous,
      },
      child: Focus(
        onKeyEvent: (_, event) {
          final focusContext = FocusManager.instance.primaryFocus?.context;
          final editing =
              searchFocus.hasFocus ||
              focusContext?.widget is EditableText ||
              focusContext?.findAncestorWidgetOfExactType<EditableText>() !=
                  null;
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.space &&
              !editing) {
            widget.playback.toggle();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            Column(
              children: [
                WindowTitleBar(window: widget.window),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: sidebarWidth,
                        child: _sidebar(context, compact),
                      ),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: DymuseTokens.background(context),
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(18),
                            ),
                            border: Border(
                              top: BorderSide(
                                color: DymuseTokens.line(context),
                              ),
                              left: BorderSide(
                                color: DymuseTokens.line(context),
                              ),
                            ),
                          ),
                          child: Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  12,
                                  24,
                                  8,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: DymuseSearchField(
                                        controller: search,
                                        focusNode: searchFocus,
                                        placeholder:
                                            '搜索${mode == MusicMode.netease ? '网易云音乐' : '哔哩哔哩'}',
                                        onSearch: submitSearch,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    ActionButton(
                                      label: '账号与设置',
                                      icon: CupertinoIcons.person_crop_circle,
                                      selected: settings,
                                      onPressed: () =>
                                          setState(() => settings = !settings),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: settings
                                    ? SettingsPage(
                                        key: ValueKey(widget.session.username),
                                        session: widget.session,
                                        appearance: widget.appearance,
                                        playback: widget.playback,
                                      )
                                    : mode == MusicMode.netease &&
                                          browser.section == 'intelligence'
                                    ? IntelligencePage(
                                        playback: widget.playback,
                                        onExpand: () =>
                                            setState(() => expanded = true),
                                      )
                                    : BrowsePage(
                                        key: ValueKey(mode),
                                        window: widget.window,
                                        browser: browser,
                                        playback: widget.playback,
                                        onExpand: () =>
                                            setState(() => expanded = true),
                                        onSettings: () =>
                                            setState(() => settings = true),
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (queue &&
                          MediaQuery.sizeOf(context).width >=
                              DymuseTokens.wideBreakpoint)
                        SizedBox(
                          width: 300,
                          child: QueuePanel(
                            controller: widget.playback,
                            onExpand: () => setState(() => expanded = true),
                            onClose: () => setState(() => queue = false),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                  child: MiniPlayer(
                    controller: widget.playback,
                    onExpand: () => setState(() => expanded = true),
                    queueVisible: queue,
                    onQueue: () => setState(() => queue = !queue),
                  ),
                ),
              ],
            ),
            if (queue &&
                MediaQuery.sizeOf(context).width < DymuseTokens.wideBreakpoint)
              Positioned(
                top: 54,
                bottom: 146,
                right: 0,
                width: 300,
                child: QueuePanel(
                  controller: widget.playback,
                  onExpand: () => setState(() => expanded = true),
                  onClose: () => setState(() => queue = false),
                ),
              ),
            if (expanded)
              Positioned.fill(
                top: 54,
                child: FullPlayer(
                  controller: widget.playback,
                  onClose: () => setState(() => expanded = false),
                  onOpenCollection: openCollection,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sidebar(BuildContext context, bool compact) => ListenableBuilder(
    listenable: browser,
    builder: (_, _) => Padding(
      padding: EdgeInsets.fromLTRB(compact ? 8 : 16, 4, compact ? 8 : 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!compact)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 0, 20),
              child: Row(
                children: [
                  Icon(
                    CupertinoIcons.waveform,
                    size: 22,
                    color: DymuseTokens.tint(context),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Dymuse',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.8,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView(
              children: [
                if (!compact)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 0, 8),
                    child: Text(
                      '音乐模式',
                      style: DymuseTokens.caption.copyWith(
                        color: DymuseTokens.secondary(context),
                      ),
                    ),
                  ),
                _nav(
                  '网易云音乐',
                  CupertinoIcons.cloud,
                  () => switchMode(MusicMode.netease),
                  mode == MusicMode.netease,
                  compact,
                ),
                _nav(
                  '哔哩哔哩',
                  CupertinoIcons.play_rectangle,
                  () => switchMode(MusicMode.bilibili),
                  mode == MusicMode.bilibili,
                  compact,
                ),
                const SizedBox(height: 28),
                if (!compact)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 0, 8),
                    child: Text(
                      '资料库',
                      style: DymuseTokens.caption.copyWith(
                        color: DymuseTokens.secondary(context),
                      ),
                    ),
                  ),
                if (mode == MusicMode.netease) ...[
                  _nav(
                    '心动模式',
                    CupertinoIcons.heart_circle,
                    () => navigate('intelligence'),
                    !settings && browser.section == 'intelligence',
                    compact,
                  ),
                  _nav(
                    '现在就听',
                    CupertinoIcons.play_circle,
                    () => navigate('discover'),
                    !settings && browser.section == 'discover',
                    compact,
                  ),
                  _nav(
                    '每日推荐',
                    CupertinoIcons.music_note_2,
                    () => navigate('songs'),
                    !settings && browser.section == 'songs',
                    compact,
                  ),
                  _nav(
                    '我喜欢的音乐',
                    CupertinoIcons.heart,
                    () => navigate('favorites'),
                    !settings && browser.section == 'favorites',
                    compact,
                  ),
                  _nav(
                    '播客',
                    CupertinoIcons.mic,
                    () => navigate('podcasts'),
                    !settings && browser.section.startsWith('podcasts'),
                    compact,
                  ),
                ] else ...[
                  _nav(
                    '我的订阅',
                    CupertinoIcons.rectangle_stack,
                    () => navigate('subscriptions'),
                    !settings && browser.section == 'subscriptions',
                    compact,
                  ),
                  _nav(
                    '我喜欢的音乐',
                    CupertinoIcons.heart,
                    () => navigate('favorites'),
                    !settings && browser.section == 'favorites',
                    compact,
                  ),
                  _nav(
                    '歌单',
                    CupertinoIcons.music_note_list,
                    () => navigate('playlists'),
                    !settings && browser.section == 'playlists',
                    compact,
                  ),
                  _nav(
                    '资料库',
                    CupertinoIcons.collections,
                    () => navigate('library'),
                    !settings && browser.section == 'library',
                    compact,
                  ),
                ],
                if (mode == MusicMode.netease)
                  _nav(
                    '我的歌单',
                    CupertinoIcons.music_note_list,
                    () => navigate('playlists'),
                    !settings && browser.section == 'playlists',
                    compact,
                  ),
                _nav(
                  '搜索',
                  CupertinoIcons.search,
                  () {
                    navigate('search');
                    searchFocus.requestFocus();
                  },
                  !settings && browser.section == 'search',
                  compact,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _nav(
              '设置',
              CupertinoIcons.gear_alt,
              () => setState(() => settings = true),
              settings,
              compact,
            ),
          ),
        ],
      ),
    ),
  );
  Widget _nav(
    String label,
    IconData icon,
    VoidCallback action,
    bool selected,
    bool compact,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: ActionButton(
      label: label,
      onPressed: switching ? null : action,
      selected: selected,
      child: Row(
        mainAxisAlignment: compact
            ? MainAxisAlignment.center
            : MainAxisAlignment.start,
        children: [
          Icon(icon, size: 19),
          if (!compact) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
