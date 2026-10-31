import 'package:dymuse/playback/audio_quality.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> detail(Iterable<String> keys) => {
    'data': {
      for (final key in ['l', 'm', 'h', 'sq', 'hr'])
        key: keys.contains(key) ? {'br': 1} : null,
    },
  };

  test('选中的档位存在就用它', () {
    final all = detail(['l', 'm', 'h', 'sq', 'hr']);
    expect(AudioQuality.hires.match(all), 'hires');
    expect(AudioQuality.standard.match(all), 'standard');
  });

  test('选中的档位不存在时降到不高于它的最高档', () {
    final noHires = detail(['l', 'm', 'h', 'sq']);
    expect(AudioQuality.hires.match(noHires), 'lossless');
    final lossy = detail(['l', 'm', 'h']);
    expect(AudioQuality.hires.match(lossy), 'exhigh');
    expect(AudioQuality.lossless.match(detail(['l', 'm'])), 'higher');
    // 只往下找，不会升档：选标准就是标准。
    expect(AudioQuality.standard.match(lossy), 'standard');
  });

  test('档位信息取不到时按所选档位请求，名称无效时回到默认档', () {
    expect(AudioQuality.lossless.match(null), 'lossless');
    expect(AudioQuality.lossless.match({'data': null}), 'lossless');
    expect(AudioQuality.fromName('nope'), AudioQuality.fallback);
    expect(AudioQuality.fromName('hires'), AudioQuality.hires);
  });

  test('默认音质按平台区分：手机省流量，桌面最高', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(AudioQuality.fallback, AudioQuality.standard);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(AudioQuality.fallback, AudioQuality.hires);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(AudioQuality.fallback, AudioQuality.hires);
    debugDefaultTargetPlatformOverride = null;
  });
}
