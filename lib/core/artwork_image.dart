import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'media_cache.dart';

/// 图片使用独立连接池；IOClient 以 set 写请求头，避免追加默认 Dart 标识。
class ArtworkLoader {
  ArtworkLoader({
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    this.maxBytes = 12 * 1024 * 1024,
    this.concurrency = 6,
  }) : client =
           client ??
           IOClient(
             HttpClient()
               ..userAgent = 'Dymuse/0.1.0'
               ..connectionTimeout = const Duration(seconds: 10)
               ..maxConnectionsPerHost = 6,
           );
  final http.Client client;
  final Duration timeout;
  final int maxBytes, concurrency;
  int _active = 0;
  final _waiting = <Completer<void>>[];

  /// 超时主动中断请求；重定向跨源时清除认证，不改变业务 API 的客户端。
  /// 并发由这里排队，超时从真正发出请求开始算。以前列表里几十张封面一起排在
  /// 连接池后面，排队时间也计入超时，网络一慢（如蜂窝网络）后面的封面全部超时，只剩占位图。
  Future<Uint8List> fetch(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    if (_active >= concurrency) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _active++;
    try {
      return await _fetch(url, headers);
    } finally {
      _active--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }

  Future<Uint8List> _fetch(String url, Map<String, String> headers) async {
    final abort = Completer<void>();
    try {
      return await _download(Uri.parse(url), headers, abort).timeout(
        timeout,
        onTimeout: () {
          if (!abort.isCompleted) abort.complete();
          throw TimeoutException('封面请求超时', timeout);
        },
      );
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<Uint8List> _download(
    Uri original,
    Map<String, String> headers,
    Completer<void> abort,
  ) async {
    var uri = original;
    var sensitiveAllowed = true;
    for (var redirects = 0; redirects <= 3; redirects++) {
      if (abort.isCompleted) throw const ArtworkException('CANCELLED');
      if (!['https', 'http'].contains(uri.scheme) ||
          !uri.hasAuthority ||
          uri.userInfo.isNotEmpty) {
        throw const ArtworkException('INVALID_URL');
      }
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers.addAll({
              for (final entry in headers.entries)
                if (sensitiveAllowed ||
                    ![
                      'authorization',
                      'cookie',
                      'proxy-authorization',
                    ].contains(entry.key.toLowerCase()))
                  entry.key: entry.value,
            })
            ..headers[HttpHeaders.userAgentHeader] = 'Dymuse/0.1.0';
      final response = await client.send(request);
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        await response.stream.listen(null).cancel();
        final location = response.headers['location'];
        if (location == null || redirects == 3) {
          throw const ArtworkException('INVALID_REDIRECT');
        }
        final next = uri.resolve(location);
        if (!['https', 'http'].contains(next.scheme) ||
            !next.hasAuthority ||
            next.userInfo.isNotEmpty) {
          throw const ArtworkException('INVALID_REDIRECT');
        }
        if (uri.scheme == 'https' && next.scheme != 'https') {
          throw const ArtworkException('INSECURE_REDIRECT');
        }
        sensitiveAllowed =
            sensitiveAllowed &&
            next.scheme == original.scheme &&
            next.host == original.host &&
            next.port == original.port;
        uri = next;
        continue;
      }
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > maxBytes) {
        await response.stream.listen(null).cancel();
        throw ArtworkException(
          response.statusCode == 200
              ? 'TOO_LARGE'
              : 'HTTP_${response.statusCode}',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const ArtworkException('TOO_LARGE');
        }
        bytes.add(chunk);
      }
      if (bytes.isEmpty) throw const ArtworkException('EMPTY_IMAGE');
      return bytes.takeBytes();
    }
    throw const ArtworkException('INVALID_REDIRECT');
  }

  void close() => client.close();
}

class ArtworkException implements Exception {
  const ArtworkException(this.code);
  final String code;
  @override
  String toString() => 'Artwork $code';
}

/// 沿用 Flutter 解码和内存缓存；缓存键包含认证头，避免私人封面跨会话命中。
class ArtworkImage extends ImageProvider<ArtworkImage> {
  ArtworkImage(
    this.url, {
    Map<String, String> headers = const {},
    ArtworkLoader? loader,
  }) : headers = Map.unmodifiable(headers),
       loader = loader ?? sharedLoader;
  static final sharedLoader = ArtworkLoader();
  final String url;
  final Map<String, String> headers;
  final ArtworkLoader loader;

  @override
  Future<ArtworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    ArtworkImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _decode(key, decode), scale: 1);

  /// 带认证的私人封面按服务与用户隔离缓存；公开图片按地址缓存。
  String get _cacheKey {
    final private = headers.keys.any((k) => k.toLowerCase() == 'authorization');
    return private ? '${MediaCache.privateScope} $url' : url;
  }

  /// 先读磁盘缓存；网络失败（多见于蜂窝网络下连接慢或被重置）稍后重试一次，
  /// 网易云图片再换一个 CDN 节点，仍失败才显示占位图。
  Future<ui.Codec> _decode(
    ArtworkImage key,
    ImageDecoderCallback decode,
  ) async {
    final cache = MediaCache.instance;
    try {
      var bytes = await cache?.read(CacheKind.images, key._cacheKey);
      if (bytes == null) {
        try {
          bytes = await loader.fetch(key.url, headers: key.headers);
        } on ArtworkException catch (error) {
          // 地址无效、过大、404 等重试也没用；只重试服务端错误。
          if (!error.code.startsWith('HTTP_5')) rethrow;
          bytes = await _retry(key);
        } catch (_) {
          // 超时、连接被重置等网络错误。
          bytes = await _retry(key);
        }
        unawaited(cache?.write(CacheKind.images, key._cacheKey, bytes));
      }
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    }
  }

  Future<Uint8List> _retry(ArtworkImage key) async {
    await Future<void>.delayed(const Duration(milliseconds: 800));
    return loader.fetch(alternateHost(key.url), headers: key.headers);
  }

  @override
  bool operator ==(Object other) =>
      other is ArtworkImage &&
      other.url == url &&
      identical(other.loader, loader) &&
      mapEquals(other.headers, headers);
  @override
  int get hashCode => Object.hash(
    url,
    loader,
    Object.hashAllUnordered(
      headers.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );
  @override
  String toString() => 'ArtworkImage(${Uri.parse(url).host})';
}

/// 网易云图片 p1–p4 节点内容相同；某个节点在当前网络下不可达时换一个。
String alternateHost(String url) {
  final uri = Uri.tryParse(url);
  final match = uri == null
      ? null
      : RegExp(r'^p(\d)\.music\.126\.net$').firstMatch(uri.host);
  if (match == null) return url;
  final next = int.parse(match[1]!) % 4 + 1;
  return uri!.replace(host: 'p$next.music.126.net').toString();
}

/// 缩略图尺寸分档复用，只有已知网易云图片域名获得 CDN 参数。
Uri thumbnailAddress(Uri uri, double pixels) {
  if (uri.host != 'music.126.net' && !uri.host.endsWith('.music.126.net')) {
    return uri;
  }
  final target = pixels.ceil().clamp(1, 1600);
  final bucket = [
    64,
    128,
    256,
    512,
    1024,
    1600,
  ].firstWhere((size) => size >= target);
  return uri.replace(
    scheme: 'https',
    queryParameters: {...uri.queryParameters, 'param': '${bucket}y$bucket'},
  );
}
