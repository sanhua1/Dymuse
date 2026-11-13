import 'package:dymuse/playback/audio_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('经代理装载时的 -1004 交给重试处理，错误流不先上报', () {
    expect(
      JustAudioEngine.reportsStreamError(-1004, loadingProxied: true),
      isFalse,
    );
  });

  test('其他错误、或不在代理装载中的 -1004 照常上报', () {
    expect(
      JustAudioEngine.reportsStreamError(-1100, loadingProxied: true),
      isTrue,
    );
    expect(
      JustAudioEngine.reportsStreamError(-1004, loadingProxied: false),
      isTrue,
    );
  });
}
