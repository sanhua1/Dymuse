import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/diag.dart';

/// Windows 的设置存放在应用支持目录的 shared_preferences.json。如果写入时程序崩溃或
/// 断电，文件可能变成全 0 或只写了一半；shared_preferences 读取时会抛出 FormatException，
/// main 停在 runApp 之前，窗口始终隐藏，看起来就是“打不开”。
/// 所以读取前先检查：解析失败就把它改名为 `.corrupt-<时间>` 留存（不删除），让应用
/// 以默认设置启动。登录凭证在 flutter_secure_storage 里，不受影响。
Future<void> guardWindowsPreferences() async {
  if (!Platform.isWindows) return;
  try {
    final dir = await getApplicationSupportDirectory();
    await quarantineCorruptPreferences(
      File('${dir.path}${Platform.pathSeparator}shared_preferences.json'),
    );
  } catch (error) {
    Diag.log('preferences guard failed: $error');
  }
}

/// 文件存在、不为空、又不能解析成 JSON 对象时改名留存，返回留存后的文件；否则返回 null。
/// 与 shared_preferences_windows 一致：空文件视为没有设置，不算损坏。
Future<File?> quarantineCorruptPreferences(File file, {DateTime? now}) async {
  if (!file.existsSync()) return null;
  String? problem;
  // 读不了（被占用等）不算损坏，交给 shared_preferences 照常处理。
  final bytes = file.readAsBytesSync();
  if (bytes.isEmpty) return null;
  try {
    final text = utf8.decode(bytes);
    if (jsonDecode(text) is! Map) problem = '不是 JSON 对象';
  } on FormatException catch (error) {
    problem = error.message;
  }
  if (problem == null) return null;
  final t = (now ?? DateTime.now()).toIso8601String().replaceAll(
    RegExp(r'[^0-9]'),
    '',
  );
  final backup = await file.rename('${file.path}.corrupt-${t.substring(0, 14)}');
  Diag.log(
    'preferences corrupt ($problem, ${backup.lengthSync()} bytes), '
    'moved to ${backup.path}; starting with defaults',
  );
  return backup;
}
