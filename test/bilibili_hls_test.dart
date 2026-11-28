import 'dart:io';
import 'dart:typed_data';

import 'package:dymuse/bilibili/hls_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

/// 拼一个最小的分片 MP4 文件头：ftyp + moov + sidx。
Uint8List _head({
  int version = 0,
  List<(int, int)> refs = const [(1000, 48000), (2000, 96000)],
}) {
  final out = BytesBuilder();
  void box(String type, List<int> payload) {
    final size = 8 + payload.length;
    out
      ..add([size >> 24 & 255, size >> 16 & 255, size >> 8 & 255, size & 255])
      ..add(type.codeUnits)
      ..add(payload);
  }

  List<int> u32(int v) => [v >> 24 & 255, v >> 16 & 255, v >> 8 & 255, v & 255];
  box('ftyp', List.filled(8, 0));
  box('moov', List.filled(20, 0));
  final sidx = <int>[
    version,
    0,
    0,
    0,
    ...u32(1),
    ...u32(48000),
    if (version == 0) ...[
      ...u32(0),
      ...u32(0),
    ] else ...[
      ...u32(0),
      ...u32(0),
      ...u32(0),
      ...u32(0),
    ],
    0,
    0,
    ...[refs.length >> 8, refs.length & 255],
    for (final (size, duration) in refs) ...[
      ...u32(size),
      ...u32(duration),
      ...u32(0),
    ],
  ];
  box('sidx', sidx);
  return out.takeBytes();
}

void main() {
  test('解析 ftyp/moov/sidx，得到初始化段与各分片的字节范围', () {
    final mp4 = FragmentedMp4.parse(_head());
    // ftyp 16 字节 + moov 28 字节
    expect(mp4.initLength, 44);
    // sidx 在 44..44+(8+12+8+4+... )；首个分片紧跟在 sidx 后。
    expect(mp4.segments.length, 2);
    expect(mp4.segments[0].length, 1000);
    expect(mp4.segments[1].offset, mp4.segments[0].offset + 1000);
    expect(mp4.segments[0].seconds, 1.0);
    expect(mp4.segments[1].seconds, 2.0);
  });

  test('64 位 sidx（version 1）同样可解析', () {
    final mp4 = FragmentedMp4.parse(_head(version: 1));
    expect(mp4.segments.length, 2);
    expect(mp4.segments[0].length, 1000);
  });

  test('播放列表是按字节范围的 VOD HLS', () {
    final text = FragmentedMp4.parse(_head()).playlist('audio.m4s');
    expect(text, startsWith('#EXTM3U'));
    expect(text, contains('#EXT-X-MAP:URI="audio.m4s",BYTERANGE="44@0"'));
    expect(text, contains('#EXT-X-BYTERANGE:1000@'));
    expect(text, contains('#EXT-X-TARGETDURATION:2'));
    expect(text.trimRight(), endsWith('#EXT-X-ENDLIST'));
  });

  test('缺少 moov 或 sidx 时报错', () {
    expect(
      () => FragmentedMp4.parse(Uint8List(8)),
      throwsA(isA<HlsException>()),
    );
  });

  group('分片转发', () {
    late HttpServer upstream;
    late bool stall;
    setUp(() async {
      BiliHlsProxy.stallTimeout = const Duration(milliseconds: 500);
      stall = false;
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        request.response
          ..contentLength = 1000
          ..add(List.filled(100, 1));
        await request.response.flush();
        if (stall) return; // 发了一部分就不动了，连接也不关
        request.response.add(List.filled(900, 2));
        await request.response.close();
      });
    });
    tearDown(() async {
      BiliHlsProxy.stallTimeout = const Duration(seconds: 10);
      await upstream.close(force: true);
    });

    /// 经代理取一个分片，返回收到的字节数；连接中途被断开（响应头前或传输中）返回 -1。
    Future<int> fetch() async {
      final proxy = await BiliHlsProxy.instance;
      final index = proxy.register(
        'http://127.0.0.1:${upstream.port}/a.m4s',
        {},
      );
      final client = HttpClient();
      try {
        final req = await client.getUrl(index.resolve('audio.m4s'));
        final res = await req.close();
        var bytes = 0;
        await for (final chunk in res) {
          bytes += chunk.length;
        }
        return bytes;
      } on IOException {
        return -1;
      } finally {
        client.close(force: true);
      }
    }

    test('上游正常：原样转发全部数据', () async {
      expect(await fetch(), 1000);
    });

    test('上游传到一半不动了：超时后断开，不会一直等', () async {
      stall = true;
      final watch = Stopwatch()..start();
      final bytes = await fetch().timeout(const Duration(seconds: 5));
      expect(bytes, lessThan(1000));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });
  });
}
