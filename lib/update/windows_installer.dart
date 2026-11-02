import 'dart:io';

/// Windows 绿色版的原地更新：解压新版到临时目录，等本进程退出后覆盖安装目录并重新启动。
/// 只覆盖同名文件，不删除安装目录里的任何文件，也不碰用户数据（数据在 AppData）。
/// 脚本和日志都放在系统临时目录；安装目录没有写权限（例如装在 Program Files）时会失败并
/// 重新启动旧版本，原因写入日志。
const _script = r'''
param([int]$ProcId, [string]$Zip, [string]$Target, [string]$Exe, [string]$Log)
$ErrorActionPreference = 'Stop'
function Write-Log($message) {
  Add-Content -LiteralPath $Log -Value ("{0} {1}" -f (Get-Date -Format o), $message) -Encoding UTF8
}
try {
  $stage = Join-Path (Split-Path -Parent $Zip) 'stage'
  Write-Log "extract $Zip"
  Expand-Archive -LiteralPath $Zip -DestinationPath $stage -Force
  $root = $stage
  if (-not (Test-Path -LiteralPath (Join-Path $root 'dymuse.exe'))) {
    $sub = Get-ChildItem -LiteralPath $stage -Directory |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'dymuse.exe') } |
      Select-Object -First 1
    if (-not $sub) { throw 'dymuse.exe not found in package' }
    $root = $sub.FullName
  }
  Write-Log "wait pid $ProcId"
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Process -Id $ProcId -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $deadline)) {
    Start-Sleep -Milliseconds 300
  }
  if (Get-Process -Id $ProcId -ErrorAction SilentlyContinue) { throw 'old process still running' }
  Write-Log "copy $root -> $Target"
  & robocopy $root $Target /E /IS /IT /R:5 /W:1 /NFL /NDL /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy exit $LASTEXITCODE" }
  Write-Log 'ok'
} catch {
  Write-Log ("failed: {0}" -f $_)
}
Start-Process -FilePath $Exe
''';

/// 启动更新脚本；调用方随后应让应用退出。
Future<void> startWindowsUpdate(File zip) async {
  final exe = Platform.resolvedExecutable;
  final target = File(exe).parent.path;
  final dir = zip.parent.path;
  final script = File('$dir/apply_update.ps1');
  await script.writeAsString(_script, flush: true);
  await Process.start(
    'powershell.exe',
    [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      script.path,
      '-ProcId',
      '$pid',
      '-Zip',
      zip.path,
      '-Target',
      target,
      '-Exe',
      exe,
      '-Log',
      '$dir/update.log',
    ], // 不能用 detached：Windows 上以 DETACHED_PROCESS 启动的 powershell.exe 不会运行脚本（实测）。
    // normal 模式的子进程在本进程退出后会继续运行；脚本不输出任何内容，管道不会堵住。
    mode: ProcessStartMode.normal,
  );
}
