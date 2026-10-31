import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import '../core/session.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';
import '../features/browse_page.dart';
import '../features/catalog.dart';
import '../features/intelligence_page.dart';
import '../features/search_controls.dart';
import '../features/settings_page.dart';
import '../features/song_actions.dart';
import '../platform/desktop_window.dart';
import '../playback/playback_controller.dart';
import '../playback/player_view.dart';

enum _SidePanel { none, lyrics, queue }

/// macOS 外壳：参照 Apple Music（macOS 26）的布局——
/// 左侧为内嵌圆角侧栏（原生侧栏材质），底部为悬浮玻璃播放条，
/// 歌词与播放队列在右侧栏切换。业务状态、页面和播放控制与 Windows 共用。
class MacShell extends StatefulWidget {
  const MacShell({
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
  State<MacShell> createState() => _MacShellState();
}

class _MacShellState extends State<MacShell> {
  static const _inset = 8.0, _sidebar = 232.0, _panel = 320.0;
  static const _barHeight = 60.0, _barGap = 12.0;
  late final browsers = {
    for (final mode in MusicMode.values)
      mode: BrowseState(mode, widget.catalog),
  };
  final search = TextEditingController();
  final searchFocus = FocusNode();
  late MusicMode mode = widget.playback.mode;
  bool settings = false, expanded = false, switching = false;
  _SidePanel panel = _SidePanel.none;
  BrowseState get browser => browsers[mode]!;
  PlaybackController get playback => widget.playback;

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

  /// 与 Windows 外壳相同：保存旧模式、暂停并恢复目标模式。
  Future<void> switchMode(MusicMode target) async {
    if (target == mode || switching) return;
    setState(() => switching = true);
    await playback.switchMode(target);
    if (!mounted) return;
    setState(() {
      mode = playback.mode;
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
      expanded = false;
      search.clear();
    });
    unawaited(browser.navigate(section));
    if (mode == MusicMode.netease && section == 'intelligence') {
      unawaited(playback.startIntelligence());
    }
  }

  void submitSearch(String text) {
    setState(() {
      settings = false;
      expanded = false;
    });
    unawaited(browser.navigate('search', text: text.trim()));
  }

  /// 艺人/专辑/播客链接：收起全屏播放器，在当前模式打开对应页面。
  void openCollection(Collection target) {
    setState(() {
      settings = false;
      expanded = false;
    });
    unawaited(browser.openCollection(target));
  }

  /// 歌词与队列共用右侧栏：再次点击同一按钮收起，点击另一个则切换。
  void togglePanel(_SidePanel target) =>
      setState(() => panel = panel == target ? _SidePanel.none : target);

  /// ⌘L：在当前列表中滚动到正在播放的歌曲并选中；列表里没有时打开播放队列。
  void revealCurrent() {
    if (playback.current == null) return;
    setState(() {
      expanded = false;
      settings = false;
    });
    TrackRow.revealed = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      TrackRow.reveal.value++;
      if (!TrackRow.revealed && mounted) {
        setState(() => panel = _SidePanel.queue);
      }
    });
  }

  void changeVolume(double delta) =>
      playback.setVolume((playback.volume + delta).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final solid =
        MediaQuery.of(context).highContrast ||
        AppearanceScope.of(context)?.reduceTransparency == true;
    final docked =
        panel != _SidePanel.none && size.width >= DymuseTokens.wideBreakpoint;
    const contentLeft = _inset + _sidebar;
    final contentRight = docked ? _panel + _inset : 0.0;
    const barReserve = _barHeight + _barGap * 2;
    return _menus(
      Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          final focusContext = FocusManager.instance.primaryFocus?.context;
          final editing =
              searchFocus.hasFocus ||
              focusContext?.widget is EditableText ||
              focusContext?.findAncestorWidgetOfExactType<EditableText>() !=
                  null;
          if (event is! KeyDownEvent || editing) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.space) {
            playback.toggle();
            return KeyEventResult.handled;
          }
          // 无修饰键的 ←/→：播放中切到上一首/下一首（“音乐”键盘快捷键）。
          final plain =
              !HardwareKeyboard.instance.isMetaPressed &&
              !HardwareKeyboard.instance.isAltPressed &&
              !HardwareKeyboard.instance.isControlPressed &&
              !HardwareKeyboard.instance.isShiftPressed;
          if (plain && playback.current != null) {
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              playback.next();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              playback.previous();
              return KeyEventResult.handled;
            }
          }
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            if (expanded) {
              setState(() => expanded = false);
            } else if (panel != _SidePanel.none) {
              setState(() => panel = _SidePanel.none);
            } else {
              TrackRow.selection.value = null;
            }
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            // 内容背景覆盖整窗，只在侧栏圆角区域镂空露出原生材质。
            Positioned.fill(
              child: CustomPaint(
                painter: _SidebarCutout(
                  panel: RRect.fromRectAndRadius(
                    Rect.fromLTWH(
                      _inset,
                      _inset,
                      _sidebar - _inset,
                      size.height - _inset * 2,
                    ),
                    const Radius.circular(14),
                  ),
                  background: DymuseTokens.background(context),
                  panelFill: solid ? DymuseTokens.surface(context) : null,
                  border: DymuseTokens.line(context),
                ),
              ),
            ),
            Positioned(
              left: _inset,
              top: _inset,
              bottom: _inset,
              width: _sidebar - _inset,
              child: _MacSidebar(
                window: widget.window,
                browser: browser,
                mode: mode,
                settings: settings,
                switching: switching,
                search: search,
                searchFocus: searchFocus,
                onSearch: submitSearch,
                onMode: switchMode,
                onNavigate: navigate,
                onSettings: () => setState(() {
                  settings = true;
                  expanded = false;
                }),
              ),
            ),
            Positioned(
              left: contentLeft,
              top: 0,
              right: contentRight,
              bottom: 0,
              child: Column(
                children: [
                  SizedBox(
                    height: 40,
                    child: WindowDragArea(window: widget.window),
                  ),
                  Expanded(
                    // 内容滚动到播放条下方，末尾留出播放条高度。
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        padding: MediaQuery.paddingOf(
                          context,
                        ).copyWith(bottom: barReserve),
                      ),
                      child: _content(),
                    ),
                  ),
                ],
              ),
            ),
            if (panel != _SidePanel.none)
              Positioned(
                top: _inset,
                right: _inset,
                bottom: barReserve,
                width: _panel,
                child: _SidePanelView(
                  panel: panel,
                  controller: playback,
                  onClose: () => setState(() => panel = _SidePanel.none),
                  onExpand: () => setState(() => expanded = true),
                ),
              ),
            Positioned(
              left: contentLeft + _barGap,
              right: _barGap,
              bottom: _barGap,
              height: _barHeight,
              child: _PlayerBar(
                controller: playback,
                panel: panel,
                onLyrics: () => togglePanel(_SidePanel.lyrics),
                onQueue: () => togglePanel(_SidePanel.queue),
                onExpand: () => setState(() => expanded = true),
                onOpenCollection: openCollection,
              ),
            ),
            if (expanded)
              Positioned.fill(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: FullPlayer(
                        controller: playback,
                        topInset: 32,
                        onClose: () => setState(() => expanded = false),
                        onOpenCollection: openCollection,
                      ),
                    ),
                    // 顶部空白可拖动窗口；左侧留给原生红黄绿按钮。
                    Positioned(
                      left: 84,
                      right: 0,
                      top: 0,
                      height: 32,
                      child: WindowDragArea(window: widget.window),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _content() => settings
      ? SettingsPage(
          key: ValueKey(widget.session.username),
          session: widget.session,
          appearance: widget.appearance,
          playback: playback,
        )
      : mode == MusicMode.netease && browser.section == 'intelligence'
      ? IntelligencePage(
          playback: playback,
          onExpand: () => setState(() => expanded = true),
        )
      : BrowsePage(
          key: ValueKey(mode),
          window: widget.window,
          browser: browser,
          playback: playback,
          onExpand: () => setState(() => expanded = true),
          onSettings: () => setState(() => settings = true),
        );

  /// 原生菜单栏：“控制”菜单对应 Apple Music 的播放操作；
  /// 空格在应用内处理，避免抢走搜索框输入。
  Widget _menus(Widget child) => PlatformMenuBar(
    menus: [
      PlatformMenu(
        label: 'Dymuse',
        menus: [
          PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.about,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: '设置…',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.comma,
                  meta: true,
                ),
                onSelected: () => setState(() {
                  settings = true;
                  expanded = false;
                }),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.servicesSubmenu,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.hideOtherApplications,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.showAllApplications,
              ),
            ],
          ),
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
        ],
      ),
      PlatformMenu(
        label: '控制',
        menus: [
          PlatformMenuItemGroup(
            members: [
              // 空格由窗口内处理，避免与文本输入冲突；菜单只显示操作。
              PlatformMenuItem(label: '播放/暂停', onSelected: playback.toggle),
              PlatformMenuItem(
                label: '停止',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.period,
                  meta: true,
                ),
                onSelected: playback.stop,
              ),
              PlatformMenuItem(
                label: '下一首',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.arrowRight,
                  meta: true,
                ),
                onSelected: () => playback.next(),
              ),
              PlatformMenuItem(
                label: '上一首',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.arrowLeft,
                  meta: true,
                ),
                onSelected: playback.previous,
              ),
              PlatformMenuItem(
                label: '快进',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.arrowRight,
                  meta: true,
                  alt: true,
                ),
                onSelected: () => playback.skipBy(const Duration(seconds: 10)),
              ),
              PlatformMenuItem(
                label: '快退',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.arrowLeft,
                  meta: true,
                  alt: true,
                ),
                onSelected: () => playback.skipBy(const Duration(seconds: -10)),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: '前往当前歌曲',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyL,
                  meta: true,
                ),
                onSelected: revealCurrent,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: '增大音量',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.arrowUp,
                  meta: true,
                ),
                onSelected: () => changeVolume(.1),
              ),
              PlatformMenuItem(
                label: '减小音量',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.arrowDown,
                  meta: true,
                ),
                onSelected: () => changeVolume(-.1),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: playback.shuffle ? '关闭随机播放' : '随机播放',
                onSelected: playback.setShuffle,
              ),
              PlatformMenuItem(
                label: switch (playback.repeat) {
                  'off' => '重复：全部',
                  'all' => '重复：单曲',
                  _ => '关闭重复',
                },
                onSelected: playback.cycleRepeat,
              ),
            ],
          ),
        ],
      ),
      PlatformMenu(
        label: '显示',
        menus: [
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: '搜索',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyF,
                  meta: true,
                ),
                onSelected: searchFocus.requestFocus,
              ),
              PlatformMenuItem(
                label: panel == _SidePanel.lyrics ? '隐藏歌词' : '显示歌词',
                onSelected: () => togglePanel(_SidePanel.lyrics),
              ),
              PlatformMenuItem(
                label: panel == _SidePanel.queue ? '隐藏待播清单' : '显示待播清单',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyU,
                  meta: true,
                  alt: true,
                ),
                onSelected: () => togglePanel(_SidePanel.queue),
              ),
            ],
          ),
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.toggleFullScreen,
          ),
        ],
      ),
      PlatformMenu(
        label: '窗口',
        menus: [
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: '关闭窗口',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyW,
                  meta: true,
                ),
                onSelected: widget.window.close,
              ),
              const PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.minimizeWindow,
              ),
              const PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.zoomWindow,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: 'Dymuse',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.digit0,
                  meta: true,
                ),
                onSelected: widget.window.show,
              ),
              PlatformMenuItem(
                label: '正在播放',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyF,
                  meta: true,
                  shift: true,
                ),
                onSelected: playback.current == null
                    ? null
                    : () => setState(() => expanded = !expanded),
              ),
            ],
          ),
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.arrangeWindowsInFront,
          ),
        ],
      ),
    ],
    child: child,
  );
}

/// 整窗内容背景，挖去侧栏圆角矩形；侧栏边缘画一圈细线。
class _SidebarCutout extends CustomPainter {
  _SidebarCutout({
    required this.panel,
    required this.background,
    required this.border,
    this.panelFill,
  });
  final RRect panel;
  final Color background, border;
  final Color? panelFill;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(panel);
    canvas.drawPath(path, Paint()..color = background);
    if (panelFill != null) canvas.drawRRect(panel, Paint()..color = panelFill!);
    canvas.drawRRect(
      panel,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = border,
    );
  }

  @override
  bool shouldRepaint(_SidebarCutout old) =>
      old.panel != panel ||
      old.background != background ||
      old.border != border ||
      old.panelFill != panelFill;
}

/// 侧栏：顶部原生红黄绿按钮区，搜索，分组列表，底部账号与设置。
class _MacSidebar extends StatelessWidget {
  const _MacSidebar({
    required this.window,
    required this.browser,
    required this.mode,
    required this.settings,
    required this.switching,
    required this.search,
    required this.searchFocus,
    required this.onSearch,
    required this.onMode,
    required this.onNavigate,
    required this.onSettings,
  });
  final DesktopWindow window;
  final BrowseState browser;
  final MusicMode mode;
  final bool settings, switching;
  final TextEditingController search;
  final FocusNode searchFocus;
  final ValueChanged<String> onSearch;
  final ValueChanged<MusicMode> onMode;
  final ValueChanged<String> onNavigate;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: browser,
    builder: (context, _) {
      bool at(String section) => !settings && browser.section == section;
      final netease = mode == MusicMode.netease;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 原生红黄绿按钮位于此拖动区。
          SizedBox(height: 44, child: WindowDragArea(window: window)),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: DymuseSearchField(
              controller: search,
              focusNode: searchFocus,
              placeholder: '搜索',
              onSearch: onSearch,
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                const _SidebarHeader('音乐模式'),
                _SidebarItem(
                  label: '网易云音乐',
                  icon: CupertinoIcons.cloud,
                  selected: netease,
                  onPressed: switching ? null : () => onMode(MusicMode.netease),
                ),
                _SidebarItem(
                  label: '哔哩哔哩',
                  icon: CupertinoIcons.play_rectangle,
                  selected: !netease,
                  onPressed: switching
                      ? null
                      : () => onMode(MusicMode.bilibili),
                ),
                // 所有内容入口收在“资料库”一组里；模式名只在上方“音乐模式”处标示。
                const _SidebarHeader('资料库'),
                if (netease) ...[
                  _SidebarItem(
                    label: '心动模式',
                    icon: CupertinoIcons.heart_circle,
                    selected: at('intelligence'),
                    onPressed: () => onNavigate('intelligence'),
                  ),
                  _SidebarItem(
                    label: '现在就听',
                    icon: CupertinoIcons.play_circle,
                    selected: at('discover'),
                    onPressed: () => onNavigate('discover'),
                  ),
                  _SidebarItem(
                    label: '每日推荐',
                    icon: CupertinoIcons.calendar_today,
                    selected: at('songs'),
                    onPressed: () => onNavigate('songs'),
                  ),
                  _SidebarItem(
                    label: '我喜欢的音乐',
                    icon: CupertinoIcons.heart,
                    selected: at('favorites'),
                    onPressed: () => onNavigate('favorites'),
                  ),
                  _SidebarItem(
                    label: '播客',
                    icon: CupertinoIcons.mic,
                    selected:
                        !settings && browser.section.startsWith('podcasts'),
                    onPressed: () => onNavigate('podcasts'),
                  ),
                ] else ...[
                  _SidebarItem(
                    label: '我的订阅',
                    icon: CupertinoIcons.rectangle_stack,
                    selected: at('subscriptions'),
                    onPressed: () => onNavigate('subscriptions'),
                  ),
                  _SidebarItem(
                    label: '我喜欢的音乐',
                    icon: CupertinoIcons.heart,
                    selected: at('favorites'),
                    onPressed: () => onNavigate('favorites'),
                  ),
                  _SidebarItem(
                    label: '歌单',
                    icon: CupertinoIcons.music_note_list,
                    selected: at('playlists'),
                    onPressed: () => onNavigate('playlists'),
                  ),
                  _SidebarItem(
                    label: '资料库',
                    icon: CupertinoIcons.collections,
                    selected: at('library'),
                    onPressed: () => onNavigate('library'),
                  ),
                ],
                if (netease)
                  _SidebarItem(
                    label: '我的歌单',
                    icon: CupertinoIcons.music_note_list,
                    selected: at('playlists'),
                    onPressed: () => onNavigate('playlists'),
                  ),
                _SidebarItem(
                  label: '搜索结果',
                  icon: CupertinoIcons.search,
                  selected: at('search'),
                  onPressed: () {
                    onNavigate('search');
                    searchFocus.requestFocus();
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
            child: _SidebarItem(
              label: '账号与设置',
              icon: CupertinoIcons.gear_alt,
              selected: settings,
              onPressed: onSettings,
            ),
          ),
        ],
      );
    },
  );
}

class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 16, 10, 6),
    child: Semantics(
      header: true,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: DymuseTokens.secondary(context),
        ),
      ),
    ),
  );
}

/// macOS 侧栏行：未选中为正文色线条图标；选中为中性圆角底、强调色图标与文字。
class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onPressed;
  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool focus = false;
  @override
  Widget build(BuildContext context) {
    final dark = DymuseTokens.dark(context);
    final tint = DymuseTokens.tint(context);
    final foreground = widget.onPressed == null
        ? DymuseTokens.secondary(context)
        : widget.selected
        ? tint
        : DymuseTokens.ink(context);
    return Semantics(
      button: true,
      selected: widget.selected,
      enabled: widget.onPressed != null,
      label: widget.label,
      excludeSemantics: true,
      child: FocusableActionDetector(
        enabled: widget.onPressed != null,
        mouseCursor: SystemMouseCursors.basic,
        onShowFocusHighlight: (value) => setState(() => focus = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Container(
            height: 32,
            margin: const EdgeInsets.only(bottom: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: widget.selected
                  ? (dark ? const Color(0x1FFFFFFF) : const Color(0x14000000))
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: focus ? tint : const Color(0x00000000),
                width: 2,
              ),
            ),
            child: Row(
              children: [
                Icon(widget.icon, size: 17, color: foreground),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: foreground),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 右侧栏：歌词或播放队列。
class _SidePanelView extends StatelessWidget {
  const _SidePanelView({
    required this.panel,
    required this.controller,
    required this.onClose,
    required this.onExpand,
  });
  final _SidePanel panel;
  final PlaybackController controller;
  final VoidCallback onClose, onExpand;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: DymuseTokens.surface(context),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: DymuseTokens.line(context)),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: panel == _SidePanel.queue
          ? _MacQueue(controller: controller, onClose: onClose)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 8, 0),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('歌词', style: DymuseTokens.title),
                      ),
                      ActionButton(
                        label: '关闭歌词',
                        icon: CupertinoIcons.xmark,
                        compact: true,
                        onPressed: onClose,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) =>
                        controller.current?.isPodcast == true
                        ? const StatusMessage(
                            title: '节目没有歌词',
                            message: '播客节目不提供歌词。',
                            icon: CupertinoIcons.mic,
                          )
                        : LyricsView(
                            controller: controller,
                            fontSize: 17,
                            padding: const EdgeInsets.fromLTRB(18, 40, 18, 80),
                          ),
                  ),
                ),
              ],
            ),
    ),
  );
}

/// 底部悬浮玻璃播放条：左侧播放控制，中部正在播放，右侧歌词、队列与音量。
class _PlayerBar extends StatelessWidget {
  const _PlayerBar({
    required this.controller,
    required this.panel,
    required this.onLyrics,
    required this.onQueue,
    required this.onExpand,
    required this.onOpenCollection,
  });
  final PlaybackController controller;
  final _SidePanel panel;
  final VoidCallback onLyrics, onQueue, onExpand;
  final ValueChanged<Collection> onOpenCollection;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    return GlassPanel(
      radius: 30,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final empty = controller.items.isEmpty;
          return Row(
            children: [
              if (wide)
                _BarButton(
                  label: controller.shuffle ? '关闭随机播放' : '随机播放',
                  icon: CupertinoIcons.shuffle,
                  size: 15,
                  selected: controller.shuffle,
                  onPressed: controller.snapshot == null
                      ? null
                      : controller.setShuffle,
                ),
              _BarButton(
                label: '上一首',
                icon: CupertinoIcons.backward_fill,
                size: 19,
                onPressed: empty ? null : controller.previous,
              ),
              ValueListenableBuilder(
                valueListenable: controller.engine.playing,
                builder: (_, playing, _) => _BarButton(
                  label: playing ? '暂停' : '播放',
                  icon: playing
                      ? CupertinoIcons.pause_fill
                      : CupertinoIcons.play_fill,
                  size: 24,
                  loading: controller.loading,
                  onPressed: empty || controller.loading
                      ? null
                      : controller.toggle,
                ),
              ),
              _BarButton(
                label: '下一首',
                icon: CupertinoIcons.forward_fill,
                size: 19,
                onPressed: empty ? null : () => controller.next(),
              ),
              if (wide)
                _BarButton(
                  label: switch (controller.repeat) {
                    'all' => '重复全部',
                    'one' => '单曲重复',
                    _ => '不重复',
                  },
                  icon: controller.repeat == 'one'
                      ? CupertinoIcons.repeat_1
                      : CupertinoIcons.repeat,
                  size: 15,
                  selected: controller.repeat != 'off',
                  onPressed: controller.snapshot == null
                      ? null
                      : controller.cycleRepeat,
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: _NowPlaying(
                      controller: controller,
                      onExpand: onExpand,
                      onOpenCollection: onOpenCollection,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _BarButton(
                label: '歌词',
                icon: CupertinoIcons.quote_bubble,
                size: 17,
                selected: panel == _SidePanel.lyrics,
                onPressed: onLyrics,
              ),
              _BarButton(
                label: '播放队列',
                icon: CupertinoIcons.list_bullet,
                size: 17,
                selected: panel == _SidePanel.queue,
                onPressed: onQueue,
              ),
              LyricLayerMenu(
                visible: panel == _SidePanel.lyrics,
                builder: (context, open, active) => _BarButton(
                  label: '歌词翻译',
                  icon: CupertinoIcons.globe,
                  size: 17,
                  selected: active,
                  onPressed: open,
                ),
              ),
              if (wide) ...[
                const SizedBox(width: 6),
                // 固定宽度：静音与普通图标宽度不同，滑条不随之跳动；与滑条留出间距。
                SizedBox(
                  width: 20,
                  child: Icon(
                    controller.volume == 0
                        ? CupertinoIcons.speaker_slash_fill
                        : CupertinoIcons.speaker_2_fill,
                    size: 14,
                    color: DymuseTokens.secondary(context),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 92,
                  child: Semantics(
                    label: '音量',
                    value: '${(controller.volume * 100).round()}%',
                    child: _ThinSlider(
                      value: controller.volume,
                      onChanged: controller.setVolume,
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// 播放条按钮：无底色方块，悬停加深图标、按下变淡；开启状态为强调色与浅圆底。
class _BarButton extends StatefulWidget {
  const _BarButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.size = 18,
    this.selected = false,
    this.loading = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final bool selected, loading;
  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool hover = false, pressed = false, focus = false;
  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final tint = DymuseTokens.tint(context);
    final ink = DymuseTokens.ink(context);
    final color = !enabled
        ? DymuseTokens.secondary(context).withValues(alpha: .45)
        : widget.selected
        ? tint
        : ink.withValues(alpha: hover ? 1 : .82);
    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.label,
      excludeSemantics: true,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: SystemMouseCursors.basic,
        onShowHoverHighlight: (value) => setState(() => hover = value),
        onShowFocusHighlight: (value) => setState(() => focus = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => pressed = true) : null,
          onTapCancel: () => setState(() => pressed = false),
          onTapUp: (_) => setState(() => pressed = false),
          onTap: widget.onPressed,
          child: Container(
            width: widget.size + 20,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.selected
                  ? tint.withValues(alpha: .14)
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: focus ? tint : const Color(0x00000000),
                width: 2,
              ),
            ),
            child: widget.loading
                ? const CupertinoActivityIndicator(radius: 8)
                : AnimatedOpacity(
                    opacity: pressed ? .45 : 1,
                    duration: const Duration(milliseconds: 80),
                    child: Icon(widget.icon, size: widget.size, color: color),
                  ),
          ),
        ),
      ),
    );
  }
}

/// 播放条中部：封面（点按打开全屏播放器）、标题、可点击的艺人与专辑、细进度条。
class _NowPlaying extends StatelessWidget {
  const _NowPlaying({
    required this.controller,
    required this.onExpand,
    required this.onOpenCollection,
  });
  final PlaybackController controller;
  final VoidCallback onExpand;
  final ValueChanged<Collection> onOpenCollection;
  @override
  Widget build(BuildContext context) {
    final track = controller.track;
    return Row(
      children: [
        Semantics(
          label: '打开全屏播放器',
          button: true,
          child: GestureDetector(
            onTap: track == null ? null : onExpand,
            child: RemoteArtwork(
              api: controller.api,
              url: track?.cover,
              size: 40,
              seed: track?.album ?? 'Dymuse',
              radius: 6,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                track?.title ?? 'Dymuse',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (controller.error != null)
                Text(
                  controller.error!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.3,
                    color: DymuseTokens.tint(context),
                  ),
                )
              else if (track == null)
                const SizedBox(height: 15)
              else
                SizedBox(
                  height: 15,
                  child: ClipRect(
                    child: TrackCredits(
                      track: track,
                      onOpen: onOpenCollection,
                      center: true,
                      fontSize: 11,
                      showAlbum: true,
                    ),
                  ),
                ),
              _ThinProgress(controller: controller),
            ],
          ),
        ),
        if (controller.error != null)
          _BarButton(
            label: '重试播放',
            icon: CupertinoIcons.arrow_clockwise,
            size: 15,
            onPressed: controller.retry,
          )
        else
          SongActions(catalog: controller.catalog, track: track),
      ],
    );
  }
}

/// 细进度条：从左向右填充；悬停加粗并显示已播放与剩余时间。
/// 点击或拖动跳转，读屏可 ±10 秒调节。
class _ThinProgress extends StatefulWidget {
  const _ThinProgress({required this.controller});
  final PlaybackController controller;
  @override
  State<_ThinProgress> createState() => _ThinProgressState();
}

class _ThinProgressState extends State<_ThinProgress> {
  double? dragging;
  bool hover = false;

  void _seekTo(double fraction) {
    final total = widget.controller.engine.duration.value;
    if (total <= Duration.zero) return;
    unawaited(widget.controller.seek(total * fraction.clamp(0.0, 1.0)));
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.controller.engine;
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
        final shown = total * progress;
        final timeStyle = TextStyle(
          fontSize: 9.5,
          height: 1,
          color: DymuseTokens.secondary(context),
          fontFeatures: const [FontFeature.tabularFigures()],
        );
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
          child: MouseRegion(
            onEnter: (_) => setState(() => hover = true),
            onExit: (_) => setState(() => hover = false),
            child: SizedBox(
              height: 12,
              child: Row(
                children: [
                  SizedBox(
                    width: 30,
                    child: hover && total > Duration.zero
                        ? Text(timeLabel(shown), style: timeStyle)
                        : null,
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        double at(Offset local) =>
                            (local.dx / constraints.maxWidth).clamp(0.0, 1.0);
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (details) =>
                              _seekTo(at(details.localPosition)),
                          onHorizontalDragStart: (details) => setState(
                            () => dragging = at(details.localPosition),
                          ),
                          onHorizontalDragUpdate: (details) => setState(
                            () => dragging = at(details.localPosition),
                          ),
                          onHorizontalDragEnd: (_) {
                            final target = dragging;
                            setState(() => dragging = null);
                            if (target != null) _seekTo(target);
                          },
                          child: Center(
                            child: _Track(
                              value: progress,
                              height: hover || dragging != null ? 5 : 3,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  SizedBox(
                    width: 34,
                    child: hover && total > Duration.zero
                        ? Text(
                            '-${timeLabel(total - shown)}',
                            textAlign: TextAlign.end,
                            style: timeStyle,
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 细轨道：底色为分隔线色，已播放部分从左侧起以强调色填充。
class _Track extends StatelessWidget {
  const _Track({required this.value, required this.height});
  final double value, height;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(height / 2),
    child: SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: DymuseTokens.line(context)),
          FractionallySizedBox(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: value.clamp(0.0, 1.0),
            child: ColoredBox(color: DymuseTokens.tint(context)),
          ),
        ],
      ),
    ),
  );
}

/// 音量细滑条：与进度条同一外观，点击或拖动设置。
class _ThinSlider extends StatelessWidget {
  const _ThinSlider({required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      void set(Offset local) =>
          onChanged((local.dx / constraints.maxWidth).clamp(0.0, 1.0));
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => set(details.localPosition),
        onHorizontalDragUpdate: (details) => set(details.localPosition),
        child: SizedBox(
          height: 24,
          child: Center(child: _Track(value: value, height: 4)),
        ),
      );
    },
  );
}

/// “音乐”式待播清单：向上为历史，中间为正在播放，下方为接下来播放。
/// 单击选中、双击播放，Delete 移除选中项；“清除”只清空接下来播放。
class _MacQueue extends StatefulWidget {
  const _MacQueue({required this.controller, required this.onClose});
  final PlaybackController controller;
  final VoidCallback onClose;
  @override
  State<_MacQueue> createState() => _MacQueueState();
}

class _MacQueueState extends State<_MacQueue> {
  static const _row = 52.0, _header = 34.0;
  late final scroll = ScrollController(
    initialScrollOffset: _offsetOf(widget.controller.index),
  );
  final focus = FocusNode();
  int? selected;
  DateTime? _lastTap;
  int? _lastIndex;

  PlaybackController get controller => widget.controller;

  /// 历史标题 + 历史行 + 正在播放标题：初始停在“正在播放”。
  double _offsetOf(int index) => index > 0 ? _header + index * _row : 0;

  @override
  void dispose() {
    scroll.dispose();
    focus.dispose();
    super.dispose();
  }

  void _tap(int index) {
    focus.requestFocus();
    final now = DateTime.now();
    final double =
        _lastIndex == index &&
        _lastTap != null &&
        now.difference(_lastTap!) <= kDoubleTapTimeout;
    _lastTap = double ? null : now;
    _lastIndex = index;
    setState(() => selected = index);
    if (double && controller.items[index]['unavailable'] != true) {
      controller.select(index);
    }
  }

  void _remove(int index) {
    if (index == controller.index) return;
    setState(() => selected = null);
    controller.removeAt(index);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final items = controller.items, current = controller.index;
      final upcoming = items.length - current - 1;
      final children = <Widget>[
        if (current > 0) ...[
          const _QueueHeader('历史记录'),
          for (var i = 0; i < current; i++)
            _queueRow(context, i, history: true),
        ],
        if (items.isNotEmpty) ...[
          const _QueueHeader('正在播放'),
          _queueRow(context, current),
        ],
        if (upcoming > 0) ...[
          _QueueHeader(
            '接下来播放',
            action: ActionButton(
              label: '清除接下来播放',
              compact: true,
              onPressed: () {
                setState(() => selected = null);
                controller.clearUpcoming();
              },
              child: const Text('清除'),
            ),
          ),
          for (var i = current + 1; i < items.length; i++)
            _queueRow(context, i),
        ],
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 8, 0),
            child: Row(
              children: [
                const Expanded(child: Text('待播清单', style: DymuseTokens.title)),
                ActionButton(
                  label: '关闭待播清单',
                  icon: CupertinoIcons.xmark,
                  compact: true,
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
            child: Text(
              '${items.length} 首',
              style: DymuseTokens.caption.copyWith(
                color: DymuseTokens.secondary(context),
              ),
            ),
          ),
          if (controller.state['origin'] == 'podcast' &&
              controller.state['nextOffset'] != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: ActionButton(
                label: '载入后续节目',
                icon: CupertinoIcons.arrow_clockwise,
                onPressed: controller.extending
                    ? null
                    : controller.morePodcasts,
              ),
            ),
          Expanded(
            child: items.isEmpty
                ? const StatusMessage(
                    title: '队列为空',
                    message: '先播放一首歌曲，才能使用待播清单。',
                  )
                : Focus(
                    focusNode: focus,
                    onKeyEvent: (_, event) {
                      final key = event.logicalKey;
                      if (event is KeyDownEvent &&
                          selected != null &&
                          (key == LogicalKeyboardKey.backspace ||
                              key == LogicalKeyboardKey.delete)) {
                        _remove(selected!);
                        return KeyEventResult.handled;
                      }
                      if (event is KeyDownEvent &&
                          selected != null &&
                          key == LogicalKeyboardKey.enter) {
                        controller.select(selected!);
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: ListView(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                      children: children,
                    ),
                  ),
          ),
        ],
      );
    },
  );

  Widget _queueRow(BuildContext context, int i, {bool history = false}) {
    final item = controller.items[i];
    final track = controller.catalog.cached(
      controller.mode,
      item['id'].toString(),
      isPodcast: item['kind'] == 'podcast',
    );
    return _QueueRow(
      key: ValueKey('queue:$i:${item['id']}'),
      controller: controller,
      track: track,
      title: track?.title ?? item['title']?.toString() ?? '歌曲 ${item['id']}',
      current: i == controller.index,
      history: history,
      selected: selected == i,
      unavailable: item['unavailable'] == true,
      height: _row,
      onTap: () => _tap(i),
      onRemove: i == controller.index ? null : () => _remove(i),
    );
  }
}

class _QueueHeader extends StatelessWidget {
  const _QueueHeader(this.label, {this.action});
  final String label;
  final Widget? action;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 34,
    child: Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: DymuseTokens.secondary(context),
                ),
              ),
            ),
          ),
          ?action,
        ],
      ),
    ),
  );
}

class _QueueRow extends StatefulWidget {
  const _QueueRow({
    super.key,
    required this.controller,
    required this.track,
    required this.title,
    required this.current,
    required this.history,
    required this.selected,
    required this.unavailable,
    required this.height,
    required this.onTap,
    required this.onRemove,
  });
  final PlaybackController controller;
  final Track? track;
  final String title;
  final bool current, history, selected, unavailable;
  final double height;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final dark = DymuseTokens.dark(context);
    final dim = widget.history || widget.unavailable;
    final track = widget.track;
    return Semantics(
      button: true,
      selected: widget.selected,
      label:
          '${widget.title}${track == null ? '' : '，${track.artist}'}${widget.current ? '，正在播放' : ''}',
      onTap: widget.unavailable ? null : widget.onTap,
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            height: widget.height,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: widget.selected
                  ? (dark ? const Color(0x24FFFFFF) : const Color(0x14000000))
                  : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Opacity(
              opacity: dim ? .55 : 1,
              child: Row(
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      RemoteArtwork(
                        api: widget.controller.api,
                        url: track?.cover,
                        seed: track?.album ?? widget.title,
                        size: 38,
                        radius: 5,
                      ),
                      if (widget.current)
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: const Color(0x66000000),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: const Icon(
                            CupertinoIcons.speaker_2_fill,
                            size: 15,
                            color: CupertinoColors.white,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: widget.current
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: widget.current
                                ? DymuseTokens.tint(context)
                                : DymuseTokens.ink(context),
                          ),
                        ),
                        if (track != null && track.artist.isNotEmpty)
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: DymuseTokens.caption.copyWith(
                              color: DymuseTokens.secondary(context),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (hover && widget.onRemove != null)
                    ActionButton(
                      label: '从待播清单移除 ${widget.title}',
                      icon: CupertinoIcons.minus_circle,
                      compact: true,
                      onPressed: widget.onRemove,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
