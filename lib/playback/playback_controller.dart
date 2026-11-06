import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../core/api_client.dart';
import '../core/media_cache.dart';
import '../core/diag.dart';
import '../features/catalog.dart';
import 'audio_engine.dart';
import 'audio_quality.dart';
import 'playback_checkpoints.dart';
import 'listening_reporter.dart';

/// 单一业务控制器；异步命令串行，装载序号隔离连续点歌。
class PlaybackController extends ChangeNotifier {
  PlaybackController(this.api, this.catalog, this.engine) {
    listening = ListeningReporter(api, engine);
    _subscriptions.add(
      engine.completed.listen((_) {
        if (!_changing && current != null) {
          listening.finish('completed');
          next(automatic: true);
        }
      }),
    );
    _subscriptions.add(
      engine.errors.listen((detail) {
        Diag.log(
          'engine error mode=${mode.name} track=${current?.id}: $detail',
        );
        if (current == null) return;
        listening.finish('error');
        error = '音频无法播放（$detail）。可重试；来源也可能暂时不可用。';
        notifyListeners();
      }),
    );
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (snapshot != null && !_changing && !_savingScheduled) {
        _savingScheduled = true;
        _command(() => _save()).whenComplete(() => _savingScheduled = false);
      }
    });
  }
  final ApiClient api;
  final Catalog catalog;
  final AudioEngine engine;

  /// 全局音质；切换后丢弃已预取的下一首，之后取链都按新档位匹配。
  AudioQuality quality = AudioQuality.fallback;
  void setQuality(AudioQuality value) {
    if (value == quality) return;
    quality = value;
    _prefetched = null;
    notifyListeners();
  }

  late final ListeningReporter listening;
  PlaybackCheckpoints? checkpoints;
  MusicMode mode = MusicMode.netease;

  /// 音乐来源变化时回调，用来把“上次所在的来源”存到本机，下次启动直接回到那里。
  void Function(MusicMode mode)? onModeChanged;
  Json? snapshot;
  Track? current;

  /// 正在装载、尚未拿到音源的歌曲：界面先显示它的封面与标题，不留空白。
  Track? pending;

  /// 界面展示的歌曲：已装载的那首，或正在装载的那首。
  Track? get track => current ?? pending;

  /// 预取的下一首详情与音源；网易云直链有时效，只在短时间内复用。
  ({
    String key,
    Track track,
    String url,
    Map<String, String> headers,
    String? cacheKey,
    DateTime at,
  })?
  _prefetched;
  String? error;
  bool loading = false;
  bool extending = false;
  bool _manualExtensionQueued = false;
  bool _changing = false;
  bool _disposed = false;
  bool _shuttingDown = false;
  Future<void>? _shutdownJob;
  bool _savingScheduled = false;
  double volume = .75;
  int _intent = 0;
  Future<void> _tail = Future.value();
  Future<void>? _startingHeart;
  Timer? _timer;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Random _random = Random();

  /// 随机播放本轮已听过的位置（按顺序）；同一 generation 内不重复，
  /// “上一首”按实际听过的顺序返回，与“音乐”的随机一致。不写入服务端。
  final List<int> _shuffled = [];
  Object? _shuffleGeneration;
  void _syncShuffle() {
    if (_shuffleGeneration != snapshot?['generation']) {
      _shuffleGeneration = snapshot?['generation'];
      _shuffled.clear();
    }
  }

  /// 队列里还没有歌曲资料的网易云歌曲（重启后只有当前曲目有资料）：后台分批补查，
  /// 查到后队列才能显示歌名、歌手和封面，而不是“歌曲 + 数字编号”。
  final Set<String> _hydrating = {}, _hydrateFailed = {};
  bool _hydrateScheduled = false;

  @override
  void notifyListeners() {
    super.notifyListeners();
    if (mode != MusicMode.netease || _hydrateScheduled || items.isEmpty) return;
    _hydrateScheduled = true;
    scheduleMicrotask(() {
      _hydrateScheduled = false;
      unawaited(_hydrateQueue());
    });
  }

  Future<void> _hydrateQueue() async {
    final session = api.token;
    final missing = [
      for (final item in items)
        if (item['kind'] != 'podcast' &&
            '${item['id']}'.isNotEmpty &&
            catalog.cached(MusicMode.netease, '${item['id']}') == null &&
            !_hydrating.contains('${item['id']}') &&
            !_hydrateFailed.contains('${item['id']}'))
          '${item['id']}',
    ];
    if (missing.isEmpty || session == null) return;
    for (var start = 0; start < missing.length; start += 50) {
      final batch = missing.skip(start).take(50).toList();
      _hydrating.addAll(batch);
      try {
        final data =
            await api.get('/netease/song/detail', {'ids': batch.join(',')})
                as Json;
        if (api.token != session || mode != MusicMode.netease) return;
        final tracks = [
          for (final song in (data['songs'] as List? ?? const []))
            Track.netease(song as Json),
        ];
        catalog.remember(tracks, session);
        // 接口没有返回的（下架等）不再重复请求。
        final got = tracks.map((t) => t.id).toSet();
        _hydrateFailed.addAll(batch.where((id) => !got.contains(id)));
      } catch (_) {
        _hydrateFailed.addAll(batch);
      } finally {
        _hydrating.removeAll(batch);
      }
      super.notifyListeners();
    }
  }

  Json get state => snapshot?['state'] as Json? ?? {};
  List<Json> get items => (state['items'] as List? ?? []).cast<Json>();
  int get index => (state['index'] as num? ?? 0).toInt();
  bool get shuffle => state['shuffle'] == true;
  String get repeat => state['repeat']?.toString() ?? 'off';
  bool get intelligence => state['intelligence'] == true;
  bool get fm => mode == MusicMode.netease && state['origin'] == 'fm';

  /// 开始FM才换队列；浏览入口不暂停原歌曲，失败保留原播放。
  Future<void> startFm() {
    if (mode != MusicMode.netease || fm || loading) return Future.value();
    final intent = ++_intent;
    return _command(() async {
      loading = true;
      error = null;
      notifyListeners();
      try {
        final result = await api.post('/netease/queues/fm') as Json;
        if (intent != _intent) return;
        _changing = true;
        listening.finish('changed');
        await engine.stop();
        snapshot = result;
        current = null;
        await _load(intent, play: true);
        if (intent == _intent) await _extend(intent);
      } finally {
        if (intent == _intent) {
          loading = false;
          _changing = false;
        }
      }
    });
  }

  Future<void> moreFm({bool manual = true}) {
    if (!fm || extending || _manualExtensionQueued) return _tail;
    _manualExtensionQueued = true;
    final intent = _intent;
    return _command(() async {
      if (intent == _intent && fm) await _extend(intent, manual: manual);
    }).whenComplete(() => _manualExtensionQueued = false);
  }

  Future<void> _command(Future<void> Function() action) {
    final session = api.token;
    final result = _tail.then((_) async {
      if (_disposed || _shuttingDown || session != api.token) return;
      try {
        await action();
      } catch (e) {
        Diag.log('command failed mode=${mode.name}: ${e.runtimeType} $e');
        if (!_shuttingDown && session == api.token) {
          error = e is ApiException ? e.message : '播放失败（${e.runtimeType}：$e）';
        }
      }
      if (!_disposed) notifyListeners();
    });
    _tail = result;
    return result;
  }

  /// 上次成功保存的进度；暂停时位置不变，定时保存不再重复上传。
  String? _savedProgress;

  /// 只上传播放位置与设置，不重传队列（私人曲库整库队列会超出请求体上限）。
  Future<Json> _putProgress(
    MusicMode target,
    Json saved, {
    required int positionMs,
    required bool playing,
  }) async {
    final state = saved['state'] as Json;
    return await api.put('/playback/${target.name}/progress', {
          'index': (state['index'] as num? ?? 0).toInt(),
          'positionMs': positionMs,
          'playing': playing,
          'shuffle': state['shuffle'] == true,
          'repeat': state['repeat']?.toString() ?? 'off',
          'expectedRevision': saved['revision'],
        })
        as Json;
  }

  /// 保存同一 generation；冲突后读取服务端版本，不盲目覆盖。
  /// 进度保存失败（离线等）不打断播放，也不在界面上报错，下次再保存。
  Future<void> _save() async {
    if (snapshot == null || api.token == null) return;
    final intent = _intent, activeMode = mode, session = api.token;
    final previous = snapshot!;
    final position = engine.position.value.inMilliseconds,
        playing = engine.playing.value;
    final signature = [
      activeMode.name,
      previous['generation'],
      index,
      position ~/ 1000,
      playing,
      shuffle,
      repeat,
    ].join('|');
    if (signature == _savedProgress) return;
    try {
      final saved = await _putProgress(
        activeMode,
        previous,
        positionMs: position,
        playing: playing,
      );
      if (intent != _intent || session != api.token) return;
      if (!identical(snapshot, previous)) return;
      _savedProgress = signature;
      state['positionMs'] = position;
      state['playing'] = playing;
      snapshot = {...previous, ...saved};
    } on ApiException catch (e) {
      if (e.code != 'QUEUE_CHANGED') return;
      final restored = await api.get('/playback/${activeMode.name}') as Json?;
      if (intent != _intent || session != api.token) return;
      snapshot = restored;
      listening.finish('changed');
      await engine.stop();
      current = null;
      pending = null;
      error = '队列已在服务端更新，请重新选择歌曲。';
    } catch (_) {
      // 网络错误：保留本地状态，下次定时保存重试。
    }
  }

  Future<void> restore() => switchMode(mode, force: true);

  /// 界面立即切到目标模式；旧模式的进度保存与新模式的恢复在后台完成，
  /// 保存失败或网络慢都不阻塞切换。
  Future<void> switchMode(MusicMode target, {bool force = false}) {
    if (target == mode && !force) return Future.value();
    final intent = ++_intent;
    final leaving = mode, saved = snapshot;
    final position = engine.position.value.inMilliseconds;
    _changing = true;
    listening.finish('mode');
    // 停止会打断仍在进行的旧音源装载，切换不必等它完成。
    unawaited(engine.stop().catchError((_) {}));
    mode = target;
    onModeChanged?.call(target);
    current = null;
    pending = null;
    _prefetched = null;
    _savedProgress = null;
    snapshot = null;
    error = null;
    loading = true;
    notifyListeners();
    return _command(() async {
      try {
        if (saved != null && !force && api.token != null) {
          try {
            await _putProgress(
              leaving,
              saved,
              positionMs: position,
              playing: false,
            );
          } catch (_) {
            // 旧模式进度未保存不影响切换。
          }
        }
        if (intent != _intent) return;
        await engine.stop();
        final restored = await api.get('/playback/${mode.name}') as Json?;
        if (intent != _intent) return;
        snapshot = restored;
        listening.restore();
        final checkpointed =
            restored != null && checkpoints?.apply(mode, restored) == true;
        if (items.isNotEmpty) {
          await _load(
            intent,
            play: false,
            position: (state['positionMs'] as num? ?? 0).toInt(),
          );
          if (checkpointed && intent == _intent) {
            await _save();
            await checkpoints?.clear(mode);
          }
        }
      } finally {
        if (intent == _intent) {
          _changing = false;
          loading = false;
        }
      }
    });
  }

  Future<void> start(
    Track track, {
    required Json context,
    Collection? collection,
  }) {
    if (track.mode != mode) return Future.value();
    final intent = ++_intent;
    _changing = true;
    loading = true;
    error = null;
    current = null;
    pending = track;
    notifyListeners();
    listening.finish('changed');
    unawaited(engine.pause());
    return _command(() async {
      try {
        current = null;
        await engine.stop();
        if (intent != _intent) return;
        // 每日推荐整张列表即队列；其他无集合的入口（搜索等）按所选歌曲推荐后续。
        final daily =
            mode == MusicMode.netease &&
            !track.isPodcast &&
            collection == null &&
            context['kind'] == 'daily';
        final path = mode == MusicMode.bilibili
            ? '/playback/bilibili/start'
            : track.isPodcast
            ? '/netease/queues/podcast'
            : collection != null
            ? '/netease/queues/collection'
            : daily
            ? '/netease/queues/daily'
            : '/netease/queues/search';
        final body = mode == MusicMode.bilibili
            ? {'context': context, 'selectedId': track.id}
            : track.isPodcast
            ? {
                'radioId': track.radioId,
                'programId': track.id,
                'offset': track.programOffset,
              }
            : collection != null
            ? {
                'kind': collection.kind,
                'collectionId': collection.id,
                'songId': track.id,
              }
            : {'songId': track.id};
        final result = await api.post(path, body) as Json;
        if (intent != _intent) return;
        snapshot = result;
        await _load(intent, play: true);
      } finally {
        if (intent == _intent) {
          loading = false;
          _changing = false;
        }
      }
      if (intent == _intent) await _extend(intent);
    });
  }

  String _key(Json item) => '${mode.name}:${item['kind']}:${item['id']}';

  /// 队列项先用列表里已知的歌曲信息，没有时至少显示标题。
  Track _placeholder(Json item) {
    final id = item['id'].toString(), podcast = item['kind'] == 'podcast';
    return catalog.cached(mode, id, isPodcast: podcast) ??
        Track(
          id: id,
          mode: mode,
          title: item['title']?.toString() ?? '',
          isPodcast: podcast,
        );
  }

  /// 歌曲缓存键：网易云歌曲按歌曲 id 与音质档位（与账号无关，不同音质各自缓存）。
  /// 播客节目与 B 站歌曲不缓存（B 站音频走本机 HLS 代理，暂不落盘）。
  String? _cacheKey(Json item) {
    if (item['kind'] == 'podcast' || mode == MusicMode.bilibili) return null;
    return 'netease:${item['id']}:${quality.level}';
  }

  /// 私人流使用 Bearer；网易云直链不携带 Dymuse 认证头。
  /// 已缓存的歌曲不再取链：网易云少一次取链请求，私人曲库不再访问服务器。
  Future<
    ({Track track, String url, Map<String, String> headers, String? cacheKey})
  >
  _resolve(Json item) async {
    final track = await catalog.detail(
      mode,
      item['id'].toString(),
      isPodcast: item['kind'] == 'podcast',
    );
    var cacheKey = _cacheKey(item);
    if (cacheKey != null &&
        MediaCache.instance?.audioCached(cacheKey) == true) {
      return (
        track: track,
        url: 'https://cache.dymuse.invalid/${track.id}',
        headers: const <String, String>{},
        cacheKey: cacheKey,
      );
    }
    if (MediaCache.instance?.audioEnabled != true) cacheKey = null;
    String url;
    Map<String, String> headers = {};
    if (mode == MusicMode.bilibili) {
      final data = await api.get('/bilibili/tracks/${track.id}/audio') as Json;
      url = data['url'].toString();
      headers = (data['headers'] as Map? ?? {}).map(
        (key, value) => MapEntry('$key', '$value'),
      );
    } else if (track.isPodcast) {
      final data =
          await api.get('/netease/podcasts/url', {'id': track.id}) as Json;
      final link = Uri.tryParse(data['url']?.toString() ?? '');
      if (link == null ||
          !['http', 'https'].contains(link.scheme) ||
          link.host.isEmpty) {
        throw const ApiException('PROGRAM_UNAVAILABLE', '当前网易云账号无法播放此节目。');
      }
      url = link.toString();
    } else {
      // 先查这首歌有哪些档位，取不高于所选音质的最高档；查询失败就按所选档位请求。
      Json? detail;
      try {
        detail =
            await api.get('/netease/song/music/detail', {'id': track.id})
                as Json;
      } catch (_) {}
      final data =
          await api.get('/netease/song/url/v1', {
                'id': track.id,
                'level': quality.match(detail),
              })
              as Json;
      final links = data['data'] as List? ?? [];
      final link = links.isEmpty ? null : links.first['url'];
      if (links.isNotEmpty) {
        Diag.log(
          'url id=${track.id} asked=${quality.match(detail)} '
          'got=${links.first['level']} br=${links.first['br']} '
          'trial=${links.first['freeTrialInfo'] != null}',
        );
      }
      // 试听片段（非会员 30 秒）不缓存，以免以后一直播放片段。
      final trial = links.isEmpty ? null : links.first['freeTrialInfo'];
      if (trial != null && trial != 'null') cacheKey = null;
      if (link is! String || link.isEmpty) {
        throw const ApiException('PLAYBACK_UNAVAILABLE', '当前账号无法播放这首歌。');
      }
      final uri = Uri.tryParse(link);
      if (uri == null || !['http', 'https'].contains(uri.scheme)) {
        throw const ApiException('INVALID_AUDIO_URL', '音频地址无效。');
      }
      url = link;
    }
    return (track: track, url: url, headers: headers, cacheKey: cacheKey);
  }

  Future<void> _load(int intent, {required bool play, int position = 0}) async {
    if (items.isEmpty || index >= items.length) return;
    final item = items[index], key = _key(item);
    Diag.log(
      'load start mode=${mode.name} id=${item['id']} index=$index/${items.length} '
      'play=$play pos=${position}ms quality=${quality.level}',
    );
    loading = true;
    error = null;
    if (current == null && pending?.id != item['id'].toString()) {
      pending = _placeholder(item);
    }
    notifyListeners();
    try {
      final ready = _prefetched;
      _prefetched = null;
      final resolved =
          ready != null &&
              ready.key == key &&
              DateTime.now().difference(ready.at) < const Duration(minutes: 4)
          ? (
              track: ready.track,
              url: ready.url,
              headers: ready.headers,
              cacheKey: ready.cacheKey,
            )
          : await _resolve(item);
      if (intent != _intent) {
        Diag.log('load superseded id=${item['id']}');
        return;
      }
      Diag.log(
        'load resolved id=${item['id']} prefetched=${ready != null && ready.key == key} '
        'cached=${resolved.url.startsWith('https://cache.dymuse.invalid')}',
      );
      current = resolved.track;
      pending = null;
      listening.begin(resolved.track, snapshot);
      await engine.open(
        resolved.url,
        resolved.headers,
        Duration(milliseconds: position),
        play,
        cacheKey: resolved.cacheKey,
      );
      if (intent != _intent) {
        await engine.pause();
        return;
      }
      await engine.volume(volume);
      listening.ready();
      if (play) unawaited(_prefetch(intent));
    } finally {
      if (intent == _intent) loading = false;
    }
  }

  /// 顺序播放时预取下一首的详情与音源，切歌不再等两次网络往返；随机与单曲循环不预取。
  Future<void> _prefetch(int intent) async {
    final at = index + 1;
    if (shuffle || repeat == 'one' || at >= items.length) return;
    final item = items[at];
    if (item['unavailable'] == true) return;
    final key = _key(item), session = api.token;
    try {
      final resolved = await _resolve(item);
      if (_disposed || intent != _intent || session != api.token) return;
      _prefetched = (
        key: key,
        track: resolved.track,
        url: resolved.url,
        headers: resolved.headers,
        cacheKey: resolved.cacheKey,
        at: DateTime.now(),
      );
    } catch (_) {
      // 预取失败不影响当前播放，切到下一首时照常装载。
    }
  }

  Future<void> _extend(int intent, {bool manual = false}) async {
    final podcast = state['origin'] == 'podcast';
    if (mode != MusicMode.netease ||
        (!intelligence && !fm && state['origin'] != 'search' && !podcast) ||
        (podcast && state['nextOffset'] == null) ||
        (!manual && items.length - index - 1 > (intelligence ? 5 : 2))) {
      return;
    }
    final generation = snapshot?['generation'];
    final session = api.token;
    extending = true;
    notifyListeners();
    try {
      final result =
          await api.post(
                podcast
                    ? '/netease/queues/podcast/extend'
                    : fm
                    ? '/netease/queues/fm/extend'
                    : intelligence
                    ? '/netease/queues/intelligence/extend'
                    : '/netease/queues/extend',
                {
                  'generation': generation,
                  if (intelligence || fm) 'manual': manual,
                },
              )
              as Json;
      // 续推只改同代队列元数据；后续点歌仍需要接收最新 revision。
      if (session == api.token &&
          mode == MusicMode.netease &&
          snapshot?['generation'] == generation) {
        snapshot = result;
        if (state['recommendationStatus'] == 'failed') {
          error = '推荐暂不可用，已有队列仍保留，可稍后重试。';
        } else {
          error = null;
        }
      }
    } on ApiException catch (e) {
      if (intent == _intent && e.code != 'QUEUE_CHANGED') {
        error = podcast ? '后续节目载入失败，可在队列重试。' : '推荐暂不可用，已有队列仍保留。';
      }
    } finally {
      extending = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 页尾浏览和手动刷新只追加，沿用当前 generation 与播放位置。
  Future<void> moreIntelligence({bool manual = true}) {
    if (!intelligence || extending || _manualExtensionQueued) {
      return Future.value();
    }
    _manualExtensionQueued = true;
    final intent = _intent;
    return _command(() async {
      if (intent == _intent && intelligence) {
        await _extend(intent, manual: manual);
      }
    }).whenComplete(() => _manualExtensionQueued = false);
  }

  /// 节目分页可显式重试，不改变当前音源或进度。
  Future<void> morePodcasts() {
    if (state['origin'] != 'podcast' ||
        extending ||
        _manualExtensionQueued ||
        state['nextOffset'] == null) {
      return Future.value();
    }
    _manualExtensionQueued = true;
    final intent = _intent;
    return _command(() async {
      if (intent == _intent) await _extend(intent, manual: true);
    }).whenComplete(() => _manualExtensionQueued = false);
  }

  Future<void> select(int selected) {
    if (selected < 0 || selected >= items.length) return Future.value();
    final intent = ++_intent;
    _changing = true;
    loading = true;
    error = null;
    current = null;
    pending = _placeholder(items[selected]);
    notifyListeners();
    listening.finish('changed');
    unawaited(engine.pause());
    return _command(() async {
      try {
        if (intent != _intent) return;
        current = null;
        state['index'] = selected;
        state['positionMs'] = 0;
        await engine.stop();
        await _load(intent, play: true);
        if (intent == _intent) {
          await _save();
          await _extend(intent);
        }
      } finally {
        if (intent == _intent) _changing = false;
      }
    });
  }

  Future<void> next({bool automatic = false}) {
    Diag.log('next automatic=$automatic index=$index/${items.length}');
    if (items.isEmpty) return Future.value();
    if (automatic && repeat == 'one') return select(index);
    if (shuffle && items.length > 1) {
      _syncShuffle();
      if (_shuffled.isEmpty || _shuffled.last != index) _shuffled.add(index);
      var remaining = [
        for (var i = 0; i < items.length; i++)
          if (!_shuffled.contains(i) && items[i]['unavailable'] != true) i,
      ];
      if (remaining.isEmpty && repeat == 'all') {
        _shuffled
          ..clear()
          ..add(index);
        remaining = [
          for (var i = 0; i < items.length; i++)
            if (i != index && items[i]['unavailable'] != true) i,
        ];
      }
      if (remaining.isNotEmpty) {
        return select(remaining[_random.nextInt(remaining.length)]);
      }
      return _command(() async {
        await engine.pause();
        await _save();
      });
    }
    if (index + 1 < items.length) return select(index + 1);
    if (fm) {
      final intent = _intent, generation = snapshot?['generation'];
      return moreFm(manual: false).then<void>((_) async {
        if (intent != _intent || snapshot?['generation'] != generation) return;
        if (index + 1 < items.length) {
          await select(index + 1);
        } else {
          await _command(() async {
            await engine.pause();
            await _save();
          });
        }
      });
    }
    if (repeat == 'all') return select(0);
    return _command(() async {
      await engine.pause();
      await _save();
    });
  }

  Future<void> previous() async {
    Diag.log('previous index=$index pos=${engine.position.value.inSeconds}s');
    if (engine.position.value.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }
    if (shuffle) {
      _syncShuffle();
      if (_shuffled.isNotEmpty && _shuffled.last == index) {
        _shuffled.removeLast();
      }
      if (_shuffled.isNotEmpty) {
        await select(_shuffled.removeLast());
        return;
      }
    }
    await select((index - 1).clamp(0, max(0, items.length - 1)));
  }

  Future<void> toggle() => _command(() async {
    Diag.log(
      'toggle playing=${engine.playing.value} current=${current?.id} '
      'loading=$loading',
    );
    if (current == null && items.isNotEmpty) {
      final intent = ++_intent;
      await _load(
        intent,
        play: true,
        position: (state['positionMs'] as num? ?? 0).toInt(),
      );
    } else if (current != null) {
      if (!engine.playing.value && !listening.active) {
        listening.begin(current!, snapshot);
        listening.ready();
      }
      await engine.toggle();
    }
    await _save();
  });
  Future<void> retry() {
    Diag.log('retry id=${current?.id} error=$error');
    final intent = ++_intent;
    return _command(
      () => _load(
        intent,
        play: true,
        position: engine.position.value.inMilliseconds,
      ),
    );
  }

  Future<void> seek(Duration value) => _command(() async {
    listening.seeking(true);
    try {
      await engine.seek(value);
    } finally {
      listening.seeking(false);
    }
    await _save();
  });
  Future<void> setVolume(double value) async {
    volume = value;
    await engine.volume(value);
    notifyListeners();
  }

  /// “接下来播放”（next=true，插到当前曲后）或“添加到队列”（next=false，放到末尾）。
  Future<void> insert(Track track, {bool next = true}) => _command(() async {
    if (snapshot == null ||
        track.mode != mode ||
        track.isPodcast != (state['origin'] == 'podcast')) {
      return;
    }
    final intent = _intent;
    final inserted =
        await api.post('/playback/${mode.name}/insert', {
              'item': {
                'id': track.id,
                'mode': mode.name,
                'title': track.title,
                'kind': track.kind,
              },
              'next': next,
              'expectedRevision': snapshot!['revision'],
            })
            as Json;
    if (intent == _intent) snapshot = inserted;
  });

  /// 从队列移除一首（不能移除正在播放的那首）；服务端保持 generation，在播收听不受影响。
  Future<void> removeAt(int target) => _edit({'index': target});

  /// 清除“接下来播放”：只保留已播放和当前歌曲，与“音乐”的“清除”一致。
  Future<void> clearUpcoming() => _edit({'upcoming': true});

  Future<void> _edit(Json body) => _command(() async {
    if (snapshot == null) return;
    final target = body['index'] as int?;
    if (target != null &&
        (target < 0 || target >= items.length || target == index)) {
      return;
    }
    if (body['upcoming'] == true && index + 1 >= items.length) return;
    final intent = _intent;
    final edited =
        await api.post('/playback/${mode.name}/remove', {
              ...body,
              'expectedRevision': snapshot!['revision'],
            })
            as Json;
    if (intent == _intent) snapshot = edited;
  });

  /// 停止（⌘.）：暂停并回到开头，队列与当前歌曲保留。
  Future<void> stop() async {
    if (current == null) return;
    if (engine.playing.value) await toggle();
    await seek(Duration.zero);
  }

  /// 在当前歌曲内快进/快退（⌥⌘→/←）。
  Future<void> skipBy(Duration delta) {
    final total = engine.duration.value;
    var target = engine.position.value + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (total > Duration.zero && target > total) target = total;
    return seek(target);
  }

  Future<void> setShuffle() => _command(() async {
    _shuffled.clear();
    state['shuffle'] = !shuffle;
    await _save();
  });
  Future<void> cycleRepeat() => _command(() async {
    state['repeat'] = {'off': 'all', 'all': 'one', 'one': 'off'}[repeat];
    await _save();
  });
  Future<void> startIntelligence() {
    if (mode != MusicMode.netease) return Future.value();
    if (intelligence) {
      return engine.playing.value ? Future.value() : toggle();
    }
    return _startingHeart ??= _setIntelligence(
      true,
    ).whenComplete(() => _startingHeart = null);
  }

  Future<void> setIntelligence() =>
      intelligence ? _setIntelligence(false) : startIntelligence();

  /// 默认以喜欢歌单开启；同一首歌保持音源和进度，关闭恢复原队列并暂停。
  Future<void> _setIntelligence(bool enabled) {
    final intent = ++_intent;
    _changing = true;
    loading = true;
    notifyListeners();
    return _command(() async {
      try {
        if (intent != _intent) return;
        await _save();
        final result =
            await api.post('/netease/queues/intelligence', {'enabled': enabled})
                as Json;
        if (intent != _intent) return;
        final incoming = result['state']['items'] as List? ?? [];
        final sameTrack =
            enabled &&
            current?.isPodcast != true &&
            incoming.isNotEmpty &&
            current?.id == incoming.first['id'].toString();
        snapshot = result;
        error = null;
        if (sameTrack) {
          if (!engine.playing.value) await engine.toggle();
          await _save();
        } else {
          listening.finish('changed');
          await engine.pause();
          await engine.stop();
          await _load(
            intent,
            play: enabled,
            position: (state['positionMs'] as num? ?? 0).toInt(),
          );
        }
      } finally {
        if (intent == _intent) {
          _changing = false;
          loading = false;
        }
      }
    });
  }

  /// 退出立即使旧装载失效，不能等待旧网络请求才暂停。
  Future<void> reset() async {
    ++_intent;
    listening.finish('logout');
    await engine.stop();
    snapshot = null;
    current = null;
    pending = null;
    _prefetched = null;
    _savedProgress = null;
    error = null;
    mode = MusicMode.netease;
    onModeChanged?.call(mode);
    loading = false;
    _changing = false;
    notifyListeners();
  }

  Future<void> shutdown() => _shutdownJob ??= _shutdown();

  /// 先停调度并取消传输；本机位置先落盘，网络保存只等待短时限。
  Future<void> _shutdown() async {
    _shuttingDown = true;
    _timer?.cancel();
    ++_intent;
    final closingMode = mode, saved = snapshot;
    final position = current == null
        ? (state['positionMs'] as num? ?? 0).toInt()
        : engine.position.value.inMilliseconds;
    api.cancelPending();
    final reporting = listening.stop();
    final pause = engine
        .pause()
        .catchError((_) {})
        .timeout(const Duration(milliseconds: 150), onTimeout: () {});
    if (saved != null) {
      try {
        await checkpoints?.save(closingMode, saved, position);
      } catch (_) {
        /* 仍尝试服务端保存。 */
      }
    }
    await pause;
    await reporting.timeout(
      const Duration(milliseconds: 100),
      onTimeout: () {},
    );
    await _tail.timeout(const Duration(milliseconds: 100), onTimeout: () {});
    if (saved == null || api.token == null) return;
    try {
      await Future.wait([
        listening.flush(),
        _putProgress(closingMode, saved, positionMs: position, playing: false),
      ]).timeout(const Duration(milliseconds: 750));
      await checkpoints?.clear(closingMode);
    } catch (_) {
      // 离线或冲突保留本机标记，下次只对同代同项队列恢复。
    } finally {
      api.cancelPending();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_intent;
    _timer?.cancel();
    listening.dispose();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(engine.dispose());
    super.dispose();
  }
}
