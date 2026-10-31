<p align="center">
  <img src="docs/images/logo.png" width="128" alt="Dymuse logo">
</p>

<h1 align="center">Dymuse</h1>

**网易云音乐在各个平台上的客户端界面都他妈太丑了，所以就有了Dymuse。**

按 Apple 的设计规范重新做了界面：玻璃质感的迷你播放器与导航、顺滑的返回手势和转场、跟随系统的深浅色，用起来就像Apple Music。Android 版沿用同一套界面（玻璃效果为适应 Android 的 GPU 做了简化：保留半透明与高光，去掉了背后的实时模糊）。

同时也支持哔哩哔哩，把 B 站的合集和视频当作歌单来听。

没有服务器，所有账号、歌单和进度只保存在你自己的设备上；需要多设备同步时，可以用自己的 WebDAV。

> Every official NetEase Cloud Music client looks ugly, so this is a Liquid Glass client for iOS, macOS and Android, with Bilibili as a second source. No server: everything stays on your device, and optional sync goes through your own WebDAV.

## 截图

**iPhone**

<table>
  <tr>
    <td align="center"><img src="docs/images/screenshots/ios-netease-home.jpg" width="220"><br>网易云 · 现在就听</td>
    <td align="center"><img src="docs/images/screenshots/ios-netease-daily.jpg" width="220"><br>网易云 · 每日推荐</td>
    <td align="center"><img src="docs/images/screenshots/ios-netease-player.jpg" width="220"><br>播放界面</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/screenshots/ios-lyrics.jpg" width="220"><br>歌词</td>
    <td align="center"><img src="docs/images/screenshots/ios-lyrics-translation.jpg" width="220"><br>歌词 + 翻译</td>
    <td align="center"><img src="docs/images/screenshots/ios-lyrics-romaji.jpg" width="220"><br>歌词 + 罗马音与翻译</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/screenshots/ios-bilibili-subscriptions.jpg" width="220"><br>哔哩哔哩 · 我的订阅</td>
    <td align="center"><img src="docs/images/screenshots/ios-bilibili-search.jpg" width="220"><br>哔哩哔哩 · 搜索</td>
    <td align="center"><img src="docs/images/screenshots/ios-bilibili-jump.jpg" width="220"><br>从搜索结果跳转到来源</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/screenshots/ios-settings.jpg" width="220"><br>账号与设置</td>
    <td></td>
    <td></td>
  </tr>
</table>

**macOS**

<p align="center">
  <img src="docs/images/screenshots/mac-player.jpg" width="49%" alt="macOS 播放界面">
  <img src="docs/images/screenshots/mac-queue.jpg" width="49%" alt="macOS 播放队列">
</p>

## 功能

**网易云模式**
- 扫码登录，推荐、搜索、歌单、专辑、艺人、播客、私人 FM、心动模式
- 音质可选（标准到 Hi-Res），按歌曲实际提供的档位自动降档
- 歌词，支持翻译与罗马音，可任意组合显示
- 收藏歌单、红心、听歌记录
- 总之除了评论和广告，官方有的基本上全都有，没有的再说吧

**哔哩哔哩模式**

- 搜索全站，或只在已订阅的内容里按原视频名搜索
- 订阅合集、系列、收藏夹、订阅的合集、UP 主投稿、单个视频；可从视频一键跳转到所属合集、多 P 视频或 UP 主并订阅
- 歌名识别：从花哨的标题里提取真正的歌名，内置规则加自定义正则，订阅内与搜索结果可分别开关，随时可查看原视频名
- 本地歌单与红心
- 理论上你自己维护一个收藏夹然后订阅，就能无视所有版权限制，整个b站都是你的曲库（

**通用**

- 两种模式的歌单、队列、播放进度互相独立
- 可选 WebDAV 同步：红心、歌单、订阅、播放进度、设置，可选加密登录凭证；服务器上不会被覆盖或损坏
- 迷你播放器、锁屏与控制中心（Android 为通知栏与锁屏控制）、媒体键与耳机键、后台播放
- 主题色可选预设或手动取色
- WebDav仅作同步用途，且有自定义加密密钥，不用担心WebDav服务商窃取你的平台oauth
- 如果没有自建的WebDav，大陆环境推荐坚果云。小白可以参考这个教程：https://www.bilibili.com/video/BV1xf4y187Cy/?spm_id_from=333.337.search-card.all.click&vd_source=9d892c79bec4fcbaca00cfd4028700e4

## 当前状态

iOS 与 macOS 完成度较高；Android 已可用，只在作者的一台 Sony Xperia 5 IV 上测试过，横屏与平板布局、不同厂商系统的通知表现还没有验证；Windows、Linux 暂未适配。项目由个人开发，很多功能只在作者自己的设备和账号上验证过，欢迎提 issue。

## 构建

需要 Flutter 3.41 或更新；macOS / iOS 还需要 Xcode，Android 还需要 JDK 17 与 Android SDK（platform 35 以上）。

```sh
flutter pub get
flutter test                  # 单元测试，不联网
flutter run -d macos          # 或连接 iPhone 后 flutter run
flutter build apk --release --target-platform android-arm64   # Android，产物在 build/app/outputs/flutter-apk/
```

- **签名**：工程里没有保存团队 ID。真机运行和发布需要在 Xcode 里打开 `ios/Runner.xcworkspace`、`macos/Runner.xcworkspace`，把 Team 改成你自己的，并把 Bundle ID（`app.dymuse.allinone`）换成你自己的。
- **Android 安装包体积**：不加 `--target-platform` 会打包 arm64、armeabi-v7a、x86_64 三套架构，约 60MB；只打 arm64 约 22MB，Release 里的 APK 就是 arm64 的。
- **Android 签名**：release 暂用调试签名，方便自行侧载安装。要长期分发请在 `android/app/build.gradle.kts` 里换成你自己的发布密钥，并同样替换包名 `app.dymuse.allinone`。
- **Android 播放通知**：第一次播放时会请求通知权限（Android 13+），不授权也能播放，只是没有通知栏控制。
- **macOS 钥匙串**：默认的临时签名每次构建都不同，钥匙串里的登录凭证会反复弹窗。用 `DYMUSE_SIGN_IDENTITY="Apple Development: …" tool/build_mac.sh` 以固定证书构建可避免。
- `tool/` 下是只读的联网探测脚本，不在默认测试里。

## 隐私与安全

- 没有自己的服务器，不收集任何数据。网易云与哔哩哔哩的请求由 App 直接发往对方。
- 登录凭证保存在系统钥匙串；WebDAV 同步里的凭证用你设置的口令（PBKDF2 + AES-256-GCM）加密后才上传，口令不上传。
- 网易云部分操作（如收藏歌单）需要反作弊令牌，App 会在隐藏的 WebView 里运行官方脚本来获取，不做其他用途。

## 声明

- 本项目仅供学习和个人使用，不提供也不绕过任何付费、会员或版权限制，请遵守相关服务的用户协议和当地法律。
- 才不会告诉你买东哥PLUS联合网易云会员，折合下来网易云黑胶一年才15块。
- 与网易云音乐、哔哩哔哩没有任何关联，名称与接口归其权利人所有。接口可能随时变化而失效。

## 许可证

[AGPL-3.0](LICENSE)。哔哩哔哩相关代码与歌名规则移植自 [azusa-player-mobile](https://github.com/lovegaoshi/azusa-player-mobile)（AGPL-3.0），网易云请求参考 api-enhanced（MIT）。详见 [THIRD_PARTY.md](THIRD_PARTY.md)。
