// B 站歌名识别：从花哨的视频标题里取出真正的歌名。
// 做法移植自 azusa-player-mobile（src/utils/re.ts）：按 UP 主 ID 匹配一组规则，规则由若干步骤组成
// （1 = 依次用正则取第一个有内容的捕获组；2 = 去掉最后一个括号及其后的内容），
// 都不匹配时默认取《》里的内容。内置规则也来自 azusa 的 rejson.json。
// 在此之上增加用户自定义规则：先于内置规则匹配，UP 主 ID 留空表示适用于所有 UP 主。
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const _extractWith = 1, _stripParenthesis = 2;

class TitleRule {
  const TitleRule({this.uploaders = const [], this.operations = const []});
  final List<String> uploaders;
  final List<List<Object?>> operations;

  bool matches(String uploader) =>
      uploaders.isEmpty || uploaders.contains(uploader);

  Map<String, dynamic> toJson() => {
    'uploaders': uploaders,
    'operations': operations,
  };

  static TitleRule? fromJson(Object? json) {
    if (json is! Map) return null;
    final ups = json['uploaders'], ops = json['operations'];
    if (ups is! List || ops is! List) return null;
    return TitleRule(
      uploaders: [for (final u in ups) '$u'],
      operations: [
        for (final op in ops)
          if (op is List && op.isNotEmpty) List<Object?>.of(op),
      ],
    );
  }

  /// 界面用的简单形式：可选“先去括号”，再按每行一条正则取歌名。
  factory TitleRule.simple({
    required List<String> uploaders,
    required bool stripParenthesis,
    required List<String> patterns,
  }) => TitleRule(
    uploaders: uploaders,
    operations: [
      if (stripParenthesis) [_stripParenthesis],
      if (patterns.isNotEmpty) [_extractWith, patterns],
    ],
  );

  bool get stripsParenthesis =>
      operations.any((op) => op.first == _stripParenthesis);

  List<String> get patterns => [
    for (final op in operations)
      if (op.first == _extractWith && op.length > 1 && op[1] is List)
        for (final p in op[1] as List) '$p',
  ];
}

class TitleRules {
  TitleRules({List<TitleRule> custom = const [], bool builtin = true})
    : _rules = [...custom, if (builtin) ...defaults];

  final List<TitleRule> _rules;
  final Map<String, RegExp?> _compiled = {};

  static final List<TitleRule> defaults = [
    for (final item in jsonDecode(_builtinJson) as List)
      ?TitleRule.fromJson(item),
  ];

  /// 识别歌名；没有匹配或没取到时原样返回标题。
  String parse(String title, String uploader) {
    for (final rule in _rules) {
      if (rule.matches(uploader)) {
        return _bracketed(_run(rule, title));
      }
    }
    return _bracketed(title);
  }

  String _run(TitleRule rule, String title) {
    var value = title;
    for (final op in rule.operations) {
      switch (op.first) {
        case _extractWith:
          value = _firstMatch(value, op.length > 1 ? op[1] : null);
        case _stripParenthesis:
          value = _firstMatch(value, const [r'(.+)[（(].+']);
      }
    }
    return value;
  }

  String _firstMatch(String value, Object? patterns) {
    if (patterns is! List) return value;
    for (final pattern in patterns) {
      final regex = _compiled.putIfAbsent('$pattern', () {
        try {
          return RegExp('$pattern');
        } on FormatException {
          return null; // 写错的正则直接跳过
        }
      });
      final group = regex?.firstMatch(value)?.group(1);
      if (group != null && group.isNotEmpty) return group;
    }
    return value;
  }

  static String _bracketed(String name) => guessSongName(name);

  // ---- 本机设置 ----

  static const enabledKey = 'bili.titleParse';
  static const customKey = 'bili.titleRules';
  static const searchKey = 'bili.titleSearch';

  /// 默认开启；用户可在设置里关闭。
  static bool enabled(SharedPreferences prefs) =>
      prefs.getString(enabledKey) != '0';

  /// 搜索结果是否也识别歌名；默认关闭，只作用于订阅、红心、歌单。
  static bool searchEnabled(SharedPreferences prefs) =>
      prefs.getString(searchKey) == '1';

  static List<TitleRule> custom(SharedPreferences prefs) {
    final raw = prefs.getString(customKey);
    if (raw == null) return [];
    try {
      return [
        for (final item in jsonDecode(raw) as List) ?TitleRule.fromJson(item),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveCustom(
    SharedPreferences prefs,
    List<TitleRule> rules,
  ) => prefs.setString(
    customKey,
    jsonEncode([for (final rule in rules) rule.toJson()]),
  );

  static String? _cachedRaw;
  static TitleRules? _cached;

  /// 按当前设置取解析器；设置没变时复用（正则只编译一次）。
  /// [search] 为真时看“搜索结果正则”开关，否则看“订阅内正则”开关；两者互相独立。
  static TitleRules? of(SharedPreferences prefs, {bool search = false}) {
    if (!(search ? searchEnabled(prefs) : enabled(prefs))) return null;
    final raw = prefs.getString(customKey) ?? '';
    if (_cached == null || _cachedRaw != raw) {
      _cached = TitleRules(custom: custom(prefs));
      _cachedRaw = raw;
    }
    return _cached;
  }
}

const _builtinJson = r'''[
  {
    "uploaders": ["442289603"],
    "operations": [[1, ["\\d\\. ?(.+)-.+"]]]
  },
  {
    "uploaders": ["1902398"],
    "operations": [
      [2],
      [
        1,
        [
          "】(.+) \\d+\\/\\d+\\/\\d+",
          "】(.+) \\d+\\/\\d+",
          "】(.+) \\d+\\.\\d+",
          "】(.+)\\d+\\.\\d+",
          "】(.+)"
        ]
      ]
    ]
  },
  {
    "uploaders": ["steria.vplayer.tk"],
    "operations": [[2], [1, ["\\d+-\\d+-\\d+-(.+)", "\\d+-\\d+-(.+)"]]]
  },
  {
    "uploaders": ["5053504", "3493085134719196"],
    "operations": [
      [2],
      [2],
      [
        1,
        [
          "\\d*_(.+) \\(?.*by .+",
          "\\d*_(.+)",
          "[.+][.+] (.+) \\d+",
          "[.+] (.+) \\d+"
        ]
      ]
    ]
  },
  {
    "uploaders": ["94558176"],
    "operations": [
      [1, ["【.+】《(.+)》/, /《(.+)》", "《(.+)》", "【.+】(.+)"]],
      [2]
    ]
  },
  {
    "uploaders": ["33576761"],
    "operations": [
      [1, ["【赫拉Kris】【.+】(.+)", "【赫拉Kris.*】(.+)", "\\d+-(.+)-.+"]]
    ]
  },
  {
    "uploaders": ["170066"],
    "operations": [
      [1, [" - (.+)", "【诺莺Nox】[\\d+] (.+)", "【诺莺Nox】(.+)", "(.+) w\\/"]]
    ]
  },
  {
    "uploaders": ["355371630"],
    "operations": [[2], [1, ["\\d+\\.(.+)-\\d+", "\\d+\\.(.+)"]]]
  },
  {
    "uploaders": ["3421497"],
    "operations": [[2], [2], [1, ["【.+】(.+)"]]]
  },
  {
    "uploaders": ["590096", "3546606146161263"],
    "operations": [[2], [1, ["\\d+ (.+)", "\\d+-(.+)"]]]
  },
  {
    "uploaders": ["1912892773"],
    "operations": [[2], [1, ["《(.+)》", "\\d+.+-(.+)", "\\d+(.+)"]]]
  },
  {
    "uploaders": ["7405415"],
    "operations": [
      [2],
      [
        1,
        [
          "《(.+)/(.+)》",
          "【.+】(.+)",
          "\\d+\\.\\d+ (.+)/",
          "\\d+\\.\\d+ (.+)",
          "\\d+\\.(.+) - .+",
          "\\d+\\.(.+)/",
          "\\d+\\.(.+)",
          "(.+)/",
          "《(.+)》"
        ]
      ]
    ]
  },
  {
    "uploaders": ["63326"],
    "operations": [
      [2],
      [
        1,
        [
          "\\d+-『(.+)』-\\d",
          "\\d+-(.+)-\\d",
          "\\d+-(.+)",
          "『露米Lumi』-『(.+)』 *『.+』",
          "『.+』 *- *『(.+)』",
          "『.+』 *『(.+)』",
          "『.+』.+『(.+)』",
          "『.+』-(.+)-\\d",
          "『.+』-(.+)",
          "『(.+)』"
        ]
      ]
    ]
  },
  {
    "uploaders": ["159910988"],
    "operations": [[2], [1, ["(.+)【.+】"]]]
  },
  {
    "uploaders": ["287837"],
    "operations": [[2], [1, ["【.+】(.+)"]]]
  },
  {
    "uploaders": ["9979698"],
    "operations": [
      [2],
      [
        1,
        [
          "【.+】(.+)",
          "\\d+\\.(.+)",
          "\\d+ (.+)",
          "第.+首(.+)",
          "(.+) \\/ HACHI",
          "『(.+)』"
        ]
      ]
    ]
  },
  {
    "uploaders": ["1304703724"],
    "operations": [[2], [1, ["\\d+\\.\\d+(.+)"]]]
  },
  {
    "uploaders": ["8136522"],
    "operations": [[2], [1, ["【.+】(.+)"]]]
  },
  {
    "uploaders": ["5085531"],
    "operations": [
      [2],
      [1, ["【.+】\\d+(.+)", "(\\D+)\\d+", "【Pomelo安妮】(.+)"]]
    ]
  },
  {
    "uploaders": ["344906417"],
    "operations": [[2], [1, ["【.+】(.+)"]]]
  },
  {
    "uploaders": ["7191181", "693579584", "1902398", "440555", "22333688"],
    "operations": [
      [2],
      [1, ["【.+】(.+)\\d+\\.\\d+", "【.+】(.+)", "《(.+)》"]]
    ]
  },
  {
    "uploaders": ["3493084803369305"],
    "operations": [
      [2],
      [1, ["\\d+\\. (.+)", "【.+】(.+)\\d+\\.\\d+", "【.+】(.+)"]]
    ]
  },
  {
    "uploaders": ["1190296645"],
    "operations": [
      [2],
      [
        1,
        [
          "【黑泽诺亚】【歌切】(.+) - (.+)",
          "【黑泽诺亚】【歌切】(.+)-(.+)",
          "【黑泽诺亚】【歌切】(.+)",
          "【黑泽诺亚NOIR】(.+) - (.+)",
          "【黑泽诺亚NOIR】(.+)",
          "【黑泽诺亚】【.+】(.+)",
          "【黑泽诺亚】(.+)",
          "【歌切】(.+)-(.+)",
          "(.+) - (.+)"
        ]
      ]
    ]
  },
  {
    "uploaders": ["284940670"],
    "operations": [[2], [1, ["【.+】(.+)-.+"]]]
  },
  {
    "uploaders": ["1035062789"],
    "operations": [
      [2],
      [1, ["(.+) - ", "(.+) w/ ", "【.+】\\d+\\.\\d+ (.+)", "【.+】(.+)"]]
    ]
  },
  {
    "uploaders": ["2509376"],
    "operations": [[2], [1, [" - (.+) \\d+\\.\\d+", " - (.+)"]]]
  },
  {
    "uploaders": ["731556"],
    "operations": [[2], [1, ["『(.+)』", "「.+」(.+)", "【.+】(.+)"]]]
  },
  {
    "uploaders": ["1632389"],
    "operations": [[2], [1, [".+ - (.+)", ".+-(.+)"]]]
  },
  {
    "uploaders": ["1020055498"],
    "operations": [[2], [1, ["\\d+-(.+)-.+-.+"]]]
  },
  {
    "uploaders": ["1375400985"],
    "operations": [[2], [1, ["『(.+)』", "【安可】(.+)", "【安可Anko】(.+)"]]]
  },
  {
    "uploaders": ["440738032"],
    "operations": [[2], [1, ["「(.+)」", "『(.+)』"]]]
  },
  {
    "uploaders": ["37754047"],
    "operations": [[2], [1, ["『(.+)』", "【(.+)】"]]]
  },
  {
    "uploaders": ["1809378863"],
    "operations": [[2], [1, ["【薇Steria】.+【(.+)】", "【薇Steria】(.+)"]]]
  },
  {
    "uploaders": ["1023630944"],
    "operations": [[2], [1, ["、(.+)"]]]
  },
  {
    "uploaders": ["1243266187"],
    "operations": [[2], [1, ["「(.+)」", "【.+】(.+)【.+】"]]]
  },
  {
    "uploaders": ["188679"],
    "operations": [[2], [1, ["【.+】(.+)【.+】", "【.*阿布】(.+)", "【(.+)】"]]]
  },
  {
    "uploaders": ["269345545"],
    "operations": [[2], [1, ["(.+)\\|"]]]
  },
  {
    "uploaders": ["1468696"],
    "operations": [[2], [1, ["【薇Steria】\\d+直播歌切 (.+)"]]]
  },
  {
    "uploaders": ["35861291"],
    "operations": [[2], [1, ["\\d+\\.\\d+\\.\\d+-(.+)"]]]
  },
  {
    "uploaders": ["1381545"],
    "operations": [[2], [1, ["【伦桑】(.+)-"]]]
  },
  {
    "uploaders": ["36908799"],
    "operations": [[2], [1, ["(.+)-", "【.+】(.+)"]]]
  },
  {
    "uploaders": ["58586"],
    "operations": [[2], [1, ["『(.+)』"]]]
  },
  {
    "uploaders": ["20159625"],
    "operations": [[2], [1, ["(.+)-咻咻满-"]]]
  },
  {
    "uploaders": ["35659076"],
    "operations": [[1, ["【赫卡特_Hecate】(.+)（直播歌切）"]]]
  },
  {
    "uploaders": [
      "https://www.youtube.com/channel/UC8zj2Yzx74dhSxXjHI_3o1g",
      "UC8zj2Yzx74dhSxXjHI_3o1g"
    ],
    "operations": [[2], [1, [".+ - \\d+ (.+)"]]]
  },
  {
    "uploaders": ["103795364"],
    "operations": [[2], [1, ["郭德纲相声经典-(.+)"]]]
  },
  {
    "uploaders": ["402110060"],
    "operations": [[2], [1, ["「(.+)」"]]]
  },
  {
    "uploaders": ["1487367615"],
    "operations": [[2], [1, ["【赫卡特_Hecate】(.+)"]]]
  },
  {
    "uploaders": [""],
    "operations": [[2], [1, []]]
  }
]
''';

// ---- 通用判断（默认规则）----
//
// 没有专门规则的 UP 主，按下面的顺序从标题里猜歌名：
// 1. 找出所有括号段：《》『』「」【】“”。
// 2. 排除不是歌名的：标签（翻唱、Cover、Live、DJ、女声、粤语、双女…）、歌词（带逗号句号、~、…、❤ 或太长）、
//    出现在标题开头的【】（多是 UP 主名或分类标签）。
// 3. 剩下的按优先级选：《》『』「」 > 结尾的【】 > 中间的【】 > “”。
//    括号里写成“歌名 / 歌手”时只取斜杠前面。
// 4. 一个都没有时：去掉所有括号段，再去掉末尾的“Cover.歌手”“翻唱”之类，剩下的就是歌名。
// 5. 有两条以上丨｜| 的标题取前两条之间的部分；字与字之间被空格隔开的（如“坐 忘 道”）合并。

final _pairs = <String, String>{
  '《': '》',
  '『': '』',
  '「': '」',
  '【': '】',
  '“': '”',
  '"': '"',
};

final _tagWords = RegExp(
  r'翻唱|cover|live|dj|女声|男声|粤语|国语|日语|英文|合集|原创|完整版|现场|伴奏|纯享|试听|歌词|双女|男女|'
  r'合唱|新歌|首发|remix|mv|4k|hi-?res|版$|^(原唱|翻自|歌曲|音乐)$',
  caseSensitive: false,
);

final _lyricMarks = RegExp(r'[，。,.~～！？!?…❤♥]|\.\.');

class _Span {
  _Span(this.open, this.start, this.end, this.text);
  final String open;
  final int start, end;
  final String text;
}

List<_Span> _spans(String title) {
  final spans = <_Span>[];
  for (var i = 0; i < title.length; i++) {
    final close = _pairs[title[i]];
    if (close == null) continue;
    final end = title.indexOf(close, i + 1);
    if (end < 0) continue;
    spans.add(_Span(title[i], i, end, title.substring(i + 1, end).trim()));
    // 成对的括号可以嵌套（“……《歌名》”）；开闭相同的引号则整段跳过。
    if (title[i] == close) i = end;
  }
  return spans;
}

String _cleanName(String text) {
  var name = text.split(RegExp(r'\s+[/／]\s+|[/／]')).first.trim();
  // 歌名后面的版本说明：“琵琶行（Remix版）”→“琵琶行”。
  final bare = name.replaceFirst(RegExp(r'\s*[（(][^（()）]*[)）]\s*$'), '');
  if (bare.isNotEmpty) name = bare;
  // “坐 忘 道”：单个字之间被空格隔开时合并。
  if (RegExp(r'^(\S\s+){2,}\S$').hasMatch(name)) {
    name = name.replaceAll(RegExp(r'\s+'), '');
  }
  return name;
}

bool _isLyricOrTag(String text) =>
    text.isEmpty ||
    text.length > 24 ||
    _tagWords.hasMatch(text) ||
    _lyricMarks.hasMatch(text);

/// 《》『』「」是最明确的歌名标记：只排除“整段就是标签”和明显的歌词，
/// 不用标签词子串筛（《夜空中最亮的星dj》《琵琶行（Remix版）》里的 dj、remix 不是标签）。
final _pureTag = RegExp(
  r'^(翻唱|cover|live|dj|remix|原创|纯享|完整版|现场|伴奏|合集|mv|pv|4k|女声|男声|粤语|国语|日语|双女|男女|合唱|新歌|首发|歌词)(版|付)?$',
  caseSensitive: false,
);
final _strongLyric = RegExp(r'[，。~～！？!?…❤♥]');

bool _isStrongNonName(String text) =>
    text.isEmpty ||
    text.length > 40 ||
    _pureTag.hasMatch(text) ||
    _strongLyric.hasMatch(text);

/// 从视频标题猜歌名；猜不出时返回去掉装饰后的标题（最差也是原标题）。
String guessSongName(String raw) {
  var title = raw.trim();
  if (title.isEmpty) return raw;
  // 两条以上的 丨｜|：取前两条之间的一段（“……丨坐 忘 道 丨”）。
  final bars = RegExp(r'[丨｜|]');
  final marks = bars.allMatches(title).toList();
  if (marks.length >= 2) {
    final between = title.substring(marks[0].end, marks[1].start).trim();
    if (between.isNotEmpty && between.length <= 24) return _cleanName(between);
  }
  final spans = _spans(title);
  int rank(_Span s) {
    if ('《『「'.contains(s.open)) return 0;
    if (s.open == '【') return s.end == title.length - 1 ? 1 : 2;
    return 3;
  }

  final candidates = [
    for (final s in spans)
      if (!(s.open == '【' && s.start == 0 && s.end < title.length - 1) &&
          !('《『「'.contains(s.open)
              ? _isStrongNonName(_cleanName(s.text))
              : _isLyricOrTag(_cleanName(s.text))))
        s,
  ];
  if (candidates.isNotEmpty) {
    candidates.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.start.compareTo(b.start);
    });
    final best = candidates.first;
    // 只有【】胜出时才检查：标题正文被表情符号装饰、且读起来是干净的歌名时，
    // 【】多半是活动名或栏目（“⚡️…八千里路明月照DJ⚡️【铁豆钢蛋杯】”），歌名取正文。
    if (best.open == '【') {
      final plain = _decoratedPlainName(title, spans);
      if (plain != null) return plain;
    }
    final name = _cleanName(best.text);
    if (name.isNotEmpty) return name;
  }
  if (spans.isEmpty) return title == raw.trim() ? raw : _cleanName(title);
  // 没有可用的括号段：去掉所有括号段与末尾的翻唱标注。
  var rest = title;
  for (final s in spans.reversed) {
    rest = rest.replaceRange(s.start, s.end + 1, ' ');
  }
  rest = rest
      .replaceAll(RegExp(r'[(（][^()（）]*[)）]'), ' ')
      .replaceFirst(
        RegExp(r'\s*(cover|翻唱)[\s.:：]*.*$', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return rest.isEmpty ? raw : _cleanName(rest);
}

final _decoration = RegExp(
  r'[\u{1F000}-\u{1FFFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}❀✨]',
  unicode: true,
);

/// 去掉所有括号段后的正文：含表情装饰，并且按表情切开后最后一段是干净的短文本时，返回它。
String? _decoratedPlainName(String title, List<_Span> spans) {
  final masked = title.split('');
  for (final s in spans) {
    for (var i = s.start; i <= s.end && i < masked.length; i++) {
      masked[i] = ' ';
    }
  }
  final rest = masked.join();
  if (!_decoration.hasMatch(rest)) return null;
  final segments = [
    for (final part in rest.split(_decoration))
      if (part.trim().isNotEmpty) part.trim(),
  ];
  if (segments.isEmpty) return null;
  final last = _cleanName(segments.last);
  if (last.isEmpty || last.length > 24 || _lyricMarks.hasMatch(rest)) {
    return null;
  }
  return last;
}
