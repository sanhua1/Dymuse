import 'dart:async';

import 'package:dymuse/core/api_client.dart';
import 'package:dymuse/features/catalog.dart';
import 'package:dymuse/playback/audio_engine.dart';
import 'package:dymuse/playback/playback_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只回应取歌曲详情与取链；其他请求一律失败（进度保存等不影响本测试）。
class _Api extends ApiClient {
  @override
  Future<dynamic> request(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Map<String, dynamic>? body,
  }) async {
    if (path == '/netease/song/detail') {
      final id = int.parse('${query!['ids']}');
      return {
        'songs': [
          {
            'id': id,
            'name': '歌$id',
            'ar': [
              {'id': 1, 'name': '歌手'},
            ],
            'al': {'id': 2, 'name': '专辑', 'picUrl': 'https://x/$id.jpg'},
            'dt': 1000,
          },
        ],
      };
    }
    if (path == '/netease/song/url/v1') {
      return {
        'data': [
          {'id': query!['id'], 'url': 'https://m.test/${query['id']}.flac'},
        ],
      };
    }
    throw const ApiException('UNSUPPORTED', '测试未提供');
  }
}

/// 打开 [failing] 里的歌曲时装载失败，错误流上报一次（与 JustAudioEngine 一致）。
class _Engine implements AudioEngine {
  final failing = <String>{};

  /// 只失败一次的歌曲：失败后自动移除。
  final failOnce = <String>{};
  final opened = <String>[];
  final offsets = <Duration>[];
  final _completed = StreamController<void>.broadcast();
  final _errors = StreamController<String>.broadcast();
  @override
  final position = PositionNotifier();
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

  void complete() {
    playing.value = false;
    _completed.add(null);
  }

  @override
  Future<void> open(
    String url,
    Map<String, String> headers,
    Duration offset,
    bool play, {
    String? cacheKey,
  }) async {
    final id = Uri.parse(url).pathSegments.last.split('.').first;
    opened.add(id);
    offsets.add(offset);
    if (failing.contains(id) || failOnce.remove(id)) {
      _errors.add('Source error');
      return;
    }
    playing.value = play;
  }

  @override
  Future<void> toggle() async => playing.value = !playing.value;
  @override
  Future<void> pause() async => playing.value = false;
  @override
  Future<void> stop() async => playing.value = false;
  @override
  Future<void> seek(Duration value) async {}
  @override
  Future<void> volume(double value) async {}
  @override
  Future<void> dispose() async {}
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 1200));

PlaybackController _controller(_Engine engine) {
  final api = _Api();
  final controller = PlaybackController(api, Catalog(api), engine)
    ..mode = MusicMode.netease
    ..snapshot = {
      'generation': 1,
      'state': {
        'items': [
          for (final id in ['1', '2', '3', '4']) {'id': id, 'mode': 'netease'},
        ],
        'index': 0,
      },
    };
  return controller;
}

void main() {
  test('自动连播的下一首失败一次：重新取链重试同一首，不显示错误', () async {
    final engine = _Engine();
    final controller = _controller(engine);
    await controller.select(0);
    engine.failOnce.add('2');
    engine.complete();
    await _settle();
    expect(engine.opened, ['1', '2', '2']);
    expect(controller.error, isNull);
    expect(controller.current?.id, '2');
    expect(engine.playing.value, isTrue);
  });

  test('自动连播一直失败：重试、跳下一首、再重试，然后停下显示错误', () async {
    final engine = _Engine();
    final controller = _controller(engine);
    await controller.select(0);
    engine.failing.addAll(['2', '3', '4']);
    engine.complete();
    await _settle();
    await _settle();
    expect(engine.opened, ['1', '2', '2', '3', '3']);
    expect(controller.error, contains('音频无法播放'));
  });

  test('用户亲自点的歌失败：直接显示错误，不自动重试或跳过', () async {
    final engine = _Engine();
    final controller = _controller(engine);
    engine.failing.add('2');
    await controller.select(1);
    await _settle();
    expect(engine.opened, ['2']);
    expect(controller.error, contains('音频无法播放'));
  });

  test('播放中在同一位置反复缓冲：在当前位置重新装载，同一首最多两次，仍卡住就暂停报错', () async {
    final engine = _Engine();
    final controller = _controller(engine);
    await controller.select(0);
    engine.position.value = const Duration(seconds: 25);
    Future<void> stall() async {
      for (var i = 0; i < 5; i++) {
        engine.buffering.value = true;
        engine.buffering.value = false;
      }
      await _settle();
    }

    await stall();
    expect(engine.opened, ['1', '1']);
    expect(engine.offsets.last, const Duration(seconds: 25));
    expect(controller.error, isNull);
    await stall();
    expect(engine.opened, ['1', '1', '1']);
    await stall();
    expect(engine.opened, ['1', '1', '1']);
    expect(engine.playing.value, isFalse);
    expect(controller.error, contains('反复缓冲'));
  });

  test('正常缓冲（次数少或位置在前进）不触发重新装载', () async {
    final engine = _Engine();
    final controller = _controller(engine);
    await controller.select(0);
    for (var i = 0; i < 8; i++) {
      engine.position.value = Duration(seconds: 10 + i * 3);
      engine.buffering.value = true;
      engine.buffering.value = false;
    }
    await _settle();
    expect(engine.opened, ['1']);
    expect(controller.error, isNull);
  });

  test('自动连播切歌装载中按“正要播放”上报，装载完结束', () async {
    final engine = _Engine();
    final controller = _controller(engine);
    await controller.select(0);
    final seen = <bool>[];
    controller.addListener(() => seen.add(controller.starting));
    engine.complete();
    await _settle();
    expect(seen, contains(true));
    expect(controller.starting, isFalse);
  });
}
