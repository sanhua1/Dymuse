import 'dart:io';

import '../core/diag.dart';

/// macOS 版去掉了 App Sandbox（这样才能自己替换 .app 完成更新），数据位置随之改变：
/// 沙盒版在 `~/Library/Containers/<标识>/Data/Library/` 下，现在用 `~/Library/` 下的标准位置。
/// 设置由原生端在 Flutter 启动前合并（见 `MainFlutterWindow.swift` 的 `SandboxPreferences`）；
/// 这里只在新位置还没有缓存时，从沙盒容器复制磁盘缓存（APFS 上 `cp -c` 只复制引用，几乎不占空间）。
/// 只复制不删除，原容器保留。
/// 钥匙串不受影响：沙盒容器里的 Keychains 本来就链接到用户的登录钥匙串。
Future<void> migrateMacSandboxData() async {
  if (!Platform.isMacOS ||
      Platform.environment.containsKey('APP_SANDBOX_CONTAINER_ID')) {
    return;
  }
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return;
  const id = 'app.dymuse.allinone';
  final container = '$home/Library/Containers/$id/Data/Library';
  try {
    final cache = Directory('$container/Caches/$id/dymuse_cache');
    final target = Directory('$home/Library/Caches/$id/dymuse_cache');
    if (!target.existsSync() && cache.existsSync()) {
      target.parent.createSync(recursive: true);
      final result = await Process.run('/bin/cp', [
        '-Rc',
        cache.path,
        target.path,
      ]);
      Diag.log(
        'mac migrate cache exit=${result.exitCode} ${'${result.stderr}'.trim()}',
      );
    }
  } catch (error) {
    Diag.log('mac migrate failed: $error');
  }
}
