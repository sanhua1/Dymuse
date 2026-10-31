import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
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

/// 已注册 Windows、macOS 与 iOS；iOS 使用独立移动导航，不创建桌面窗口。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isIOS) {
    throw UnsupportedError('本阶段仅支持 Windows、macOS 与 iOS。');
  }
  final apple = Platform.isMacOS || Platform.isIOS;
  if (Platform.isWindows) MediaKit.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
  final api = ApiClient(), window = DesktopWindow();
  api.cache = await MediaCache.open(preferences, audioEnabled: apple);
  if (api.cache != null) {
    for (final group in CacheGroup.values) {
      unawaited(api.cache!.trim(group));
    }
  }
  final session = Session(api, preferences), catalog = Catalog(api);
  final playback = PlaybackController(
    api,
    catalog,
    apple ? AppleAudioEngine() : WindowsAudioEngine(),
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
  if (apple) NowPlaying(playback);
  final appearance = Appearance(
    brightness: switch (preferences.getString('appearance')) {
      'light' => Brightness.light,
      'dark' => Brightness.dark,
      _ => null,
    },
    // Apple 平台跟随系统辅助功能设置，不读应用内旧开关（设置页也不再显示）。
    reduceTransparency:
        !apple && (preferences.getBool('reduceTransparency') ?? false),
    reduceMotion: !apple && (preferences.getBool('reduceMotion') ?? false),
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
  if (!Platform.isIOS) await window.initialize();
  unawaited(
    session.restore().then((_) async {
      await sync.load();
      if (sync.configured) unawaited(sync.sync());
    }),
  );
}
