import 'dart:convert';
import 'dart:io';

import 'package:dymuse/bilibili/client.dart';
import 'package:dymuse/local/bilibili_backend.dart';
import 'package:dymuse/sync/docs.dart';
import 'package:dymuse/sync/sync_crypto.dart';
import 'package:dymuse/sync/sync_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内存里的 WebDAV：GET / PUT / MKCOL，支持 ETag 与 If-Match / If-None-Match。
class FakeDav {
  final files = <String, List<int>>{};
  final etags = <String, String>{};
  final dirs = <String>{};
  int puts = 0, conflicts = 0, gets = 0, lists = 0;

  /// 模拟不会覆盖已有文件的服务器：对已存在的文件，PUT 只会留下带随机后缀的临时文件。
  bool noOverwrite = false;
  late HttpServer server;
  int _version = 0;

  Future<void> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) async {
      final path = request.uri.path;
      final response = request.response;
      switch (request.method) {
        case 'MKCOL':
          response.statusCode = dirs.add(path) ? 201 : 405;
        case 'PROPFIND':
          lists++;
          await request.drain<void>();
          final prefix = path.endsWith('/') ? path : '$path/';
          final items = files.keys
              .where(
                (f) =>
                    f.startsWith(prefix) &&
                    !f.substring(prefix.length).contains('/'),
              )
              .toList();
          if (!dirs.contains(path) && items.isEmpty) {
            response.statusCode = 404;
          } else {
            response.statusCode = 207;
            final buf = StringBuffer(
              '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">',
            );
            buf.write(
              '<D:response><D:href>$path/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>',
            );
            for (final f in items) {
              buf.write(
                '<D:response><D:href>$f</D:href><D:propstat><D:prop><D:getetag>${etags[f]}</D:getetag><D:resourcetype/></D:prop></D:propstat></D:response>',
              );
            }
            buf.write('</D:multistatus>');
            response.write(buf);
          }
        case 'DELETE':
          response.statusCode = files.remove(path) == null ? 404 : 204;
        case 'GET':
          gets++;
          final body = files[path];
          if (body == null) {
            response.statusCode = 404;
          } else {
            response.headers.set('etag', etags[path]!);
            response.add(body);
          }
        case 'PUT':
          final data = <int>[];
          await for (final chunk in request) {
            data.addAll(chunk);
          }
          final ifMatch = request.headers.value('if-match');
          final none = request.headers.value('if-none-match');
          final exists = files.containsKey(path);
          if (noOverwrite && exists) {
            final temp = '$path-${++_version}-tmp.gz';
            files[temp] = data;
            etags[temp] = '"t$_version"';
            puts++;
            response.statusCode = 201;
          } else if ((ifMatch != null && etags[path] != ifMatch) ||
              (none == '*' && exists)) {
            conflicts++;
            response.statusCode = 412;
          } else {
            files[path] = data;
            etags[path] = '"${++_version}"';
            puts++;
            response.statusCode = exists ? 204 : 201;
          }
        default:
          response.statusCode = 405;
      }
      await response.close();
    });
  }

  String get url => 'http://127.0.0.1:${server.port}/dav';
}

/// 模拟一台设备：各自独立的偏好设置、凭证与设置。
class Device {
  Device(this.name, this.dav, this.passphrase);
  final String name;
  final FakeDav dav;
  String passphrase;
  Map<String, Object> store = {};
  Map<String, String>? netease, bilibili;
  Map<String, String> settings = {'audioQuality': 'exhigh'};
  bool playing = false;
  final received = <String>[];
  final changes = <Set<String>>[];

  Future<T> run<T>(Future<T> Function(SyncService, LocalDocs) body) async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(store);
    final prefs = await SharedPreferences.getInstance();
    final service = SyncService(prefs, storage: const FlutterSecureStorage())
      ..readCredentials = (() => {'netease': netease, 'bilibili': bilibili})
      ..writeCredentials = (kind, cookie) async {
        received.add(kind);
        if (kind == 'netease') netease = cookie;
        if (kind == 'bilibili') bilibili = cookie;
      }
      ..readSettings = (() => settings)
      ..applySettings = ((values) => settings = values)
      ..isPlaying = (() => playing)
      ..onApplied = changes.add;
    await service.save(
      SyncConfig(
        url: dav.url,
        user: 'u',
        password: 'p',
        passphrase: passphrase,
      ),
    );
    try {
      return await body(service, service.docs);
    } finally {
      store = {for (final k in prefs.getKeys()) k: prefs.get(k)!};
      service.dispose();
    }
  }
}

Map<String, dynamic> song(String bvid, [int cid = 1]) => {
  'bvid': bvid,
  'cid': cid,
  'title': '歌 $bvid',
  'artist': 'UP',
  'artistId': '1',
  'cover': '',
  'duration': 100,
  'album': '',
  'page': 1,
};

Map<String, dynamic> heart(String bvid, int ts, {bool del = false}) => {
  'ts': ts,
  'del': del,
  'song': song(bvid),
};

final t0 = DateTime.now().millisecondsSinceEpoch - 60000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  setUpAll(() => HttpOverrides.global = null);

  group('合并规则', () {
    test('逐条取新，同时间删除优先，合并满足交换律与幂等', () {
      final a = {
        'x': heart('BVa', t0 + 10),
        'y': heart('BVb', t0 + 20, del: true),
      };
      final b = {
        'x': heart('BVa', t0 + 15, del: true),
        'y': heart('BVb', t0 + 20),
      };
      final ab = mergeTable(a, b);
      final ba = mergeTable(b, a);
      expect(jsonEncode(ab), jsonEncode(ba));
      expect(ab['x']['del'], true, reason: 'x：b 更新，是删除');
      expect(ab['y']['del'], true, reason: 'y：同时间删除优先');
      expect(jsonEncode(mergeTable(ab, ab)), jsonEncode(ab));
    });

    test('过期墓碑被清理，未过期的保留', () {
      final day = const Duration(days: 1).inMilliseconds;
      final now = 200 * day;
      final merged = mergeTable(
        {
          'old': heart('BVa', 100 * day, del: true),
          'fresh': heart('BVb', 190 * day, del: true),
        },
        {},
        now: now,
      );
      expect(merged.containsKey('old'), false);
      expect(merged.containsKey('fresh'), true);
    });

    test('歌单：名称按歌单时间，歌曲逐首合并', () {
      J list(String name, int ts, Map<String, dynamic> items) => {
        'ts': ts,
        'del': false,
        'name': name,
        'description': '',
        'items': items,
      };
      J item(String id, int ts, {bool del = false}) => {
        'ts': ts,
        'del': del,
        'order': 0,
        'song': song(id),
      };
      final merged = mergeTable(
        {
          'p': list('旧名', t0 + 5, {
            'a:1': item('a', t0 + 5),
            'b:1': item('b', t0 + 5),
          }),
        },
        {
          'p': list('新名', t0 + 9, {
            'a:1': item('a', t0 + 9, del: true),
            'c:1': item('c', t0 + 9),
          }),
        },
        combine: mergePlaylist,
      );
      final p = merged['p'] as Map;
      expect(p['name'], '新名');
      final items = p['items'] as Map;
      expect(items['a:1']['del'], true);
      expect(items['b:1']['del'], false, reason: '本机独有的歌保留');
      expect(items.containsKey('c:1'), true, reason: '对方独有的歌合入');
    });

    test('订阅：元信息与歌曲列表各按自己的时间取新', () {
      J sub(String name, int ts, int tracksTs, List<String> tracks) => {
        'ts': ts,
        'del': false,
        'name': name,
        'tracksTs': tracksTs,
        'tracks': tracks,
      };
      final m = mergeSub(sub('旧名', 5, 20, ['a']), sub('新名', 9, 10, ['b']));
      expect(m['name'], '新名');
      expect(m['tracks'], ['a']);
      expect(m['tracksTs'], 20);
    });
  });

  group('加密', () {
    test('同一口令可解密，错误口令被拒绝', () async {
      final salt = SyncCrypto.randomBytes(16);
      final a = await SyncCrypto.derive('秘密', salt, rounds: 1000);
      final b = await SyncCrypto.derive('别的', salt, rounds: 1000);
      final blob = a.encrypt('{"cookie":"MUSIC_U=abc"}');
      expect(blob['ct'], isNot(contains('MUSIC_U')));
      expect(a.decrypt(blob), '{"cookie":"MUSIC_U=abc"}');
      expect(() => b.decrypt(blob), throwsA(isA<SyncCryptoError>()));
      expect(a.verify(a.checkBlock()), true);
      expect(b.verify(a.checkBlock()), false);
    });
  });

  group('两台设备经 WebDAV 同步', () {
    late FakeDav dav;
    late Device a, b;
    setUp(() async {
      dav = FakeDav();
      await dav.start();
      a = Device('A', dav, '口令');
      b = Device('B', dav, '口令');
    });
    tearDown(() => dav.server.close(force: true));

    test('红心、歌单、订阅（含歌曲）从 A 到 B，再互相增删后收敛', () async {
      await a.run((s, d) async {
        await d.writeHearts({
          'BV1:1': heart('BV1', t0 + 100),
          'BV2:1': heart('BV2', t0 + 100),
        });
        await d.writePlaylists({
          'p1': {
            'ts': t0 + 100,
            'del': false,
            'name': '通勤',
            'description': '',
            'items': {
              'BV1:1': {
                'ts': t0 + 100,
                'del': false,
                'order': 0,
                'song': song('BV1'),
              },
            },
          },
        });
        await d.writeSubs({
          's1': {
            'ts': t0 + 100,
            'del': false,
            'name': '合集',
            'type': 'collection',
            'input': 'x',
            'source': {'type': 'collection', 'params': {}},
            'cover': '',
            'tracksTs': t0 + 100,
            'updatedAt': t0 + 100,
            'tracks': [song('BV9')],
          },
        });
        expect(await s.sync(), true, reason: s.error);
      });
      // B 第一次同步：全部取下来。
      await b.run((s, d) async {
        expect(await s.sync(), true, reason: s.error);
        expect(d.hearts().keys.toSet(), {'BV1:1', 'BV2:1'});
        expect((d.playlists()['p1'] as Map)['name'], '通勤');
        expect(((d.subs()['s1'] as Map)['tracks'] as List).length, 1);
      });
      // B 删一颗红心、加一颗；A 同时加另一颗并改歌单名。
      await b.run((s, d) async {
        final hearts = d.hearts();
        hearts['BV1:1'] = heart('BV1', t0 + 200, del: true);
        hearts['BV3:1'] = heart('BV3', t0 + 200);
        await d.writeHearts(hearts);
        await s.sync();
      });
      await a.run((s, d) async {
        final hearts = d.hearts();
        hearts['BV4:1'] = heart('BV4', t0 + 210);
        await d.writeHearts(hearts);
        final lists = d.playlists();
        (lists['p1'] as Map)['name'] = '通勤路上';
        (lists['p1'] as Map)['ts'] = t0 + 220;
        await d.writePlaylists(lists);
        await s.sync();
      });
      await b.run((s, d) async => s.sync());
      await a.run((s, d) async => s.sync());
      Set<String> liveHearts(LocalDocs d) => {
        for (final e in d.hearts().entries)
          if ((e.value as Map)['del'] != true) e.key,
      };
      late Set<String> fromA, fromB;
      late String nameA, nameB;
      await a.run((s, d) async {
        fromA = liveHearts(d);
        nameA = '${(d.playlists()['p1'] as Map)['name']}';
      });
      await b.run((s, d) async {
        fromB = liveHearts(d);
        nameB = '${(d.playlists()['p1'] as Map)['name']}';
      });
      expect(fromA, {
        'BV2:1',
        'BV3:1',
        'BV4:1',
      }, reason: 'BV1 被 B 删除，BV3、BV4 都在');
      expect(fromB, fromA);
      expect(nameA, '通勤路上');
      expect(nameB, nameA);
    });

    test('凭证加密存放，新设备用同一口令取回，错误口令被拒', () async {
      a.netease = {'MUSIC_U': 'secret-music-u'};
      a.bilibili = {'SESSDATA': 'secret-sess'};
      await a.run(
        (s, d) async => expect(await s.sync(), true, reason: s.error),
      );
      final uploaded = dav.files.entries
          .firstWhere((e) => e.key.startsWith('/dav/Dymuse/devices/'))
          .value;
      final raw = utf8.decode(gzip.decode(uploaded));
      expect(raw, isNot(contains('secret-music-u')));
      expect(raw, isNot(contains('secret-sess')));
      expect(raw, contains('"enc"'));

      final wrong = Device('C', dav, '错的口令');
      await wrong.run((s, d) async {
        expect(await s.sync(), false);
        expect(s.error, contains('同步密码'));
      });
      expect(wrong.netease, isNull);

      await b.run(
        (s, d) async => expect(await s.sync(), true, reason: s.error),
      );
      expect(b.netease, {'MUSIC_U': 'secret-music-u'});
      expect(b.bilibili, {'SESSDATA': 'secret-sess'});
    });

    test('退出登录的设备不会被远端凭证重新登录', () async {
      a.netease = {'MUSIC_U': 'x'};
      await a.run((s, d) async => s.sync());
      await b.run((s, d) async {
        await s.noteLogout('netease');
        await s.sync();
      });
      expect(b.netease, isNull);
    });

    test('播放进度：较新者生效；正在播放时不抢队列', () async {
      final queue = {
        'generation': 'g',
        'revision': 3,
        'updatedAt': t0 + 500,
        'state': {'items': [], 'index': 0, 'positionMs': 42000},
      };
      a.store['aio.queue.bilibili'] = jsonEncode(queue);
      await a.run((s, d) async => s.sync());
      b.playing = true;
      await b.run((s, d) async => s.sync());
      expect(b.store['aio.queue.bilibili'], isNull);
      b.playing = false;
      // 正在播放时没有采纳，记录里的对方 ETag 也不能当成“已看过”之外的状态影响下一次——
      // 这里直接清掉已看记录，模拟下一次同步重新比较。
      b.store.remove('sync.peers');
      await b.run((s, d) async => s.sync());
      final adopted =
          jsonDecode(b.store['aio.queue.bilibili'] as String) as Map;
      expect((adopted['state'] as Map)['positionMs'], 42000);
      expect(adopted['revision'], 1, reason: '本机修订号递增，进行中的保存会重读');
    });

    test('设置：只同步有变化的一方', () async {
      a.settings = {'audioQuality': 'lossless'};
      await a.run((s, d) async => s.sync());
      await b.run((s, d) async => s.sync());
      expect(b.settings['audioQuality'], 'lossless');
    });

    test('增删编辑：iPhone 删改后同步，Mac 随后同步不会把删掉的传回去', () async {
      // 用真实的 B 站本地后端做增删改，走和界面一样的写入路径。
      BilibiliBackend backend(SyncService s) =>
          BilibiliBackend(s.prefs, BilibiliClient());
      Future<Map> call(
        BilibiliBackend b,
        String method,
        List<String> path, [
        Map<String, dynamic>? body,
      ]) async => (await b.handle(method, path, body ?? {})) as Map;
      late String p1, p2;

      // 初始状态：iPhone(A) 有 3 颗红心、2 个歌单、1 个订阅，同步到 Mac(B)。
      await a.run((s, d) async {
        await d.writeHearts({
          for (final id in ['BV1', 'BV2', 'BV3']) '$id:1': heart(id, t0 + 10),
        });
        final b = backend(s);
        await call(b, 'GET', ['favorites'], {}); // 让后端认识这三首歌
        p1 =
            '${(await call(b, 'POST', ['playlists'], {
              'name': '通勤',
              'trackIds': ['BV1:1', 'BV2:1'],
            }))['id']}';
        p2 =
            '${(await call(b, 'POST', ['playlists'], {
              'name': '睡前',
              'trackIds': ['BV3:1'],
            }))['id']}';
        final sub = (d.subs()
          ..['s1'] = {
            'ts': t0 + 10,
            'del': false,
            'name': '合集',
            'type': 'collection',
            'input': 'x',
            'source': {'type': 'collection', 'params': {}},
            'cover': '',
            'tracksTs': t0 + 10,
            'updatedAt': t0 + 10,
            'tracks': [song('BV9')],
          });
        await d.writeSubs(sub);
        expect(await s.sync(), true, reason: s.error);
      });
      await b.run((s, d) async {
        expect(await s.sync(), true, reason: s.error);
        expect(d.playlists().length, 2);
        expect(d.subs().containsKey('s1'), true);
      });

      // Mac 离线时自己加了一颗红心（没有同步）。
      await b.run((s, d) async {
        final hearts = d.hearts()..['BV7:1'] = heart('BV7', t0 + 500);
        await d.writeHearts(hearts);
      });

      // iPhone：删歌单“睡前”、从“通勤”里去掉 BV2 并改名、取消 BV3 的红心、删订阅。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await a.run((s, d) async {
        final bk = backend(s);
        await call(bk, 'GET', ['favorites'], {});
        await call(bk, 'POST', ['playlists', p2, 'archive'], {});
        final cur = await call(bk, 'GET', ['playlists', p1], {});
        await call(
          bk,
          'PUT',
          ['playlists', p1],
          {
            'name': '上班路上',
            'revision': cur['revision'],
            'trackIds': ['BV1:1'],
          },
        );
        await call(
          bk,
          'PUT',
          ['tracks', 'BV3:1', 'favorite'],
          {'favorite': false},
        );
        final subs = d.subs();
        subs['s1'] = {
          ...(subs['s1'] as Map),
          'del': true,
          'ts': DateTime.now().millisecondsSinceEpoch,
          'tracks': [],
        };
        await d.writeSubs(subs);
        expect(await s.sync(), true, reason: s.error);
      });

      // Mac 同步：删除和编辑生效，自己新加的红心保留。
      await b.run((s, d) async {
        expect(await s.sync(), true, reason: s.error);
        final bk = backend(s);
        final lists =
            ((await call(bk, 'GET', ['playlists'], {}))['items'] as List)
                .cast<Map>();
        expect(lists.map((l) => l['name']), ['上班路上'], reason: '“睡前”被删，没有传回去');
        final p = await call(bk, 'GET', ['playlists', p1], {});
        expect((p['items'] as List).map((e) => e['id']), ['BV1:1']);
        final hearts =
            ((await call(bk, 'GET', ['favorites'], {}))['items'] as List)
                .map((e) => (e as Map)['id'])
                .toSet();
        expect(hearts, {
          'BV1:1',
          'BV2:1',
          'BV7:1',
        }, reason: 'BV3 被取消，BV7 是 Mac 新加的');
        expect(d.subs()['s1']['del'], true);
      });

      // 之后两边再各同步几轮，结果不变（没有死而复生）。
      await a.run((s, d) async => s.sync());
      await b.run((s, d) async => s.sync());
      await a.run((s, d) async {
        await s.sync();
        final bk = backend(s);
        final lists =
            ((await call(bk, 'GET', ['playlists'], {}))['items'] as List)
                .cast<Map>();
        expect(lists.map((l) => l['name']), ['上班路上']);
        final hearts =
            ((await call(bk, 'GET', ['favorites'], {}))['items'] as List)
                .map((e) => (e as Map)['id'])
                .toSet();
        expect(hearts, {
          'BV1:1',
          'BV2:1',
          'BV7:1',
        }, reason: 'Mac 新加的红心传到了 iPhone');
        expect(d.subs()['s1']['del'], true);
      });
    });

    test('服务器不覆盖已有文件时仍能同步（凭证、红心都到对方）', () async {
      dav.noOverwrite = true;
      a.netease = {'MUSIC_U': 'first'};
      await a.run((s, d) async {
        await d.writeHearts({'BV1:1': heart('BV1', t0 + 1)});
        expect(await s.sync(), true, reason: s.error);
      });
      await b.run((s, d) async => s.sync());
      // A 之后登录 B 站并加红心，再次上传（服务器对同名文件不覆盖）。
      a.bilibili = {'SESSDATA': 'late-login'};
      await a.run((s, d) async {
        await d.writeHearts({...d.hearts(), 'BV2:1': heart('BV2', t0 + 2)});
        expect(await s.sync(), true, reason: s.error);
      });
      await b.run((s, d) async {
        expect(await s.sync(), true, reason: s.error);
        expect(d.hearts().keys, containsAll(['BV1:1', 'BV2:1']));
      });
      expect(b.bilibili, {'SESSDATA': 'late-login'});
    });

    test('每次上传是新文件，旧版本被清理，不会堆积', () async {
      Set<String> mine() => dav.files.keys
          .where((k) => k.contains('/devices/'))
          .map((k) => k.split('/').last)
          .toSet();
      for (var i = 1; i <= 4; i++) {
        await a.run((s, d) async {
          await d.writeHearts({...d.hearts(), 'BV$i:1': heart('BV$i', t0 + i)});
          await s.sync();
        });
      }
      expect(mine().length, 1, reason: '只留最新一份：${mine()}');
    });

    test('增量：对方没变就不重新下载；无变化的同步只列一次目录', () async {
      await a.run((s, d) async {
        await d.writeHearts({'BV1:1': heart('BV1', t0 + 100)});
        await s.sync();
      });
      await b.run((s, d) async => s.sync());
      final gets = dav.gets, puts = dav.puts, lists = dav.lists;
      await b.run((s, d) async => s.sync());
      expect(dav.puts, puts, reason: '本机没变不上传');
      expect(dav.lists, lists + 1, reason: '只列了一次目录');
      // 只剩读取 manifest 校验口令；A 的快照没有被再次下载。
      expect(dav.gets - gets, 1);
    });

    test('快照是压缩的，且远端每台设备只有一个文件', () async {
      await a.run((s, d) async {
        final table = <String, dynamic>{
          for (var i = 0; i < 500; i++) 'BV$i:1': heart('BV$i', t0 + i),
        };
        await d.writeHearts(table);
        await s.sync();
      });
      final file = dav.files.entries
          .firstWhere((e) => e.key.startsWith('/dav/Dymuse/devices/'))
          .value;
      final plain = gzip.decode(file).length;
      expect(file.length, lessThan(plain ~/ 4), reason: '重复的字段压缩得很好');
      expect(dav.files.keys.where((k) => k.contains('/devices/')).length, 1);
    });

    test('每天一份备份，只保留最近 7 天', () async {
      await a.run((s, d) async {
        await d.writeHearts({'BV1:1': heart('BV1', t0 + 1)});
        await s.sync();
      });
      expect(dav.files.keys.where((k) => k.contains('/backup/')).length, 1);
      // 预置 9 份旧备份，下一次“新的一天”上传后只剩 7 份。
      final id = dav.files.keys
          .firstWhere((k) => k.contains('/backup/'))
          .split('-')
          .last;
      for (var day = 1; day <= 9; day++) {
        final name =
            '/dav/Dymuse/backup/2020-01-${day.toString().padLeft(2, '0')}-$id';
        dav.files[name] = [1];
        dav.etags[name] = '"x$day"';
      }
      a.store['sync.backup.day'] = '2020-01-01';
      await a.run((s, d) async {
        await d.writeHearts({'BV2:1': heart('BV2', t0 + 2)});
        await s.sync();
      });
      expect(dav.files.keys.where((k) => k.contains('/backup/')).length, 7);
    });

    test('损坏的快照被跳过，不影响其他设备', () async {
      await a.run((s, d) async {
        await d.writeHearts({'BV1:1': heart('BV1', t0 + 1)});
        await s.sync();
      });
      dav.files['/dav/Dymuse/devices/broken.json.gz'] = [1, 2, 3];
      dav.etags['/dav/Dymuse/devices/broken.json.gz'] = '"b"';
      await b.run((s, d) async {
        expect(await s.sync(), true, reason: s.error);
        expect(d.hearts().keys, contains('BV1:1'));
      });
    });

    test('无变化时再次同步不重复写远端', () async {
      await a.run((s, d) async {
        await d.writeHearts({'BV1:1': heart('BV1', t0 + 100)});
        await s.sync();
      });
      final before = dav.puts;
      await a.run((s, d) async => s.sync());
      expect(dav.puts, before);
    });
  });
}
