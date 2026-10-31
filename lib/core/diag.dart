// 本机诊断日志：只记录播放失败等少量事件（不含凭证、链接里的令牌），
// 方便在“某台设备播不了”时查看原因。文件在应用缓存目录的 dymuse.log，超过 200 KB 自动截断。
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class Diag {
  static File? _file;
  static bool _failed = false;

  static Future<File?> _open() async {
    if (_file != null || _failed) return _file;
    try {
      final dir = await getApplicationCacheDirectory();
      _file = File('${dir.path}/dymuse.log');
    } catch (_) {
      _failed = true;
    }
    return _file;
  }

  /// 去掉地址里的查询串（可能带令牌），只留主机与路径。
  static String scrub(String text) =>
      text.replaceAllMapped(RegExp(r'https?://[^\s?]+\?[^\s)\]}"]*'), (m) {
        final url = m.group(0)!;
        return url.substring(0, url.indexOf('?'));
      });

  static void log(String message) {
    () async {
      try {
        final file = await _open();
        if (file == null) return;
        if (file.existsSync() && file.lengthSync() > 200 * 1024) {
          file.writeAsStringSync('');
        }
        file.writeAsStringSync(
          '${DateTime.now().toIso8601String()} ${scrub(message)}\n',
          mode: FileMode.append,
        );
      } catch (_) {}
    }();
  }
}
