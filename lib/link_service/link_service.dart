// 取链服务：用「服务地址 + 账号 + 密码」登录自己部署的取链服务（见 README 的部署教程），
// 拉取里面共享的会员账号的 Cookie，只用于取歌曲链接（见 NeteaseClient.songUrls）；
// 红心、歌单、推荐等个人数据仍用自己登录的网易云账号。没有配置时完全不联网、取链沿用自己的账号。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class LinkService extends ChangeNotifier {
  LinkService({FlutterSecureStorage? storage})
    : storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  // 钥匙串里只放一项（地址、账号、密码、取链账号缓存），读取时系统只会询问一次授权。
  static const _storeKey = 'dymuse.linkservice';
  static const refreshEvery = Duration(hours: 6);

  final FlutterSecureStorage storage;

  String url = '', username = '', password = '';

  /// 开关：关闭后保留配置，但取链沿用自己登录的账号。
  bool enabled = true;
  Map<String, String>? _cookie;
  Map<String, dynamic>? _credentialJson;
  String nickname = '';
  int vipType = 0;
  String? updatedAt;
  String? error;
  bool busy = false;
  Timer? _timer;
  Future<void>? _inflight;

  bool get configured =>
      url.isNotEmpty && username.isNotEmpty && password.isNotEmpty;

  /// 取链用的 Cookie；还没有取到账号时为 null（取链沿用自己的账号）。
  Map<String, String>? get cookie => configured && enabled ? _cookie : null;
  bool get ready => cookie != null;

  static String vipLabel(int type) => switch (type) {
    0 => '非会员',
    10 => '音乐包',
    11 => '黑胶 VIP',
    12 => '黑胶 SVIP',
    _ => '会员',
  };

  static bool _privateHost(String host) {
    if (host == 'localhost' || host.endsWith('.local')) return true;
    final address = InternetAddress.tryParse(host);
    if (address == null) return false;
    if (address.isLoopback) return true;
    if (address.type != InternetAddressType.IPv4) return false;
    final b = address.rawAddress;
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }

  /// 整理用户填写的地址：补全 https://、去掉末尾斜杠；明文 http 只允许本机和局域网地址。
  /// 空串返回 ''，不合法返回 null。
  static String? normalizeUrl(String input) {
    var text = input.trim();
    if (text.isEmpty) return '';
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'https' &&
        !(uri.scheme == 'http' && _privateHost(uri.host))) {
      return null;
    }
    return '${uri.scheme}://${uri.authority}${uri.path.replaceAll(RegExp(r'/+$'), '')}';
  }

  /// 启动：读本机缓存（离线也能用上次的账号），随后联网刷新并定时更新。
  Future<void> start() async {
    await _loadSaved();
    if (!configured || !enabled) return;
    unawaited(refresh());
    _timer?.cancel();
    _timer = Timer.periodic(refreshEvery, (_) => unawaited(refresh()));
  }

  Future<void> _loadSaved() async {
    try {
      final raw = await storage.read(key: _storeKey);
      if (raw == null || raw.isEmpty) return;
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      url = '${saved['url'] ?? ''}';
      username = '${saved['username'] ?? ''}';
      password = '${saved['password'] ?? ''}';
      enabled = saved['enabled'] != false;
      final credential = saved['credential'];
      if (credential is Map<String, dynamic>) {
        _credentialJson = credential;
        _apply(credential);
      }
    } catch (_) {
      // 安全存储不可用或内容损坏：当作没有配置。
    }
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      await storage.write(
        key: _storeKey,
        value: jsonEncode({
          'url': url,
          'username': username,
          'password': password,
          'enabled': enabled,
          'credential': _credentialJson,
        }),
      );
    } catch (_) {
      // 安全存储不可用时只保留本次内存，下次启动需要重新填写。
    }
  }

  void _apply(Map<String, dynamic> body) {
    final cookie = <String, String>{};
    for (final entry in ((body['cookie'] as Map?) ?? const {}).entries) {
      if (entry.value is String && (entry.value as String).isNotEmpty) {
        cookie['${entry.key}'] = entry.value as String;
      }
    }
    if ((cookie['MUSIC_U'] ?? '').isEmpty) throw const FormatException();
    final account = (body['account'] as Map?) ?? const {};
    _cookie = cookie;
    nickname = '${account['nickname'] ?? ''}';
    vipType = (account['vipType'] as num?)?.toInt() ?? 0;
    updatedAt = body['updatedAt'] as String?;
  }

  /// 保存配置并立刻联网验证；结果看 [error]（null 表示成功）。
  Future<void> configure({
    required String url,
    required String username,
    required String password,
  }) async {
    final changed =
        url != this.url ||
        username != this.username ||
        password != this.password;
    this.url = url;
    this.username = username;
    this.password = password;
    if (changed) {
      _cookie = null;
      _credentialJson = null;
      nickname = '';
      vipType = 0;
      updatedAt = null;
    }
    error = null;
    enabled = true;
    await _save();
    notifyListeners();
    _timer?.cancel();
    _timer = Timer.periodic(refreshEvery, (_) => unawaited(refresh()));
    await refresh();
  }

  /// 开启或关闭取链服务；关闭后不再联网刷新，取链用自己的账号。
  Future<void> setEnabled(bool value) async {
    if (enabled == value) return;
    enabled = value;
    await _save();
    notifyListeners();
    _timer?.cancel();
    if (value && configured) {
      _timer = Timer.periodic(refreshEvery, (_) => unawaited(refresh()));
      await refresh();
    }
  }

  /// 移除配置：之后取链沿用自己的账号。
  Future<void> clear() async {
    _timer?.cancel();
    url = username = password = '';
    enabled = true;
    _cookie = null;
    _credentialJson = null;
    nickname = '';
    vipType = 0;
    updatedAt = null;
    error = null;
    await _save();
    notifyListeners();
  }

  /// 联网拉取最新取链账号；同时只会有一个请求在飞。
  Future<void> refresh() => _inflight ??= _refresh().whenComplete(() {
    _inflight = null;
  });

  Future<void> _refresh() async {
    if (!configured || !enabled) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final result = await _get('/v1/credential');
      switch (result.status) {
        case 200:
          _apply(result.body);
          _credentialJson = result.body;
          await _save();
        case 401:
          error = '账号或密码不正确。';
        case 404:
          error = '服务里还没有设置取链账号，请先打开服务网页设置。';
        case 409:
          error = '服务还没有完成首次设置，请先打开服务网页设置账号和密码。';
        case 429:
          error = '尝试次数过多，请稍后再试。';
        default:
          error = '取链服务返回了异常（${result.status}）。';
      }
    } on FormatException {
      error = '取链服务返回的账号数据不完整，请检查服务地址。';
    } on SocketException {
      error = _cookie == null ? '无法连接取链服务。' : '无法连接取链服务，沿用上次获取的账号。';
    } on TimeoutException {
      error = _cookie == null ? '连接取链服务超时。' : '连接取链服务超时，沿用上次获取的账号。';
    } on HandshakeException {
      error = '与取链服务建立安全连接失败，请检查服务地址和证书。';
    } on HttpException {
      error = '与取链服务的连接中断。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<({int status, Map<String, dynamic> body})> _get(String path) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'Dymuse/1.0';
    try {
      final request = await client
          .getUrl(Uri.parse('$url$path'))
          .timeout(const Duration(seconds: 15));
      request.headers
        ..set(
          HttpHeaders.authorizationHeader,
          'Basic ${base64.encode(utf8.encode('$username:$password'))}',
        )
        ..set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final text = await utf8
          .decodeStream(response)
          .timeout(const Duration(seconds: 15));
      Map<String, dynamic> json = const {};
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) json = decoded;
      } catch (_) {}
      return (status: response.statusCode, body: json);
    } finally {
      client.close(force: true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
