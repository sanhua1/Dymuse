// 起本机 HLS 代理并保持运行，供 AVFoundation 验证能否播放 B 站音频。
import 'dart:io';
import 'package:dymuse/bilibili/client.dart';
import 'package:dymuse/bilibili/hls_proxy.dart';

Future<void> main() async {
  final client = BilibiliClient();
  final r = await client.search('周杰伦 晴天');
  final s = (await client.videoSongs(r.songs.first.bvid)).first;
  final audio = await client.audioUrl(s.bvid, s.cid);
  client.close();
  final proxy = await BiliHlsProxy.instance;
  final uri = proxy.register(audio.url, audio.headers);
  File('/tmp/bili_hls_url.txt').writeAsStringSync('$uri');
  print('READY $uri');
  await Future<void>.delayed(const Duration(seconds: 90));
  await proxy.close();
}
