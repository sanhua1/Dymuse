// 歌词的三层内容：原词、翻译、罗马音。按时间戳把后两层配到原词的每一行上。
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/api_client.dart' show Json;

/// 显示哪几层（位掩码，保存在本机偏好里）。
class LyricLayout {
  static const original = 1, translation = 2, romaji = 4;
  static const _key = 'lyric.layers';

  /// 默认：原词 + 翻译。
  static const defaults = original | translation;

  static int decode(int? raw) {
    final value = (raw ?? defaults) & 7;
    return value == 0 ? original : value;
  }

  static Future<int> load() async =>
      decode((await SharedPreferences.getInstance()).getInt(_key));

  static Future<void> save(int flags) async =>
      (await SharedPreferences.getInstance()).setInt(_key, flags);

  /// 切换某一层；至少保留一层，且没有任何附加层可用时一定显示原词。
  static int toggle(int flags, int layer) {
    final next = flags ^ layer;
    return next == 0 ? flags : next;
  }
}

/// 一份歌词的全部内容：带翻译与罗马音的行，以及附加层的署名与版本。
class LyricBundle {
  const LyricBundle({
    this.lines = const [],
    this.translator,
    this.translationVersion,
    this.romajiVersion,
    this.hasTranslation = false,
    this.hasRomaji = false,
  });
  final List<Json> lines;
  final String? translator;
  final int? translationVersion, romajiVersion;
  final bool hasTranslation, hasRomaji;

  /// 解析网易云歌词接口的返回；[parse] 把 LRC 文本变成行。
  factory LyricBundle.fromResponse(
    Json data,
    List<Json> Function(String) parse,
  ) {
    String text(String key) =>
        (data[key] is Map ? (data[key] as Map)['lyric']?.toString() : null) ??
        '';
    int? version(String key) => data[key] is Map
        ? ((data[key] as Map)['version'] as num?)?.toInt()
        : null;
    final lines = parse(text('lrc'));
    final trans = _usable(parse(text('tlyric')));
    final roma = _usable(parse(text('romalrc')));
    final timed =
        lines.isNotEmpty && lines.every((l) => (l['timeMs'] as int) >= 0);
    final merged = [for (final line in lines) Map<String, dynamic>.of(line)];
    var hasTrans = false, hasRoma = false;
    if (timed) {
      hasTrans = _attach(merged, trans, 'trans');
      hasRoma = _attach(merged, roma, 'roma');
    }
    final name = data['transUser'] is Map
        ? (data['transUser'] as Map)['nickname']?.toString()
        : null;
    return LyricBundle(
      lines: merged,
      translator: name == null || name.isEmpty ? null : name,
      translationVersion: version('tlyric'),
      romajiVersion: version('romalrc'),
      hasTranslation: hasTrans,
      hasRomaji: hasRoma,
    );
  }

  /// 去掉空行与没有时间戳的行，只留可对时的内容。
  static List<Json> _usable(List<Json> lines) => [
    for (final l in lines)
      if ((l['timeMs'] as int) >= 0 && '${l['text']}'.trim().isNotEmpty) l,
  ];

  /// 先按完全相同的时间配对，其次取 500ms 内最近的未用行。返回是否配上至少一行。
  static bool _attach(List<Json> base, List<Json> layer, String key) {
    if (layer.isEmpty) return false;
    final used = <int>{};
    var any = false;
    for (final line in base) {
      final time = line['timeMs'] as int;
      var best = -1, gap = 501;
      for (var i = 0; i < layer.length; i++) {
        if (used.contains(i)) continue;
        final d = ((layer[i]['timeMs'] as int) - time).abs();
        if (d < gap) {
          gap = d;
          best = i;
          if (d == 0) break;
        }
      }
      if (best < 0) continue;
      used.add(best);
      final value = '${layer[best]['text']}'.trim();
      // 与原词一字不差的“翻译”（常见于外语歌里的英文行）没有信息量，不显示。
      if (value == '${line['text']}'.trim()) continue;
      line[key] = value;
      any = true;
    }
    return any;
  }
}

/// 当前显示的歌词与图层选择。歌词视图写入，各处的“译”按钮读取；
/// 歌词视图每次换歌都会先清空再写入；“译”按钮只在歌词显示时才出现。
class LyricStore extends ChangeNotifier {
  LyricStore._();
  static final instance = LyricStore._();

  LyricBundle bundle = const LyricBundle();

  /// 当前歌词属于哪首歌；同一首歌重新进入歌词页时保留，避免按钮闪烁。
  String key = '';
  int layers = LyricLayout.defaults;
  bool _loaded = false;

  bool get available => bundle.hasTranslation || bundle.hasRomaji;

  /// 歌词视图出现时调用：首次读取本机保存的选择。
  void attach() {
    if (_loaded) return;
    _loaded = true;
    LyricLayout.load().then((value) {
      layers = value;
      notifyListeners();
    });
  }

  void show(LyricBundle value, [String? forKey]) {
    if (forKey != null) key = forKey;
    bundle = value;
    notifyListeners();
  }

  Future<void> toggle(int layer) async {
    final next = LyricLayout.toggle(layers, layer);
    if (next == layers) return;
    layers = next;
    notifyListeners();
    await LyricLayout.save(next);
  }
}
