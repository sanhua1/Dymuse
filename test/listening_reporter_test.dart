import 'dart:convert';

import 'package:dymuse/core/api_client.dart';
import 'package:dymuse/features/catalog.dart';
import 'package:dymuse/playback/audio_engine.dart';
import 'package:dymuse/playback/listening_reporter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Engine implements AudioEngine {
  @override
  final PositionNotifier position = PositionNotifier();
  @override
  final duration = ValueNotifier(Duration.zero);
  @override
  final playing = ValueNotifier(true);
  @override
  final buffering = ValueNotifier(false);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      switch (invocation.memberName) {
        #completed => const Stream<void>.empty(),
        #errors => const Stream<String>.empty(),
        _ => Future<void>.value(),
      };
}

void main() {
  // 引擎在后台不推送位置（只按需读取），收听时长要靠定时取样累计。
  testWidgets('后台不推送位置时，定时取样仍累计真实收听；挂起的整段不补算', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var now = 0, pos = 0;
    final engine = _Engine();
    final reporter =
        ListeningReporter(ApiClient()..token = '42', engine, clock: () => now)
          ..preferences = prefs
          ..scope = () => 'owner';
    reporter.begin(
      const Track(id: '1', mode: MusicMode.netease, title: '歌', duration: 300),
      {'generation': 'g'},
    );
    reporter.ready();
    engine.position.live = () => Duration(milliseconds: pos);

    // 后台连续播放 60 秒。
    for (var i = 0; i < 30; i++) {
      now += 2000;
      pos += 2000;
      await tester.pump(ListeningReporter.sampleInterval);
    }
    // 进程被挂起 60 秒（期间没有任何取样），恢复后不补算这一段。
    now += 60000;
    pos += 60000;
    await tester.pump(ListeningReporter.sampleInterval);

    reporter.finish('completed');
    await tester.pump();
    final saved =
        (jsonDecode(prefs.getString('listening.pending:owner')!) as List)
            .cast<Map>()
            .single;
    expect(saved['listenedMs'], 60000);
    expect(saved['finished'], true);
    reporter.dispose();
  });
}
