import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../core/api_client.dart';
import '../design_system/components.dart';
import '../playback/playback_controller.dart';
import 'catalog.dart';

/// B 站歌曲的“跳转到…”：查出这个视频所属的合集、多 P 视频、UP 主投稿，选一个进入
/// （进入后可添加订阅）。列表的“···”菜单与播放页点歌名、UP 主名共用这一份。
class BilibiliJump {
  BilibiliJump._();

  /// 刚查过的来源按 BV 号留 10 分钟：在播放页来回点歌名不会反复请求 B 站（会被限流）。
  static final _cache = <String, ({DateTime at, List<Json> sources})>{};
  static bool _busy = false;

  /// 播放页点歌名或 UP 主名的动作；当前不是 B 站歌曲、或没有打开来源的回调时为 null。
  static VoidCallback? forPlayer(
    BuildContext context,
    PlaybackController controller,
    ValueChanged<Collection>? onOpen,
  ) {
    final track = controller.track;
    if (track == null || track.mode != MusicMode.bilibili || onOpen == null) {
      return null;
    }
    return () => unawaited(
      open(context, api: controller.api, track: track, onOpen: onOpen),
    );
  }

  static Future<void> open(
    BuildContext context, {
    required ApiClient api,
    required Track track,
    required ValueChanged<Collection> onOpen,
  }) async {
    if (_busy) return;
    _busy = true;
    try {
      final sources = await _sourcesOf(api, track);
      if (!context.mounted) return;
      final picked = await showChoiceSheet<Json>(
        context,
        title: '跳转到',
        message: sources.isEmpty ? '这个视频没有可以跳转的来源。' : null,
        choices: [
          for (final item in sources)
            ('${item['typeLabel']} · ${item['label']}', item),
        ],
      );
      if (picked == null) return;
      onOpen(
        Collection(
          '${picked['input']}',
          '${picked['label']}',
          '${picked['typeLabel']}',
          track.cover,
          'source',
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialog) => CupertinoAlertDialog(
          title: const Text('无法查询'),
          content: Text(readableError(error)),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('好'),
            ),
          ],
        ),
      );
    } finally {
      _busy = false;
    }
  }

  static Future<List<Json>> _sourcesOf(ApiClient api, Track track) async {
    final bvid = track.id.split(':').first;
    final hit = _cache[bvid];
    if (hit != null &&
        DateTime.now().difference(hit.at) < const Duration(minutes: 10)) {
      return hit.sources;
    }
    final data =
        await api.get(
              '/bilibili/tracks/${Uri.encodeComponent(track.id)}/sources',
            )
            as Json;
    final sources = (data['items'] as List? ?? const []).cast<Json>();
    _cache[bvid] = (at: DateTime.now(), sources: sources);
    if (_cache.length > 20) _cache.remove(_cache.keys.first);
    return sources;
  }
}
