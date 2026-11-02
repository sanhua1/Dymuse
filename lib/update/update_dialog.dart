import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:url_launcher/url_launcher.dart';
import '../design_system/tokens.dart';
import 'update_service.dart';
import 'windows_installer.dart';

/// 启动或手动检查更新。有新版本弹出提示；[manual] 时没有更新或失败也会说明。
/// 自动检查遇到被“忽略”的版本、或任何网络问题，都悄悄跳过。
Future<void> checkForUpdates(
  NavigatorState navigator,
  UpdateService service, {
  bool manual = false,
}) async {
  UpdateInfo? info;
  try {
    info = await service.check();
  } catch (error) {
    if (manual && navigator.mounted) {
      await _notice(navigator, '检查更新失败', '$error');
    }
    return;
  }
  if (!navigator.mounted) return;
  if (info == null) {
    if (manual) await _notice(navigator, '已是最新版本', '当前版本 $appVersion。');
    return;
  }
  if (!manual && service.ignoredVersion == info.version) return;
  await _showUpdate(navigator, service, info);
}

Future<void> _notice(NavigatorState navigator, String title, String text) =>
    navigator.push<void>(
      CupertinoDialogRoute<void>(
        context: navigator.context,
        builder: (dialog) => CupertinoAlertDialog(
          title: Text(title),
          content: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(text),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('好'),
            ),
          ],
        ),
      ),
    );

Future<void> _showUpdate(
  NavigatorState navigator,
  UpdateService service,
  UpdateInfo info,
) => navigator.push<void>(
  CupertinoDialogRoute<void>(
    context: navigator.context,
    barrierDismissible: false,
    builder: (dialog) => _UpdateDialog(service: service, info: info),
  ),
);

enum _Phase { offer, working, failed }

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.service, required this.info});
  final UpdateService service;
  final UpdateInfo info;
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  _Phase _phase = _Phase.offer;
  String _status = '';
  double? _progress;
  String? _error;

  UpdateInfo get _info => widget.info;

  @override
  void initState() {
    super.initState();
    // 联调用：编译时带 --dart-define=DYMUSE_UPDATE_AUTOINSTALL=true 才会自动点“更新”，正式包为 false。
    if (const bool.fromEnvironment('DYMUSE_UPDATE_AUTOINSTALL')) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_update()));
    }
  }

  Future<void> _update() async {
    final service = widget.service;
    if (!service.canInstall) {
      // 其他平台暂时交给浏览器下载（Android 应用内安装之后再做）。
      final url = _info.downloadUrls.isEmpty ? null : _info.downloadUrls.first;
      if (url != null) {
        unawaited(
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        );
      }
      if (mounted) Navigator.pop(context);
      return;
    }
    setState(() {
      _phase = _Phase.working;
      _status = '正在下载…';
      _progress = 0;
      _error = null;
    });
    try {
      final file = await service.download(
        _info,
        onProgress: (got, total) {
          if (!mounted) return;
          setState(() {
            _progress = total > 0 ? got / total : null;
            _status = total > 0
                ? '正在下载… ${(got / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB'
                : '正在下载…';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _status = '校验通过，正在更新并重启…';
        _progress = null;
      });
      await startWindowsUpdate(file);
      await service.quit?.call();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final secondary = DymuseTokens.secondary(context);
    // iOS 只提示，不提供下载。
    final hasPackage = _info.asset != null && !Platform.isIOS;
    final Widget body = switch (_phase) {
      _Phase.working => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(
          children: [
            Text(_status, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 6,
                child: _progress == null
                    ? const CupertinoActivityIndicator()
                    : Stack(
                        children: [
                          ColoredBox(
                            color: secondary.withValues(alpha: .25),
                            child: const SizedBox.expand(),
                          ),
                          FractionallySizedBox(
                            widthFactor: _progress!.clamp(0.0, 1.0),
                            child: ColoredBox(
                              color: DymuseTokens.tint(context),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
      _Phase.failed => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          _error ?? '更新失败。',
          style: TextStyle(
            fontSize: 13,
            color: CupertinoColors.systemRed.resolveFrom(context),
          ),
        ),
      ),
      _Phase.offer => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: SingleChildScrollView(
            child: Text(
              _info.notes.isEmpty ? '修复问题并改进体验。' : _info.notes,
              textAlign: TextAlign.start,
              style: const TextStyle(fontSize: 13, height: 1.45),
            ),
          ),
        ),
      ),
    };
    final actions = switch (_phase) {
      _Phase.working => <Widget>[],
      _Phase.failed => [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: _update,
          child: const Text('重试'),
        ),
      ],
      // 没有本平台安装包（例如 iOS）只提示，不提供忽略与更新。
      _Phase.offer when !hasPackage => [
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
      _Phase.offer => [
        CupertinoDialogAction(
          onPressed: () {
            unawaited(widget.service.ignore(_info.version));
            Navigator.pop(context);
          },
          child: const Text('忽略此版本'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: _update,
          child: const Text('更新'),
        ),
      ],
    };
    return PopScope(
      canPop: _phase != _Phase.working,
      child: CupertinoAlertDialog(
        title: Text('发现新版本 ${_info.version}'),
        content: body,
        actions: actions,
      ),
    );
  }
}
