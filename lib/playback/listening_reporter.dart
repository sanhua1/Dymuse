import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/api_client.dart';
import '../features/catalog.dart';
import 'audio_engine.dart';

/// 用单调时间约束音频进度，只记录真正推进的收听片段。
class ListeningReporter {
  ListeningReporter(this.api, this.engine, {int Function()? clock}) {
    final watch = Stopwatch()..start();
    _clock = clock ?? () => watch.elapsedMilliseconds;
    engine.position.addListener(_positionChanged);
    engine.playing.addListener(_stateChanged);
    engine.buffering.addListener(_stateChanged);
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(checkpoint());
    });
  }
  final ApiClient api;
  final AudioEngine engine;
  late final int Function() _clock;
  SharedPreferences? preferences;
  String? Function()? scope;
  final Map<String, Json> _pending = {};
  Json? _current;
  String? _owner, _session, _server;
  Timer? _timer;
  Future<void>? _sending;
  Future<void> _writes = Future.value();
  int _lastAt = 0, _lastPosition = 0;
  bool _ready = false, _eligible = false, _seeking = false, _closed = false;
  bool get active => _current != null;

  String _uuid() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// 本机待发记录按服务、用户及设备隔离，不保存令牌或网易云凭证。
  void restore() {
    final owner = scope?.call();
    if (owner == _owner && _session == api.token && _server == api.server) {
      return;
    }
    _current = null;
    _ready = false;
    _pending.clear();
    _owner = owner;
    _session = api.token;
    _server = api.server;
    if (owner == null) return;
    try {
      final raw = preferences?.getString('listening.pending:$owner');
      if (raw != null && raw.isNotEmpty) {
        for (final value in (jsonDecode(raw) as List).take(200)) {
          final entry = Map<String, dynamic>.from(value as Map);
          // 重启后只提交之前确认的时长，不继续累加关闭期间的时间。
          if (entry['finished'] != true) {
            entry['finished'] = true;
            entry['reason'] = 'shutdown';
          }
          _pending[entry['playId'] as String] = entry;
        }
      }
    } catch (_) {
      /* 损坏的标记不转化成收听记录。 */
    }
    unawaited(flush());
  }

  void begin(Track track, Json? snapshot) {
    finish('changed');
    restore();
    if (_closed ||
        api.token == null ||
        track.mode != MusicMode.netease ||
        track.isPodcast ||
        track.duration <= 0 ||
        snapshot == null ||
        _pending.length >= 200) {
      return;
    }
    _current = {
      'playId': _uuid(),
      'generation': snapshot['generation'],
      'songId': track.id,
      'durationMs': (track.duration * 1000).round().clamp(1, 86400000),
      'listenedMs': 0,
      'finished': false,
      'registered': false,
    };
    _ready = false;
    _seeking = false;
    _baseline();
  }

  void ready() {
    _ready = true;
    _baseline();
  }

  void _baseline() {
    _lastAt = _clock();
    _lastPosition = engine.position.value.inMilliseconds;
    _eligible =
        _ready && !_seeking && engine.playing.value && !engine.buffering.value;
  }

  void _stateChanged() {
    _positionChanged();
    _baseline();
  }

  void _positionChanged() {
    final entry = _current;
    final elapsed = _clock() - _lastAt;
    final delta = engine.position.value.inMilliseconds - _lastPosition;
    // 跳变、长时间停更和倒退都不计时；后台挂起不能补算整段墙钟时间。
    if (entry != null &&
        _eligible &&
        elapsed > 0 &&
        elapsed <= 2500 &&
        delta > 0 &&
        delta <= elapsed + 500) {
      entry['listenedMs'] = min(
        entry['durationMs'] as int,
        (entry['listenedMs'] as int) + min(delta, elapsed),
      );
      if ((entry['listenedMs'] as int) >= 1000 &&
          !_pending.containsKey(entry['playId'])) {
        _pending[entry['playId'] as String] = entry;
        unawaited(checkpoint());
      }
    }
    _baseline();
  }

  void seeking(bool value) {
    _positionChanged();
    _seeking = value;
    _baseline();
  }

  void finish(String reason) {
    _positionChanged();
    final entry = _current;
    _current = null;
    _ready = false;
    if (entry == null || (entry['listenedMs'] as int) < 1000) return;
    entry['finished'] = true;
    entry['reason'] = reason;
    _pending[entry['playId'] as String] = entry;
    unawaited(checkpoint());
  }

  Future<void> _persist() {
    final owner = _owner, prefs = preferences;
    final content = jsonEncode(_pending.values.toList());
    // 串行写入快照，旧异步保存不能覆盖较新的结束标记。
    return _writes = _writes
        .then((_) async {
          if (owner != null && prefs != null) {
            await prefs.setString('listening.pending:$owner', content);
          }
        })
        .catchError((_) {});
  }

  Future<void> checkpoint() async {
    await _persist();
    unawaited(flush());
  }

  Future<void> flush() =>
      _sending ??= _send().whenComplete(() => _sending = null);
  Future<void> _send() async {
    final session = _session, server = _server;
    bool valid() =>
        session != null && session == api.token && server == api.server;
    for (final entry in _pending.values.toList()) {
      if (!valid()) return;
      try {
        if (entry['registered'] != true) {
          await api.post('/netease/listening/start', {
            for (final key in ['playId', 'generation', 'songId', 'durationMs'])
              key: entry[key],
          });
          if (!valid()) return;
          entry['registered'] = true;
          await _persist();
        }
        for (var attempt = 0; attempt < 2; attempt++) {
          final finished = entry['finished'] == true;
          final result =
              await api.post('/netease/listening', {
                    'playId': entry['playId'],
                    'listenedMs': entry['listenedMs'],
                    'finished': finished,
                    if (finished) 'reason': entry['reason'],
                  })
                  as Json;
          if (!valid()) return;
          if (result['finished'] == true) {
            _pending.remove(entry['playId']);
            // 服务端已结算的旧租约不再累加，避免睡眠恢复后重复计数。
            if (identical(_current, entry)) {
              _current = null;
              _ready = false;
            }
          }
          // 关闭可能发生在检查点传输期间，再补一次结束标记即可。
          if (finished ||
              entry['finished'] != true ||
              result['finished'] == true) {
            break;
          }
        }
        await _persist();
      } on ApiException catch (error) {
        if (!valid()) return;
        if ([400, 403, 404, 409].contains(error.status)) {
          _pending.remove(entry['playId']);
          if (identical(_current, entry)) {
            _current = null;
            _ready = false;
          }
          await _persist();
        } else {
          return;
        }
      } catch (_) {
        return;
      }
    }
  }

  /// 关闭只要求先保存本机检查点，网络发送受控制器的既有时限约束。
  Future<void> stop() async {
    _closed = true;
    _timer?.cancel();
    finish('shutdown');
    await _persist();
  }

  void dispose() {
    _timer?.cancel();
    finish('disposed');
    engine.position.removeListener(_positionChanged);
    engine.playing.removeListener(_stateChanged);
    engine.buffering.removeListener(_stateChanged);
  }
}
