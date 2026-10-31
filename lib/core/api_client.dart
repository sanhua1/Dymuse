import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../local/backend.dart';
import 'media_cache.dart';

typedef Json = Map<String, dynamic>;

/// 请求缓存只用于浏览页：[cacheWrite] 区域里的 GET 成功后写入磁盘，
/// [cacheOnly] 区域里的 GET 只读磁盘、不发网络请求（未命中抛 CACHE_MISS）。
const cacheWrite = #dymuse.cacheWrite, cacheOnly = #dymuse.cacheOnly;

/// 纯前端版：所有 /api/v1 请求由手机内的 [LocalBackend] 处理，
/// 不连接任何自建服务；公开成员与后端版保持一致，界面代码无需区分。
class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  LocalBackend? backend;
  /// 本机伪地址：封面等界面代码用它判断“自有资源”，实际不发网络请求。
  String server = 'dymuse://local';

  /// 登录后为网易云用户 ID，用于切换账号时清理缓存与喜欢状态。
  String? token;
  void Function()? onUnauthorized;
  MediaCache? cache;
  String? cacheScope;

  Uri uri(String path, [Map<String, dynamic>? query]) => Uri.parse(
    'dymuse://local/api/v1$path',
  ).replace(queryParameters: query?.map((key, value) => MapEntry(key, '$value')));

  Future<dynamic> get(String path, [Json? query]) async {
    final store = cache, scope = cacheScope;
    final key = '$scope ${uri(path, query)}';
    if (Zone.current[cacheOnly] == true) {
      final bytes = store == null || scope == null
          ? null
          : await store.read(CacheKind.data, key);
      if (bytes == null) throw const ApiException('CACHE_MISS', '没有缓存。');
      return jsonDecode(utf8.decode(bytes));
    }
    final data = await request('GET', path, query: query);
    if (Zone.current[cacheWrite] == true && store != null && scope != null) {
      unawaited(
        store.write(CacheKind.data, key, utf8.encode(jsonEncode(data))),
      );
    }
    return data;
  }

  Future<dynamic> post(String path, [Json? body]) =>
      request('POST', path, body: body);
  Future<dynamic> put(String path, Json body) =>
      request('PUT', path, body: body);

  Future<List<int>?> download(String address) async => null;

  Future<dynamic> request(
    String method,
    String path, {
    Json? query,
    Json? body,
  }) async {
    final local = backend;
    if (local == null) {
      throw const ApiException('NOT_READY', '应用尚未初始化完成，请稍后重试。');
    }
    // 与后端接口路径保持一致：/netease/* 交给网易云部分，/playback/* 交给队列。
    final relative = path.startsWith('/netease')
        ? path.substring('/netease'.length)
        : path;
    final session = token;
    try {
      return await local.handle(method, relative, query, body);
    } on LocalError catch (error) {
      if (error.status == 401 && session != null && token == session) {
        onUnauthorized?.call();
      }
      throw ApiException(error.code, error.message, error.status);
    } on SocketException {
      throw const ApiException('NETWORK', '无法连接网络，请检查网络。');
    } on TimeoutException {
      throw const ApiException('TIMEOUT', '请求超时，请稍后重试。');
    } on http.ClientException {
      throw const ApiException('NETWORK', '网络连接中断，请重试。');
    }
  }

  /// 本地请求没有在途传输，保留接口以兼容关闭流程。
  void cancelPending() {}

  void close() {
    _client.close();
  }
}

class ApiException implements Exception {
  const ApiException(this.code, this.message, [this.status = 0]);
  final String code;
  final String message;
  final int status;
  @override
  String toString() => message;
}

String readableError(Object error) =>
    error is ApiException ? error.message : '操作失败，请重试。';
