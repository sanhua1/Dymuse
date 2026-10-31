import 'package:dymuse/playback/audio_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('后台按需读取播放器位置，回到前台恢复推送值', () {
    final position = PositionNotifier();
    var notified = 0;
    position.addListener(() => notified++);
    position.value = const Duration(seconds: 3);
    expect(position.value, const Duration(seconds: 3));
    expect(notified, 1);

    var real = const Duration(seconds: 40);
    position.live = () => real;
    expect(position.value, const Duration(seconds: 40));
    real = const Duration(seconds: 41);
    expect(position.value, const Duration(seconds: 41));
    expect(notified, 1, reason: '后台读取不触发通知');

    position.live = null;
    position.value = real;
    expect(position.value, const Duration(seconds: 41));
    expect(notified, 2);
  });
}
