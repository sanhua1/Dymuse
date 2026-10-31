import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:media_kit/media_kit.dart';
import '../bilibili/hls_proxy.dart';
import '../core/media_cache.dart';
import 'caching_audio_source.dart';

/// 平台唯一引擎；队列和模式由上层持有。
abstract class AudioEngine {
  ValueNotifier<Duration> get position;
  ValueNotifier<Duration> get duration;
  ValueNotifier<bool> get playing;
  ValueNotifier<bool> get buffering;
  Stream<void> get completed;
  Stream<String> get errors;

  /// [cacheKey] 不为空时边播边把整首歌缓存到本地，下次直接读缓存（仅 Apple 引擎支持）。
  Future<void> open(
    String url,
    Map<String, String> headers,
    Duration offset,
    bool play, {
    String? cacheKey,
  });
  Future<void> toggle();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration value);
  Future<void> volume(double value);
  Future<void> dispose();
}

/// Windows 使用 audio-only libmpv，不引入视频视图。
class WindowsAudioEngine implements AudioEngine {
  final Player _player = Player(
    configuration: const PlayerConfiguration(title: 'Dymuse'),
  );
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  @override
  final position = ValueNotifier(Duration.zero);
  @override
  final duration = ValueNotifier(Duration.zero);
  @override
  final playing = ValueNotifier(false);
  @override
  final buffering = ValueNotifier(false);
  @override
  Stream<void> get completed =>
      _player.stream.completed.where((value) => value).map((_) {});
  @override
  Stream<String> get errors => _player.stream.error;
  WindowsAudioEngine() {
    _subscriptions.addAll([
      _player.stream.position.listen((value) => position.value = value),
      _player.stream.duration.listen((value) => duration.value = value),
      _player.stream.playing.listen((value) => playing.value = value),
      _player.stream.buffering.listen((value) => buffering.value = value),
    ]);
  }
  @override
  Future<void> open(
    String url,
    Map<String, String> headers,
    Duration offset,
    bool play, {
    String? cacheKey,
  }) async {
    await _player.open(
      Media(url, httpHeaders: headers, start: offset),
      play: play,
    );
  }

  @override
  Future<void> toggle() => _player.playOrPause();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> seek(Duration value) => _player.seek(value);
  @override
  Future<void> volume(double value) => _player.setVolume(value * 100);
  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    position.dispose();
    duration.dispose();
    playing.dispose();
    buffering.dispose();
  }
}

/// 播放位置。前台由引擎推送；后台没有界面在看，[live] 不为空时每次读取
/// 才向播放器要当前位置（保存进度、收听上报按需读取），不再被动接收推送。
class PositionNotifier extends ValueNotifier<Duration> {
  PositionNotifier() : super(Duration.zero);
  Duration Function()? live;
  @override
  Duration get value => live?.call() ?? super.value;
}

/// iOS、macOS 与 Android 使用 just_audio（AVQueuePlayer / ExoPlayer）；请求头与 Windows 一致，由插件本机代理转发。
class JustAudioEngine with WidgetsBindingObserver implements AudioEngine {
  final ja.AudioPlayer _player = ja.AudioPlayer();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  StreamSubscription<Duration>? _positionSubscription;
  final _completed = StreamController<void>.broadcast();
  final _errors = StreamController<String>.broadcast();
  @override
  final PositionNotifier position = PositionNotifier();
  @override
  final duration = ValueNotifier(Duration.zero);
  @override
  final playing = ValueNotifier(false);
  @override
  final buffering = ValueNotifier(false);
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<String> get errors => _errors.stream;
  JustAudioEngine() {
    WidgetsBinding.instance.addObserver(this);
    _listenPosition();
    _subscriptions.addAll([
      _player.durationStream.listen(
        (value) => duration.value = value ?? Duration.zero,
      ),
      _player.playingStream.listen((value) => playing.value = value),
      _player.processingStateStream.listen((state) {
        buffering.value =
            state == ja.ProcessingState.loading ||
            state == ja.ProcessingState.buffering;
        if (state == ja.ProcessingState.completed) _completed.add(null);
      }),
      _player.errorStream.listen((error) => _errors.add('${error.message}')),
    ]);
  }

  void _listenPosition() {
    _positionSubscription ??= _player.positionStream.listen(
      (value) => position.value = value,
    );
  }

  /// 锁屏或切到后台后停止订阅位置流（just_audio 播放时每 200 ms 推一次，
  /// 会让 Dart 在后台持续被唤醒）；回到前台先对齐一次再恢复订阅。
  /// 播放本身在 AVPlayer 里继续，切歌、完成、错误走其他流，不受影响。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final background =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (background) {
      position.live = () => _player.position;
      final subscription = _positionSubscription;
      _positionSubscription = null;
      unawaited(subscription?.cancel());
    } else if (position.live != null) {
      position.live = null;
      position.value = _player.position;
      _listenPosition();
    }
  }

  /// 与 media_kit 一致：装载失败经 errors 上报，被新装载打断的旧请求静默结束。
  /// 缓存用 [CachingAudioSource]：经本机代理边下边播，下完才把 .part 改名为正式文件，
  /// 未下完的不会被当成缓存。已缓存时直接从文件读取，[url] 不再请求。
  @override
  Future<void> open(
    String url,
    Map<String, String> headers,
    Duration offset,
    bool play, {
    String? cacheKey,
  }) async {
    // B 站音频是 DASH 分片 MP4，AVPlayer 打不开；经本机代理包成 HLS 再播，不做歌曲缓存。
    if (Uri.tryParse(url)?.path.endsWith('.m4s') == true) {
      try {
        final proxy = await BiliHlsProxy.instance;
        await _player.setAudioSource(
          ja.AudioSource.uri(proxy.register(url, headers)),
          initialPosition: offset,
        );
      } on ja.PlayerInterruptedException {
        return;
      } on ja.PlayerException catch (error) {
        _errors.add('${error.message}');
        return;
      }
      if (play) unawaited(_player.play());
      return;
    }
    final cache = MediaCache.instance;
    final file = cache != null && cacheKey != null
        ? cache.file(CacheKind.audio, cacheKey)
        : null;
    CachingAudioSource.cancelOthers(file);
    try {
      await _player.setAudioSource(
        file != null
            ? CachingAudioSource(
                Uri.parse(url),
                headers: headers.isEmpty ? null : headers,
                file: file,
              )
            : ja.AudioSource.uri(
                Uri.parse(url),
                headers: headers.isEmpty ? null : headers,
              ),
        initialPosition: offset,
      );
      if (cacheKey != null) cache?.audioStarted();
    } on ja.PlayerInterruptedException {
      return;
    } on ja.PlayerException catch (error) {
      _errors.add('${error.message}');
      return;
    }
    // play() 在暂停或结束后才返回，不能等待。
    if (play) unawaited(_player.play());
  }

  @override
  Future<void> toggle() async {
    if (_player.playing) return _player.pause();
    unawaited(_player.play());
  }

  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> seek(Duration value) => _player.seek(value);
  @override
  Future<void> volume(double value) => _player.setVolume(value);
  @override
  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    await _positionSubscription?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    await _completed.close();
    await _errors.close();
    position.dispose();
    duration.dispose();
    playing.dispose();
    buffering.dispose();
  }
}
