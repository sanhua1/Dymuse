import 'package:dymuse/bilibili/title_rules.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  samples();
  test('默认取《》里的内容，没有就原样返回', () {
    final rules = TitleRules();
    expect(rules.parse('【超燃】《千本樱》全网最强翻唱！！', '1'), '千本樱');
    expect(rules.parse('普通标题', '1'), '普通标题');
  });

  test('内置规则按 UP 主匹配（来自 azusa）', () {
    final rules = TitleRules();
    expect(rules.parse('【赫拉Kris】【翻唱】夜に駆ける', '33576761'), '夜に駆ける');
    // 其他 UP 主走通用判断：开头的【】是标签，不当歌名。
    expect(rules.parse('【赫拉Kris】【翻唱】夜に駆ける', '999'), '夜に駆ける');
  });

  test('自定义规则优先，空 UP 主适用于所有人，坏正则被跳过', () {
    final rules = TitleRules(
      custom: [
        TitleRule.simple(
          uploaders: ['33576761'],
          stripParenthesis: false,
          patterns: ['(.+)-翻唱'],
        ),
        TitleRule.simple(
          uploaders: [],
          stripParenthesis: true,
          patterns: ['[', r'^\d+\.(.+)'],
        ),
      ],
    );
    expect(rules.parse('晴天-翻唱', '33576761'), '晴天');
    expect(rules.parse('3.七里香（Live）', '5'), '七里香');
  });

  test('总开关与自定义规则存在偏好里', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(TitleRules.of(prefs)?.parse('《A》', '1'), 'A');
    await prefs.setString(TitleRules.enabledKey, '0');
    expect(TitleRules.of(prefs), isNull);
    await prefs.setString(TitleRules.enabledKey, '1');
    await TitleRules.saveCustom(prefs, [
      TitleRule.simple(
        uploaders: ['7'],
        stripParenthesis: false,
        patterns: ['«(.+)»'],
      ),
    ]);
    expect(TitleRules.of(prefs)?.parse('x«歌»y', '7'), '歌');
  });
}

void samples() {
  const cases = {
    '❀“花田里犯了错”~国风R&B女声翻唱cover王力宏': '花田里犯了错',
    '当戏腔遇上 DJ！古风蹦迪！这版 DJ『青衣』听完直接循环': '青衣',
    '想要上演一出疯狂的独角戏｜「大女優さん / いよわ」【四时小路】': '大女優さん',
    '周杰伦新歌『那天下雨了』“我应该对你唱着晴天~”【翻唱】': '那天下雨了',
    '俺唱了完整版的丨坐 忘 道 丨': '坐忘道',
    'ChiliChill「辞职信」广州Live版': '辞职信',
    '🌙 明月高悬，为何独不照我.....【我恨明月不照我】': '我恨明月不照我',
    '【粤语DJ】活着viva (DJ女声版)「年轻得碰着谁亦能像威化般干脆，快…」': '活着viva',
    '【Lilith】活着VIVA Cover.谢霆锋': '活着VIVA',
    '【双女】“我就当我的爱是罪~是东流水❤️”「锁」': '锁',
    '“十年寒窗无人晓 儿郎志气高.”|《八千里路明月照dj》降调': '八千里路明月照dj',
    '“感我此言良久立.”|《琵琶行（Remix版）》0.97x  伴奏弱人声': '琵琶行',
    '“每当我找不到存在的意义.”|《夜空中最亮的星dj》0.87x': '夜空中最亮的星dj',
    '⚡️上岸の小曲📜八千里路明月照DJ⚡️【铁豆钢蛋杯】': '八千里路明月照DJ',
    '【洛天依AI】“梦里依旧，《明月天涯》”【原创PV付】【2.0】': '明月天涯',
  };
  group('截图里的标题', () {
    cases.forEach((title, name) {
      test(title, () => expect(guessSongName(title), name));
    });
  });
}
