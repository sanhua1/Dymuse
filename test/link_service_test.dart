import 'dart:convert';
import 'dart:io';

import 'package:dymuse/link_service/link_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用真正的 server/server.py 起一个本机实例（不接网易云 API），测客户端与服务端的整条协议。
void main() {
  late Process process;
  late Directory state;
  late int port;
  late String url;

  Future<({int status, Map<String, dynamic> body})> post(
    String path,
    Map<String, Object?> body, {
    String? auth,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('$url$path'));
      final bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      if (auth != null) request.headers.set('authorization', auth);
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      return (
        status: response.statusCode,
        body: jsonDecode(text) as Map<String, dynamic>,
      );
    } finally {
      client.close(force: true);
    }
  }

  setUpAll(() async {
    state = await Directory.systemTemp.createTemp('link-state');
    final probe = await ServerSocket.bind('127.0.0.1', 0);
    port = probe.port;
    await probe.close();
    url = 'http://127.0.0.1:$port';
    process = await Process.start(
      Platform.environment['DYMUSE_TEST_PYTHON'] ??
          (Platform.isWindows ? 'py' : 'python3'),
      ['server/server.py', 'serve'],
      environment: {
        'DYMUSE_STATE': state.path,
        'DYMUSE_BIND': '127.0.0.1',
        'DYMUSE_PORT': '$port',
        'DYMUSE_NETEASE_API': '',
      },
    );
    process.stderr.drain<void>();
    for (var i = 0; i < 50; i++) {
      try {
        final socket = await Socket.connect('127.0.0.1', port);
        await socket.close();
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  tearDownAll(() async {
    process.kill();
    // 保留隔离测试数据，便于失败后排查；不自动清理文件。
  });

  LinkService service() {
    FlutterSecureStorage.setMockInitialValues({});
    return LinkService(storage: const FlutterSecureStorage());
  }

  test('地址整理：补全 https、去掉斜杠，明文 http 只允许本机和局域网', () {
    expect(LinkService.normalizeUrl('a.example.com/'), 'https://a.example.com');
    expect(
      LinkService.normalizeUrl(' https://a.example.com/x/ '),
      'https://a.example.com/x',
    );
    expect(
      LinkService.normalizeUrl('http://127.0.0.1:9'),
      'http://127.0.0.1:9',
    );
    expect(
      LinkService.normalizeUrl('http://192.168.1.5:8080'),
      'http://192.168.1.5:8080',
    );
    expect(LinkService.normalizeUrl('http://10.0.0.2'), 'http://10.0.0.2');
    expect(LinkService.normalizeUrl('http://172.20.1.1'), 'http://172.20.1.1');
    expect(LinkService.normalizeUrl('http://172.32.1.1'), isNull);
    expect(LinkService.normalizeUrl('http://a.example.com'), isNull);
    expect(LinkService.normalizeUrl(''), '');
  });

  test('没有配置：不联网、不提供账号', () async {
    final s = service();
    await s.start();
    await s.refresh();
    expect(s.configured, isFalse);
    expect(s.cookie, isNull);
    expect(s.error, isNull);
  });

  test('服务还没首次设置，再到设置好、没有取链账号、取到账号', () async {
    final s = service();
    await s.configure(url: url, username: 'family', password: 'correct-horse');
    expect(s.error, contains('首次设置'));

    final code = File('${state.path}/setup_code').readAsStringSync().trim();
    final done = await post('/v1/setup', {
      'code': code,
      'username': 'family',
      'password': 'correct-horse',
    });
    expect(done.status, 200);

    await s.refresh();
    expect(s.error, contains('还没有设置取链账号'));
    expect(s.cookie, isNull);

    final auth = 'Basic ${base64.encode(utf8.encode('family:correct-horse'))}';
    final saved = await post('/v1/credential/paste', {
      'cookie': 'MUSIC_U=secret-value; __csrf=c; other=1',
    }, auth: auth);
    expect(saved.status, 200);

    await s.refresh();
    expect(s.error, isNull);
    expect(s.cookie, {'MUSIC_U': 'secret-value', '__csrf': 'c'});
  });

  test('密码不对、地址不是取链服务、取到账号后改密码', () async {
    var s = service();
    await s.configure(url: url, username: 'family', password: 'wrong-pass');
    expect(s.error, '账号或密码不正确。');
    expect(s.cookie, isNull);

    s = service();
    await s.configure(url: 'http://127.0.0.1:1', username: 'a', password: 'b');
    expect(s.error, contains('无法连接'));

    s = service();
    await s.configure(url: url, username: 'family', password: 'correct-horse');
    expect(s.error, isNull);
    expect(s.cookie?['MUSIC_U'], 'secret-value');

    // 在面板里改了密码：旧密码刷新失败，但已取到的账号不会被清掉
    final auth = 'Basic ${base64.encode(utf8.encode('family:correct-horse'))}';
    final changed = await post('/v1/account', {
      'currentPassword': 'correct-horse',
      'newPassword': 'brand-new-pass',
    }, auth: auth);
    expect(changed.status, 200);
    await s.refresh();
    expect(s.error, '账号或密码不正确。');
    expect(s.cookie?['MUSIC_U'], 'secret-value');
    await s.configure(url: url, username: 'family', password: 'brand-new-pass');
    expect(s.error, isNull);
  });

  test('开关：关闭后不提供账号也不联网，重新打开恢复，设置会保留', () async {
    final s = service();
    await s.configure(url: url, username: 'family', password: 'brand-new-pass');
    expect(s.cookie?['MUSIC_U'], 'secret-value');
    await s.setEnabled(false);
    expect(s.enabled, isFalse);
    expect(s.cookie, isNull);
    expect(s.configured, isTrue);
    await s.refresh();
    expect(s.error, isNull);
    await s.setEnabled(true);
    expect(s.cookie?['MUSIC_U'], 'secret-value');
  });

  test('关闭服务后沿用本机缓存；清除配置后不再提供账号', () async {
    final s = service();
    await s.configure(url: url, username: 'family', password: 'brand-new-pass');
    expect(s.ready, isTrue);
    process.kill();
    await process.exitCode;
    await s.refresh();
    expect(s.cookie?['MUSIC_U'], 'secret-value');
    expect(s.error, contains('沿用上次获取的账号'));
    await s.clear();
    expect(s.configured, isFalse);
    expect(s.cookie, isNull);
  });
}
