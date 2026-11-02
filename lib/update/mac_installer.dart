import 'dart:io';

/// macOS 的半自动更新：应用在沙盒里不能改写自己的 .app，所以只做到下载并校验（SHA-256）安装盘，
/// 再用系统打开它——弹出常见的安装窗口（Dymuse 与「应用程序」快捷方式），由用户拖过去替换；点“好”后应用自动退出（SystemNavigator.pop）。
Future<void> prepareMacUpdate(File dmg) async {
  final result = await Process.run('/usr/bin/open', [dmg.path]);
  if (result.exitCode != 0) {
    throw StateError('无法打开安装盘：${result.stderr}'.trim());
  }
}
