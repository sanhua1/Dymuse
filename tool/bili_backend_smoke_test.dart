// 真实联网冒烟：搜索、找一个合集订阅、读取歌曲、取音频直链（只读，不登录）。
// 用法：flutter test tool/bili_backend_smoke_test.dart（需要联网，不在默认测试里）
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:dymuse/bilibili/client.dart';
import 'package:dymuse/local/bilibili_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => test('B 站联网冒烟', () async {
  HttpOverrides.global = null;
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final client = BilibiliClient();
  final bili = BilibiliBackend(prefs, client);
  final found = await bili.handle('GET', ['tracks'], {'q': '周杰伦 晴天'}) as Map;
  final items = (found['items'] as List).cast<Map>();
  print('搜索 ${items.length} 条，总数 ${found['total']}；第一条：${items.first['title']}');
  String? source;
  for (final item in items.take(6)) {
    final bvid = '${item['id']}'.split(':').first;
    final detail = await client.wbiGet('/x/web-interface/wbi/view/detail', {'bvid': bvid});
    final view = (detail['data'] as Map)['View'] as Map;
    final season = view['ugc_season'] as Map?;
    if (season != null) {
      source = 'https://space.bilibili.com/${(view['owner'] as Map)['mid']}/channel/collectiondetail?sid=${season['id']}';
      print('找到合集：${season['title']} -> $source');
      break;
    }
  }
  if (source == null) {
    print('前几条都没有合集，跳过订阅');
    return;
  }
  final sub = await bili.handle('POST', ['subscriptions'], {'input': source}) as Map;
  print('订阅：${sub['name']}（${sub['typeLabel']}，${sub['trackCount']} 首）');
  final tracks = await bili.handle('GET', ['subscriptions', '${sub['id']}', 'tracks'], {}) as Map;
  final first = (tracks['items'] as List).first as Map;
  print('订阅首曲：${first['title']} / ${first['id']}');
  final q = await bili.queueFor({'kind': 'subscription', 'id': sub['id']}, '${first['id']}');
  print('队列 ${q.items.length} 首，定位 ${q.index}');
  final audio = await bili.handle('GET', ['tracks', '${first['id']}', 'audio'], {}) as Map;
  print('音频：${audio['codec']} ${audio['bandwidth']} ${Uri.parse('${audio['url']}').host}');
  client.close();
}, timeout: const Timeout(Duration(minutes: 3)));
