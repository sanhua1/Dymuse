# 第三方来源与许可证

Dymuse 的整体许可证是 **AGPL-3.0**（见 `LICENSE`），原因是下面第 1 项。

## 1. azusa-player-mobile（AGPL-3.0）

<https://github.com/lovegaoshi/azusa-player-mobile>，许可证全文见 `third_party_licenses/azusa-player-mobile-AGPL-3.0.txt`。

以下代码和数据移植或改写自该项目，因此本项目整体按 AGPL-3.0 发布：

| 文件 | 内容 |
| --- | --- |
| `lib/bilibili/client.dart` | B 站协议客户端（来自 `utils/mediafetch/*`） |
| `lib/bilibili/sources.dart` | 合集、系列、收藏夹、订阅合集、UP 主投稿、单个视频的解析与分页（来自 mediafetch） |
| `lib/bilibili/wbi.dart` | B 站 WBI 签名（来自 `stores/wbi.ts`） |
| `lib/bilibili/title_rules.dart` | 按 UP 主匹配的歌名规则，内置规则数据来自其 `rejson.json`（做法来自 `src/utils/re.ts`） |
| `lib/sync/sync_service.dart` | WebDAV 整体打包同步的思路 |

## 2. api-enhanced / NeteaseCloudMusicApi（MIT）

<https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced>，许可证全文见 `third_party_licenses/api-enhanced-MIT.txt`。

`lib/netease/` 下网易云请求的加密、接口路径和参数参考并移植自该项目及其上游 Binaryify/NeteaseCloudMusicApi（Copyright (c) 2013-2022 Binaryify）。

## 3. 依赖包

各 Dart/Flutter 依赖包遵循各自的许可证，版本见 `pubspec.lock`；运行 `flutter pub deps` 可列出。其中 `liquid_glass_widgets`、`media_kit`、`just_audio`、`webview_flutter` 等的条款以其仓库为准。

## 4. 商标与服务

“网易云音乐”“哔哩哔哩”及相关名称、接口归其各自权利人所有。本项目与这些公司无关，也未获得其授权或认可。
