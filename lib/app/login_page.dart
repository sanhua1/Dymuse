import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../core/api_client.dart';
import '../core/session.dart';
import '../features/sync_settings.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';

/// 网易云扫码登录：二维码由手机自己向网易云申请，登录后 Cookie 只留本机。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.session});
  final Session session;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  String _url = '';
  int _code = 801;
  DateTime? _expiresAt;
  Timer? _timer;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_create());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _url = '';
    });
    try {
      final data = await widget.session.createQr();
      if (!mounted) return;
      setState(() {
        _url = '${data['url'] ?? ''}';
        _code = (data['code'] as num?)?.toInt() ?? 801;
        final at = (data['expiresAt'] as num?)?.toInt();
        _expiresAt = at == null
            ? DateTime.now().add(const Duration(minutes: 2))
            : DateTime.fromMillisecondsSinceEpoch(at);
      });
      _timer?.cancel();
      _timer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_check()),
      );
    } catch (error) {
      if (mounted) setState(() => _error = readableError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check() async {
    if (_code == 803 || _code == 800) return;
    try {
      final data = await widget.session.checkQr();
      if (!mounted) return;
      final code = (data['code'] as num?)?.toInt() ?? _code;
      // 803 时 Session 会切到已登录界面，这里不再改状态。
      if (code == 803) {
        _timer?.cancel();
        return;
      }
      setState(() => _code = code);
    } catch (error) {
      if (mounted) setState(() => _error = readableError(error));
    }
  }

  String get _status => switch (_code) {
    800 => '二维码已过期',
    802 => '已扫码，请在手机上确认登录',
    803 => '登录成功',
    _ => '打开网易云音乐 App，扫一扫登录',
  };

  @override
  Widget build(BuildContext context) {
    final ink = DymuseTokens.ink(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1000;
        return Row(
          children: [
            if (wide)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(70, 30, 30, 55),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Spacer(),
                      const Text(
                        '音乐，\n回到纯粹。',
                        style: TextStyle(
                          fontSize: 46,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -1.8,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        '你的音乐。你的片刻。',
                        style: TextStyle(
                          color: DymuseTokens.secondary(context),
                          fontSize: 17,
                        ),
                      ),
                      const Expanded(
                        flex: 5,
                        child: Center(child: RecordArtwork()),
                      ),
                      Text(
                        'D Y M U S E',
                        style: TextStyle(
                          color: DymuseTokens.secondary(context),
                          fontSize: 11,
                          letterSpacing: 5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 42,
                    vertical: 30,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 350),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.asset(
                            'assets/brand/app_icon.png',
                            width: 64,
                            height: 64,
                            semanticLabel: 'Dymuse',
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text('登录网易云音乐', style: DymuseTokens.heading),
                        const SizedBox(height: 10),
                        Text(
                          '用网易云音乐 App 扫码登录。登录信息只保存在这台设备上，'
                          '歌曲、歌单和播放请求都由这台设备直接连接网易云。',
                          style: DymuseTokens.body.copyWith(
                            color: DymuseTokens.secondary(context),
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 26),
                        Center(
                          child: GestureDetector(
                            onTap: _busy ? null : _create,
                            child: Container(
                              width: 216,
                              height: 216,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: CupertinoColors.white,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: _url.isEmpty
                                  ? const Center(
                                      child: CupertinoActivityIndicator(
                                        radius: 16,
                                      ),
                                    )
                                  : Opacity(
                                      opacity: _code == 800 ? .18 : 1,
                                      child: QrImageView(
                                        data: _url,
                                        size: 192,
                                        backgroundColor: CupertinoColors.white,
                                        eyeStyle: const QrEyeStyle(
                                          eyeShape: QrEyeShape.square,
                                          color: CupertinoColors.black,
                                        ),
                                        dataModuleStyle:
                                            const QrDataModuleStyle(
                                              dataModuleShape:
                                                  QrDataModuleShape.square,
                                              color: CupertinoColors.black,
                                            ),
                                      ),
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Center(
                          child: Text(
                            _status,
                            style: TextStyle(
                              fontSize: 13,
                              color: _code == 802
                                  ? ink
                                  : DymuseTokens.secondary(context),
                            ),
                          ),
                        ),
                        if (_code == 800)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Center(
                              child: ActionButton(
                                label: '刷新二维码',
                                onPressed: _create,
                              ),
                            ),
                          ),
                        const SizedBox(height: 18),
                        if (_error != null || widget.session.notice != null)
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _error ?? widget.session.notice!,
                              style: TextStyle(
                                color: _error != null
                                    ? DymuseTokens.tint(context)
                                    : DymuseTokens.secondary(context),
                                fontSize: 12,
                                height: 1.5,
                              ),
                            ),
                          ),
                        if (widget.session.sync != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Center(
                              child: ActionButton(
                                label: '已有同步？用 WebDAV 恢复登录',
                                onPressed: () => showSyncForm(
                                  context,
                                  widget.session.sync!,
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Text(
                          _expiresAt == null
                              ? ''
                              : '二维码约 2 分钟有效，过期后点按二维码刷新。',
                          style: DymuseTokens.caption.copyWith(
                            color: DymuseTokens.secondary(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 程序绘制的唱片标识，无外部图片或未经许可的字体资产。
class RecordArtwork extends StatelessWidget {
  const RecordArtwork({super.key});
  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1,
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: CustomPaint(painter: _RecordPainter()),
    ),
  );
}

class _RecordPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center.translate(0, 12),
      radius * .95,
      Paint()
        ..color = const Color(0x14382948)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF34313E),
            Color(0xFF15131C),
            Color(0xFF4D4352),
            Color(0xFF201C29),
          ],
        ).createShader(rect),
    );
    for (var i = 0; i < 35; i++) {
      canvas.drawCircle(
        center,
        radius * (.42 + i * .015),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .6
          ..color = const Color(0x165F596A),
      );
    }
    canvas.drawCircle(
      center,
      radius * .34,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFE9B4C2), Color(0xFFB56589), Color(0xFF785778)],
        ).createShader(rect),
    );
    final text = TextPainter(
      text: const TextSpan(
        text: 'dy',
        style: TextStyle(
          fontSize: 34,
          fontWeight: FontWeight.w600,
          color: Color(0xFFF7E8EE),
          letterSpacing: -3,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(
      canvas,
      center - Offset(text.width / 2, text.height / 2 + radius * .025),
    );
    canvas.drawCircle(
      center.translate(0, radius * .2),
      radius * .018,
      Paint()..color = const Color(0xFF342839),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
