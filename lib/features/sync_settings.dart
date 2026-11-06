import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';
import '../sync/sync_service.dart';

/// 设置页里的“WebDAV 同步”。
class SyncPanel extends StatelessWidget {
  const SyncPanel({super.key, required this.sync});
  final SyncService sync;

  static String _ago(DateTime? time) {
    if (time == null) return '尚未同步';
    final seconds = DateTime.now().difference(time).inSeconds;
    if (seconds < 60) return '刚刚';
    if (seconds < 3600) return '${seconds ~/ 60} 分钟前';
    if (seconds < 86400) return '${seconds ~/ 3600} 小时前';
    return '${seconds ~/ 86400} 天前';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sync,
    builder: (context, _) {
      final secondary = DymuseTokens.secondary(context);
      final caption = DymuseTokens.caption.copyWith(
        color: secondary,
        height: 1.6,
      );
      final config = sync.config;
      if (config == null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PanelButton(
              label: '设置 WebDAV 同步',
              onPressed: () => showSyncForm(context, sync),
            ),
          ],
        );
      }
      final syncing = sync.state == SyncState.syncing;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            Uri.tryParse(config.url)?.host ?? config.url,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            syncing ? '正在同步…' : '上次同步：${_ago(sync.lastSync)}',
            style: caption,
          ),
          if (sync.error != null) ...[
            const SizedBox(height: 6),
            Text(
              sync.error!,
              style: const TextStyle(
                fontSize: 12,
                color: CupertinoColors.systemRed,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              PanelButton(
                label: '立即同步',
                icon: CupertinoIcons.arrow_2_circlepath,
                onPressed: syncing ? null : () => unawaited(sync.sync()),
              ),
              PanelButton(
                label: '修改设置',
                onPressed: () => showSyncForm(context, sync),
              ),
              PanelButton(
                label: '断开',
                onPressed: () async {
                  final sure = await showCupertinoDialog<bool>(
                    context: context,
                    builder: (context) => CupertinoAlertDialog(
                      title: const Text('断开 WebDAV 同步？'),
                      content: const Text('本机数据保留，WebDAV 上的数据也不会被删除。'),
                      actions: [
                        CupertinoDialogAction(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消'),
                        ),
                        CupertinoDialogAction(
                          isDestructiveAction: true,
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('断开'),
                        ),
                      ],
                    ),
                  );
                  if (sure == true) await sync.disconnect();
                },
              ),
            ],
          ),
        ],
      );
    },
  );
}

/// 填写 WebDAV 信息并立即同步一次；成功返回 true。
Future<bool> showSyncForm(BuildContext context, SyncService sync) async =>
    await showFormSheet<bool>(context, _SyncForm(sync: sync)) ?? false;

class _SyncForm extends StatefulWidget {
  const _SyncForm({required this.sync});
  final SyncService sync;
  @override
  State<_SyncForm> createState() => _SyncFormState();
}

class _SyncFormState extends State<_SyncForm> {
  late final url = TextEditingController(text: widget.sync.config?.url ?? '');
  late final user = TextEditingController(text: widget.sync.config?.user ?? '');
  late final password = TextEditingController(
    text: widget.sync.config?.password ?? '',
  );
  late final phrase = TextEditingController(
    text: widget.sync.config?.passphrase ?? '',
  );
  late final folder = TextEditingController(
    text: widget.sync.config?.folder ?? 'Dymuse',
  );
  bool busy = false;
  String? error;

  @override
  void dispose() {
    for (final c in [url, user, password, phrase, folder]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    if (url.text.trim().isEmpty || phrase.text.isEmpty) {
      setState(() => error = '请填写 WebDAV 地址和同步密码。');
      return;
    }
    final address = Uri.tryParse(url.text.trim());
    if (address == null || !address.hasScheme || address.host.isEmpty) {
      setState(() => error = 'WebDAV 地址应以 https:// 开头。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    await widget.sync.save(
      SyncConfig(
        url: url.text,
        user: user.text,
        password: password.text,
        passphrase: phrase.text,
        folder: folder.text,
      ),
    );
    final ok = await widget.sync.sync();
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        busy = false;
        error = widget.sync.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final secondary = CupertinoColors.secondaryLabel.resolveFrom(context);
    Widget field(
      TextEditingController c,
      String label,
      String hint, {
      bool secret = false,
      TextInputType? type,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: secondary)),
          const SizedBox(height: 6),
          CupertinoTextField(
            controller: c,
            placeholder: hint,
            enabled: !busy,
            obscureText: secret,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: type,
            padding: const EdgeInsets.all(12),
            style: const TextStyle(fontSize: 16),
            placeholderStyle: TextStyle(fontSize: 15, color: secondary),
          ),
        ],
      ),
    );
    return CupertinoPopupSurface(
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: busy
                        ? null
                        : () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  const Expanded(
                    child: Text(
                      'WebDAV 同步',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: busy ? null : submit,
                    child: const Text(
                      '同步',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              field(
                url,
                '服务器地址',
                'https://dav.example.com/dav',
                type: TextInputType.url,
              ),
              field(user, '用户名', '用户名'),
              field(password, '密码', '密码', secret: true),
              field(phrase, '同步密码（加密登录凭证）', '所有设备填同一个；忘记后只能重建', secret: true),
              field(folder, '远端文件夹', 'Dymuse'),
              if (busy) ...[
                const Center(child: CupertinoActivityIndicator()),
                const SizedBox(height: 6),
                Text(
                  '正在连接并同步…',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: secondary),
                ),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    error!,
                    style: const TextStyle(
                      fontSize: 13,
                      color: CupertinoColors.systemRed,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
