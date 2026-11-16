import 'package:dymuse/playback/audio_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('装载中的错误交给装载调用处理（-1004 重试，其他上报一次），错误流不先上报', () {
    expect(JustAudioEngine.reportsStreamError(loading: true), isFalse);
  });

  test('播放途中（不在装载）的错误照常从错误流上报', () {
    expect(JustAudioEngine.reportsStreamError(loading: false), isTrue);
  });
}
