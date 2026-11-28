import 'package:dymuse/core/api_client.dart';
import 'package:dymuse/features/catalog.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _res(
  String type,
  Object id,
  String title, {
  Map<String, dynamic>? ext,
  List<String>? labels,
}) => {
  'resourceType': type,
  'resourceId': '$id',
  'uiElement': {
    'mainTitle': {'title': title},
    'image': {'imageUrl': 'http://img/$id.jpg'},
    'labelTexts': ?labels,
  },
  'resourceExtInfo': ?ext,
};

Map<String, dynamic> _song(int id, String name) => {
  'songData': {
    'id': id,
    'name': name,
    'duration': 200000,
    'artists': [
      {'id': 9, 'name': '歌手'},
    ],
    'album': {'id': 7, 'name': '专辑'},
  },
};

Map<String, dynamic> _block(
  String code,
  String title,
  List<(String, List<Map<String, dynamic>>)> creatives,
) => {
  'blockCode': code,
  'uiElement': {
    'subTitle': {'title': title},
  },
  'creatives': [
    for (final (type, resources) in creatives)
      {'creativeType': type, 'resources': resources},
  ],
};

void main() {
  test('首页板块：按上游顺序取推荐歌单、雷达、风格推荐、新歌新碟，跳过播客和数字专辑', () {
    final blocks = CatalogBlock.home({
      'code': 200,
      'data': {
        'blocks': [
          _block('HOMEPAGE_BLOCK_PLAYLIST_RCMD', '推荐歌单', [
            (
              'list',
              [
                _res('list', 1, '歌单一', labels: ['华语', '流行', '治愈', '多余']),
              ],
            ),
          ]),
          _block('HOMEPAGE_VOICELIST_RCMD', '热门播客', [
            ('voiceList', [_res('voiceList', 2, '播客')]),
          ]),
          _block('HOMEPAGE_BLOCK_STYLE_RCMD', '猜你喜欢的「华语」好歌', [
            (
              'SONG_LIST_HOMEPAGE',
              [
                _res('song', 11, '歌一', ext: _song(11, '歌一')),
                _res('song', 12, '歌二', ext: _song(12, '歌二')),
              ],
            ),
          ]),
          _block('HOMEPAGE_BLOCK_MGC_PLAYLIST', '我的雷达歌单', [
            ('list', [_res('list', 3, '还在听《九万字》吗|时光雷达')]),
          ]),
          _block('HOMEPAGE_BLOCK_NEW_ALBUM_NEW_SONG', '新歌新碟', [
            (
              'NEW_SONG_HOMEPAGE',
              [_res('song', 21, '新歌', ext: _song(21, '新歌'))],
            ),
            (
              'NEW_ALBUM_HOMEPAGE',
              [
                _res('digitalEntrance', 0, '数字专辑'),
                _res(
                  'album',
                  31,
                  '新碟',
                  ext: {
                    'artists': [
                      {'name': '甲'},
                      {'name': '乙'},
                    ],
                  },
                ),
              ],
            ),
            ('DIGITAL_ALBUM_HOMEPAGE', [_res('digitalAlbum', 41, '付费专辑')]),
          ]),
        ],
      },
    });

    expect(blocks.map((b) => b.label), [
      '推荐歌单',
      '猜你喜欢的「华语」好歌',
      '我的雷达歌单',
      '新歌新碟',
    ]);

    final rcmd = blocks[0];
    expect(rcmd.more, DiscoverSection.playlists);
    expect(rcmd.page.collections.single.subtitle, '华语 · 流行 · 治愈');
    expect(rcmd.page.collections.single.kind, 'playlist');

    final style = blocks[1];
    expect(style.playAll, isTrue);
    expect(style.page.tracks.map((t) => t.id), ['11', '12']);
    expect(style.page.tracks.first.artist, '歌手');
    expect(style.page.tracks.first.duration, 200);
    // 歌曲资料里没有封面时用板块图片。
    expect(style.page.tracks.first.cover, 'http://img/11.jpg');

    final radar = blocks[2].page.collections.single;
    expect(radar.title, '时光雷达');
    expect(radar.subtitle, '还在听《九万字》吗');
    expect(blocks[2].more, isNull);

    final fresh = blocks[3];
    expect(fresh.page.tracks.single.title, '新歌');
    expect(fresh.page.collections.map((c) => (c.id, c.kind, c.subtitle)), [
      ('31', 'album', '甲 / 乙'),
    ]);
  });

  test('响应不完整时不出错，返回空列表', () {
    expect(CatalogBlock.home({}), isEmpty);
    expect(
      CatalogBlock.home({
        'data': {
          'blocks': [
            {'blockCode': 'HOMEPAGE_BLOCK_STYLE_RCMD', 'creatives': null},
          ],
        },
      }),
      isEmpty,
    );
  });

  test('现在就听：首页没有可显示的板块时退回每日推荐歌单', () async {
    final api = _Api({
      '/netease/homepage': {'code': 200, 'data': {}},
      '/netease/recommend/resource': {
        'recommend': [
          {'id': 600, 'name': '每日推荐', 'trackCount': 3},
        ],
      },
    });
    final page = await Catalog(api).browse(MusicMode.netease, 'discover');
    expect(page.blocks, isEmpty);
    expect(page.collections.single.title, '每日推荐');
  });

  test('现在就听：有板块时直接显示板块；刷新时带 refresh', () async {
    final api = _Api({
      '/netease/homepage': {
        'data': {
          'blocks': [
            _block('HOMEPAGE_BLOCK_MGC_PLAYLIST', '雷达', [
              ('list', [_res('list', 3, '理由|私人雷达')]),
            ]),
          ],
        },
      },
    });
    final catalog = Catalog(api);
    final page = await catalog.browse(MusicMode.netease, 'discover');
    expect(page.blocks.single.page.collections.single.title, '私人雷达');
    expect(api.queries.last, isNull);
    await catalog.browse(MusicMode.netease, 'discover', refresh: true);
    expect(api.queries.last, {'refresh': true});
    expect(api.paths, isNot(contains('/netease/recommend/resource')));
  });
}

class _Api extends ApiClient {
  _Api(this.responses);
  final Map<String, Object> responses;
  final paths = <String>[];
  final queries = <Map<String, dynamic>?>[];
  @override
  Future<dynamic> get(String path, [Map<String, dynamic>? query]) async {
    paths.add(path);
    queries.add(query);
    return responses[path] ?? {'code': 200};
  }
}
