import 'dart:io';

/// macOS 的半自动更新：应用在沙盒里不能改写自己的 .app，所以只做到下载并校验（SHA-256）安装盘，
/// 再用系统打开它——弹出常见的安装窗口（Dymuse 与「应用程序」快捷方式），由用户拖过去替换；点“好”后应用自动退出（SystemNavigator.pop）。
Future<void> prepareMacUpdate(File dmg) async {
  final result = await Process.run('/usr/bin/open', [dmg.path]);
  if (result.exitCode != 0) {
    throw StateError('无法打开安装盘：${result.stderr}'.trim());
  }
}

/// 新版没有经过 Apple 公证，带隔离标记，首次打开可能被系统拦下；用户在终端里运行这条命令即可放行。
const macQuarantineFix =
    'xattr -dr com.apple.quarantine /Applications/Dymuse.app';

/// 下载并打开安装盘后的说明（应用随后退出，用户按这里的步骤替换并放行）。
const macInstallSteps =
    '新版已下载并校验，安装窗口已打开。点“好”后 Dymuse 会自动退出，'
    '请把新版 Dymuse 拖到「应用程序」上并选择“替换”，再重新打开。\n\n'
    '如果提示“无法打开”：到“系统设置 → 隐私与安全性”，拉到最下方，'
    '在 Dymuse 旁点“仍要打开”；或者先点“复制命令”，退出后打开“终端”粘贴运行，再打开 Dymuse。';
