import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/scheduler.dart';

import '../core/api_client.dart';
import '../core/artwork_image.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';

/// 播放页的背景：从封面里取最多 5 个颜色（主色加平均色），压低浓度后，画成几团
/// 大小、深浅各不相同的径向渐变叠在底色上，像把封面高斯模糊后的色块（Apple Music 播放页的观感）。
/// 不做任何实时模糊：只解码一张 24 像素的小图；色块在播放时以每秒约 15 帧缓慢漂移，
/// 暂停、减弱动态效果或页面不在前台时完全静止，不占用 GPU。
class PlayerBackdrop extends StatefulWidget {
  const PlayerBackdrop({
    super.key,
    required this.api,
    required this.url,
    required this.playing,
    required this.child,
  });
  final ApiClient api;
  final String? url;

  /// 播放中才让色块漂移。
  final ValueListenable<bool> playing;
  final Widget child;

  @override
  State<PlayerBackdrop> createState() => _PlayerBackdropState();
}

class _PlayerBackdropState extends State<PlayerBackdrop>
    with SingleTickerProviderStateMixin {
  static final _cache = <String, List<Color>>{};
  late final Ticker _ticker = createTicker(_tick);
  final _time = ValueNotifier<double>(0);
  Duration _lastFrame = Duration.zero;
  bool _still = false;
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  List<Color> _from = const [], _to = const [];
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    _fade.value = 1;
    widget.playing.addListener(_syncMotion);
  }

  /// 约 15 帧/秒：漂移很慢，用不着满帧率，GPU 能多休息。
  void _tick(Duration elapsed) {
    if (elapsed - _lastFrame < const Duration(milliseconds: 66)) return;
    _lastFrame = elapsed;
    _time.value = elapsed.inMilliseconds / 1000;
  }

  void _syncMotion() {
    final run = widget.playing.value && !_still;
    if (run && !_ticker.isActive) {
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still =
        MediaQuery.maybeDisableAnimationsOf(context) == true ||
        AppearanceScope.of(context)?.reduceMotion == true ||
        AppearanceScope.of(context)?.backdropDrift == false;
    _syncMotion();
    _load();
  }

  @override
  void didUpdateWidget(PlayerBackdrop old) {
    super.didUpdateWidget(old);
    if (old.playing != widget.playing) {
      old.playing.removeListener(_syncMotion);
      widget.playing.addListener(_syncMotion);
      _syncMotion();
    }
    if (old.url != widget.url) _load();
  }

  void _load() {
    _stopListening();
    final request = RemoteArtwork.request(widget.api, widget.url, 64);
    if (request == null) return;
    final cached = _cache[request.url];
    if (cached != null) return _show(cached);
    final provider = ResizeImage.resizeIfNeeded(
      24,
      null,
      ArtworkImage(request.url, headers: request.headers),
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) async {
      // 先清掉记录再移除：之后 dispose 时不会对已释放的 ImageStream 再移除一次。
      if (_listener == listener) _listener = null;
      stream.removeListener(listener);
      final colors = await _dominant(info.image);
      info.dispose();
      if (!mounted || colors.isEmpty) return;
      if (_cache.length > 40) _cache.remove(_cache.keys.first);
      _cache[request.url] = colors;
      if (_stream == stream) _show(colors);
    }, onError: (_, _) {});
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _stopListening() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  void _show(List<Color> colors) {
    setState(() {
      _from = _current();
      _to = colors;
    });
    _fade.forward(from: 0);
  }

  List<Color> _current() =>
      _blend(_from, _to, Curves.easeInOut.transform(_fade.value));

  @override
  void dispose() {
    widget.playing.removeListener(_syncMotion);
    _ticker.dispose();
    _time.dispose();
    _stopListening();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = DymuseTokens.background(context);
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return ColoredBox(
      color: base,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: Listenable.merge([_fade, _time]),
              builder: (context, _) => CustomPaint(
                painter: _BackdropPainter(
                  colors: _blend(
                    _from,
                    _to,
                    Curves.easeInOut.transform(_fade.value),
                  ),
                  base: base,
                  dark: dark,
                  time: _time.value,
                ),
              ),
            ),
          ),
          widget.child,
        ],
      ),
    );
  }
}

/// 逐个颜色按 [t] 混合；两边数量不同时缺的用另一边最后一个补齐。
List<Color> _blend(List<Color> a, List<Color> b, double t) {
  final count = math.max(a.length, b.length);
  if (count == 0) return const [];
  Color at(List<Color> list, int i) => list.isEmpty
      ? const Color(0x00000000)
      : list[math.min(i, list.length - 1)];
  return [
    for (var i = 0; i < count; i++)
      a.isEmpty
          ? at(b, i).withValues(alpha: t)
          : Color.lerp(at(a, i), at(b, i), t)!,
  ];
}

/// 从小图里挑最多 3 个“有色相”的主色（色相分 12 组，按饱和度加权）。
/// 灰度封面（没有饱和的颜色）退回平均色。
Future<List<Color>> _dominant(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return const [];
  const bins = 12;
  final weight = List<double>.filled(bins, 0);
  final sum = List.generate(bins, (_) => [0.0, 0.0, 0.0]);
  var avg = [0.0, 0.0, 0.0];
  final pixels = data.lengthInBytes ~/ 4;
  for (var i = 0; i < pixels; i++) {
    final r = data.getUint8(i * 4) / 255,
        g = data.getUint8(i * 4 + 1) / 255,
        b = data.getUint8(i * 4 + 2) / 255;
    avg = [avg[0] + r, avg[1] + g, avg[2] + b];
    final hsl = HSLColor.fromColor(
      Color.from(alpha: 1, red: r, green: g, blue: b),
    );
    // 太暗、太亮的像素对氛围贡献小。
    final w =
        hsl.saturation * (1 - ((hsl.lightness - .5).abs() * 1.7)).clamp(.05, 1);
    if (hsl.saturation < .12) continue;
    final bin = (hsl.hue / 360 * bins).floor() % bins;
    weight[bin] += w;
    sum[bin][0] += r * w;
    sum[bin][1] += g * w;
    sum[bin][2] += b * w;
  }
  final order = List.generate(bins, (i) => i)
    ..sort((x, y) => weight[y].compareTo(weight[x]));
  final picked = <int>[];
  for (final bin in order) {
    if (weight[bin] < pixels * .01) break;
    // 相邻色相组合并看作同一种颜色，避免三个颜色几乎一样。
    if (picked.any(
      (p) => math.min((p - bin).abs(), bins - (p - bin).abs()) < 2,
    )) {
      continue;
    }
    picked.add(bin);
    if (picked.length == 4) break;
  }
  Color rgb(double r, double g, double b) =>
      Color.from(alpha: 1, red: r, green: g, blue: b);
  if (picked.isEmpty) {
    return [rgb(avg[0] / pixels, avg[1] / pixels, avg[2] / pixels)];
  }
  return [
    for (final bin in picked)
      rgb(
        sum[bin][0] / weight[bin],
        sum[bin][1] / weight[bin],
        sum[bin][2] / weight[bin],
      ),
  ];
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required this.colors,
    required this.base,
    required this.dark,
    required this.time,
  });
  final List<Color> colors;
  final Color base;
  final bool dark;
  final double time;

  /// 压低浓度：饱和度封顶、明度落在柔和的区间，再向底色靠拢，再亮的封面也不刺眼；
  /// 每团色块的明度略有高低，层次比单一色调更丰富。
  Color _soften(Color color, double lift) {
    final hsl = HSLColor.fromColor(color);
    final tuned = hsl
        .withSaturation((hsl.saturation * .85).clamp(0.0, dark ? .55 : .6))
        .withLightness(((dark ? .3 : .8) + (dark ? lift : -lift)).clamp(0, 1))
        .toColor();
    return Color.lerp(base, tuned, .8)!;
  }

  // 每团色块：中心（占屏幕比例）、半径（占长边比例）、明度起伏、漂移相位与幅度。
  static const _blobs = [
    (x: .85, y: .08, r: .9, lift: .06, phase: 0.0, speed: .11),
    (x: .08, y: .38, r: .85, lift: .0, phase: 1.7, speed: .09),
    (x: .92, y: .72, r: .95, lift: -.04, phase: 3.1, speed: .1),
    (x: .2, y: .92, r: .8, lift: .08, phase: 4.6, speed: .12),
    (x: .5, y: .5, r: 1.1, lift: -.06, phase: 5.8, speed: .07),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (colors.isEmpty) return;
    final longest = size.longestSide;
    // 颜色多于色块时多出的忽略；少于色块时循环使用，保证总是铺满。
    for (var i = 0; i < _blobs.length; i++) {
      final blob = _blobs[i];
      final color = _soften(colors[i % colors.length], blob.lift);
      // 缓慢漂移：每团沿各自的相位画小圈，幅度约屏幕的 8%。
      final angle = time * blob.speed + blob.phase;
      final center = Offset(
        (blob.x + math.sin(angle) * .08) * size.width,
        (blob.y + math.cos(angle * .8) * .06) * size.height,
      );
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.radial(center, longest * blob.r * .7, [
            color.withValues(alpha: .95),
            color.withValues(alpha: 0),
          ]),
      );
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.base != base ||
      old.dark != dark ||
      old.time != time ||
      !listEquals(old.colors, colors);
}
