import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';
import 'update_dialog.dart';
import 'update_service.dart';

/// 设置页里的“软件更新”：当前版本、手动检查、下载源优先级。
class UpdatePanel extends StatefulWidget {
  const UpdatePanel({super.key, required this.service});
  final UpdateService service;
  @override
  State<UpdatePanel> createState() => _UpdatePanelState();
}

class _UpdatePanelState extends State<UpdatePanel> {
  bool _busy = false;

  Future<void> _check() async {
    final navigator = Navigator.of(context, rootNavigator: true);
    setState(() => _busy = true);
    try {
      await checkForUpdates(navigator, widget.service, manual: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.service,
    builder: (context, _) {
      final secondary = DymuseTokens.secondary(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '当前版本 $appVersion',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              PanelButton(
                label: _busy ? '检查中…' : '检查更新',
                onPressed: _busy ? null : () => unawaited(_check()),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  '优先从 GitHub 下载（默认 Gitee）',
                  style: TextStyle(fontSize: 13, color: secondary),
                ),
              ),
              CupertinoSwitch(
                value: widget.service.githubFirst,
                onChanged: (value) =>
                    unawaited(widget.service.setGithubFirst(value)),
              ),
            ],
          ),
        ],
      );
    },
  );
}
