// B 站 DASH 音频是分片 MP4（.m4s），AVPlayer 无法直接打开（format not supported）。
// 这里在本机起一个回环服务：读取文件开头的 moov/sidx，生成按字节范围的 fMP4 HLS 播放列表，
// 分片请求原样转发给 B 站（带 Referer 与 UA），AVPlayer 即可把它当纯音频播放。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class HlsException implements Exception {
  const HlsException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 解析出的 HLS 描述：初始化段长度与各分片（偏移、长度、秒）。
class FragmentedMp4 {
  const FragmentedMp4(this.initLength, this.segments);
  final int initLength;
  final List<({int offset, int length, double seconds})> segments;

  /// 读取 [head]（文件开头若干字节）里的 ftyp/moov/sidx。
  static FragmentedMp4 parse(Uint8List head) {
    final data = ByteData.sublistView(head);
    var position = 0, moovEnd = -1;
    ({int start, int end})? sidx;
    while (position + 8 <= head.length) {
      var size = data.getUint32(position);
      final type = String.fromCharCodes(
        head.sublist(position + 4, position + 8),
      );
      if (size == 1) {
        if (position + 16 > head.length) break;
        size = data.getUint64(position + 8);
      } else if (size == 0) {
        break;
      }
      if (size < 8) throw const HlsException('分片 MP4 结构无效。');
      if (type == 'moof' || type == 'mdat') break;
      final end = position + size;
      if (type == 'moov') {
        if (end > head.length) throw const HlsException('分片 MP4 文件头不完整。');
        moovEnd = end;
      } else if (type == 'sidx') {
        if (end > head.length) throw const HlsException('分片 MP4 索引不完整。');
        sidx = (start: position, end: end);
      }
      position = end;
    }
    if (moovEnd < 0 || sidx == null) {
      throw const HlsException('分片 MP4 缺少 moov 或 sidx。');
    }
    var cursor = sidx.start + 8;
    final version = data.getUint8(cursor);
    cursor += 4 + 4; // version/flags、reference_ID
    final timescale = data.getUint32(cursor);
    cursor += 4;
    final int firstOffset;
    if (version == 0) {
      cursor += 4;
      firstOffset = data.getUint32(cursor);
      cursor += 4;
    } else {
      cursor += 8;
      firstOffset = data.getUint64(cursor);
      cursor += 8;
    }
    cursor += 2;
    final count = data.getUint16(cursor);
    cursor += 2;
    if (timescale == 0 || count == 0) {
      throw const HlsException('分片 MP4 索引为空。');
    }
    var offset = sidx.end + firstOffset;
    final segments = <({int offset, int length, double seconds})>[];
    for (var i = 0; i < count; i++) {
      final size = data.getUint32(cursor) & 0x7FFFFFFF;
      final duration = data.getUint32(cursor + 4);
      cursor += 12;
      segments.add((
        offset: offset,
        length: size,
        seconds: duration / timescale,
      ));
      offset += size;
    }
    return FragmentedMp4(moovEnd, segments);
  }

  String playlist(String segmentUri) {
    final target = segments
        .map((s) => s.seconds)
        .fold<double>(1, (a, b) => b > a ? b : a)
        .ceil();
    final out = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:7')
      ..writeln('#EXT-X-TARGETDURATION:$target')
      ..writeln('#EXT-X-MEDIA-SEQUENCE:0')
      ..writeln('#EXT-X-PLAYLIST-TYPE:VOD')
      ..writeln('#EXT-X-INDEPENDENT-SEGMENTS')
      ..writeln('#EXT-X-MAP:URI="$segmentUri",BYTERANGE="$initLength@0"');
    for (final s in segments) {
      out
        ..writeln('#EXTINF:${s.seconds.toStringAsFixed(5)},')
        ..writeln('#EXT-X-BYTERANGE:${s.length}@${s.offset}')
        ..writeln(segmentUri);
    }
    out.writeln('#EXT-X-ENDLIST');
    return out.toString();
  }
}

class _Entry {
  _Entry(this.url, this.headers);
  final String url;
  final Map<String, String> headers;
  Future<String>? playlist;
}

/// 单例回环服务；每首歌注册一次，得到 `http://127.0.0.1:端口/<token>/index.m3u8`。
class BiliHlsProxy {
  BiliHlsProxy._(this._server) {
    _server.listen(_handle, onError: (_) {});
  }
  final HttpServer _server;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 30);
  final Map<String, _Entry> _entries = {};
  int _counter = 0;

  static Future<BiliHlsProxy>? _instance;
  static Future<BiliHlsProxy> get instance => _instance ??= HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  ).then(BiliHlsProxy._);

  /// 丢弃当前实例（回环 socket 可能已被 iOS 在挂起期间回收），下次 [instance] 重新监听。
  static Future<void> reset() async {
    final old = _instance;
    _instance = null;
    try {
      await (await old)?._server.close(force: true);
    } catch (_) {}
  }

  /// 注册一条上游直链；只保留最近的若干条，避免无限增长。
  Uri register(String url, Map<String, String> headers) {
    final token = '${++_counter}';
    _entries[token] = _Entry(url, headers);
    while (_entries.length > 8) {
      _entries.remove(_entries.keys.first);
    }
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: _server.port,
      path: '/$token/index.m3u8',
    );
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final parts = request.uri.pathSegments;
      final entry = parts.length == 2 ? _entries[parts[0]] : null;
      if (entry == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else if (parts[1] == 'index.m3u8') {
        final text = await (entry.playlist ??= _buildPlaylist(entry, parts[0]));
        request.response
          ..headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          )
          ..write(text);
      } else if (parts[1] == 'audio.m4s') {
        await _forward(request, entry);
        return;
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      request.response.statusCode = HttpStatus.badGateway;
    }
    await request.response.close();
  }

  Future<String> _buildPlaylist(_Entry entry, String token) async {
    final head = await _fetch(entry, 'bytes=0-262143');
    return FragmentedMp4.parse(head).playlist('audio.m4s');
  }

  Future<Uint8List> _fetch(_Entry entry, String range) async {
    final req = await _client.getUrl(Uri.parse(entry.url));
    try {
      entry.headers.forEach(req.headers.set);
      req.headers.set(HttpHeaders.rangeHeader, range);
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200 && res.statusCode != 206) {
        await res.drain<void>();
        throw HlsException('B 站音频请求失败（HTTP ${res.statusCode}）。');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in res) {
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } finally {
      req.abort();
    }
  }

  Future<void> _forward(HttpRequest request, _Entry entry) async {
    final req = await _client.getUrl(Uri.parse(entry.url));
    try {
      entry.headers.forEach(req.headers.set);
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      final res = await req.close().timeout(const Duration(seconds: 15));
      request.response.statusCode = res.statusCode;
      for (final name in const [
        HttpHeaders.contentRangeHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.acceptRangesHeader,
      ]) {
        final value = res.headers.value(name);
        if (value != null) request.response.headers.set(name, value);
      }
      request.response.headers.contentType = ContentType('audio', 'mp4');
      await request.response.addStream(res);
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
    } finally {
      req.abort();
    }
  }

  Future<void> close() async {
    await _server.close(force: true);
    _client.close(force: true);
    _instance = null;
  }
}
