import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../design_system/tokens.dart';
import 'android_installer.dart';
import 'update_service.dart';
import 'mac_installer.dart';
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

enum _Phase { offer, working, manual, failed }

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

  /// 已下载并校验好的安装包；Android 授权“安装未知应用”后重试时不必重新下载。
  File? _package;

  /// macOS：“复制命令”已点过（按钮改为“已复制”）。
  bool _copied = false;

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
      // 其余平台（iOS）交给浏览器下载。
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
      final file =
          _package ??
          await service.download(
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
      _package = file;
      if (!mounted) return;
      if (Platform.isAndroid) {
        final (result, detail) = await installAndroidApk(file);
        if (!mounted) return;
        switch (result) {
          case AndroidInstallResult.started:
            Navigator.pop(context);
          case AndroidInstallResult.needPermission:
            setState(() {
              _phase = _Phase.failed;
              _error = '请在刚打开的系统设置里允许 Dymuse 安装应用，然后返回这里点“重试”。';
            });
          case AndroidInstallResult.failed:
            setState(() {
              _phase = _Phase.failed;
              _error = detail.isEmpty ? '无法打开系统安装器。' : '无法打开系统安装器。\n$detail';
            });
        }
        return;
      }
      setState(() {
        _status = '校验通过，正在更新并重启…';
        _progress = null;
      });
      if (Platform.isMacOS) {
        await prepareMacUpdate(file);
        if (!mounted) return;
        setState(() {
          _phase = _Phase.manual;
          _error = macInstallSteps;
        });
        return;
      }
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

  /// iOS：选 Gitee 还是 GitHub，用浏览器打开对应的 Release 页面。
  Future<void> _chooseDownload() async {
    final sources = widget.service.sources;
    final picked = await showCupertinoModalPopup<UpdateSource>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: const Text('选择下载来源'),
        actions: [
          for (final source in sources)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(sheet, source),
              child: Text(source.name == 'Gitee' ? 'Gitee（国内推荐）' : source.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          child: const Text('取消'),
        ),
      ),
    );
    if (picked == null) return;
    unawaited(
      launchUrl(
        Uri.parse(picked.pageUrl(_info.tag)),
        mode: LaunchMode.externalApplication,
      ),
    );
    if (mounted) Navigator.pop(context);
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
      _Phase.manual => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          _error ?? '',
          style: const TextStyle(fontSize: 13, height: 1.45),
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
      _Phase.manual => [
        // 应用退出后就没法再复制，所以在退出前提供；点了不关闭提示。
        CupertinoDialogAction(
          onPressed: () async {
            await Clipboard.setData(
              const ClipboardData(text: macQuarantineFix),
            );
            if (mounted) setState(() => _copied = true);
          },
          child: Text(_copied ? '已复制' : '复制命令'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => SystemNavigator.pop(), // 真正退出（会先保存播放进度），Finder 才能替换
          child: const Text('好'),
        ),
      ],
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
      // 没有本平台安装包（例如 iOS）只提示，不提供忽略与更新；iOS 可以去网页自己下载。
      _Phase.offer when !hasPackage => [
        CupertinoDialogAction(
          isDefaultAction: !Platform.isIOS,
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
        if (Platform.isIOS)
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: _chooseDownload,
            child: const Text('去下载'),
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
