import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 缓存分区：歌曲音频；封面图片与接口数据共用一个容量上限。
enum CacheKind { audio, images, data }

enum CacheGroup {
  audio('歌曲缓存', [CacheKind.audio]),
  artwork('封面与请求缓存', [CacheKind.images, CacheKind.data]);

  const CacheGroup(this.label, this.kinds);
  final String label;
  final List<CacheKind> kinds;
}

/// 设备本地的磁盘缓存，位于系统缓存目录（系统空间不足时也可能清理）。
/// 每组有容量上限（默认 500 MB，可在设置里调整），超出后按最近使用时间自动淘汰最旧的文件；
/// 读取命中会刷新文件时间。缓存只是加速，读写失败一律当作未命中。
class MediaCache extends ChangeNotifier {
  MediaCache(this.root, this.preferences, {this.audioEnabled = true});
  static MediaCache? instance;

  /// 当前服务与用户，用于隔离带认证的私人封面缓存。
  static String? privateScope;
  static const defaultLimitMb = 500;
  static const limitChoices = [200, 500, 1024, 2048, 5120];

  static Future<MediaCache?> open(
    SharedPreferences preferences, {
    bool audioEnabled = true,
  }) async {
    try {
      final base = await getApplicationCacheDirectory();
      return instance = MediaCache(
        Directory('${base.path}/dymuse_cache'),
        preferences,
        audioEnabled: audioEnabled,
      );
    } catch (_) {
      return null;
    }
  }

  final Directory root;
  final SharedPreferences preferences;

  /// 只有 Apple 引擎接入了歌曲缓存；Windows 不显示也不使用。
  final bool audioEnabled;
  final Map<CacheGroup, Timer> _trims = {};

  Directory directory(CacheKind kind) => Directory('${root.path}/${kind.name}');
  File file(CacheKind kind, String key) =>
      File('${directory(kind).path}/${_hash(key)}');

  int limitMb(CacheGroup group) =>
      preferences.getInt('cache.${group.name}.mb') ?? defaultLimitMb;

  Future<void> setLimit(CacheGroup group, int mb) async {
    await preferences.setInt('cache.${group.name}.mb', mb);
    await trim(group);
  }

  Future<Uint8List?> read(CacheKind kind, String key) async {
    final target = file(kind, key);
    try {
      final bytes = await target.readAsBytes();
      _touch(target);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 先写临时文件再改名，读到的不会是写了一半的内容。
  Future<void> write(CacheKind kind, String key, List<int> bytes) async {
    final target = file(kind, key);
    try {
      await target.parent.create(recursive: true);
      final temporary = File('${target.path}.${_hash('$key${bytes.length}')}');
      await temporary.writeAsBytes(bytes, flush: false);
      await temporary.rename(target.path);
      _scheduleTrim(kind);
    } catch (_) {
      // 磁盘满或目录不可写时不缓存。
    }
  }

  /// 已完整缓存的歌曲（just_audio 下载完成后才把 .part 改名为正式文件）。
  bool audioCached(String key) {
    if (!audioEnabled) return false;
    final target = file(CacheKind.audio, key);
    if (!target.existsSync()) return false;
    _touch(target);
    return true;
  }

  /// 歌曲开始播放后调用：下载在后台进行，稍后再按上限淘汰。
  void audioStarted() => _scheduleTrim(CacheKind.audio);

  Future<int> usage(CacheGroup group) async {
    var total = 0;
    for (final entry in await _entries(group)) {
      total += entry.size;
    }
    return total;
  }

  /// 用户在设置里点“清除”时调用；正在下载的歌曲保留。
  Future<void> clear(CacheGroup group) async {
    for (final entry in await _entries(group)) {
      if (entry.path.endsWith('.part')) continue;
      await _delete(entry.path);
    }
    notifyListeners();
  }

  /// 按最近使用时间淘汰到上限以内。10 分钟内用过的文件不淘汰，
  /// 避免删掉正在播放或刚检查过“已缓存”的歌曲；遗留超过一天的未完成下载一并删除。
  Future<void> trim(CacheGroup group) async {
    final entries = await _entries(group);
    final now = DateTime.now();
    var total = entries.fold<int>(0, (sum, entry) => sum + entry.size);
    final limit = limitMb(group) * 1024 * 1024;
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in entries) {
      final age = now.difference(entry.modified);
      if (entry.path.endsWith('.part')) {
        if (age > const Duration(days: 1)) {
          await _delete(entry.path);
          total -= entry.size;
        }
        continue;
      }
      if (entry.path.endsWith('.mime')) continue;
      if (total <= limit) continue;
      if (age < const Duration(minutes: 10)) continue;
      await _delete(entry.path);
      total -= entry.size;
      final mime = File('${entry.path}.mime');
      if (mime.existsSync()) {
        total -= mime.lengthSync();
        await _delete(mime.path);
      }
    }
    notifyListeners();
  }

  void _scheduleTrim(CacheKind kind) {
    final group = CacheGroup.values.firstWhere((g) => g.kinds.contains(kind));
    _trims[group]?.cancel();
    _trims[group] = Timer(const Duration(seconds: 20), () => trim(group));
  }

  Future<List<({String path, int size, DateTime modified})>> _entries(
    CacheGroup group,
  ) async {
    final result = <({String path, int size, DateTime modified})>[];
    for (final kind in group.kinds) {
      final folder = directory(kind);
      try {
        if (!await folder.exists()) continue;
        await for (final item in folder.list(followLinks: false)) {
          if (item is! File) continue;
          final stat = await item.stat();
          result.add((
            path: item.path,
            size: stat.size,
            modified: stat.modified,
          ));
        }
      } catch (_) {
        // 目录读失败时按空处理。
      }
    }
    return result;
  }

  Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  void _touch(File target) {
    unawaited(target.setLastModified(DateTime.now()).catchError((Object _) {}));
  }

  @override
  void dispose() {
    for (final timer in _trims.values) {
      timer.cancel();
    }
    super.dispose();
  }

  /// 64 位 FNV-1a，作为文件名；不引入额外哈希依赖。
  static String _hash(String value) {
    var hash = 0xcbf29ce484222325;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
