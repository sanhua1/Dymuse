import 'package:dymuse/bilibili/client.dart';
import 'package:dymuse/core/api_client.dart';
import 'package:dymuse/features/catalog.dart';
import 'package:dymuse/local/backend.dart';
import 'package:dymuse/local/bilibili_backend.dart';
import 'package:dymuse/playback/audio_engine.dart';
import 'package:dymuse/playback/playback_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_backend_test.dart' show FakeClient;

class _Songs extends FakeClient {
  final asked = <List<String>>[];
  @override
  Future<Map<String, dynamic>> songDetail(Iterable<String> ids) async {
    asked.add(ids.toList());
    return {
      'songs': [
        for (final id in ids)
          if (id != '999')
            {
              'id': int.parse(id),
              'name': '歌$id',
              'ar': [
                {'id': 1, 'name': '歌手'},
              ],
              'al': {'id': 2, 'name': '专辑', 'picUrl': 'https://x/$id.jpg'},
              'dt': 1000,
            },
      ],
    };
  }
}

class _Engine implements AudioEngine {
  @override
  noSuchMethod(Invocation invocation) => switch (invocation.memberName) {
    #position || #duration => ValueNotifier(Duration.zero),
    #playing || #buffering => ValueNotifier(false),
    #completed => const Stream<void>.empty(),
    #errors => const Stream<String>.empty(),
    _ => Future<void>.value(),
  };
}

void main() {
  test('重启后队列里没有资料的歌曲会在后台补查，查不到的不重复请求', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final fake = _Songs();
    final api = ApiClient()
      ..token = '42'
      ..backend = LocalBackend(
        prefs,
        fake,
        BilibiliBackend(prefs, BilibiliClient()),
      );
    final catalog = Catalog(api);
    final controller = PlaybackController(api, catalog, _Engine());
    controller.snapshot = {
      'state': {
        'items': [
          for (final id in ['1', '2', '999']) {'id': id, 'mode': 'netease'},
        ],
        'index': 0,
      },
    };
    controller.mode = MusicMode.netease;
    controller.notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(catalog.cached(MusicMode.netease, '1')?.title, '歌1');
    expect(catalog.cached(MusicMode.netease, '2')?.artist, '歌手');
    expect(catalog.cached(MusicMode.netease, '999'), isNull);
    expect(fake.asked, [
      ['1', '2', '999'],
    ]);
    // 再次通知时，已查到的和查不到的都不再请求。
    controller.notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(fake.asked.length, 1);
  });
}
