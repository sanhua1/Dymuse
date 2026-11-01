// WebDAV 同步引擎。
//
// 取 azusa-player-mobile 的“整体打包成一个压缩文件”，去掉它“手动覆盖”的做法：
//
//   Dymuse/manifest.json                    版本、口令盐、口令校验块（只在第一次创建）
//   Dymuse/devices/<设备id>.json.gz         这台设备的完整快照（gzip 压缩的 JSON）
//   Dymuse/backup/<日期>-<设备id>.json.gz   每天一份滚动备份，保留最近 7 天，可手动回滚
//
// 每台设备只写自己的快照文件，所以不会有两台设备同时写同一个文件的冲突，
// 也不需要 If-Match 之类服务器特性，任何 WebDAV 都能用。一次同步：
//   1. 列目录（1 次请求）：看其他设备的快照有没有变化（比较 ETag）。
//   2. 只下载有变化的快照，与本机逐条合并（每条记录带修改时间，删除留墓碑）。
//   3. 本机合并结果与上次上传的内容比较，有变化才上传自己的快照。
// 没有任何变化时只有 1 次列目录请求。合并满足交换律与幂等，多台设备以任意顺序同步，
// 最终都会收敛到同一份数据；“自动选最新”体现在每条记录上，而不是整个文件。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/diag.dart';
import 'docs.dart';
import 'sync_crypto.dart';
import 'webdav.dart';

enum SyncState { off, idle, syncing, error }

/// 同步配置。
class SyncConfig {
  const SyncConfig({
    required this.url,
    required this.user,
    required this.password,
    required this.passphrase,
    this.folder = 'Dymuse',
  });
  final String url, user, password, passphrase, folder;
}

/// 键排序后的 JSON，用来比较两份数据是否相同（与键的插入顺序无关）。
String canonical(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return {for (final k in keys) k: _sorted(value[k])};
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}

class SyncService extends ChangeNotifier {
  SyncService(this.prefs, {FlutterSecureStorage? storage, this.clientFactory})
    : storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          ),
      docs = LocalDocs(prefs) {
    docs.onChanged = schedule;
  }

  final SharedPreferences prefs;
  final FlutterSecureStorage storage;
  final LocalDocs docs;

  /// 测试时替换成连到本地假服务器的客户端。
  final WebDavClient Function(SyncConfig config)? clientFactory;

  // ---- 与应用其余部分的接口（由 main 接上） ----

  /// 读取本机登录凭证：`{'netease': cookie|null, 'bilibili': cookie|null}`。
  Map<String, Map<String, String>?> Function() readCredentials = () => {};

  /// 写入从其他设备同步来的凭证并使其生效（登录该账号）。
  Future<void> Function(String kind, Map<String, String> cookie)?
  writeCredentials;

  /// 读取 / 应用设置：音质、外观、强调色。
  Map<String, String> Function() readSettings = () => {};
  void Function(Map<String, String> values)? applySettings;

  /// 正在播放时不替换本机播放队列。
  bool Function() isPlaying = () => false;

  /// 同步改变了本机数据后通知界面刷新：hearts / playlists / subs / settings /
  /// credentials / `playback:<来源>`。
  void Function(Set<String> changed)? onApplied;

  // ---- 状态 ----

  SyncState state = SyncState.off;
  String? error;
  DateTime? lastSync;
  SyncConfig? _config;
  bool get configured => _config != null;
  SyncConfig? get config => _config;
  bool _running = false, _again = false;
  Timer? _debounce, _periodic;
  SyncCrypto? _crypto;
  String? _cryptoSalt;

  static const _kUrl = 'sync.url',
      _kUser = 'sync.user',
      _kFolder = 'sync.folder';
  static const _kPass = 'dymuse.sync.password', _kPhrase = 'dymuse.sync.phrase';
  static const _kinds = ['netease', 'bilibili', 'link'];
  static const _queueKeys = {
    'netease': 'aio.queue',
    'bilibili': 'aio.queue.bilibili',
  };

  /// 同步设备标识：每台设备一个，快照文件以它命名。
  String get deviceId {
    var id = prefs.getString('sync.device');
    if (id == null) {
      final bytes = SyncCrypto.randomBytes(6);
      id = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      prefs.setString('sync.device', id);
    }
    return id;
  }

  // ---- 配置 ----

  Future<void> load() async {
    final url = prefs.getString(_kUrl);
    if (url == null || url.isEmpty) return;
    try {
      final password = await storage.read(key: _kPass) ?? '';
      final phrase = await storage.read(key: _kPhrase) ?? '';
      _config = SyncConfig(
        url: url,
        user: prefs.getString(_kUser) ?? '',
        password: password,
        passphrase: phrase,
        folder: prefs.getString(_kFolder) ?? 'Dymuse',
      );
      state = SyncState.idle;
      final last = prefs.getInt('sync.last');
      if (last != null) lastSync = DateTime.fromMillisecondsSinceEpoch(last);
      _startPeriodic();
    } catch (_) {
      state = SyncState.off;
    }
    notifyListeners();
  }

  Future<void> save(SyncConfig config) async {
    final moved =
        prefs.getString(_kUrl) != config.url.trim() ||
        (prefs.getString(_kFolder) ?? '') != config.folder.trim();
    await prefs.setString(_kUrl, config.url.trim());
    await prefs.setString(_kUser, config.user.trim());
    await prefs.setString(_kFolder, config.folder.trim());
    await storage.write(key: _kPass, value: config.password);
    await storage.write(key: _kPhrase, value: config.passphrase);
    _config = SyncConfig(
      url: config.url.trim(),
      user: config.user.trim(),
      password: config.password,
      passphrase: config.passphrase,
      folder: config.folder.trim().isEmpty ? 'Dymuse' : config.folder.trim(),
    );
    _crypto = null;
    // 换了服务器或文件夹：重新比较所有设备的快照，并重新上传自己的。
    if (moved) {
      await prefs.remove('sync.peers');
      await prefs.remove('sync.uploaded');
    }
    state = SyncState.idle;
    error = null;
    _startPeriodic();
    notifyListeners();
  }

  /// 断开同步：只清除本机配置，不动远端数据，也不影响本机数据。
  Future<void> disconnect() async {
    _debounce?.cancel();
    _periodic?.cancel();
    await prefs.remove(_kUrl);
    await prefs.remove('sync.last');
    await prefs.remove('sync.peers');
    await prefs.remove('sync.uploaded');
    await storage.write(key: _kPass, value: '');
    await storage.write(key: _kPhrase, value: '');
    _config = null;
    _crypto = null;
    lastSync = null;
    state = SyncState.off;
    error = null;
    notifyListeners();
  }

  void _startPeriodic() {
    _periodic?.cancel();
    _periodic = Timer.periodic(const Duration(minutes: 5), (_) {
      unawaited(sync());
    });
  }

  /// 本机数据变化后稍等再同步，合并连续的修改。
  void schedule() {
    if (_config == null) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 15), () => unawaited(sync()));
  }

  /// 登录凭证变化后尽快同步（几秒内），让另一台设备马上能取到。
  void scheduleSoon() {
    if (_config == null) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () => unawaited(sync()));
  }

  /// 登出/登录时记一笔：登出的设备不会被其他设备的凭证重新登录。
  Future<void> noteLogout(String kind) =>
      prefs.setBool('sync.skipcred.$kind', true);
  Future<void> noteLogin(String kind) => prefs.remove('sync.skipcred.$kind');

  // ---- 同步 ----

  /// 立即同步。返回是否成功；失败原因在 [error]。
  Future<bool> sync() async {
    final config = _config;
    if (config == null) return false;
    if (_running) {
      _again = true;
      return true;
    }
    _running = true;
    state = SyncState.syncing;
    error = null;
    notifyListeners();
    final changed = <String>{};
    WebDavClient? dav;
    try {
      dav =
          clientFactory?.call(config) ??
          WebDavClient(config.url, config.user, config.password);
      await _run(dav, config, changed);
      lastSync = DateTime.now();
      await prefs.setInt('sync.last', lastSync!.millisecondsSinceEpoch);
      state = SyncState.idle;
    } on DavException catch (e) {
      Diag.log('sync failed: ${e.code} ${e.message}');
      error = e.message;
      state = SyncState.error;
    } on SyncCryptoError catch (e) {
      error = e.message;
      state = SyncState.error;
    } catch (e) {
      error = '同步失败：$e';
      state = SyncState.error;
    } finally {
      dav?.close();
      _running = false;
    }
    notifyListeners();
    if (changed.isNotEmpty) onApplied?.call(changed);
    if (_again) {
      _again = false;
      schedule();
    }
    return state != SyncState.error;
  }

  Future<void> _run(
    WebDavClient dav,
    SyncConfig config,
    Set<String> changed,
  ) async {
    final root = config.folder;
    await dav.ensureDir(root);
    await dav.ensureDir('$root/devices');
    final crypto = await _prepareCrypto(dav, config);
    final me = deviceId;

    // 1. 其他设备的快照：每台设备取名字里时间最大的那一份，且只取变了的。
    //    文件名带上传时间（`<设备>.<毫秒>.json.gz`），每次上传都是新文件、从不覆盖：
    //    有些 WebDAV 服务器对已存在的文件不会真正覆盖（只留下带随机后缀的临时文件），
    //    覆盖式写入会让其他设备永远读到旧版本。
    final listing = await dav.list('$root/devices');
    final latest = <String, ({int ts, DavEntry entry})>{};
    for (final entry in listing) {
      final m = _snapshotName.firstMatch(entry.name);
      if (entry.isDir || m == null) continue;
      final ts = int.tryParse(m.group(2) ?? '') ?? 0;
      final known = latest[m.group(1)!];
      if (known == null || ts > known.ts) {
        latest[m.group(1)!] = (ts: ts, entry: entry);
      }
    }
    Diag.log(
      'sync listing: ${listing.length} files, devices=${latest.keys.toList()}',
    );
    final seen = _peers();
    var peersChanged = false;
    for (final item in latest.entries) {
      final id = item.key, entry = item.value.entry;
      final tag = '${entry.name}|${entry.tag}';
      if (id == me || seen[id] == tag) continue;
      final file = await dav.get('$root/devices/${entry.name}');
      if (file == null) continue;
      J snapshot;
      try {
        snapshot = (jsonDecode(utf8.decode(gzip.decode(file.bytes))) as Map)
            .cast<String, dynamic>();
      } catch (_) {
        // 损坏的快照跳过，不影响其他设备；该设备下次重新上传后会恢复。
        continue;
      }
      if ((snapshot['v'] as num?) != 1) continue;
      Diag.log(
        'sync peer ${entry.name} ${file.bytes.length}B '
        'creds=${((snapshot['credentials'] as Map?) ?? {}).keys.toList()}',
      );
      await _absorb(snapshot, crypto, changed);
      seen[id] = tag;
      peersChanged = true;
    }
    if (peersChanged) {
      await prefs.setString('sync.peers', jsonEncode(seen));
    }

    // 2. 本机快照与上次上传的比较，有变化才上传。
    final snapshot = await _snapshot(
      crypto,
      firstDevice: latest.keys.every((id) => id == me),
    );
    final digest = hash.sha256
        .convert(utf8.encode(canonical(snapshot)))
        .toString();
    final missing = !latest.containsKey(me);
    Diag.log(
      'sync local creds=${((snapshot['credentials'] as Map?) ?? {}).keys.toList()} '
      'missing=$missing changed=${digest != prefs.getString('sync.uploaded')}',
    );
    if (missing || digest != prefs.getString('sync.uploaded')) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = prefs.getInt('sync.uploadTs') ?? 0;
      final stamp = now > last ? now : last + 1;
      snapshot['ts'] = stamp;
      final bytes = Uint8List.fromList(
        gzip.encode(utf8.encode(jsonEncode(snapshot))),
      );
      final name = '$me.$stamp.json.gz';
      await dav.put('$root/devices/$name', bytes);
      await prefs.setInt('sync.uploadTs', stamp);
      await prefs.setString('sync.uploaded', digest);
      Diag.log('sync uploaded $name ${bytes.length}B');
      await _dailyBackup(dav, root, bytes);
      await _cleanOwn(dav, root, listing, keep: name);
    }
  }

  static final _snapshotName = RegExp(
    r'^([0-9a-f]+)(?:\.(\d{10,}))?\.json\.gz$',
  );

  /// 新快照写成功后，删掉本机旧版本（以及旧做法留下的同名文件和服务器的临时文件）。
  /// 删除失败不影响同步。
  Future<void> _cleanOwn(
    WebDavClient dav,
    String root,
    List<DavEntry> listing, {
    required String keep,
  }) async {
    final me = deviceId;
    for (final entry in listing) {
      final mine =
          entry.name.startsWith('$me.json.gz') ||
          RegExp('^$me\\.\\d{10,}\\.json\\.gz').hasMatch(entry.name);
      if (!mine || entry.name == keep || entry.isDir) continue;
      try {
        await dav.delete('$root/devices/${entry.name}');
      } on DavException {
        // 留着也无妨：读取时只看每台设备时间最大的那一份。
      }
    }
  }

  J _peers() {
    final raw = prefs.getString('sync.peers');
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  // ---- 每日备份 ----

  /// 每天第一次上传时顺带存一份，保留最近 7 天；出了问题可以手动下载回滚。
  Future<void> _dailyBackup(
    WebDavClient dav,
    String root,
    Uint8List bytes,
  ) async {
    final now = DateTime.now();
    final day =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    if (prefs.getString('sync.backup.day') == day) return;
    try {
      await dav.ensureDir('$root/backup');
      await dav.put('$root/backup/$day-$deviceId.json.gz', bytes);
      await prefs.setString('sync.backup.day', day);
      final mine =
          (await dav.list('$root/backup'))
              .where((e) => e.name.endsWith('-$deviceId.json.gz'))
              .map((e) => e.name)
              .toList()
            ..sort();
      final extra = mine.length - 7;
      for (var i = 0; i < extra; i++) {
        await dav.delete('$root/backup/${mine[i]}');
      }
    } on DavException {
      // 备份失败不影响同步，明天再试。
    }
  }

  // ---- 口令与清单 ----

  Future<SyncCrypto> _prepareCrypto(WebDavClient dav, SyncConfig config) async {
    if (config.passphrase.isEmpty) {
      throw const SyncCryptoError('请设置同步密码（用来加密登录凭证）。');
    }
    final path = '${config.folder}/manifest.json';
    for (var attempt = 0; attempt < 2; attempt++) {
      final file = await dav.get(path);
      if (file == null) {
        final salt = SyncCrypto.randomBytes(16);
        final crypto = await SyncCrypto.derive(config.passphrase, salt);
        final manifest = {
          'v': 1,
          'app': 'dymuse',
          'kdf': {
            'alg': 'pbkdf2-hmac-sha256',
            'iter': SyncCrypto.iterations,
            'salt': base64.encode(salt),
          },
          'check': crypto.checkBlock(),
          'created': DateTime.now().millisecondsSinceEpoch,
        };
        try {
          await dav.put(
            path,
            Uint8List.fromList(utf8.encode(jsonEncode(manifest))),
            mustNotExist: true,
          );
        } on DavConflict {
          // 另一台设备刚好同时创建了：重读它的。
          continue;
        }
        _crypto = crypto;
        _cryptoSalt = base64.encode(salt);
        return crypto;
      }
      final J manifest;
      try {
        manifest = (jsonDecode(utf8.decode(file.bytes)) as Map)
            .cast<String, dynamic>();
      } catch (_) {
        throw const DavException('SYNC_CORRUPT', '远端数据格式不正确。');
      }
      if ((manifest['v'] as num?) != 1) {
        throw const DavException('SYNC_VERSION', '远端数据来自更新版本的 Dymuse，请先升级应用。');
      }
      final kdf = (manifest['kdf'] as Map).cast<String, dynamic>();
      final saltText = '${kdf['salt']}';
      if (_crypto != null && _cryptoSalt == saltText) return _crypto!;
      final crypto = await SyncCrypto.derive(
        config.passphrase,
        Uint8List.fromList(base64.decode(saltText)),
        rounds: (kdf['iter'] as num).toInt(),
      );
      if (!crypto.verify((manifest['check'] as Map).cast<String, dynamic>())) {
        throw const SyncCryptoError('同步密码不正确。');
      }
      _crypto = crypto;
      _cryptoSalt = saltText;
      return crypto;
    }
    throw const DavConflict();
  }

  // ---- 本机快照 ----

  J? _readQueue(String mode) {
    final raw = prefs.getString(_queueKeys[mode]!);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  static String _cookieText(Map<String, String>? cookie) {
    if (cookie == null || cookie.isEmpty) return '';
    final keys = cookie.keys.toList()..sort();
    return jsonEncode({for (final k in keys) k: cookie[k]});
  }

  /// 本机凭证有变化（刚登录）才重新加密；否则沿用上次的密文，避免每次同步密文都不同。
  Future<J> _credentials(SyncCrypto crypto) async {
    final local = readCredentials();
    final result = <String, dynamic>{};
    for (final kind in _kinds) {
      final text = _cookieText(local[kind]);
      final base = prefs.getString('sync.cred.base.$kind') ?? '';
      if (text != base) {
        await prefs.setString('sync.cred.base.$kind', text);
        if (text.isNotEmpty) {
          // 退出登录（空）只在本机生效，不传播。
          final ts = DateTime.now().millisecondsSinceEpoch;
          await prefs.setInt('sync.cred.ts.$kind', ts);
          await prefs.setString(
            'sync.cred.blob.$kind',
            jsonEncode(crypto.encrypt(text)),
          );
        }
      }
      final blob = prefs.getString('sync.cred.blob.$kind');
      if (blob != null) {
        result[kind] = {
          'ts': prefs.getInt('sync.cred.ts.$kind') ?? 0,
          'enc': jsonDecode(blob),
        };
      }
    }
    return result;
  }

  Future<J> _settings({required bool firstDevice}) async {
    final current = readSettings();
    final base = prefs.getString('sync.settings.base');
    var ts = prefs.getInt('sync.settings.ts') ?? 0;
    if (base == null) {
      // 第一次同步：已有其他设备时，本机的默认值不算“修改”，以它们为准；
      // 自己是第一台设备时，本机设置就是基准。
      ts = firstDevice ? DateTime.now().millisecondsSinceEpoch : 0;
      await prefs.setString('sync.settings.base', jsonEncode(current));
      await prefs.setInt('sync.settings.ts', ts);
    } else if (jsonEncode(current) != base) {
      ts = DateTime.now().millisecondsSinceEpoch;
      await prefs.setString('sync.settings.base', jsonEncode(current));
      await prefs.setInt('sync.settings.ts', ts);
    }
    return {'ts': ts, 'values': current};
  }

  Future<J> _snapshot(SyncCrypto crypto, {required bool firstDevice}) async => {
    'v': 1,
    'device': deviceId,
    'hearts': docs.hearts(),
    'playlists': docs.playlists(),
    'subs': docs.subs(),
    'playback': {
      for (final mode in _queueKeys.keys)
        if (_readQueue(mode) != null) mode: _readQueue(mode),
    },
    'settings': await _settings(firstDevice: firstDevice),
    'credentials': await _credentials(crypto),
  };

  // ---- 合并其他设备的快照 ----

  Future<void> _absorb(
    J snapshot,
    SyncCrypto crypto,
    Set<String> changed,
  ) async {
    J table(String key) =>
        ((snapshot[key] as Map?) ?? {}).cast<String, dynamic>();
    if (await docs.absorbHearts(table('hearts'))) changed.add('hearts');
    if (await docs.absorbPlaylists(table('playlists'))) {
      changed.add('playlists');
    }
    if (await docs.absorbSubs(table('subs'))) changed.add('subs');

    final playback = table('playback');
    for (final mode in _queueKeys.keys) {
      final remote = (playback[mode] as Map?)?.cast<String, dynamic>();
      if (remote == null) continue;
      final local = _readQueue(mode);
      final localTs = (local?['updatedAt'] as num?)?.toInt() ?? 0;
      final remoteTs = (remote['updatedAt'] as num?)?.toInt() ?? 0;
      // 正在这台设备上播放时不抢走队列，下次同步再取。
      if (remoteTs > localTs && !isPlaying()) {
        final revision = ((local?['revision'] as num?)?.toInt() ?? 0) + 1;
        await prefs.setString(
          _queueKeys[mode]!,
          jsonEncode({...remote, 'revision': revision}),
        );
        changed.add('playback:$mode');
      }
    }

    final settings = table('settings');
    final remoteSettingsTs = (settings['ts'] as num?)?.toInt() ?? 0;
    if (remoteSettingsTs > (prefs.getInt('sync.settings.ts') ?? 0)) {
      final values = {
        for (final e in ((settings['values'] as Map?) ?? {}).entries)
          '${e.key}': '${e.value}',
      };
      final differs = jsonEncode(values) != jsonEncode(readSettings());
      await prefs.setString('sync.settings.base', jsonEncode(values));
      await prefs.setInt('sync.settings.ts', remoteSettingsTs);
      if (differs) {
        applySettings?.call(values);
        changed.add('settings');
      }
    }

    final credentials = table('credentials');
    final local = readCredentials();
    for (final kind in _kinds) {
      final theirs = (credentials[kind] as Map?)?.cast<String, dynamic>();
      if (theirs == null) continue;
      final theirTs = (theirs['ts'] as num?)?.toInt() ?? 0;
      final myTs = prefs.getInt('sync.cred.ts.$kind') ?? 0;
      if (theirTs <= myTs) continue;
      final text = _cookieText(local[kind]);
      // 在这台设备上退出登录的，不被其他设备的凭证重新登录。
      if (text.isEmpty && prefs.getBool('sync.skipcred.$kind') == true) {
        continue;
      }
      final Map<String, String> cookie;
      try {
        cookie =
            (jsonDecode(
                      crypto.decrypt(
                        (theirs['enc'] as Map).cast<String, dynamic>(),
                      ),
                    )
                    as Map)
                .map((k, v) => MapEntry('$k', '$v'));
      } on SyncCryptoError {
        continue;
      }
      // 密文与时间先记下：之后本机快照带着它，其他设备也能取到。
      await prefs.setString('sync.cred.blob.$kind', jsonEncode(theirs['enc']));
      await prefs.setInt('sync.cred.ts.$kind', theirTs);
      await prefs.setString('sync.cred.base.$kind', _cookieText(cookie));
      if (_cookieText(cookie) != text) {
        await writeCredentials?.call(kind, cookie);
        changed.add('credentials');
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _periodic?.cancel();
    super.dispose();
  }
}
