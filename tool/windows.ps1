param(
    [ValidateSet('check', 'test', 'build', 'run', 'integration')]
    [string]$Action = 'build',
    [ValidateSet('debug', 'profile', 'release')]
    [string]$Mode = 'release',
    [string]$FlutterRoot = $env:DYMUSE_FLUTTER_ROOT,
    # 联调用的编译期开关（形如 NAME=value），只对 build、run 生效。
    [string[]]$DartDefine = @()
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 记录并恢复进程环境；不改注册表、系统 PATH 或其他项目配置。
$originalEnvironment = @{}
Get-ChildItem Env: | ForEach-Object { $originalEnvironment[$_.Name] = $_.Value }
$project = Split-Path -Parent $PSScriptRoot
try {
    if (!$IsWindows) { throw '本脚本仅支持 Windows。' }
    if (!$FlutterRoot) { $FlutterRoot = 'D:\devtools\flutter-dymuse' }
    $flutter = Join-Path $FlutterRoot 'bin\flutter.bat'
    if (!(Test-Path -LiteralPath $flutter)) { throw '找不到 Flutter SDK，请传入 -FlutterRoot。' }
    $env:PATH = "$(Join-Path $FlutterRoot 'bin');$env:PATH"
    $localNuget = Join-Path $project 'build\tools\nuget.exe'
    if (Test-Path -LiteralPath $localNuget) {
        $env:PATH = "$(Split-Path -Parent $localNuget);$env:PATH"
    }

    # MSBuild 的 64 位注册表路径可能指向错误目录，显式选取实际 SDK。
    $sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
    $sdk = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'ucrt\x64\ucrtd.lib') } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (!$sdk) { throw '未找到 Windows SDK x64 运行库。' }
    $env:UCRTContentRoot = "$sdkRoot\"
    $env:UniversalCRTSdkDir = "$sdkRoot\"
    $env:TargetUniversalCRTVersion = $sdk.Name

    # 只复用已配置的系统代理；本机联调始终直连。
    if (!$env:HTTPS_PROXY) {
        $endpoint = [uri]'https://pub.dev'
        $proxy = [System.Net.Http.HttpClient]::DefaultProxy.GetProxy($endpoint)
        if ($proxy -and $proxy.Authority -ne $endpoint.Authority) { $env:HTTPS_PROXY = $proxy.AbsoluteUri }
    }
    if (!$env:HTTP_PROXY -and $env:HTTPS_PROXY) { $env:HTTP_PROXY = $env:HTTPS_PROXY }
    $env:NO_PROXY = (@($env:NO_PROXY, 'localhost', '127.0.0.1', '::1') | Where-Object { $_ }) -join ','
    Push-Location -LiteralPath $project
    try {
        & $flutter pub get --enforce-lockfile
        if ($LASTEXITCODE -ne 0) { throw 'Flutter 依赖恢复失败。' }

        # 修复首次探测失败留下的空 Debug 参数，避免混用 release/debug CRT。
        $cache = Join-Path $project 'build\windows\x64\CMakeCache.txt'
        if ((Test-Path -LiteralPath $cache) -and
            (Select-String -LiteralPath $cache -Pattern '^CMAKE_CXX_FLAGS_DEBUG:STRING=$' -Quiet)) {
            $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
            $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
            $cmake = Join-Path $visualStudio 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
            & $cmake -S windows -B build/windows/x64 -G 'Visual Studio 17 2022' -A x64 `
                '-DCMAKE_CXX_FLAGS_DEBUG=/D_DEBUG /MDd /Zi /Ob0 /Od /RTC1' `
                '-DCMAKE_CXX_FLAGS_RELEASE=/MD /O2 /Ob2 /DNDEBUG' `
                '-DCMAKE_CXX_FLAGS_RELWITHDEBINFO=/MD /Zi /O2 /Ob1 /DNDEBUG'
            if ($LASTEXITCODE -ne 0) { throw 'CMake 本地缓存修正失败。' }
        }

        switch ($Action) {
            'check' { & $flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings }
            'test' {
                # 缓存清理用例会删除临时文件，本脚本只运行不清理文件的回归。
                $tests = @(Get-ChildItem -LiteralPath test -Filter '*_test.dart' -File |
                    Where-Object Name -notin @('media_cache_test.dart', 'caching_audio_source_test.dart') |
                    ForEach-Object { $_.FullName })
                & $flutter test --no-pub @tests
            }
            'build' { & $flutter build windows "--$Mode" --no-pub @($DartDefine | ForEach-Object { "--dart-define=$_" }) }
            'run' { & $flutter run -d windows "--$Mode" --no-pub @($DartDefine | ForEach-Object { "--dart-define=$_" }) }
            'integration' { & $flutter test integration_test/windows_test.dart -d windows --no-pub }
        }
        if ($LASTEXITCODE -ne 0) { throw "Flutter $Action 失败，退出码 $LASTEXITCODE。" }
        if ($Action -eq 'build') {
            # exe、插件和资源是一整套产物，缺失时不能当作构建成功交付。
            $bundle = Join-Path $project "build\windows\x64\runner\$Mode"
            $requiredFiles = @('dymuse.exe', 'flutter_windows.dll', 'libmpv-2.dll',
                'screen_retriever_windows_plugin.dll', 'media_kit_libs_windows_audio_plugin.dll',
                'flutter_secure_storage_windows_plugin.dll', 'window_manager_plugin.dll',
                'url_launcher_windows_plugin.dll', 'webview_windows_plugin.dll',
                'data\icudtl.dat', 'data\flutter_assets\AssetManifest.bin')
            $requiredFiles += if ($Mode -eq 'debug') { 'data\flutter_assets\kernel_blob.bin' } else { 'data\app.so' }
            foreach ($file in $requiredFiles) {
                if (!(Test-Path -LiteralPath (Join-Path $bundle $file))) { throw "构建产物不完整：$file" }
            }
            Write-Output "完整应用目录：$bundle"
        }
    } finally { Pop-Location }
} finally {
    # 新增环境项置空，已有项还原；不删除文件或配置。
    Get-ChildItem Env: | ForEach-Object {
        if (!$originalEnvironment.ContainsKey($_.Name)) { [Environment]::SetEnvironmentVariable($_.Name, $null, 'Process') }
    }
    foreach ($name in $originalEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process') }
}
