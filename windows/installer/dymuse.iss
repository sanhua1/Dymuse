; Dymuse Windows 安装包（Inno Setup 6）。由 tool/windows.ps1 -Action package 调用：
;   ISCC /DAppVersion=0.2.8 /DAppBuild=10 /DSourceDir=<Release 目录> /DOutputDir=<输出目录> dymuse.iss
; 默认装到 C:\Program Files\Dymuse（需要管理员权限）。卸载只删除安装的文件，
; 不碰 AppData 里的设置、登录状态与缓存。
; 应用内更新（lib/update/windows_installer.dart）静默运行本安装包：
;   /SILENT /SUPPRESSMSGBOXES /NORESTART /DIR=<当前程序目录>
; 装完以原用户身份（非管理员）重新启动 Dymuse。

#ifndef AppVersion
  #error 缺少 /DAppVersion
#endif
#ifndef AppBuild
  #error 缺少 /DAppBuild
#endif
#ifndef SourceDir
  #error 缺少 /DSourceDir
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
; AppId 固定不变，升级、卸载都靠它识别同一个应用。
AppId={{812CAEF9-2894-4DF3-818D-213B2BCE0D1A}
AppName=Dymuse
AppVersion={#AppVersion}
AppVerName=Dymuse {#AppVersion}
AppPublisher=Dymuse
AppPublisherURL=https://github.com/sanhua1/Dymuse
VersionInfoVersion={#AppVersion}.{#AppBuild}
VersionInfoProductVersion={#AppVersion}
DefaultDirName={autopf}\Dymuse
DefaultGroupName=Dymuse
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=Dymuse-windows-x64-setup
SetupIconFile={#SourcePath}..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\dymuse.exe
UninstallDisplayName=Dymuse
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 安装时 Dymuse 还开着就先关掉（应用内更新时应用自己会先退出）。
CloseApplications=force
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "chs"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 只装运行所需文件；构建中间产物（.lib/.exp/.pdb）不进安装包。
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "*.lib,*.exp,*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Dymuse"; Filename: "{app}\dymuse.exe"
Name: "{autodesktop}\Dymuse"; Filename: "{app}\dymuse.exe"; Tasks: desktopicon

[Run]
; 手动安装：完成页上的“运行 Dymuse”。
Filename: "{app}\dymuse.exe"; Description: "{cm:LaunchProgram,Dymuse}"; Flags: nowait postinstall skipifsilent
; 应用内静默更新：装完以原用户身份重新启动，不以管理员身份运行应用。
Filename: "{app}\dymuse.exe"; Flags: nowait runasoriginaluser; Check: WizardSilent