import 'dart:io';
import 'package:flutter/services.dart';

/// 唤起系统安装器的结果。
enum AndroidInstallResult {
  /// 已打开系统安装界面，之后由用户确认安装。
  started,

  /// 用户还没允许本应用安装应用，已打开系统授权页；授权后需要再点一次“更新”。
  needPermission,
  failed,
}

const _channel = MethodChannel('dymuse/update');

/// 把已校验的安装包交给系统安装器；原生端会先复制到 FileProvider 共享的缓存目录。
/// 失败时 [detail] 是原生端给出的原因。
Future<(AndroidInstallResult, String)> installAndroidApk(File apk) async {
  try {
    final result = await _channel.invokeMethod<String>('install', apk.path);
    return switch (result) {
      'started' => (AndroidInstallResult.started, ''),
      'needPermission' => (AndroidInstallResult.needPermission, ''),
      _ => (AndroidInstallResult.failed, result ?? ''),
    };
  } on PlatformException catch (error) {
    return (AndroidInstallResult.failed, '${error.message}');
  }
}
