import 'package:dymuse/bilibili/title_rules.dart';
import 'package:dymuse/design_system/tokens.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('主题色：预设写名字，手动颜色写十六进制，两者可互相读回', () {
    final a = Appearance();
    expect(a.accentValue, 'rose');
    a.update(custom: const Color(0xFF2090C0));
    expect(a.accentValue, '#2090C0');
    final b = Appearance()..applyAccent(a.accentValue);
    expect(b.custom, const Color(0xFF2090C0));
    // 选预设会取消手动颜色。
    b.update(accent: AccentColor.blue);
    expect(b.custom, isNull);
    expect(b.accentValue, 'blue');
    // 认不出的内容保持原样。
    b.applyAccent('乱码');
    expect(b.accentValue, 'blue');
  });

  test('手动颜色在浅色下更深、深色下更亮，保证文字对比度', () {
    final a = Appearance()..update(custom: const Color(0xFFFFFF00));
    expect(
      HSLColor.fromColor(a.accentLight).lightness,
      lessThan(HSLColor.fromColor(a.accentDark).lightness),
    );
  });

  test('订阅内与搜索结果的歌名正则是两个独立开关', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(TitleRules.of(prefs), isNotNull);
    expect(TitleRules.of(prefs, search: true), isNull);
    await prefs.setString(TitleRules.searchKey, '1');
    await prefs.setString(TitleRules.enabledKey, '0');
    expect(TitleRules.of(prefs), isNull);
    expect(TitleRules.of(prefs, search: true), isNotNull);
  });
}
