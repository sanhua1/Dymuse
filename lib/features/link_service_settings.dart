import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';
import '../link_service/link_service.dart';

/// 设置页里的“取链服务”：添加自己部署的服务（网址、账号、密码），显示当前使用的会员账号。
class LinkServicePanel extends StatelessWidget {
  const LinkServicePanel({super.key, required this.service});
  final LinkService service;

  static String _ago(String? iso) {
    final time = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (time == null) return '';
    final seconds = DateTime.now().difference(time).inSeconds;
    if (seconds < 3600) return '${(seconds ~/ 60).clamp(1, 59)} 分钟前';
    if (seconds < 86400) return '${seconds ~/ 3600} 小时前';
    return '${seconds ~/ 86400} 天前';
  }

  Future<void> _remove(BuildContext context) async {
    final sure = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: const Text('移除取链服务？'),
        content: const Text('之后取歌曲链接用你自己登录的网易云账号。服务里的数据不受影响。'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (sure == true) await service.clear();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      final secondary = DymuseTokens.secondary(context);
      final caption = DymuseTokens.caption.copyWith(
        color: secondary,
        height: 1.6,
      );
      Widget form(String label) => PanelButton(
        label: label,
        onPressed: () =>
            showFormSheet<void>(context, _LinkServiceForm(service: service)),
      );
      if (!service.configured) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '和家人朋友共用一个会员账号取歌曲链接：添加你自己部署的取链服务（网址、账号、密码），'
              '播放时就会用服务里的会员账号取链接。不添加则用你自己登录的账号。部署方法见项目 README。',
              style: caption,
            ),
            const SizedBox(height: 12),
            form('添加取链服务'),
          ],
        );
      }
      final host = Uri.tryParse(service.url)?.host ?? service.url;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text('使用取链服务', style: DymuseTokens.body)),
              CupertinoSwitch(
                value: service.enabled,
                onChanged: (value) => unawaited(service.setEnabled(value)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (!service.enabled)
            Text('已关闭：播放时用你自己登录的网易云账号取歌曲链接。打开开关即可恢复使用「$host」。', style: caption)
          else ...[
            Text(
              !service.ready
                  ? '尚未获取会员账号'
                  : service.nickname.isEmpty
                  ? '会员账号（服务未核对昵称）'
                  : '${service.nickname} · ${LinkService.vipLabel(service.vipType)}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              service.busy
                  ? '正在获取…'
                  : '$host${service.updatedAt == null ? '' : ' · 账号更新于 ${_ago(service.updatedAt)}'}',
              style: caption,
            ),
            if (service.error != null) ...[
              const SizedBox(height: 6),
              Text(
                service.error!,
                style: const TextStyle(
                  fontSize: 12,
                  color: CupertinoColors.systemRed,
                ),
              ),
            ],
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              if (service.enabled)
                PanelButton(
                  label: '立即刷新',
                  onPressed: service.busy
                      ? null
                      : () => unawaited(service.refresh()),
                ),
              form('修改'),
              PanelButton(label: '移除', onPressed: () => _remove(context)),
            ],
          ),
          if (service.enabled) ...[
            const SizedBox(height: 12),
            Text(
              '播放时用这个账号取歌曲链接（会员歌曲、无损音质）；红心、歌单、推荐等仍是你自己登录的账号。'
              '账号每 6 小时自动更新，也可以手动刷新。',
              style: caption,
            ),
          ],
        ],
      );
    },
  );
}

class _LinkServiceForm extends StatefulWidget {
  const _LinkServiceForm({required this.service});
  final LinkService service;
  @override
  State<_LinkServiceForm> createState() => _LinkServiceFormState();
}

class _LinkServiceFormState extends State<_LinkServiceForm> {
  late final url = TextEditingController(text: widget.service.url);
  late final user = TextEditingController(text: widget.service.username);
  late final password = TextEditingController(text: widget.service.password);
  bool busy = false;
  String? error;

  @override
  void dispose() {
    for (final c in [url, user, password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    final address = LinkService.normalizeUrl(url.text);
    if (address == null || address.isEmpty) {
      setState(() => error = '请填写服务地址，应以 https:// 开头。');
      return;
    }
    if (user.text.trim().isEmpty || password.text.isEmpty) {
      setState(() => error = '请填写账号和密码。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    await widget.service.configure(
      url: address,
      username: user.text.trim(),
      password: password.text,
    );
    if (!mounted) return;
    if (widget.service.error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        busy = false;
        error = widget.service.error;
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
                    onPressed: busy ? null : () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const Expanded(
                    child: Text(
                      '取链服务',
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
                    child: busy
                        ? const CupertinoActivityIndicator()
                        : const Text(
                            '保存',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              field(
                url,
                '服务地址',
                'https://link.example.com',
                type: TextInputType.url,
              ),
              field(user, '账号', '首次打开服务网页时设置的账号'),
              field(password, '密码', '', secret: true),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    error!,
                    style: const TextStyle(
                      fontSize: 13,
                      color: CupertinoColors.systemRed,
                    ),
                  ),
                ),
              Text(
                '保存后会立刻连接服务验证。账号和密码只保存在本机的安全存储里。',
                style: TextStyle(fontSize: 12, color: secondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
