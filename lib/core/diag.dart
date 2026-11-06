// 本机诊断日志：记录播放、取链、缓冲、被系统打断、应用前后台、未捕获错误等事件，
// 方便排查偶发问题。不含凭证、Cookie 和链接里的令牌（见 [scrub]），歌曲只记 ID。
// 文件在应用支持目录的 dymuse.log；超过 1 MB 时改名为 dymuse.log.1（覆盖上一个旧文件），
// 所以最多保留约 2 MB、两段时间的日志。
import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class Diag {
  static const _limit = 1024 * 1024;
  static File? _file;
  static bool _failed = false;
  static Future<void> _tail = Future.value();

  static Future<File?> _open() async {
    if (_file != null || _failed) return _file;
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/dymuse.log');
    } catch (_) {
      _failed = true;
    }
    return _file;
  }

  /// 去掉地址里的查询串（可能带令牌），只留主机与路径；Cookie、令牌字段整体打码。
  static String scrub(String text) => text
      .replaceAllMapped(RegExp(r'https?://[^\s?]+\?[^\s)\]}"]*'), (m) {
        final url = m.group(0)!;
        return url.substring(0, url.indexOf('?'));
      })
      .replaceAllMapped(
        RegExp(
          r'(MUSIC_U|__csrf|Cookie|Authorization|token|password)([=:]\s*)[^\s;,"]+',
          caseSensitive: false,
        ),
        (m) => '${m.group(1)}${m.group(2)}***',
      );

  /// 当前日志文件路径（可能还没写过任何内容）。
  static Future<String?> path() async => (await _open())?.path;

  /// 读出全部日志（旧段在前），用于复制。
  static Future<String> readAll() async {
    final file = await _open();
    if (file == null) return '';
    await _tail;
    final old = File('${file.path}.1');
    return [
      if (old.existsSync()) old.readAsStringSync(),
      if (file.existsSync()) file.readAsStringSync(),
    ].join();
  }

  /// 写一行；按调用顺序排队，不阻塞调用方。
  static void log(String message) {
    final line = '${DateTime.now().toIso8601String()} ${scrub(message)}\n';
    _tail = _tail.then((_) async {
      try {
        final file = await _open();
        if (file == null) return;
        if (file.existsSync() && file.lengthSync() > _limit) {
          file.renameSync('${file.path}.1');
        }
        file.writeAsStringSync(line, mode: FileMode.append);
      } catch (_) {}
    });
  }
}
