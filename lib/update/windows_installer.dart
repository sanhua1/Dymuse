import 'dart:io';

/// Windows 更新：静默运行新版安装包（Inno Setup，见 windows/installer/dymuse.iss），
/// 装到当前程序所在目录。默认目录是 C:\Program Files\Dymuse；早先解压 zip 使用的绿色版
/// 也会就地升级，此后同样出现在“应用和功能”里。
///
/// 安装包以普通权限启动，需要时自己申请管理员权限（系统会弹出 UAC 确认）；它会等本进程
/// 退出（还没退出就关掉），覆盖文件，再以原用户身份重新启动 Dymuse。用户数据在 AppData，
/// 不受影响。安装日志写在安装包旁边的 update.log。UAC 被拒绝时安装包直接退出，旧版不变，
/// 需要用户自己重新打开 Dymuse。
List<String> windowsSetupArguments(String installDir, String log) => [
  '/SILENT',
  '/SUPPRESSMSGBOXES',
  '/NORESTART',
  '/DIR=$installDir',
  '/LOG=$log',
];

/// 启动安装包；调用方随后应让应用退出。
Future<void> startWindowsUpdate(File setup) async {
  final installDir = File(Platform.resolvedExecutable).parent.path;
  await Process.start(
    setup.path,
    windowsSetupArguments(installDir, '${setup.parent.path}\\update.log'),
    // 安装包是图形程序，可以脱离本进程独立运行；本进程随后退出。
    mode: ProcessStartMode.detached,
  );
}
