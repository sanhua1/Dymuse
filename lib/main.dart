import 'dart:async';
import 'dart:io';
import 'dart:ui' show FrameTiming;
import 'package:flutter/cupertino.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app/dymuse_app.dart';
import 'bilibili/title_rules.dart';
import 'core/api_client.dart';
import 'core/media_cache.dart';
import 'core/session.dart';
import 'design_system/tokens.dart';
import 'features/catalog.dart';
import 'platform/desktop_window.dart';
import 'platform/now_playing.dart';
import 'playback/audio_engine.dart';
import 'playback/audio_quality.dart';
import 'playback/playback_controller.dart';
import 'sync/sync_service.dart';

/// 已注册 Windows、macOS、iOS 与 Android；手机使用独立移动导航，不创建桌面窗口。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('FRAME_LOG')) _logFrames();
  if (!Platform.isWindows &&
      !Platform.isMacOS &&
      !Platform.isIOS &&
      !Platform.isAndroid) {
    throw UnsupportedError('本阶段仅支持 Windows、macOS、iOS 与 Android。');
  }
  // 除 Windows（libmpv）外都用 just_audio，并启用歌曲缓存与系统播放控制。
  final justAudio = !Platform.isWindows;
  if (Platform.isWindows) MediaKit.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
  final api = ApiClient(), window = DesktopWindow();
  api.cache = await MediaCache.open(preferences, audioEnabled: justAudio);
  if (api.cache != null) {
    for (final group in CacheGroup.values) {
      unawaited(api.cache!.trim(group));
    }
  }
  final session = Session(api, preferences), catalog = Catalog(api);
  final playback = PlaybackController(
    api,
    catalog,
    justAudio ? JustAudioEngine() : WindowsAudioEngine(),
  );
  playback.mode = MusicMode.values.firstWhere(
    (mode) => mode.name == preferences.getString('lastMode'),
    orElse: () => MusicMode.netease,
  );
  playback.onModeChanged = (mode) =>
      unawaited(preferences.setString('lastMode', mode.name));
  playback.quality = AudioQuality.fromName(
    preferences.getString('audioQuality'),
  );
  if (justAudio) NowPlaying(playback);
  final appearance = Appearance(
    brightness: switch (preferences.getString('appearance')) {
      'light' => Brightness.light,
      'dark' => Brightness.dark,
      _ => null,
    },
    // 除 Windows 外跟随系统辅助功能设置，不读应用内旧开关（设置页也不再显示）。
    reduceTransparency:
        !justAudio && (preferences.getBool('reduceTransparency') ?? false),
    reduceMotion: !justAudio && (preferences.getBool('reduceMotion') ?? false),
  )..applyAccent(preferences.getString('accent'));
  final sync = SyncService(preferences);
  session.sync = sync;
  session.onTitleRules = catalog.syncApplied;
  sync
    ..readCredentials = session.syncCredentials
    ..writeCredentials = session.applySyncedCredentials
    ..isPlaying = (() => playback.engine.playing.value)
    ..readSettings = (() => {
      'appearance': appearance.brightness?.name ?? 'system',
      'accent': appearance.accentValue,
      'titleParse': preferences.getString(TitleRules.enabledKey) ?? '1',
      'titleRules': preferences.getString(TitleRules.customKey) ?? '',
      'titleSearch': preferences.getString(TitleRules.searchKey) ?? '0',
    })
    ..applySettings = ((values) {
      final parse = values['titleParse'] ?? '1',
          rules = values['titleRules'] ?? '';
      final search = values['titleSearch'] ?? '0';
      if (search != (preferences.getString(TitleRules.searchKey) ?? '0') ||
          parse != (preferences.getString(TitleRules.enabledKey) ?? '1') ||
          rules != (preferences.getString(TitleRules.customKey) ?? '')) {
        unawaited(preferences.setString(TitleRules.enabledKey, parse));
        unawaited(preferences.setString(TitleRules.customKey, rules));
        unawaited(preferences.setString(TitleRules.searchKey, search));
        session.titleRulesChanged();
      }
      appearance.update(
        system: values['appearance'] == 'system',
        brightness: values['appearance'] == 'dark'
            ? Brightness.dark
            : values['appearance'] == 'light'
            ? Brightness.light
            : null,
      );
      appearance.applyAccent(values['accent']);
    })
    ..onApplied = ((changed) {
      catalog.syncApplied();
      final key = 'playback:${playback.mode.name}';
      if (changed.contains(key)) unawaited(playback.restore());
    });
  runApp(
    DymuseApp(
      session: session,
      catalog: catalog,
      playback: playback,
      appearance: appearance,
      window: window,
    ),
  );
  if (!Platform.isIOS && !Platform.isAndroid) await window.initialize();
  unawaited(
    session.restore().then((_) async {
      await sync.load();
      if (sync.configured) unawaited(sync.sync());
    }),
  );
}

/// 性能排查：用 `--dart-define=FRAME_LOG=true` 构建后，每 120 帧在 logcat 输出
/// 构建与光栅耗时的中位数、p90 和超时帧比例。
void _logFrames() {
  final build = <double>[], raster = <double>[];
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final FrameTiming t in timings) {
      build.add(t.buildDuration.inMicroseconds / 1000);
      raster.add(t.rasterDuration.inMicroseconds / 1000);
    }
    if (build.length < 120) return;
    String stat(List<double> v) {
      final s = [...v]..sort();
      return 'p50 ${s[s.length ~/ 2].toStringAsFixed(1)} '
          'p90 ${s[(s.length * .9).floor()].toStringAsFixed(1)} '
          'max ${s.last.toStringAsFixed(1)}';
    }

    final slow = [
      for (var i = 0; i < build.length; i++)
        if (build[i] > 8.3 || raster[i] > 8.3) 1,
    ].length;
    debugPrint(
      'FRAMES n=${build.length} build[${stat(build)}] raster[${stat(raster)}] '
      'slow>8.3ms=${(100 * slow / build.length).round()}%',
    );
    build.clear();
    raster.clear();
  });
}
