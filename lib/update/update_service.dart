import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 与 pubspec.yaml 的 version 保持一致（测试会核对）；发版时一起改。
const appVersion = '0.2.2';
const appBuild = 4;

/// 一个发布源：用它的接口读取最新 Release，再按 tag 和文件名拼出下载地址。
class UpdateSource {
  const UpdateSource(this.name, this.api, this.assetBase, [this.pageBase = '']);
  final String name;

  /// `releases/latest` 接口地址。
  final String api;

  /// 下载地址前缀；完整地址是 `<前缀>/<tag>/<文件名>`。
  final String assetBase;
  String assetUrl(String tag, String file) => '$assetBase/$tag/$file';

  /// Release 网页前缀；完整地址是 `<前缀>/<tag>`，iOS 让用户去这里自己下载。
  final String pageBase;
  String pageUrl(String tag) => '$pageBase/$tag';
}

const giteeSource = UpdateSource(
  'Gitee',
  'https://gitee.com/api/v5/repos/sanhua1/dymuserelease/releases/latest',
  'https://gitee.com/sanhua1/dymuserelease/releases/download',
  'https://gitee.com/sanhua1/dymuserelease/releases/tag',
);
const githubSource = UpdateSource(
  'GitHub',
  'https://api.github.com/repos/sanhua1/Dymuse/releases/latest',
  'https://github.com/sanhua1/Dymuse/releases/download',
  'https://github.com/sanhua1/Dymuse/releases/tag',
);

/// 联调用：`--dart-define=DYMUSE_UPDATE_API=...` 与 `DYMUSE_UPDATE_BASE=...` 编译时才存在，
/// 正式包没有定义，不会读取任何环境变量。
const _testApi = String.fromEnvironment('DYMUSE_UPDATE_API');
const _testBase = String.fromEnvironment('DYMUSE_UPDATE_BASE');

class UpdateError implements Exception {
  const UpdateError(this.message);
  final String message;
  @override
  String toString() => message;
}

class UpdateAsset {
  const UpdateAsset(this.name, this.size, this.sha256);
  final String name;
  final int size;
  final String sha256;
}

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.tag,
    required this.notes,
    required this.asset,
    required this.downloadUrls,
    required this.sourceName,
  });
  final String version, tag, notes, sourceName;

  /// 本平台的安装包；为空表示只提示（iOS，或这次没有发本平台的包）。
  final UpdateAsset? asset;

  /// 按优先级排好的下载地址，前一个失败就换下一个。
  final List<String> downloadUrls;
}

/// 比较 `0.2.1` / `v0.2.1+3` 这类版本号；返回正数表示 [a] 更新。
int compareVersions(String a, String b) {
  List<int> parts(String v) {
    final core = v.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first;
    return [for (final p in core.split('.')) int.tryParse(p) ?? 0];
  }

  final x = parts(a), y = parts(b);
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final l = i < x.length ? x[i] : 0, r = i < y.length ? y[i] : 0;
    if (l != r) return l - r;
  }
  return 0;
}

/// 更新检测与下载：Gitee 优先（大陆直连），失败回退 GitHub；下载后校验大小与 SHA-256。
class UpdateService extends ChangeNotifier {
  UpdateService(
    this.preferences, {
    http.Client? client,
    List<UpdateSource>? sources,
    String? platform,
    this.currentVersion = appVersion,
    this.currentBuild = appBuild,
  }) : _client = client ?? http.Client(),
       _sources = sources ?? _defaultSources(),
       platform = platform ?? platformKey();
  final SharedPreferences preferences;
  final http.Client _client;
  final List<UpdateSource> _sources;
  final String platform, currentVersion;
  final int currentBuild;

  /// 由主程序挂上：保存播放进度并结束进程（更新脚本等它退出后替换文件）。
  Future<void> Function()? quit;

  static const ignoredKey = 'update.ignored';
  static const githubFirstKey = 'update.githubFirst';

  static List<UpdateSource> _defaultSources() => _testApi.isNotEmpty
      ? const [UpdateSource('测试', _testApi, _testBase)]
      : const [giteeSource, githubSource];

  static String platformKey() {
    if (Platform.isWindows) return 'windows-x64';
    if (Platform.isAndroid) return 'android-arm64';
    if (Platform.isMacOS) return 'macos';
    return 'ios';
  }

  /// 本平台能否在应用内下载并安装（Windows、macOS 原地更新，Android 交给系统安装器）。
  bool get canInstall =>
      (Platform.isWindows && platform == 'windows-x64') ||
      (Platform.isAndroid && platform == 'android-arm64') ||
      (Platform.isMacOS && platform == 'macos');

  String? get ignoredVersion => preferences.getString(ignoredKey);
  Future<void> ignore(String version) =>
      preferences.setString(ignoredKey, version);

  bool get githubFirst => preferences.getBool(githubFirstKey) ?? false;
  Future<void> setGithubFirst(bool value) async {
    await preferences.setBool(githubFirstKey, value);
    notifyListeners();
  }

  /// 按当前偏好排好的发布源（默认 Gitee 在前）。
  List<UpdateSource> get sources => _ordered;

  List<UpdateSource> get _ordered {
    if (_sources.length < 2 || !githubFirst) return _sources;
    return _sources.reversed.toList();
  }

  Future<Map<String, dynamic>> _json(String url) async {
    final res = await _client
        .get(
          Uri.parse(url),
          headers: {'Accept': 'application/json', 'User-Agent': 'Dymuse'},
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw UpdateError('HTTP ${res.statusCode}');
    final value = jsonDecode(utf8.decode(res.bodyBytes));
    if (value is! Map<String, dynamic>) throw const UpdateError('格式不对');
    return value;
  }

  /// 检查最新版本：有比当前更新的版本返回 [UpdateInfo]，否则返回 null；
  /// 所有发布源都失败时抛出 [UpdateError]。“忽略此版本”由调用方判断。
  Future<UpdateInfo?> check() async {
    Object? last;
    for (final source in _ordered) {
      try {
        final release = await _json(source.api);
        if (release['prerelease'] == true || release['draft'] == true) {
          continue;
        }
        final tag = '${release['tag_name'] ?? ''}';
        if (tag.isEmpty) throw const UpdateError('没有版本号');
        final assets = (release['assets'] as List? ?? const [])
            .whereType<Map>()
            .toList();
        final manifestAsset = assets.firstWhere(
          (a) => a['name'] == 'latest.json',
          orElse: () => const {},
        );
        final manifestUrl =
            '${manifestAsset['browser_download_url'] ?? source.assetUrl(tag, 'latest.json')}';
        final manifest = await _json(manifestUrl);
        return _info(source, tag, release, manifest);
      } catch (error) {
        last = error;
      }
    }
    if (last != null) throw UpdateError('无法连接更新服务器（$last）。');
    return null;
  }

  UpdateInfo? _info(
    UpdateSource source,
    String tag,
    Map<String, dynamic> release,
    Map<String, dynamic> manifest,
  ) {
    final version = '${manifest['version'] ?? ''}';
    if (version.isEmpty) throw const UpdateError('清单缺少版本号');
    final build = (manifest['build'] as num?)?.toInt() ?? 0;
    final newer =
        compareVersions(version, currentVersion) > 0 ||
        (compareVersions(version, currentVersion) == 0 && build > currentBuild);
    if (!newer) return null;
    UpdateAsset? asset;
    final raw = (manifest['assets'] as Map?)?[platform];
    if (raw is Map &&
        '${raw['name']}'.isNotEmpty &&
        '${raw['sha256']}'.length == 64) {
      asset = UpdateAsset(
        '${raw['name']}',
        (raw['size'] as num?)?.toInt() ?? 0,
        '${raw['sha256']}'.toLowerCase(),
      );
    }
    return UpdateInfo(
      version: version,
      tag: tag,
      notes: '${manifest['notes'] ?? release['body'] ?? ''}'.trim(),
      asset: asset,
      downloadUrls: asset == null
          ? const []
          : [for (final s in _ordered) s.assetUrl(tag, asset.name)],
      sourceName: source.name,
    );
  }

  /// 下载安装包并校验大小与 SHA-256；一个地址失败就换下一个。返回校验通过的文件。
  Future<File> download(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
  }) async {
    final asset = info.asset;
    if (asset == null) throw const UpdateError('这个版本没有适用于本机的安装包。');
    final dir = Directory.systemTemp.createTempSync('dymuse-update-');
    final file = File('${dir.path}/${asset.name}');
    Object? last;
    for (final url in info.downloadUrls) {
      try {
        final res = await _client
            .send(
              http.Request('GET', Uri.parse(url))
                ..headers['User-Agent'] = 'Dymuse',
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) throw UpdateError('HTTP ${res.statusCode}');
        final total = res.contentLength ?? asset.size;
        var got = 0;
        final sink = file.openWrite();
        try {
          await for (final chunk in res.stream.timeout(
            const Duration(seconds: 30),
          )) {
            sink.add(chunk);
            got += chunk.length;
            onProgress?.call(got, total);
          }
        } finally {
          await sink.close();
        }
        if (asset.size > 0 && got != asset.size) {
          throw const UpdateError('文件大小不符');
        }
        final digest = await sha256.bind(file.openRead()).first;
        if (digest.toString() != asset.sha256) {
          throw const UpdateError('校验不通过');
        }
        return file;
      } catch (error) {
        last = error;
      }
    }
    throw UpdateError('下载失败（$last）。');
  }
}
