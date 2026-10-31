import 'package:flutter_test/flutter_test.dart';
import 'package:dymuse/playback/lyric_layers.dart';
import 'package:dymuse/playback/player_view.dart' show parseLrc;

void main() {
  test('翻译与罗马音按时间戳配到原词行上，缺的行只留原词', () {
    final bundle = LyricBundle.fromResponse({
      'lrc': {'lyric': '[00:01.00]hello\n[00:05.50]world\n[00:09.00]again'},
      'tlyric': {
        'version': 3,
        'lyric': '[00:01.00]你好\n[00:05.52]世界\n[00:40.00]多余',
      },
      'romalrc': {'version': 2, 'lyric': '[00:01.00]heroo'},
      'transUser': {'nickname': '译者甲'},
    }, parseLrc);
    expect(bundle.hasTranslation, isTrue);
    expect(bundle.hasRomaji, isTrue);
    expect(bundle.lines[0]['trans'], '你好');
    expect(bundle.lines[0]['roma'], 'heroo');
    expect(bundle.lines[1]['trans'], '世界');
    expect(bundle.lines[2].containsKey('trans'), isFalse);
    expect(bundle.translator, '译者甲');
    expect(bundle.translationVersion, 3);
  });

  test('没有翻译、或翻译与原词相同时不当作有翻译', () {
    final none = LyricBundle.fromResponse({
      'lrc': {'lyric': '[00:01.00]a'},
      'tlyric': {'version': 0, 'lyric': ''},
    }, parseLrc);
    expect(none.hasTranslation, isFalse);
    final same = LyricBundle.fromResponse({
      'lrc': {'lyric': '[00:01.00]a'},
      'tlyric': {'lyric': '[00:01.00]a'},
    }, parseLrc);
    expect(same.hasTranslation, isFalse);
  });

  test('图层开关至少保留一层', () {
    expect(
      LyricLayout.toggle(LyricLayout.original, LyricLayout.original),
      LyricLayout.original,
    );
    expect(LyricLayout.decode(0), LyricLayout.original);
    expect(LyricLayout.decode(null), LyricLayout.defaults);
  });
}
