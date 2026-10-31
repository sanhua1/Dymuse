// StreamAudioSource 在 just_audio 0.10.6 标为实验性接口；版本已锁定，升级时需复查。
// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:just_audio/just_audio.dart' as ja;

/// 边下边播并写入缓存的音频源，替代 just_audio 的 LockCachingAudioSource。
///
/// 网易云 CDN 支持 Range，但完整响应不带 Accept-Ranges 头；LockCachingAudioSource
/// 因此当作不支持分段，播放器拿不到总长度也不能跳读，总时长要等整首下载完才显示。
/// 这里始终按支持分段回应播放器：已下载的部分从文件读，未下载到的位置直接向源站
/// 发 Range 请求。整首只下载一次，先写 .part，完整后才改名为正式缓存文件。
/// 切歌时取消其他歌曲的下载（[cancelOthers]），快速连切时不会有十几个整首下载
/// 同时抢带宽，导致当前歌曲读不到数据而报错。
class CachingAudioSource extends ja.StreamAudioSource {
  CachingAudioSource(this.uri, {this.headers, required this.file});

  final Uri uri;
  final Map<String, String>? headers;
  final File file;

  /// 同一首歌只保留一个下载，重复播放时共用，避免两个任务写同一个 .part。
  static final _downloads = <String, _Download>{};

  /// 播放位置在已下载进度之后这么多字节以内时等下载追上，不另发 Range 请求。
  static const _followWindow = 512 * 1024;

  /// 换歌时调用：取消除 [keep] 以外的下载；没下完的不进缓存，下次播放重新下载。
  static void cancelOthers(File? keep) {
    for (final download in [..._downloads.values]) {
      if (download.file.path != keep?.path) download.cancel();
    }
  }

  @override
  Future<ja.StreamAudioResponse> request([int? start, int? end]) async {
    if (file.existsSync()) return _fromFile(start, end);
    final download = _downloads.putIfAbsent(
      file.path,
      () => _Download(uri, headers, file, () => _downloads.remove(file.path)),
    );
    await download.ready;
    if (download.complete) return _fromFile(start, end);
    final length = download.length;
    final from = start ?? 0;
    if (download.failed ||
        length == null ||
        from > download.progress + _followWindow) {
      return _fromOrigin(from, end ?? length, length, download.contentType);
    }
    final to = end ?? length;
    return ja.StreamAudioResponse(
      sourceLength: start != null ? length : null,
      contentLength: to - from,
      offset: start,
      contentType: download.contentType,
      stream: download.follow(from, to),
    );
  }

  Future<ja.StreamAudioResponse> _fromFile(int? start, int? end) async {
    final length = file.lengthSync();
    final from = start ?? 0;
    return ja.StreamAudioResponse(
      sourceLength: start != null ? length : null,
      contentLength: (end ?? length) - from,
      offset: start,
      contentType: await _Download.cachedType(file),
      stream: file.openRead(from, end),
    );
  }

  /// 未下载到的位置（例如拖到后段）直接向源站请求，不等整首下载。
  Future<ja.StreamAudioResponse> _fromOrigin(
    int start,
    int? end,
    int? length,
    String contentType,
  ) async {
    final range = await _range(uri, headers, start, end);
    final total =
        length ??
        int.tryParse(
          range.headers
                  .value(HttpHeaders.contentRangeHeader)
                  ?.split('/')
                  .last ??
              '',
        );
    return ja.StreamAudioResponse(
      sourceLength: total,
      contentLength: range.contentLength == -1 ? null : range.contentLength,
      offset: start,
      contentType: contentType,
      stream: range.stream,
    );
  }
}

/// 向源站请求 [start, end) 这一段；连接和读取都有超时，卡住时报错而不是一直等。
Future<({HttpHeaders headers, int contentLength, Stream<List<int>> stream})>
_range(Uri uri, Map<String, String>? headers, int start, int? end) async {
  final client = HttpClient()..connectionTimeout = _Download.timeout;
  try {
    final request = await client.getUrl(uri);
    headers?.forEach(request.headers.set);
    request.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=$start-${end == null ? '' : end - 1}',
    );
    final response = await request.close().timeout(_Download.timeout);
    if (response.statusCode != HttpStatus.partialContent) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    return (
      headers: response.headers,
      contentLength: response.contentLength,
      stream: response
          .timeout(_Download.timeout)
          .transform(
            StreamTransformer<List<int>, List<int>>.fromHandlers(
              handleError: (error, trace, sink) {
                client.close(force: true);
                sink.addError(error, trace);
              },
              handleDone: (sink) {
                client.close();
                sink.close();
              },
            ),
          ),
    );
  } catch (_) {
    client.close(force: true);
    rethrow;
  }
}

/// 一首歌的整首下载：顺序写入 .part，并通知等待中的读取者。
class _Download {
  _Download(this.uri, this.headers, this.file, this.onFinished) {
    unawaited(_run());
  }

  final Uri uri;
  final Map<String, String>? headers;
  final File file;
  final void Function() onFinished;
  final _ready = Completer<void>();
  final _changes = StreamController<void>.broadcast();
  final _client = HttpClient()..connectionTimeout = timeout;

  /// 连接、响应头和两块数据之间的最长等待。
  static const timeout = Duration(seconds: 15);

  int? length;
  int progress = 0;
  String contentType = 'audio/mpeg';
  bool failed = false;
  bool complete = false;
  bool cancelled = false;

  /// 换歌后不再需要：断开连接，_run 按失败处理并删除 .part。
  void cancel() {
    if (complete || failed) return;
    cancelled = true;
    _client.close(force: true);
  }

  File get part => File('${file.path}.part');
  File get _mime => File('${file.path}.mime');

  /// 响应头到达（或失败）后完成。
  Future<void> get ready => _ready.future;

  /// 旧缓存（LockCachingAudioSource 写的）有 .mime；没有时按文件头判断格式。
  static Future<String> cachedType(File file) async {
    try {
      final mime = File('${file.path}.mime');
      if (mime.existsSync()) return await mime.readAsString();
      final head = await file.openRead(0, 4).first;
      if (String.fromCharCodes(head) == 'fLaC') return 'audio/flac';
    } catch (_) {}
    return 'audio/mpeg';
  }

  Future<void> _run() async {
    final client = _client;
    RandomAccessFile? output;
    try {
      final request = await client.getUrl(uri);
      headers?.forEach(request.headers.set);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      length = response.contentLength == -1 ? null : response.contentLength;
      contentType = response.headers.contentType?.toString() ?? contentType;
      await part.parent.create(recursive: true);
      output = await part.open(mode: FileMode.write);
      _ready.complete();
      await for (final chunk in response.timeout(timeout)) {
        await output.writeFrom(chunk);
        progress += chunk.length;
        _changes.add(null);
      }
      await output.close();
      output = null;
      if (length != null && progress != length) {
        throw const HttpException('下载不完整');
      }
      await _mime.writeAsString(contentType);
      await part.rename(file.path);
      complete = true;
    } catch (_) {
      failed = true;
      try {
        await output?.close();
        if (part.existsSync()) await part.delete();
      } catch (_) {}
    } finally {
      client.close(force: true);
      if (!_ready.isCompleted) _ready.complete();
      _changes.add(null);
      onFinished();
      await _changes.close();
    }
  }

  /// 从 [from] 读到 [to]（不含）；数据还没下载到时等待。整首下载中途失败时
  /// （网络抖动、切到后台断开），剩余部分改向源站发 Range 请求，播放不中断。
  Stream<List<int>> follow(int from, int? to) async* {
    var position = from;
    // 每写一块都会通知，结束时关闭通知流，等待不会卡住；文件句柄在 .part 改名后仍然有效。
    final changes = StreamIterator(_changes.stream);
    RandomAccessFile? reader;
    try {
      reader = await (part.existsSync() ? part : file).open();
      while (to == null || position < to) {
        final available = to == null ? progress : math.min(progress, to);
        if (position < available) {
          await reader.setPosition(position);
          final chunk = await reader.read(
            math.min(available - position, 64 * 1024),
          );
          if (chunk.isEmpty) throw const HttpException('缓存读取失败');
          position += chunk.length;
          yield chunk;
          continue;
        }
        if (complete) break;
        if (failed) {
          // 已换歌而取消的下载，播放器不再读这首，不必补请求。
          if (cancelled) throw const HttpException('下载已取消');
          yield* (await _range(uri, headers, position, to)).stream;
          return;
        }
        // 通知流关闭（下载结束）时回到循环开头，按完成或失败处理。
        if (!await changes.moveNext() && !complete && !failed) {
          throw const HttpException('音频下载中断');
        }
      }
    } finally {
      await changes.cancel();
      await reader?.close();
    }
  }
}
