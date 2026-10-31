import 'package:flutter_test/flutter_test.dart';
import 'package:dymuse/features/catalog.dart';

void main() {
  test('网易云歌曲保留艺人与专辑 id，缺 id 的艺人不可跳转', () {
    final track = Track.netease({
      'id': 1,
      'name': '演员',
      'ar': [
        {'id': 5781, 'name': '薛之谦'},
        {'id': 0, 'name': '未收录'},
      ],
      'al': {'id': 3, 'name': '绅士'},
    });
    expect(track.artists.map((a) => a.id), ['5781']);
    expect(track.artistTarget?.kind, 'artist');
    expect(track.artistTarget?.id, '5781');
    expect(track.albumTarget?.kind, 'album');
    expect(track.albumTarget?.id, '3');
  });

  test('B 站歌曲没有艺人与专辑页，艺人名只作展示', () {
    final track = Track.bilibili({
      'id': 'BV1xx411c7mD:0',
      'title': '晚风来信',
      'artists': ['某 UP 主'],
      'album': '晚风来信',
    });
    expect(track.mode, MusicMode.bilibili);
    expect(track.artist, '某 UP 主');
    expect(track.artistTarget, isNull);
    expect(track.albumTarget, isNull);
  });

  test('节目的所属链接指向播客，没有电台 id 时不可跳转', () {
    final program = Track.podcast({'id': 9, 'title': '节目', 'radioId': 70});
    expect(program.albumTarget?.kind, 'podcast');
    expect(program.albumTarget?.id, '70');
    expect(Track.podcast({'id': 9}).albumTarget, isNull);
  });
}
