// 只读探测：按 level 取链时网易云返回的实际档位（匿名，只会得到试听或标准档，用于核对字段）。
import 'dart:convert';
import 'package:dymuse/netease/client.dart';

Future<void> main() async {
  final client = NeteaseClient();
  for (final level in ['standard', 'exhigh', 'lossless', 'hires']) {
    try {
      final body = await client.request('/api/song/enhance/player/url/v1', {
        'ids': jsonEncode(['1969519579']),
        'level': level,
        'encodeType': 'flac',
      });
      final d = (body['data'] as List).first as Map;
      print(
        '$level -> level=${d['level']} br=${d['br']} type=${d['type']} trial=${d['freeTrialInfo'] != null} url=${(d['url'] ?? '').toString().isNotEmpty}',
      );
    } catch (e) {
      print('$level FAILED $e');
    }
  }
  final detail = await client.request('/api/song/music/detail/get', {
    'songId': '347230',
  });
  print('detail keys: ${(detail['data'] as Map).keys.toList()}');
  client.close();
}
