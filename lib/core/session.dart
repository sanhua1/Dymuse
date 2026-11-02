import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../bilibili/client.dart';
import '../local/backend.dart';
import '../local/bilibili_backend.dart';
import '../netease/anti_cheat.dart';
import '../netease/client.dart';
import '../link_service/link_service.dart';
import '../sync/sync_service.dart';
import '../update/update_service.dart';
import 'api_client.dart';
import 'media_cache.dart';

/// 纯本地网易云：账号即网易云账号，Cookie 只保存在本机安全存储中。
class Session extends ChangeNotifier {
  Session(this.api, this.preferences, {FlutterSecureStorage? storage})
    : storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );
  final ApiClient api;
  final SharedPreferences preferences;
  final FlutterSecureStorage storage;
  Json? user;

  /// 游客：没有登录网易云账号，也能搜索、浏览和播放；依赖账号的功能提示登录。
  bool guest = false;
  bool restoring = true;
  String? notice;
  int epoch = 0;
  NeteaseClient? netease;
  BilibiliClient? bilibili;

  /// WebDAV 同步；由 main 创建后挂上，用来同步登录凭证等。
  SyncService? sync;

  /// 更新检测；由 main 创建后挂上，设置页用它手动检查。
  UpdateService? updates;

  /// 取链服务（多人共享会员账号）；由 main 创建后挂上，没有配置时不起作用。
  LinkService? linkService;
  LocalBackend? backend;
  String get username => user?['nickname']?.toString() ?? '';

  /// 纯本地版没有需要强制修改的 Dymuse 账号。
  bool get mustChangePassword => false;
  bool get firstLogin => false;
  String get deviceId => preferences.getString('deviceId')!;
  String get avatarUrl => user?['avatarUrl']?.toString() ?? '';
  int get vipType => (user?['vipType'] as num?)?.toInt() ?? 0;

  static const _cookieKey = 'dymuse.netease.cookie';
  static const _biliCookieKey = 'dymuse.bilibili.cookie';
  static const _guestKey = 'netease.guest';

  /// 设备标识固定；网易云 Cookie 作为一个受保护记录恢复。
  Future<void> restore() async {
    api.server = 'dymuse://local';
    api.onUnauthorized = expire;
    api.onLoginRequested = startLogin;
    if (!preferences.containsKey('deviceId')) {
      final random = Random.secure();
      await preferences.setString(
        'deviceId',
        'iphone-${List.generate(24, (_) => random.nextInt(16).toRadixString(16)).join()}',
      );
    }
    try {
      final raw = await storage.read(key: _cookieKey);
      Map<String, String>? cookie;
      if (raw != null && raw.isNotEmpty) {
        try {
          cookie = (jsonDecode(raw) as Map).cast<String, String>();
        } catch (_) {
          cookie = null;
        }
      }
      _attach(cookie, await _readBiliCookie());
      if (cookie != null && cookie['MUSIC_U'] != null) {
        final profile = await backend!.refreshAccount();
        if (profile == null) {
          notice = '网易云登录已失效，请重新登录。';
          _reset();
        } else {
          _signIn(profile);
        }
      } else if (preferences.getBool(_guestKey) == true) {
        _enterGuest();
      }
    } catch (error) {
      _reset();
      notice = readableError(error);
    } finally {
      restoring = false;
      notifyListeners();
    }
  }

  Future<Map<String, String>?> _readBiliCookie() async {
    try {
      final raw = await storage.read(key: _biliCookieKey);
      if (raw == null || raw.isEmpty) return null;
      return (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return null;
    }
  }

  /// 同步用：当前登录凭证（未登录为 null）。
  Map<String, Map<String, String>?> syncCredentials() => {
    'netease': (netease?.loggedIn ?? false) ? {...netease!.cookie} : null,
    'bilibili': (bilibili?.loggedIn ?? false) ? {...bilibili!.cookie} : null,
    // 取链服务的地址、账号、密码和开关；和登录凭证一样加密后才上传。
    'link': (linkService?.configured ?? false)
        ? {
            'url': linkService!.url,
            'username': linkService!.username,
            'password': linkService!.password,
            'enabled': linkService!.enabled ? '1' : '0',
          }
        : null,
  };

  String? _linkSignature;

  /// 取链服务的配置有变化（添加、修改、移除、开关）时尽快同步；刷新账号不算。
  void linkServiceChanged() {
    final service = linkService;
    if (service == null) return;
    final signature = service.configured
        ? '${service.url}\n${service.username}\n${service.password}\n${service.enabled}'
        : '';
    if (signature == _linkSignature) return;
    final first = _linkSignature == null;
    _linkSignature = signature;
    if (first) return;
    if (signature.isEmpty) {
      unawaited(sync?.noteLogout('link') ?? Future<void>.value());
    } else {
      unawaited(sync?.noteLogin('link') ?? Future<void>.value());
      sync?.scheduleSoon();
    }
  }

  /// 同步来的凭证：保存并让对应账号立即生效。
  Future<void> applySyncedCredentials(
    String kind,
    Map<String, String> cookie,
  ) async {
    if (kind == 'link') {
      final service = linkService;
      if (service == null || (cookie['url'] ?? '').isEmpty) return;
      await service.configure(
        url: cookie['url']!,
        username: cookie['username'] ?? '',
        password: cookie['password'] ?? '',
      );
      await service.setEnabled(cookie['enabled'] != '0');
      return;
    }
    if (kind == 'bilibili') {
      final client = bilibili ??= BilibiliClient(onCookie: _persistBili);
      client.cookie
        ..clear()
        ..addAll(cookie);
      _persistBili(client.cookie);
      notifyListeners();
      return;
    }
    await storage.write(key: _cookieKey, value: jsonEncode(cookie));
    _detach();
    _attach(cookie, bilibili?.cookie);
    final profile = await backend!.refreshAccount();
    if (profile == null) {
      notice = '同步来的网易云登录已失效，请重新登录。';
      _reset();
      notifyListeners();
      return;
    }
    _signIn(profile);
  }

  void _persistBili(Map<String, String> cookie) {
    if (cookie.isEmpty) {
      unawaited(sync?.noteLogout('bilibili') ?? Future<void>.value());
    } else {
      unawaited(sync?.noteLogin('bilibili') ?? Future<void>.value());
      sync?.scheduleSoon();
    }
    storage
        .write(
          key: _biliCookieKey,
          value: cookie.isEmpty ? '' : jsonEncode(cookie),
        )
        .catchError((_) {
          notice = '安全存储不可用，B 站登录下次启动需要重新扫码。';
          notifyListeners();
        });
  }

  final _antiCheat = AntiCheat();

  /// 歌名识别的开关或规则变了：让已显示的列表重新载入（由主程序接到目录刷新上）。
  VoidCallback? onTitleRules;
  void titleRulesChanged() => onTitleRules?.call();

  void _attach(Map<String, String>? cookie, [Map<String, String>? biliCookie]) {
    final client = NeteaseClient(
      cookie: cookie,
      onCookie: _persist,
      antiCheat: _antiCheat.token,
      vipCookie: () => linkService?.cookie,
      onVipExpired: () async => linkService?.refresh(),
    );
    // B 站登录独立于网易云：网易云重新登录时沿用已有的 B 站客户端。
    final bili = bilibili ??= BilibiliClient(
      cookie: biliCookie,
      onCookie: _persistBili,
    );
    final local = LocalBackend(
      preferences,
      client,
      BilibiliBackend(preferences, bili),
    );
    netease = client;
    backend = local;
    api.backend = local;
  }

  void _persist(Map<String, String> cookie) {
    // Cookie 写入失败时保留本次内存会话，明确提示无法自动登录。
    storage.write(key: _cookieKey, value: jsonEncode(cookie)).catchError((_) {
      notice = '安全存储不可用，下次启动需要重新登录。';
      notifyListeners();
    });
  }

  void _signIn(Map<String, dynamic> profile) {
    guest = false;
    api.guest = false;
    unawaited(preferences.remove(_guestKey));
    // 界面按 'id' 判断账号切换，网易云资料里叫 userId。
    user = {...profile, 'id': profile['userId']};
    api.token = profile['userId']?.toString() ?? 'netease';
    _scope();
    epoch++;
    notice = null;
    notifyListeners();
  }

  /// 先不登录，以游客身份使用。
  Future<void> enterGuest() async {
    await preferences.setBool(_guestKey, true);
    _enterGuest();
    notifyListeners();
  }

  void _enterGuest() {
    guest = true;
    api.guest = true;
    user = {
      'id': 'guest',
      'userId': 'guest',
      'nickname': '游客',
      'avatarUrl': '',
      'vipType': 0,
    };
    api.token = 'guest';
    _scope();
    epoch++;
    notice = null;
  }

  /// 由界面层挂上：弹出“登录网易云”页面（桌面是弹窗，手机是 Sheet）。
  /// 游客身份保持不变，关掉就回到原来的页面；登录成功后自动关闭。
  VoidCallback? loginPresenter;

  /// 游客想用需要账号的功能，或在设置里点“登录网易云账号”。
  void startLogin() => loginPresenter?.call();

  /// 二维码登录：生成或复用当前二维码。
  Future<Json> createQr() async {
    final data = await api.post('/netease/auth/qr') as Json;
    return data;
  }

  /// 查询扫码状态；803 表示登录成功，Cookie 与资料已保存。
  Future<Json> checkQr() async {
    final data = await api.post('/netease/auth/qr/check') as Json;
    if (data['code'] == 803 && data['profile'] is Map) {
      _signIn((data['profile'] as Map).cast<String, dynamic>());
      unawaited(sync?.noteLogin('netease') ?? Future<void>.value());
      await _save();
      sync?.scheduleSoon();
    }
    return data;
  }

  /// 手机号登录（密码或验证码）。成功后与扫码登录一样保存凭证并进入账号。
  /// 失败抛 [NeteaseError]；需要安全验证时 code 为 [NeteaseClient.loginRisk]。
  Future<void> loginWithPhone({
    required String phone,
    String? password,
    String? captcha,
  }) async {
    final client = netease;
    final local = backend;
    if (client == null || local == null) {
      throw const NeteaseError('NOT_READY', '应用尚未初始化完成。');
    }
    await client.loginCellphone(
      phone: phone,
      password: password,
      captcha: captcha,
    );
    final profile = await local.refreshAccount();
    if (profile == null) {
      client.logout();
      throw const NeteaseError('LOGIN_FAILED', '登录失败，请重试。', 401);
    }
    _signIn(profile);
    unawaited(sync?.noteLogin('netease') ?? Future<void>.value());
    await _save();
    sync?.scheduleSoon();
  }

  /// 向手机号发送登录验证码。
  Future<void> sendLoginCaptcha(String phone) async {
    final client = netease;
    if (client == null) {
      throw const NeteaseError('NOT_READY', '应用尚未初始化完成。');
    }
    await client.sendCaptcha(phone);
  }

  Future<void> _save() async {
    final client = netease;
    if (client == null) return;
    try {
      await storage.write(key: _cookieKey, value: jsonEncode(client.cookie));
    } catch (_) {
      notice = '本次已登录。安全存储不可用，下次启动需要重新登录。';
      notifyListeners();
    }
  }

  /// 预览头像等网易云资料，失败时不影响播放。
  Future<void> refreshProfile() async {
    final value = await backend?.refreshAccount();
    if (value == null) {
      expire();
      return;
    }
    user = value;
    notifyListeners();
  }

  void _scope() => api.cacheScope = MediaCache.privateScope = user == null
      ? null
      : 'netease|${user!['userId']}';

  Future<void> logout() async {
    unawaited(sync?.noteLogout('netease') ?? Future<void>.value());
    await backend?.signOut();
    expire();
  }

  void _detach() {
    netease?.close();
    netease = null;
    backend = null;
    api.backend = null;
  }

  /// 丢掉当前网易云连接并换一个没有登录信息的，登录页才能继续申请二维码。
  void _reset() {
    _detach();
    _attach(null, bilibili?.cookie);
  }

  void expire() {
    // 游客没有会话可失效；依赖账号的功能在界面上提示登录。
    if (guest) return;
    epoch++;
    api.token = null;
    api.cacheScope = MediaCache.privateScope = null;
    user = null;
    _reset();
    notice = '网易云登录已结束，请重新登录。';
    storage.write(key: _cookieKey, value: '').catchError((_) {});
    notifyListeners();
  }
}
