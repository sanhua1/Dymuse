// 同步用的数据文档：本机存储格式与合并规则。
//
// 原则：每一条记录（一颗红心、一个歌单、歌单里的一首歌、一个订阅）都带修改时间 `ts`
// 和删除标记 `del`。合并时逐条比较：时间新的赢；时间相同时“删除”赢。
// 删除不是真的移除，而是留下墓碑，这样一台设备删掉的东西不会被另一台设备再同步回来。
// 墓碑保留 90 天后清理。合并满足交换律与幂等，所以先后同步的顺序不影响结果。
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

typedef J = Map<String, dynamic>;

/// 墓碑保留时间。
const tombstoneAge = Duration(days: 90);

int tsOf(Map? record) => (record?['ts'] as num?)?.toInt() ?? 0;

/// [a] 是否比 [b] 新：时间大者新；时间相同时删除者胜出。
bool newerThan(J a, J b) {
  final x = tsOf(a), y = tsOf(b);
  if (x != y) return x > y;
  return a['del'] == true && b['del'] != true;
}

J _copy(Object? value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();

/// 两张 `id → 记录` 的表，逐条合并；[combine] 用于记录内部还有子表的情况。
J mergeTable(
  J local,
  J remote, {
  J Function(J a, J b)? combine,
  int? now,
  bool gc = true,
}) {
  final result = <String, dynamic>{};
  final cutoff =
      (now ?? DateTime.now().millisecondsSinceEpoch) -
      tombstoneAge.inMilliseconds;
  for (final id in {...local.keys, ...remote.keys}) {
    final a = (local[id] as Map?)?.cast<String, dynamic>();
    final b = (remote[id] as Map?)?.cast<String, dynamic>();
    final J picked;
    if (a == null) {
      picked = b!;
    } else if (b == null) {
      picked = a;
    } else if (combine != null) {
      picked = combine(a, b);
    } else {
      picked = newerThan(b, a) ? b : a;
    }
    if (gc && picked['del'] == true && tsOf(picked) < cutoff) continue;
    result[id] = picked;
  }
  return result;
}

/// 歌单：名称、描述、删除状态按歌单自己的时间合并；歌单里的歌逐首合并。
J mergePlaylist(J a, J b) {
  final winner = newerThan(b, a) ? b : a;
  return {
    ...winner,
    'items': mergeTable(
      (a['items'] as Map? ?? {}).cast<String, dynamic>(),
      (b['items'] as Map? ?? {}).cast<String, dynamic>(),
    ),
  };
}

/// 订阅的元信息（名称、来源、删除）按 `ts` 合并；歌曲列表按 `tracksTs` 另算，
/// 取更新者（歌曲列表只会整体刷新，不需要逐首合并）。
J mergeSub(J a, J b) {
  final winner = newerThan(b, a) ? b : a;
  var tracksFrom = (b['tracksTs'] as num? ?? 0) > (a['tracksTs'] as num? ?? 0)
      ? b
      : a;
  // 对方只带了元信息（没有歌曲）时，不能丢掉本机的歌曲。
  if (!tracksFrom.containsKey('tracks')) {
    tracksFrom = identical(tracksFrom, a) ? b : a;
  }
  return {
    ...winner,
    'tracksTs': tracksFrom['tracksTs'],
    if (tracksFrom.containsKey('tracks')) 'tracks': tracksFrom['tracks'],
    'updatedAt': tracksFrom['updatedAt'] ?? winner['updatedAt'],
  };
}

/// 播放进度：整份快照，更新时间新者胜出（用快照里的 `updatedAt`）。
J mergePlayback(J? a, J? b) {
  if (a == null || a.isEmpty) return b ?? {};
  if (b == null || b.isEmpty) return a;
  return ((b['updatedAt'] as num? ?? 0) > (a['updatedAt'] as num? ?? 0))
      ? b
      : a;
}

/// 本机的歌单、红心、订阅存放在偏好设置里，格式即同步格式。
class LocalDocs {
  LocalDocs(this.prefs);
  final SharedPreferences prefs;

  static const heartsKey = 'bili.hearts.v2';
  static const playlistsKey = 'bili.playlists.v2';
  static const subsKey = 'bili.subs.v2';

  /// 旧版（列表）存储；只读取用于一次性迁移，不删除。
  static const _legacyHearts = 'bili.hearts';
  static const _legacyPlaylists = 'bili.playlists';
  static const _legacySubs = 'bili.subs';

  /// 任何一张表写入后调用（用于触发同步）。
  void Function()? onChanged;

  J _read(String key, J Function() migrate) {
    final raw = prefs.getString(key);
    if (raw != null) {
      try {
        return (jsonDecode(raw) as Map).cast<String, dynamic>();
      } catch (_) {
        return {};
      }
    }
    final migrated = migrate();
    if (migrated.isNotEmpty) {
      // 迁移结果落盘，之后不再读旧格式。
      prefs.setString(key, jsonEncode(migrated));
    }
    return migrated;
  }

  List<J> _legacy(String key) {
    final raw = prefs.getString(key);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).cast<J>();
    } catch (_) {
      return [];
    }
  }

  static String songId(J song) => '${song['bvid']}:${song['cid']}';

  /// 红心：`id → {ts, del, song}`。展示按 `ts` 倒序（新红心在前）。
  J hearts() => _read(heartsKey, () {
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _legacy(_legacyHearts);
    return {
      for (var i = 0; i < old.length; i++)
        songId(old[i]): {'ts': now - i, 'del': false, 'song': old[i]},
    };
  });

  /// 歌单：`id → {ts, del, name, description, items:{songId → {ts, del, order, song}}}`。
  J playlists() => _read(playlistsKey, () {
    final now = DateTime.now().millisecondsSinceEpoch;
    final result = <String, dynamic>{};
    for (final list in _legacy(_legacyPlaylists)) {
      final tracks = (list['tracks'] as List? ?? []).cast<J>();
      result['${list['id']}'] = {
        'ts': now,
        'del': false,
        'name': list['name'],
        'description': list['description'] ?? '',
        'items': {
          for (var i = 0; i < tracks.length; i++)
            songId(tracks[i]): {
              'ts': now,
              'del': false,
              'order': i,
              'song': tracks[i],
            },
        },
      };
    }
    return result;
  });

  /// 订阅：`id → {ts, del, name, customName, type, input, source, cover,
  /// tracksTs, updatedAt, tracks:[song]}`。
  J subs() => _read(subsKey, () {
    final now = DateTime.now().millisecondsSinceEpoch;
    final result = <String, dynamic>{};
    for (final sub in _legacy(_legacySubs)) {
      result['${sub['id']}'] = {
        'ts': now,
        'del': false,
        'name': sub['name'],
        'customName': sub['customName'] == true,
        'type': sub['type'],
        'input': sub['input'],
        'source': sub['source'],
        'cover': sub['cover'],
        'tracksTs': now,
        'updatedAt': sub['updatedAt'],
        'tracks': sub['tracks'],
      };
    }
    return result;
  });

  Future<void> writeHearts(J value) => _write(heartsKey, value);
  Future<void> writePlaylists(J value) => _write(playlistsKey, value);
  Future<void> writeSubs(J value) => _write(subsKey, value);

  Future<void> _write(String key, J value) async {
    await prefs.setString(key, jsonEncode(value));
    onChanged?.call();
  }

  /// 同步写回：与写入瞬间的本机数据再合并一次，避免覆盖同步期间的本地修改。
  Future<bool> absorbHearts(J incoming) async {
    final current = hearts();
    final merged = mergeTable(current, incoming);
    if (jsonEncode(merged) == jsonEncode(current)) return false;
    await prefs.setString(heartsKey, jsonEncode(merged));
    return true;
  }

  Future<bool> absorbPlaylists(J incoming) async {
    final current = playlists();
    final merged = mergeTable(current, incoming, combine: mergePlaylist);
    if (jsonEncode(merged) == jsonEncode(current)) return false;
    await prefs.setString(playlistsKey, jsonEncode(merged));
    return true;
  }

  Future<bool> absorbSubs(J incoming) async {
    final current = subs();
    final merged = mergeTable(current, incoming, combine: mergeSub);
    if (jsonEncode(merged) == jsonEncode(current)) return false;
    await prefs.setString(subsKey, jsonEncode(merged));
    return true;
  }

  static J copy(Object? value) => _copy(value);
}
