import 'dart:async';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/cupertino.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import 'package:flutter/services.dart';
import '../core/api_client.dart';
import '../core/diag.dart';
import '../core/media_cache.dart';
import '../core/session.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';
import '../playback/audio_quality.dart';
import '../platform/desktop_window.dart';
import '../update/update_panel.dart';
import '../playback/playback_controller.dart';
import 'accent_picker.dart';
import 'bilibili_account.dart';
import 'link_service_settings.dart';
import 'sync_settings.dart';
import 'title_rules_panel.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.session,
    required this.appearance,
    required this.playback,
    this.window,
    this.topInset = 0,
  });

  /// 顶部为悬浮栏让出的高度（手机上的设置 Sheet 用）。
  final double topInset;
  final DesktopWindow? window;
  final Session session;
  final Appearance appearance;
  final PlaybackController playback;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final Map<CacheGroup, int> usage = {};
  MediaCache? get cache => widget.session.api.cache;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    refreshUsage();
  }

  Future<void> refreshUsage() async {
    final store = cache;
    if (store == null) return;
    for (final group in CacheGroup.values) {
      final bytes = await store.usage(group);
      if (mounted) setState(() => usage[group] = bytes);
    }
  }

  Future<void> signOut() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.session.logout();
    } catch (e) {
      if (mounted) setState(() => error = readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  static String _accountInfo(bool guest) => guest
      ? '没有登录网易云账号。请登录网易云账号之后使用红心、我的歌单等功能。\n\n'
            '歌曲、歌单、推荐和播放都直接连接网易云，不经过任何中转服务器。'
      : '登录只保存在这台设备。\n\n'
            '歌曲、歌单、推荐和播放都直接连接网易云，不经过任何中转服务器。';

  static String _vipLabel(int type) => switch (type) {
    0 => '非会员',
    10 => '音乐包',
    11 => '黑胶 VIP',
    12 => '黑胶 SVIP',
    _ => '会员',
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.appearance,
    builder: (_, _) {
      final appearance = widget.appearance;
      final session = widget.session;
      final name = session.username.isEmpty ? '网易云账号' : session.username;
      final pages = <List<Widget>>[
        [
          if (session.updates != null)
            _section('软件更新', [UpdatePanel(service: session.updates!)]),
          _section('外观', [
            _setting(
              '配色',
              CupertinoSlidingSegmentedControl<String>(
                groupValue: appearance.brightness?.name ?? 'system',
                children: const {
                  'system': Text('跟随系统'),
                  'light': Text('浅色'),
                  'dark': Text('深色'),
                },
                onValueChanged: (value) {
                  if (value != null) {
                    appearance.update(
                      system: value == 'system',
                      brightness: value == 'dark'
                          ? Brightness.dark
                          : Brightness.light,
                    );
                  }
                },
              ),
            ),
            const SizedBox(height: 18),
            _setting('主题色', _AccentPicker(appearance: appearance)),
            // Android 本来就没有背后模糊（为了流畅），这一项只对有完整玻璃的平台有意义。
            if (!DymuseTokens.android) ...[
              const SizedBox(height: 18),
              Row(
                children: [
                  const Text('玻璃效果', style: DymuseTokens.body),
                  const InfoButton(
                    title: '玻璃效果',
                    text:
                        '拖到最左是最强的液态玻璃（折射、高光明显），拖到最右是磨砂（模糊更强、底色更实，文字更清楚），中间可自己调。'
                        '作用于面板、迷你播放器、弹出菜单和底部标签栏。系统开启“提高对比度”时，玻璃会改成不透明底色。',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 单独成行占满宽度：放进 _setting 的横排里滑块拿不到宽度（桌面端会挤成一团）。
              Row(
                children: [
                  Text('液态', style: DymuseTokens.caption),
                  const SizedBox(width: 8),
                  Expanded(
                    child: glass.GlassSlider(
                      value: appearance.glassFrost,
                      useOwnLayer: true,
                      quality: DymuseTokens.glassQuality,
                      onChanged: appearance.setGlassFrost,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('磨砂', style: DymuseTokens.caption),
                ],
              ),
            ],
            if (DymuseTokens.mobile) ...[
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: const [
                        Text('迷你播放器显示进度条', style: DymuseTokens.body),
                        InfoButton(
                          title: '迷你播放器显示进度条',
                          text: '在底部小播放窗口里显示可拖动的播放进度。',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  CupertinoSwitch(
                    value: appearance.miniProgress,
                    onChanged: (value) {
                      appearance.setMiniProgress(value);
                      unawaited(
                        widget.session.preferences.setBool(
                          'miniProgress',
                          value,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                const Expanded(
                  child: Row(
                    children: [
                      Text('播放页背景漂移', style: DymuseTokens.body),
                      InfoButton(
                        title: '播放页背景漂移',
                        text:
                            '播放页的背景由封面的颜色生成。打开后，歌曲播放时色块会缓慢漂移（约每秒 15 帧，暂停时静止）；'
                            '关闭后背景完全静止，颜色加载出来就不再刷新，更省电。\n\n'
                            '系统开启“减弱动态效果”时，无论此开关如何都不会漂移。',
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                CupertinoSwitch(
                  value: appearance.backdropDrift,
                  onChanged: (value) {
                    appearance.setBackdropDrift(value);
                    unawaited(
                      widget.session.preferences.setBool(
                        'backdropDrift',
                        value,
                      ),
                    );
                  },
                ),
              ],
            ),
          ]),
          if (DymuseTokens.macOS && widget.window != null)
            _section(
              '窗口',
              [
                _setting(
                  '关闭窗口后只在菜单栏显示',
                  CupertinoSwitch(
                    value: widget.window!.menuBarMode,
                    onChanged: (value) {
                      widget.window!.menuBarMode = value;
                      unawaited(
                        widget.session.preferences.setBool(
                          'menuBarMode',
                          value,
                        ),
                      );
                      setState(() {});
                    },
                  ),
                ),
              ],
              info:
                  '开启后，按 ⌘W 或点红色按钮关闭窗口时，程序坞图标会隐藏，只在屏幕顶部菜单栏留下一个图标，音乐继续播放。'
                  '点菜单栏图标重新打开窗口；右键图标可选择退出。',
            ),
          if (session.sync != null)
            _section(
              'WebDAV 同步',
              info:
                  '把登录凭证、取链服务配置、B 站红心/歌单/订阅和播放进度同步到你自己的 WebDAV 空间，在多台设备之间保持一致。\n\n'
                  '登录凭证用同步密码加密后才会上传；红心、歌单、订阅与播放进度以明文 JSON 存放。各设备的改动逐条合并，删除也会同步。',
              [SyncPanel(sync: session.sync!)],
            ),
          if (cache != null)
            _section(
              '缓存',
              [
                for (final group in CacheGroup.values)
                  if (group != CacheGroup.audio || cache!.audioEnabled) ...[
                    _setting(
                      '${group.label}（已用 ${usage[group] == null ? '…' : formatBytes(usage[group]!)}）',
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CupertinoButton(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(44, 44),
                            onPressed: () => chooseLimit(group),
                            child: Text(
                              '上限 ${limitLabel(cache!.limitMb(group))}',
                            ),
                          ),
                          CupertinoButton(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(44, 44),
                            onPressed: () async {
                              await cache!.clear(group);
                              await refreshUsage();
                            },
                            child: const Text('清除'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
              ],
              info:
                  '超过上限时自动删除最久没用的缓存。歌曲缓存让听过的歌再次播放时不用重新下载；封面与请求缓存让页面打开时先显示上次的内容。',
            ),
          _section('诊断日志', [
            _DiagLogRow(),
          ], info: '记录播放、取链、缓冲、被系统打断等事件，不含账号和令牌；遇到问题后点“复制日志”发给开发者即可。'),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  error!,
                  style: TextStyle(color: DymuseTokens.tint(context)),
                ),
              ),
            ),
        ],
        [
          _section('网易云账号', info: _accountInfo(session.guest), [
            if (session.guest)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Artwork(url: null, size: 44, seed: name, radius: 22),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Text(
                          '游客',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  PanelButton(
                    label: '登录网易云账号',
                    prominent: true,
                    onPressed: session.startLogin,
                  ),
                ],
              )
            else
              Row(
                children: [
                  Artwork(
                    url: session.avatarUrl.isEmpty ? null : session.avatarUrl,
                    size: 50,
                    seed: name,
                    radius: 25,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _vipLabel(session.vipType),
                          style: DymuseTokens.caption.copyWith(
                            color: DymuseTokens.secondary(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  PanelButton(label: '退出登录', onPressed: busy ? null : signOut),
                ],
              ),
          ]),
          if (session.linkService != null)
            _section(
              '取链服务',
              info:
                  '和家人朋友共用一个会员账号取歌曲链接：添加你自己部署的取链服务（网址、账号、密码），'
                  '播放时就会用服务里的会员账号取链接。不添加则用你自己登录的账号。部署方法见项目 README。\n\n'
                  '添加后，播放时用服务里的账号取歌曲链接（会员歌曲、无损音质）；红心、歌单、推荐等仍是你自己登录的账号。'
                  '账号每 6 小时自动更新，也可以手动刷新。',
              [LinkServicePanel(service: session.linkService!)],
            ),
          _section(
            '网易云音质',
            [
              for (final quality in AudioQuality.values.reversed)
                _qualityRow(quality),
            ],
            info:
                '只作用于网易云歌曲，B 站歌曲不受影响。所选档位不存在时自动降到这首歌可用的最高档；无损与 Hi-Res 需要会员，账号没有权限时由网易云降级。',
          ),
        ],
        [
          _section(
            'B 站账号',
            info: '登录后可使用你账号里的收藏夹，并可能取得更高音质的音频。不登录也能搜索、订阅与播放。',
            [BilibiliAccountPanel(api: session.api, session: session)],
          ),
          _section(
            'B 站歌名正则',
            [TitleRulesPanel(session: session)],
            info:
                'B 站视频标题里常带有【】、序号、宣传语，真正的歌名藏在里面。'
                'Dymuse 内置了一批正则规则，会从视频标题里识别出歌名；关闭则显示原标题。\n\n'
                '“订阅内正则”作用于订阅、红心和歌单，默认开启；“搜索结果正则”作用于全 B 站搜索结果，默认关闭。\n\n'
                '自定义规则优先于内置规则。在列表的“···”菜单里随时可以查看原视频名。',
          ),
        ],
      ];
      return _paged(pages);
    },
  );

  final _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// 三页：通用、网易云、B 站。顶部是固定的玻璃分段控件，左右滑动或点分段都能切换。
  Widget _paged(List<List<Widget>> pages) {
    final bottom = 32 + MediaQuery.paddingOf(context).bottom;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(32, 32 + widget.topInset, 32, 0),
          child: const Text('设置', style: DymuseTokens.heading),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 16, 32, 12),
          child: glass.GlassSegmentedControl(
            segments: const [
              glass.GlassSegment(label: '通用'),
              glass.GlassSegment(label: '网易云'),
              glass.GlassSegment(label: 'B 站'),
            ],
            selectedIndex: _page,
            useOwnLayer: true,
            quality: DymuseTokens.glassQuality,
            onSegmentSelected: (index) {
              setState(() => _page = index);
              unawaited(
                _pages.animateToPage(
                  index,
                  duration: DymuseTokens.motion,
                  curve: Curves.easeOutCubic,
                ),
              );
            },
          ),
        ),
        Expanded(
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: {
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.trackpad,
              },
            ),
            child: PageView(
              controller: _pages,
              onPageChanged: (index) => setState(() => _page = index),
              children: [
                for (final children in pages)
                  _KeepAlive(
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(32, 12, 32, bottom),
                      children: children,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _qualityRow(AudioQuality quality) {
    final selected = widget.playback.quality == quality;
    return Semantics(
      button: true,
      selected: selected,
      label: '音质 ${quality.label}，${quality.hint}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          widget.playback.setQuality(quality);
          unawaited(
            widget.session.preferences.setString('audioQuality', quality.name),
          );
          setState(() {});
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text(quality.label, style: DymuseTokens.body)],
                ),
              ),
              if (selected)
                Icon(
                  CupertinoIcons.checkmark,
                  color: DymuseTokens.tint(context),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String limitLabel(int mb) =>
      mb >= 1024 ? '${(mb / 1024).toStringAsFixed(0)} GB' : '$mb MB';

  Future<void> chooseLimit(CacheGroup group) async {
    final picked = await showChoiceSheet<int>(
      context,
      title: '${group.label}上限',
      choices: [for (final mb in MediaCache.limitChoices) (limitLabel(mb), mb)],
      current: cache!.limitMb(group),
    );
    if (picked == null) return;
    await cache!.setLimit(group, picked);
    await refreshUsage();
  }

  Widget _section(String title, List<Widget> children, {String? info}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (info != null) InfoButton(title: title, text: info),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: DymuseTokens.surface(context),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
          ],
        ),
      );
  Widget _setting(String label, Widget control) => LayoutBuilder(
    builder: (_, constraints) => constraints.maxWidth < 460
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: DymuseTokens.body),
              const SizedBox(height: 8),
              control,
            ],
          )
        : Row(
            children: [
              Expanded(child: Text(label, style: DymuseTokens.body)),
              control,
            ],
          ),
  );
}

/// 主题色色块：选中的带描边和对勾；每个色块有独立的无障碍标签。
class _AccentPicker extends StatelessWidget {
  const _AccentPicker({required this.appearance});
  final Appearance appearance;
  @override
  Widget build(BuildContext context) {
    final dark = DymuseTokens.dark(context);
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final color in AccentColor.values)
          Semantics(
            button: true,
            selected: appearance.custom == null && color == appearance.accent,
            label: '主题色 ${color.label}',
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => appearance.update(accent: color),
              child: SizedBox.square(
                dimension: 36,
                child: Center(
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: dark ? color.dark : color.light,
                      shape: BoxShape.circle,
                      border:
                          appearance.custom == null &&
                              color == appearance.accent
                          ? Border.all(
                              color: DymuseTokens.ink(context),
                              width: 2,
                            )
                          : null,
                    ),
                    child:
                        appearance.custom == null && color == appearance.accent
                        ? Icon(
                            CupertinoIcons.checkmark,
                            size: 14,
                            color: dark
                                ? const Color(0xFF18171B)
                                : const Color(0xFFFFFFFF),
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ),
        Semantics(
          button: true,
          selected: appearance.custom != null,
          label: '自定义主题色',
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => showFormSheet<void>(
              context,
              AccentPickerSheet(appearance: appearance),
            ),
            child: SizedBox.square(
              dimension: 36,
              child: Center(
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: appearance.custom == null
                        ? const SweepGradient(
                            colors: [
                              Color(0xFFFF5252),
                              Color(0xFFFFD740),
                              Color(0xFF69F0AE),
                              Color(0xFF40C4FF),
                              Color(0xFFB388FF),
                              Color(0xFFFF5252),
                            ],
                          )
                        : null,
                    color: appearance.custom == null
                        ? null
                        : (dark
                              ? appearance.accentDark
                              : appearance.accentLight),
                    border: appearance.custom != null
                        ? Border.all(color: DymuseTokens.ink(context), width: 2)
                        : null,
                  ),
                  child: appearance.custom != null
                      ? Icon(
                          CupertinoIcons.checkmark,
                          size: 14,
                          color: dark
                              ? const Color(0xFF18171B)
                              : const Color(0xFFFFFFFF),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 设置里的“复制诊断日志”：把日志文本放进剪贴板。
class _DiagLogRow extends StatefulWidget {
  @override
  State<_DiagLogRow> createState() => _DiagLogRowState();
}

class _DiagLogRowState extends State<_DiagLogRow> {
  String? _note;

  Future<void> _copy() async {
    final text = await Diag.readAll();
    if (text.isEmpty) {
      setState(() => _note = '还没有日志。');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      setState(() => _note = '已复制 ${(text.length / 1024).ceil()} KB。');
    }
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      PanelButton(label: '复制日志', onPressed: _copy),
      if (_note != null) ...[
        const SizedBox(width: 12),
        Text(_note!, style: DymuseTokens.caption),
      ],
    ],
  );
}

/// 切页时保留每一页的状态（滚动位置、已加载的账号信息）。
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});
  final Widget child;
  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
