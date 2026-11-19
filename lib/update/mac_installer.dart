import 'dart:io';

/// macOS 更新。应用不在沙盒中、所在目录可写时自动替换：先挂载安装盘，把新版复制到临时目录，
/// 校验签名（必须与当前应用的标识和 TeamIdentifier 一致），再启动一个独立脚本。
/// 脚本等本进程退出后，把旧版移到临时目录（不删除），把新版移到原位置并重新打开；
/// 新版移不过去时放回旧版。整个过程不需要管理员密码，因为 .app 属于当前用户。
/// 不满足条件时（旧的沙盒版、被系统随机转移、目录不可写）退回半自动：打开安装盘，由用户拖过去替换。

/// 不能自动替换的原因；返回 null 表示可以自动替换。
Future<String?> macAutoUpdateBlocker() async {
  if (Platform.environment.containsKey('APP_SANDBOX_CONTAINER_ID')) {
    return '应用在沙盒中运行';
  }
  final app = macAppBundle();
  if (app == null) return '找不到应用包';
  if (app.contains('/AppTranslocation/')) return '应用被系统随机转移';
  // 自行编译的临时签名版本没有 TeamIdentifier，无法确认新版来自同一开发者。
  if ((await _signer(app)).endsWith('/')) return '当前应用没有开发者签名';
  for (final path in [app, File(app).parent.path]) {
    final result = await Process.run('/bin/test', ['-w', path]);
    if (result.exitCode != 0) return '没有写入权限：$path';
  }
  return null;
}

/// 当前运行的 .app 路径（可执行文件在 `Dymuse.app/Contents/MacOS/` 下）。
String? macAppBundle() {
  final app = File(Platform.resolvedExecutable).parent.parent.parent.path;
  return app.endsWith('.app') ? app : null;
}

Future<String> _run(String exe, List<String> args) async {
  final result = await Process.run(exe, args);
  if (result.exitCode != 0) {
    final detail = '${result.stderr}'.trim();
    throw StateError(
      '${exe.split('/').last} 失败${detail.isEmpty ? '' : '：$detail'}',
    );
  }
  return '${result.stdout}';
}

/// 签名里的标识与 TeamIdentifier，例如 `app.dymuse.allinone/6588Y7722F`。
Future<String> _signer(String app) async {
  final result = await Process.run('/usr/bin/codesign', ['-dv', app]);
  final text = '${result.stderr}';
  String field(String name) =>
      RegExp('^$name=(.*)\$', multiLine: true).firstMatch(text)?.group(1) ??
      '';
  return '${field('Identifier')}/${field('TeamIdentifier')}';
}

/// 准备好新版并启动替换脚本；调用方随后应让应用退出。
Future<void> startMacUpdate(File dmg) async {
  final app = macAppBundle()!;
  final work = dmg.parent.createTempSync('install-');
  final mount = Directory('${work.path}/mnt')..createSync();
  await _run('/usr/bin/hdiutil', [
    'attach',
    dmg.path,
    '-nobrowse',
    '-readonly',
    '-noautoopen',
    '-mountpoint',
    mount.path,
  ]);
  final staged = '${work.path}/Dymuse.app';
  try {
    final source = mount
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.endsWith('.app'))
        .firstOrNull;
    if (source == null) throw StateError('安装盘里没有应用');
    await _run('/usr/bin/ditto', [source.path, staged]);
  } finally {
    await Process.run('/usr/bin/hdiutil', ['detach', mount.path, '-force']);
  }
  await _run('/usr/bin/codesign', ['--verify', '--deep', '--strict', staged]);
  final mine = await _signer(app), theirs = await _signer(staged);
  if (theirs.endsWith('/') || theirs != mine) {
    throw StateError('新版签名与当前应用不一致（$theirs）');
  }
  // 应用自己下载的文件一般没有隔离标记；保险起见再清一次，没有时忽略。
  await Process.run('/usr/bin/xattr', ['-dr', 'com.apple.quarantine', staged]);
  final script = File('${work.path}/apply_update.sh');
  await script.writeAsString(_script, flush: true);
  await Process.start('/bin/bash', [
    script.path,
    '$pid',
    staged,
    app,
    '${work.path}/old',
    '${work.path}/update.log',
  ], mode: ProcessStartMode.detached);
}

const _script = r'''
pid="$1"; staged="$2"; target="$3"; old="$4"; log="$5"
note() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$log"; }
note "wait pid $pid"
for _ in $(seq 1 200); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.3
done
if kill -0 "$pid" 2>/dev/null; then
  note "old process still running"
  exit 1
fi
mkdir -p "$old"
if ! mv "$target" "$old/"; then
  note "move old failed"
elif ! mv "$staged" "$target"; then
  note "move new failed, restore old"
  mv "$old/$(basename "$target")" "$target"
else
  note "ok"
fi
open "$target"
''';

/// 半自动更新：用系统打开安装盘，弹出常见的安装窗口（Dymuse 与「应用程序」快捷方式），由用户拖过去替换。
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
