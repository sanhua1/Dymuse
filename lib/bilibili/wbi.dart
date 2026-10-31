// B 站 WBI 签名：移植自 azusa-player-mobile 的 stores/wbi.ts，
// 算法见 bilibili-API-collect 的 docs/misc/sign/wbi.md。
import 'dart:convert';

import 'package:crypto/crypto.dart';

const _mixinKeyEncTab = [
  46,
  47,
  18,
  2,
  53,
  8,
  23,
  32,
  15,
  50,
  10,
  31,
  58,
  3,
  45,
  35,
  27,
  43,
  5,
  49,
  33,
  9,
  42,
  19,
  29,
  28,
  14,
  39,
  12,
  38,
  41,
  13,
  37,
  48,
  7,
  16,
  24,
  55,
  40,
  61,
  26,
  17,
  0,
  1,
  60,
  51,
  30,
  4,
  22,
  25,
  54,
  21,
  56,
  59,
  6,
  63,
  57,
  62,
  11,
  36,
  20,
  34,
  44,
  52,
];

/// 把 imgKey+subKey 按固定置换表打乱，取前 32 位。
String mixinKey(String imgKey, String subKey) {
  final raw = imgKey + subKey;
  return _mixinKeyEncTab.map((i) => raw[i]).join().substring(0, 32);
}

/// 返回带 `wts` 与 `w_rid` 的查询串；值里的 `!'()*` 会被过滤。
String signWbi(
  Map<String, Object?> params, {
  required String imgKey,
  required String subKey,
  int? timestamp,
}) {
  final signed = <String, String>{
    for (final e in params.entries) e.key: '${e.value}',
    'wts': '${timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000}',
  };
  final keys = signed.keys.toList()..sort();
  final query = keys
      .map(
        (key) =>
            '${Uri.encodeQueryComponent(key).replaceAll('+', '%20')}='
            '${Uri.encodeQueryComponent(signed[key]!.replaceAll(RegExp(r"[!'()*]"), '')).replaceAll('+', '%20')}',
      )
      .join('&');
  final sign = md5.convert(utf8.encode(query + mixinKey(imgKey, subKey)));
  return '$query&w_rid=$sign';
}
