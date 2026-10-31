import 'dart:async';
import 'package:flutter/services.dart';
import '../design_system/tokens.dart';
import '../playback/audio_engine.dart';
import '../playback/playback_controller.dart';

/// 系统“正在播放”与媒体键：Apple 端为 MPNowPlayingInfoCenter 与
/// MPRemoteCommandCenter，Android 端为前台服务里的 MediaSession 与媒体通知。
/// 所有系统命令都走同一 PlaybackController。
class NowPlaying {
  NowPlaying(this.controller) {
    _channel.setMethodCallHandler(_command);
    controller.addListener(_update);
    engine.playing.addListener(_update);
    engine.duration.addListener(_update);
    engine.position.addListener(_positionChanged);
    _update();
  }
  static const _channel = MethodChannel('dymuse/now_playing');

  /// Android：把应用移到后台而不结束 Activity，音乐继续播放。
  static Future<void> moveToBack() async {
    try {
      await _channel.invokeMethod('moveToBack');
    } on PlatformException {
      // 原生端不可用时忽略。
    } on MissingPluginException {
      // 非 Android 平台没有这个方法。
    }
  }

  bool _askedNotifications = false;
  final PlaybackController controller;
  AudioEngine get engine => controller.engine;
  String? _sent;

  final _clock = Stopwatch();
  Duration _base = Duration.zero;

  Future<dynamic> _command(MethodCall call) async {
    switch (call.method) {
      case 'play':
        if (!engine.playing.value) await controller.toggle();
      case 'pause':
        if (engine.playing.value) await controller.toggle();
      case 'toggle':
        await controller.toggle();
      case 'next':
        await controller.next();
      case 'previous':
        await controller.previous();
      case 'seek':
        await controller.seek(
          Duration(milliseconds: (call.arguments as num).round()),
        );
    }
  }

  /// 系统按播放速率自行推算进度；只有跳转或暂停这类不连续变化才重新上报。
  void _positionChanged() {
    final position = engine.position.value;
    final expected = engine.playing.value ? _base + _clock.elapsed : _base;
    if ((position - expected).abs() > const Duration(milliseconds: 1500)) {
      _sent = null;
      _update();
    }
  }

  void _update() {
    final track = controller.current;
    // Android 13+ 的媒体通知需要授权；第一次有歌曲时再询问，而不是启动时。
    if (track != null && DymuseTokens.android && !_askedNotifications) {
      _askedNotifications = true;
      unawaited(
        _channel.invokeMethod('requestNotifications').catchError((_) => null),
      );
    }
    final playing = engine.playing.value;
    final position = engine.position.value;
    final Map<String, Object?>? info = track == null
        ? null
        : {
            'title': track.title,
            'artist': track.artist,
            'album': track.album,
            'durationMs': engine.duration.value.inMilliseconds,
            'positionMs': position.inMilliseconds,
            'playing': playing,
            // 网易云与 B 站的封面都是公开的 https 图片，系统可自行下载。
            if (track.cover?.startsWith('http') == true)
              'artwork': track.cover!.replaceFirst('http://', 'https://'),
          };
    final signature = info == null
        ? ''
        : '${track!.mode.name}:${track.id}:$playing:${info['durationMs']}';
    if (signature == _sent) return;
    _sent = signature;
    _base = position;
    _clock
      ..reset()
      ..start();
    unawaited(_channel.invokeMethod('update', info).catchError((_) => null));
  }
}
