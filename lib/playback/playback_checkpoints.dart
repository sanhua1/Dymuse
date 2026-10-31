import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/api_client.dart';
import '../features/catalog.dart';

/// 只保留待同步的位置标记，不保存凭证、音频链接或整份队列。
class PlaybackCheckpoints {
  PlaybackCheckpoints(this.preferences, {required this.scope});
  final SharedPreferences preferences;
  final String? Function() scope;
  String? _key(MusicMode mode) {
    final owner = scope();
    return owner == null ? null : 'playback.pending:$owner:${mode.name}';
  }

  Future<void> save(MusicMode mode, Json snapshot, int position) async {
    final key = _key(mode), state = snapshot['state'] as Json;
    final items = state['items'] as List? ?? [];
    final index = (state['index'] as num? ?? 0).toInt();
    if (key == null || index < 0 || index >= items.length) return;
    await preferences.setString(
      key,
      jsonEncode({
        'generation': snapshot['generation'],
        'index': index,
        'id': items[index]['id'],
        'kind': items[index]['kind'],
        'positionMs': position,
      }),
    );
  }

  /// 仅同一账号、设备、曲库和同代同项队列可以恢复本机标记。
  bool apply(MusicMode mode, Json snapshot) {
    final key = _key(mode),
        raw = key == null ? null : preferences.getString(key);
    if (raw == null || raw.isEmpty) return false;
    try {
      final marker = jsonDecode(raw) as Json, state = snapshot['state'] as Json;
      final items = state['items'] as List, index = marker['index'] as int;
      if (marker['generation'] != snapshot['generation'] ||
          index < 0 ||
          index >= items.length ||
          marker['id'] != items[index]['id'] ||
          marker['kind'] != items[index]['kind']) {
        return false;
      }
      final position = marker['positionMs'] as int;
      if (position < 0 || position > 604800000) return false;
      state['index'] = index;
      state['positionMs'] = position;
      state['playing'] = false;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> clear(MusicMode mode) async {
    final key = _key(mode);
    if (key != null) await preferences.setString(key, '');
  }
}
