// 只读探测：少量请求验证 B 站搜索、详情、取直链（不登录、不写任何数据）。
import 'package:dymuse/bilibili/client.dart';

Future<void> main() async {
  final client = BilibiliClient();
  try {
    final result = await client.search('周杰伦 晴天');
    print(
      'search total=${result.total} pageSize=${result.pageSize} first=${result.songs.first.title} / ${result.songs.first.artist} ${result.songs.first.duration}s',
    );
    final songs = await client.videoSongs(result.songs.first.bvid);
    print(
      'detail songs=${songs.length} first=${songs.first.id} ${songs.first.title}',
    );
    final audio = await client.audioUrl(songs.first.bvid, songs.first.cid);
    print(
      'audio codec=${audio.codec} bandwidth=${audio.bandwidth} host=${Uri.parse(audio.url).host}',
    );
  } on BilibiliError catch (e) {
    print('FAILED ${e.code} ${e.message}');
  } finally {
    client.close();
  }
}
