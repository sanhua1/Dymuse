// 最小 WebDAV 客户端：只用 GET / PUT / MKCOL，不需要解析 PROPFIND 的 XML。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class DavException implements Exception {
  const DavException(this.code, this.message, [this.status = 0]);
  final String code, message;
  final int status;
  @override
  String toString() => message;
}

/// 带条件写入失败（别的设备刚刚改过）。
class DavConflict extends DavException {
  const DavConflict() : super('WEBDAV_CONFLICT', '远端刚刚被另一台设备更新，请重试。', 412);
}

/// 目录列表里的一项。[tag] 优先用 ETag，缺失时用“修改时间+大小”，只用来判断有没有变化。
class DavEntry {
  const DavEntry(this.name, this.tag, this.isDir);
  final String name, tag;
  final bool isDir;
}

class DavFile {
  const DavFile(this.bytes, this.etag);
  final Uint8List bytes;
  final String? etag;
}

class WebDavClient {
  WebDavClient(this.base, this.user, this.password);

  /// 服务器地址（含目录），例如 `https://dav.example.com/dav`。
  final String base;
  final String user, password;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 20);

  Uri _uri(String path) {
    final root = Uri.parse(base.endsWith('/') ? base : '$base/');
    final parts = [
      ...root.pathSegments.where((p) => p.isNotEmpty),
      ...path.split('/').where((p) => p.isNotEmpty),
    ];
    return root.replace(pathSegments: parts);
  }

  Future<HttpClientResponse> _send(
    String method,
    String path, {
    Uint8List? body,
    Map<String, String>? headers,
  }) async {
    try {
      final request = await _http.openUrl(method, _uri(path));
      request.headers
        ..set(
          HttpHeaders.authorizationHeader,
          'Basic ${base64.encode(utf8.encode('$user:$password'))}',
        )
        ..set(HttpHeaders.userAgentHeader, 'Dymuse-Sync/1');
      headers?.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentLength = body.length;
        request.add(body);
      }
      return await request.close().timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw const DavException('WEBDAV_TIMEOUT', '连接 WebDAV 服务器超时。');
    } on SocketException {
      throw const DavException('WEBDAV_NETWORK', '无法连接 WebDAV 服务器，请检查地址和网络。');
    } on HandshakeException {
      throw const DavException('WEBDAV_TLS', '与 WebDAV 服务器建立安全连接失败。');
    } on HttpException catch (e) {
      throw DavException('WEBDAV_NETWORK', '网络连接中断：${e.message}');
    } on ArgumentError {
      throw const DavException('WEBDAV_URL', 'WebDAV 地址无效。');
    }
  }

  static DavException _status(HttpClientResponse res, String action) {
    final code = res.statusCode;
    if (code == 401 || code == 403) {
      return DavException('WEBDAV_AUTH', '用户名或密码不正确，或没有写入权限。', code);
    }
    if (code == 507) return DavException('WEBDAV_FULL', 'WebDAV 空间已满。', code);
    return DavException('WEBDAV_HTTP', '$action失败（HTTP $code）。', code);
  }

  /// 读取文件；不存在返回 null。
  Future<DavFile?> get(String path) async {
    final res = await _send('GET', path);
    if (res.statusCode == 404) {
      await res.drain<void>();
      return null;
    }
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw _status(res, '读取');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    return DavFile(builder.takeBytes(), res.headers.value('etag'));
  }

  /// 写入文件。[etag] 存在时要求远端仍是该版本；[mustNotExist] 要求文件还不存在。
  Future<void> put(
    String path,
    Uint8List body, {
    String? etag,
    bool mustNotExist = false,
  }) async {
    final res = await _send(
      'PUT',
      path,
      body: body,
      headers: {
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        if (etag != null) HttpHeaders.ifMatchHeader: etag,
        if (mustNotExist) HttpHeaders.ifNoneMatchHeader: '*',
      },
    );
    await res.drain<void>();
    final code = res.statusCode;
    if (code == 412) throw const DavConflict();
    if (code != 200 && code != 201 && code != 204) throw _status(res, '写入');
  }

  /// 逐级创建目录；已存在（405）视为成功。
  Future<void> ensureDir(String path) async {
    var current = '';
    for (final part in path.split('/').where((p) => p.isNotEmpty)) {
      current = current.isEmpty ? part : '$current/$part';
      final res = await _send('MKCOL', current);
      await res.drain<void>();
      final code = res.statusCode;
      if (code == 201 || code == 405 || code == 301 || code == 200) continue;
      // 个别服务器对已存在目录返回 409/403，先当作存在，真有问题写入时会报错。
      if (code == 409 || code == 403) continue;
      if (code == 401) throw _status(res, '创建目录');
      throw _status(res, '创建目录');
    }
  }

  static final _blocks = RegExp(
    r'<(?:\w+:)?response[ >].*?</(?:\w+:)?response>',
    dotAll: true,
  );
  static String? _tag(String block, String name) {
    final m = RegExp(
      '<(?:\\w+:)?$name[^>]*>([^<]*)</(?:\\w+:)?$name>',
    ).firstMatch(block);
    return m == null ? null : m.group(1)!.trim();
  }

  /// 列出目录（Depth: 1）；目录不存在返回空列表。不依赖 XML 库，只取需要的几个字段。
  Future<List<DavEntry>> list(String path) async {
    final res = await _send(
      'PROPFIND',
      path,
      body: Uint8List.fromList(
        utf8.encode(
          '<?xml version="1.0"?><propfind xmlns="DAV:"><prop>'
          '<getetag/><getlastmodified/><getcontentlength/><resourcetype/>'
          '</prop></propfind>',
        ),
      ),
      headers: {'Depth': '1', HttpHeaders.contentTypeHeader: 'application/xml'},
    );
    if (res.statusCode == 404) {
      await res.drain<void>();
      return [];
    }
    if (res.statusCode != 207 && res.statusCode != 200) {
      await res.drain<void>();
      throw _status(res, '读取目录');
    }
    final xml = await utf8.decodeStream(res);
    final self = _uri(path).pathSegments.where((p) => p.isNotEmpty).toList();
    final entries = <DavEntry>[];
    for (final m in _blocks.allMatches(xml)) {
      final block = m.group(0)!;
      final href = _tag(block, 'href');
      if (href == null) continue;
      final parts = Uri.decodeFull(
        Uri.parse(href).path,
      ).split('/').where((p) => p.isNotEmpty).toList();
      // 目录自己也会出现在结果里，只要它下面的一级。
      if (parts.length != self.length + 1) continue;
      final etag = _tag(block, 'getetag') ?? '';
      final tag = etag.isNotEmpty
          ? etag
          : '${_tag(block, 'getlastmodified')}|${_tag(block, 'getcontentlength')}';
      entries.add(
        DavEntry(
          parts.last,
          tag,
          RegExp(r'<(?:\w+:)?collection').hasMatch(block),
        ),
      );
    }
    return entries;
  }

  Future<void> delete(String path) async {
    final res = await _send('DELETE', path);
    await res.drain<void>();
    final code = res.statusCode;
    if (code != 200 && code != 204 && code != 404) throw _status(res, '删除');
  }

  void close() => _http.close(force: true);
}
