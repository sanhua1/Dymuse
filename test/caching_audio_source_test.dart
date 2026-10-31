import 'dart:async';
import 'dart:io';

import 'package:dymuse/playback/caching_audio_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// 模拟网易云 CDN：完整响应不带 Accept-Ranges，但支持 Range（206）。
/// [cutAt] 不为空时，完整下载发到这个字节就断开连接（模拟网络中断）。
Future<(HttpServer, List<String?>)> _origin(
  List<int> data, {
  int? cutAt,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final ranges = <String?>[];
  server.listen((request) async {
    final range = request.headers.value(HttpHeaders.rangeHeader);
    ranges.add(range);
    final response = request.response;
    response.headers.contentType = ContentType('audio', 'mpeg');
    if (range == null && cutAt != null) {
      response.contentLength = data.length;
      final socket = await response.detachSocket();
      socket.add(data.sublist(0, cutAt));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      socket.destroy();
      return;
    }
    if (range == null) {
      response.contentLength = data.length;
      // 分块慢速发送，模拟边下边播。
      for (var i = 0; i < data.length; i += 4096) {
        response.add(data.sublist(i, (i + 4096).clamp(0, data.length)));
        await response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    } else {
      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
      final start = int.parse(match[1]!);
      final end = match[2]!.isEmpty ? data.length - 1 : int.parse(match[2]!);
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${data.length}',
      );
      response.contentLength = end - start + 1;
      response.add(data.sublist(start, end + 1));
    }
    await response.close();
  });
  return (server, ranges);
}

Future<List<int>> _read(Stream<List<int>> stream) async => [
  for (final chunk in await stream.toList()) ...chunk,
];

void main() {
  final data = List<int>.generate(2 * 1024 * 1024, (i) => (i * 31) % 251);
  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('dymuse-audio'));
  tearDown(() => folder.deleteSync(recursive: true));

  test('源站不声明 Accept-Ranges 时仍按分段回应，并在下完后写入缓存', () async {
    final (server, ranges) = await _origin(data);
    final file = File('${folder.path}/song');
    final source = CachingAudioSource(
      Uri.parse('http://127.0.0.1:${server.port}/a.mp3'),
      file: file,
    );
    // 播放器先探测开头两个字节：要拿到总长度和分段支持。
    final probe = await source.request(0, 2);
    expect(probe.rangeRequestsSupported, isTrue);
    expect(probe.sourceLength, data.length);
    expect(await _read(probe.stream), data.sublist(0, 2));
    // 跳到后段：不等整首下载，直接向源站发 Range 请求。
    final tail = await source.request(data.length - 1000);
    expect(tail.sourceLength, data.length);
    expect(await _read(tail.stream), data.sublist(data.length - 1000));
    expect(ranges, contains('bytes=${data.length - 1000}-${data.length - 1}'));
    // 从头完整读取：跟随下载进度，内容一致。
    final whole = await source.request();
    expect(await _read(whole.stream), data);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(file.existsSync(), isTrue);
    expect(file.readAsBytesSync(), data);
    expect(File('${file.path}.part').existsSync(), isFalse);
    // 整首只下载一次（另一次是 Range 请求）。
    expect(ranges.where((range) => range == null).length, 1);
    // 已缓存后从文件读取，不再请求源站。
    final count = ranges.length;
    final cached = await source.request(100, 200);
    expect(await _read(cached.stream), data.sublist(100, 200));
    expect(cached.sourceLength, data.length);
    expect(ranges.length, count);
    await server.close(force: true);
  });

  test('整首下载中途断开时，剩余部分改用 Range 请求，读取不中断', () async {
    final (server, ranges) = await _origin(data, cutAt: 300 * 1024);
    final file = File('${folder.path}/song');
    final source = CachingAudioSource(
      Uri.parse('http://127.0.0.1:${server.port}/a.mp3'),
      file: file,
    );
    final whole = await source.request();
    expect(await _read(whole.stream), data);
    expect(ranges.whereType<String>(), isNotEmpty);
    // 下载不完整，不写入缓存。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(file.existsSync(), isFalse);
    expect(File('${file.path}.part').existsSync(), isFalse);
    await server.close(force: true);
  });

  test('换歌时取消其他歌曲的下载，未下完的不进缓存', () async {
    final (server, _) = await _origin(data);
    final first = File('${folder.path}/first'),
        second = File('${folder.path}/second');
    final uri = Uri.parse('http://127.0.0.1:${server.port}/a.mp3');
    final probe = await CachingAudioSource(uri, file: first).request(0, 2);
    await _read(probe.stream);
    CachingAudioSource.cancelOthers(second);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(first.existsSync(), isFalse);
    expect(File('${first.path}.part').existsSync(), isFalse);
    await server.close(force: true);
  });
}
