import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../core/api_client.dart';
import '../core/media_cache.dart';
import '../core/session.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';
import '../playback/audio_quality.dart';
import '../playback/playback_controller.dart';
import 'accent_picker.dart';
import 'bilibili_account.dart';
import 'sync_settings.dart';
import 'title_rules_panel.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.session,
    required this.appearance,
    required this.playback,
  });
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
      return ListView(
        padding: EdgeInsets.fromLTRB(
          32,
          32,
          32,
          32 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          const Text('设置', style: DymuseTokens.heading),
          const SizedBox(height: 8),
          Text(
            '让音乐按你的方式呈现。',
            style: TextStyle(color: DymuseTokens.secondary(context)),
          ),
          const SizedBox(height: 28),
          _section('网易云账号', [
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
                        '${_vipLabel(session.vipType)} · 登录只保存在这台设备',
                        style: DymuseTokens.caption.copyWith(
                          color: DymuseTokens.secondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                ActionButton(label: '退出登录', onPressed: busy ? null : signOut),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '歌曲、歌单、推荐和播放都直接连接网易云，不经过任何中转服务器。',
              style: DymuseTokens.caption.copyWith(
                color: DymuseTokens.secondary(context),
                height: 1.6,
              ),
            ),
          ]),
          _section('B 站账号', [
            BilibiliAccountPanel(api: session.api, session: session),
          ]),
          _section(
            'B 站歌名正则',
            [TitleRulesPanel(session: session)],
            info:
                '很多 B 站视频标题带有【】、序号、夸张的宣传语，真正的歌名藏在里面。'
                '开启后显示识别出的歌名（默认取《》里的内容，并内置了一批常见 UP 主的规则）；关闭则显示原标题。\n\n'
                '“订阅内正则”作用于订阅、红心和歌单，默认开启；“搜索结果正则”作用于全 B 站搜索结果，默认关闭。\n\n'
                '自定义规则优先于内置规则。在列表的“···”菜单里随时可以查看原视频名。',
          ),
          if (session.sync != null)
            _section('WebDAV 同步', [SyncPanel(sync: session.sync!)]),
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
          ]),
          _section(
            '音质',
            [
              for (final quality in AudioQuality.values.reversed)
                _qualityRow(quality),
            ],
            info:
                '对所有歌曲生效。所选档位不存在时自动降到这首歌可用的最高档；无损与 Hi-Res 需要会员，账号没有权限时由网易云降级。',
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
      );
    },
  );
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
                  children: [
                    Text(quality.label, style: DymuseTokens.body),
                    Text(
                      quality.hint,
                      style: DymuseTokens.caption.copyWith(
                        color: DymuseTokens.secondary(context),
                      ),
                    ),
                  ],
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
    final picked = await showCupertinoModalPopup<int>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text('${group.label}上限'),
        actions: [
          for (final mb in MediaCache.limitChoices)
            CupertinoActionSheetAction(
              isDefaultAction: mb == cache!.limitMb(group),
              onPressed: () => Navigator.pop(sheet, mb),
              child: Text(limitLabel(mb)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          child: const Text('取消'),
        ),
      ),
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
                if (info != null)
                  Semantics(
                    button: true,
                    label: '$title 说明',
                    excludeSemantics: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => showCupertinoDialog<void>(
                        context: context,
                        barrierDismissible: true,
                        builder: (dialog) => CupertinoAlertDialog(
                          title: Text(title),
                          content: Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(info, textAlign: TextAlign.start),
                          ),
                          actions: [
                            CupertinoDialogAction(
                              onPressed: () => Navigator.pop(dialog),
                              child: const Text('好'),
                            ),
                          ],
                        ),
                      ),
                      child: SizedBox(
                        width: 36,
                        height: 28,
                        child: Center(
                          child: Icon(
                            CupertinoIcons.info_circle,
                            size: 16,
                            color: DymuseTokens.secondary(context),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
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
