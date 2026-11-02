import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dymuse/core/api_client.dart';
import 'package:dymuse/playback/audio_engine.dart';

/// 所有业务请求只读写内存；音源由调用方提供本机合成WAV。
class WindowsFixtureApi extends ApiClient {
  String audioUrl = 'http://127.0.0.1:1/audio.wav';
  final calls = <({String method, String path, Json? query, Json? body})>[];
  final Map<String, Json> _queues = {};
  int _generation = 0;

  static Json song(String id) => {
    'id': int.parse(id),
    'name': 'Windows 合成歌曲 $id',
    'dt': 120000,
    'ar': [
      {'id': 40, 'name': 'Dymuse 测试音频'},
    ],
    'al': {'id': 1, 'name': 'Windows 隔离验证'},
  };

  Json _queue(String mode, String id) => _queues[mode] = {
    'generation': 'windows-fixture-${++_generation}',
    'revision': 1,
    'state': {
      'items': [
        for (final value in ['101', '102', '103']) {'id': value, 'mode': mode},
      ],
      'index': ['101', '102', '103'].indexOf(id).clamp(0, 2),
      'positionMs': 0,
      'playing': false,
      'repeat': 'off',
      'shuffle': false,
      'origin': 'playlist',
      'playlistId': '600',
    },
  };

  @override
  Future<dynamic> request(
    String method,
    String path, {
    Json? query,
    Json? body,
  }) async {
    calls.add((method: method, path: path, query: query, body: body));
    if (path.startsWith('/playback/')) {
      final mode = path.split('/')[2];
      if (method == 'GET') return _queues[mode];
      final queue = _queues[mode];
      if (queue != null && path.endsWith('/progress')) {
        (queue['state'] as Json).addAll({...?body}..remove('expectedRevision'));
        queue['revision'] = (queue['revision'] as int) + 1;
      }
      return queue;
    }
    if (path.startsWith('/netease/queues/')) {
      return _queues['netease'] ??
          _queue('netease', body?['songId']?.toString() ?? '101');
    }
    if (path == '/netease/song/detail') {
      return {
        'songs': '${query?['ids'] ?? '101'}'.split(',').map(song).toList(),
      };
    }
    if (path == '/netease/song/url/v1') {
      return {
        'data': [
          {'url': audioUrl},
        ],
      };
    }
    if (path == '/netease/song/music/detail') return <String, dynamic>{};
    if (path == '/netease/likelist') {
      return {
        'ids': [101],
      };
    }
    if (path.contains('/lyric')) {
      return {
        'lrc': {'lyric': '[00:00.00]Windows 合成音频\n[00:03.00]不访问真实账号'},
      };
    }
    if (path == '/netease/search/combined') {
      return {
        'code': 200,
        'result': {
          'order': ['song'],
          'song': {
            'songs': [song('101'), song('102')],
          },
        },
      };
    }
    if (path == '/netease/search') {
      return {
        'code': 200,
        'result': {
          'songs': [song('101'), song('102')],
          'songCount': 2,
        },
      };
    }
    if (path.startsWith('/netease/listening')) return {...?body};
    if (path == '/netease/recommend/resource') {
      return {
        'recommend': [
          {'id': 600, 'name': 'Windows 合成歌单', 'trackCount': 3},
        ],
      };
    }
    if (path == '/netease/recommend/songs') {
      return {
        'data': {
          'dailySongs': [song('101'), song('102')],
        },
      };
    }
    return {
      'code': 200,
      'data': [],
      'items': [],
      'playlist': [],
      'recommend': [],
      'ids': [],
    };
  }
}

/// 组件测试只观察状态，原生集成另用真正的WindowsAudioEngine。
class WindowsFixtureEngine implements AudioEngine {
  @override
  final position = ValueNotifier(Duration.zero);
  @override
  final duration = ValueNotifier(const Duration(seconds: 120));
  @override
  final playing = ValueNotifier(false);
  @override
  final buffering = ValueNotifier(false);
  final _completed = StreamController<void>.broadcast();
  final _errors = StreamController<String>.broadcast();
  int toggles = 0;
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<String> get errors => _errors.stream;
  @override
  Future<void> open(
    String url,
    Map<String, String> headers,
    Duration offset,
    bool play, {
    String? cacheKey,
  }) async {
    position.value = offset;
    playing.value = play;
  }

  @override
  Future<void> toggle() async {
    toggles++;
    playing.value = !playing.value;
  }

  @override
  Future<void> pause() async {
    playing.value = false;
  }

  @override
  Future<void> stop() async {
    playing.value = false;
    position.value = Duration.zero;
  }

  @override
  Future<void> seek(Duration value) async {
    position.value = value;
  }

  @override
  Future<void> volume(double value) async {}
  @override
  Future<void> dispose() async {
    await _completed.close();
    await _errors.close();
  }
}

/// 内存生成120秒PCM，不创建、覆盖或清理任何音频文件。
List<int> windowsFixtureWav() {
  const length = 120 * 8000 * 2;
  final bytes = ByteData(44 + length);
  void tag(int offset, String value) {
    bytes.buffer.asUint8List().setRange(
      offset,
      offset + value.length,
      ascii.encode(value),
    );
  }

  tag(0, 'RIFF');
  bytes.setUint32(4, 36 + length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, 8000, Endian.little);
  bytes.setUint32(28, 16000, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  bytes.setUint32(40, length, Endian.little);
  return bytes.buffer.asUint8List();
}
