import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../core/api_client.dart';
import '../core/session.dart';
import '../design_system/components.dart';
import '../design_system/sheet.dart';
import '../design_system/tokens.dart';
import '../netease/client.dart';

/// 登录网易云账号：扫码、密码、验证码三种方式。
/// 首次打开的欢迎页和之后在设置里登录都用它；登录信息只保存在本机。
class NeteaseLoginView extends StatefulWidget {
  const NeteaseLoginView({
    super.key,
    required this.session,
    this.onBack,
    this.onDone,
  });
  final Session session;

  /// 左上角“返回”；为空时不显示。
  final VoidCallback? onBack;

  /// 登录成功后调用（弹出的登录页用它关闭自己）；欢迎页登录后会被整页替换，不需要。
  final VoidCallback? onDone;
  @override
  State<NeteaseLoginView> createState() => _NeteaseLoginViewState();
}

enum _Method { qr, password, code }

class _NeteaseLoginViewState extends State<NeteaseLoginView> {
  _Method _method = _Method.qr;
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false, _sending = false, _risk = false, _finished = false;
  String? _error;
  int _cooldown = 0;
  Timer? _cooldownTimer;

  // 扫码
  String _url = '';
  int _qrCode = 801;
  Timer? _qrTimer;
  bool _qrBusy = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_sessionChanged);
    unawaited(_createQr());
  }

  @override
  void dispose() {
    widget.session.removeListener(_sessionChanged);
    _qrTimer?.cancel();
    _cooldownTimer?.cancel();
    _phone.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  void _sessionChanged() {
    final session = widget.session;
    if (_finished || session.user == null || session.guest) return;
    _finished = true;
    _qrTimer?.cancel();
    widget.onDone?.call();
  }

  // ---- 扫码 ----

  Future<void> _createQr() async {
    if (_qrBusy) return;
    setState(() {
      _qrBusy = true;
      _error = null;
      _url = '';
    });
    try {
      final data = await widget.session.createQr();
      if (!mounted) return;
      setState(() {
        _url = '${data['url'] ?? ''}';
        _qrCode = (data['code'] as num?)?.toInt() ?? 801;
      });
      _qrTimer?.cancel();
      if (_method == _Method.qr) {
        _qrTimer = Timer.periodic(
          const Duration(seconds: 2),
          (_) => unawaited(_checkQr()),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _qrBusy = false);
    }
  }

  Future<void> _checkQr() async {
    if (_qrCode == 803 || _qrCode == 800) return;
    try {
      final data = await widget.session.checkQr();
      if (!mounted) return;
      final code = (data['code'] as num?)?.toInt() ?? _qrCode;
      if (code == 803) {
        _qrTimer?.cancel();
        return;
      }
      setState(() => _qrCode = code);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  String get _qrStatus => switch (_qrCode) {
    800 => '二维码已过期',
    802 => '已扫码，请在手机上确认',
    803 => '登录成功',
    _ => '打开网易云音乐 App，扫一扫',
  };

  // ---- 手机号 ----

  String _message(Object error) =>
      error is NeteaseError ? error.message : readableError(error);

  String? _checkPhone() {
    final phone = _phone.text.trim();
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) return '请输入 11 位手机号。';
    return null;
  }

  void _select(_Method method) {
    if (method == _method) return;
    setState(() {
      _method = method;
      _error = null;
    });
    if (method == _Method.qr) {
      if (_url.isEmpty || _qrCode == 800) {
        unawaited(_createQr());
      } else {
        _qrTimer?.cancel();
        _qrTimer = Timer.periodic(
          const Duration(seconds: 2),
          (_) => unawaited(_checkQr()),
        );
      }
    } else {
      _qrTimer?.cancel();
    }
  }

  Future<void> _sendCode() async {
    final problem = _checkPhone();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.session.sendLoginCaptcha(_phone.text.trim());
      if (!mounted) return;
      setState(() => _cooldown = 60);
      _cooldownTimer?.cancel();
      _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return timer.cancel();
        setState(() => _cooldown--);
        if (_cooldown <= 0) timer.cancel();
      });
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 密码登录被网易云要求安全验证后，同一个页面里补填短信验证码继续登录。
  bool get _usesCode => _method == _Method.code || _risk;

  Future<void> _submit() async {
    if (_busy) return;
    final problem = _checkPhone();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    if (_usesCode) {
      if (_code.text.trim().isEmpty) {
        setState(() => _error = '请输入验证码。');
        return;
      }
    } else if (_password.text.isEmpty) {
      setState(() => _error = '请输入密码。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.loginWithPhone(
        phone: _phone.text.trim(),
        password: _usesCode ? null : _password.text,
        captcha: _usesCode ? _code.text.trim() : null,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (error is NeteaseError &&
            error.code == NeteaseClient.loginRisk &&
            _method == _Method.password) {
          _risk = true;
          _error = null;
        } else {
          _error = _message(error);
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showInfo() => showCupertinoDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialog) => CupertinoAlertDialog(
      title: const Text('关于登录'),
      content: const Padding(
        padding: EdgeInsets.only(top: 10),
        child: Text(
          '登录信息只保存在这台设备上，歌曲、歌单和播放请求都由这台设备直接连接网易云。\n\n'
          '密码登录被网易云要求安全验证时，会改为填写短信验证码。',
          textAlign: TextAlign.start,
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('好'),
        ),
      ],
    ),
  );

  // ---- 界面 ----

  Widget _field(
    TextEditingController controller,
    String placeholder, {
    Widget? prefix,
    Widget? suffix,
    bool secret = false,
    int? maxLength,
    bool digits = false,
    TextInputAction action = TextInputAction.next,
    VoidCallback? onSubmitted,
    TextInputType? type,
  }) {
    final secondary = DymuseTokens.secondary(context);
    return CupertinoTextField(
      controller: controller,
      placeholder: placeholder,
      enabled: !_busy,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: type ?? (digits ? TextInputType.number : null),
      textInputAction: action,
      inputFormatters: [
        if (digits) FilteringTextInputFormatter.digitsOnly,
        if (maxLength != null) LengthLimitingTextInputFormatter(maxLength),
      ],
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted(),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      style: const TextStyle(fontSize: 16),
      placeholderStyle: TextStyle(fontSize: 16, color: secondary),
      prefix: prefix == null
          ? null
          : Padding(padding: const EdgeInsets.only(left: 14), child: prefix),
      suffix: suffix,
      decoration: BoxDecoration(
        color: DymuseTokens.surface(context),
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }

  Widget get _phoneField => _field(
    _phone,
    '手机号',
    prefix: Text(
      '+86',
      style: TextStyle(fontSize: 16, color: DymuseTokens.secondary(context)),
    ),
    digits: true,
    maxLength: 11,
    type: TextInputType.phone,
  );

  Widget get _codeField {
    final tint = DymuseTokens.tint(context);
    final secondary = DymuseTokens.secondary(context);
    final waiting = _cooldown > 0;
    return _field(
      _code,
      '验证码',
      digits: true,
      maxLength: 6,
      action: TextInputAction.done,
      onSubmitted: _submit,
      suffix: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        minimumSize: const Size(0, 44),
        onPressed: waiting || _sending || _busy ? null : _sendCode,
        child: _sending
            ? const CupertinoActivityIndicator(radius: 8)
            : Text(
                waiting ? '${_cooldown}s' : '获取验证码',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: waiting ? secondary : tint,
                ),
              ),
      ),
    );
  }

  Widget _submitButton(String label) {
    final dark = DymuseTokens.dark(context);
    return CupertinoButton(
      color: DymuseTokens.tint(context),
      disabledColor: DymuseTokens.tint(context).withValues(alpha: .45),
      borderRadius: BorderRadius.circular(12),
      minimumSize: const Size.fromHeight(46),
      onPressed: _busy ? null : _submit,
      child: _busy
          ? const CupertinoActivityIndicator(color: CupertinoColors.white)
          : Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: dark ? const Color(0xFF2D1520) : CupertinoColors.white,
              ),
            ),
    );
  }

  Widget _qrPane() {
    final secondary = DymuseTokens.secondary(context);
    return Column(
      children: [
        GestureDetector(
          onTap: _qrBusy ? null : _createQr,
          child: Container(
            width: 196,
            height: 196,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: CupertinoColors.white,
              borderRadius: BorderRadius.circular(18),
            ),
            child: _url.isEmpty
                ? const Center(child: CupertinoActivityIndicator(radius: 14))
                : Opacity(
                    opacity: _qrCode == 800 ? .18 : 1,
                    child: QrImageView(
                      data: _url,
                      size: 172,
                      backgroundColor: CupertinoColors.white,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: CupertinoColors.black,
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: CupertinoColors.black,
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          _qrStatus,
          style: TextStyle(
            fontSize: 13,
            color: _qrCode == 802 ? DymuseTokens.ink(context) : secondary,
          ),
        ),
        if (_qrCode == 800)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ActionButton(label: '刷新二维码', onPressed: _createQr),
          ),
      ],
    );
  }

  Widget _passwordPane() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _phoneField,
      const SizedBox(height: 12),
      _field(
        _password,
        '密码',
        secret: true,
        action: _risk ? TextInputAction.next : TextInputAction.done,
        onSubmitted: _risk ? null : _submit,
      ),
      if (_risk) ...[
        const SizedBox(height: 14),
        Row(
          children: [
            Icon(
              CupertinoIcons.shield_lefthalf_fill,
              size: 16,
              color: DymuseTokens.tint(context),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '网易云要求安全验证，请填写短信验证码。',
                style: TextStyle(
                  fontSize: 13,
                  color: DymuseTokens.secondary(context),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _codeField,
      ],
      const SizedBox(height: 18),
      _submitButton(_risk ? '验证并登录' : '登录'),
    ],
  );

  Widget _codePane() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _phoneField,
      const SizedBox(height: 12),
      _codeField,
      const SizedBox(height: 18),
      _submitButton('登录'),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final pane = switch (_method) {
      _Method.qr => _qrPane(),
      _Method.password => _passwordPane(),
      _Method.code => _codePane(),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.onBack != null)
          Align(
            alignment: Alignment.centerLeft,
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(44, 44),
              onPressed: widget.onBack,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(CupertinoIcons.chevron_back, size: 20),
                  const SizedBox(width: 2),
                  Text('返回', style: TextStyle(fontSize: 16)),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('登录网易云', style: DymuseTokens.heading),
            Semantics(
              button: true,
              label: '登录说明',
              excludeSemantics: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _showInfo,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Center(
                    child: Icon(
                      CupertinoIcons.info_circle,
                      size: 17,
                      color: DymuseTokens.secondary(context),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        CupertinoSlidingSegmentedControl<_Method>(
          groupValue: _method,
          onValueChanged: (value) {
            if (value != null && !_busy) _select(value);
          },
          children: const {
            _Method.qr: Padding(
              padding: EdgeInsets.symmetric(vertical: 5),
              child: Text('扫码', style: TextStyle(fontSize: 14)),
            ),
            _Method.password: Padding(
              padding: EdgeInsets.symmetric(vertical: 5),
              child: Text('密码', style: TextStyle(fontSize: 14)),
            ),
            _Method.code: Padding(
              padding: EdgeInsets.symmetric(vertical: 5),
              child: Text('验证码', style: TextStyle(fontSize: 14)),
            ),
          },
        ),
        const SizedBox(height: 24),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 252),
          child: Align(alignment: Alignment.topCenter, child: pane),
        ),
        if (_error != null || widget.session.notice != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _error ?? widget.session.notice!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: _error != null
                      ? CupertinoColors.systemRed.resolveFrom(context)
                      : DymuseTokens.secondary(context),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

bool _presenting = false;

/// 在当前页面上方打开登录页：桌面是居中的弹窗，手机是页面 Sheet。
/// 当前的游客身份保持不变，关掉就回到原来的页面；登录成功后自动关闭。
Future<void> showNeteaseLogin(NavigatorState navigator, Session session) async {
  if (_presenting) return;
  _presenting = true;
  try {
    if (DymuseTokens.mobile) {
      sheetCovering.value = true;
      try {
        await navigator.push<void>(
          DymuseSheetRoute<void>(
            builder: (context) => _LoginSheet(session: session),
          ),
        );
      } finally {
        sheetCovering.value = false;
      }
    } else {
      await navigator.push<void>(
        RawDialogRoute<void>(
          barrierDismissible: true,
          barrierLabel: '关闭',
          barrierColor: const Color(0x73000000),
          transitionDuration: const Duration(milliseconds: 220),
          pageBuilder: (context, _, _) => _LoginDialog(session: session),
          transitionBuilder: (context, animation, _, child) => FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: ScaleTransition(
              scale: Tween<double>(begin: .96, end: 1).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
              child: child,
            ),
          ),
        ),
      );
    }
  } finally {
    _presenting = false;
  }
}

class _LoginDialog extends StatelessWidget {
  const _LoginDialog({required this.session});
  final Session session;
  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.of(context).pop(),
    },
    child: Focus(
      autofocus: true,
      child: DefaultTextStyle(
        style: CupertinoTheme.of(context).textTheme.textStyle,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: DymuseTokens.background(context),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: DymuseTokens.line(context)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 40,
                        offset: Offset(0, 16),
                      ),
                    ],
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 10, 24, 28),
                    child: NeteaseLoginView(
                      session: session,
                      onBack: () => Navigator.of(context).pop(),
                      onDone: () => Navigator.of(context).pop(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _LoginSheet extends StatelessWidget {
  const _LoginSheet({required this.session});
  final Session session;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: DymuseTokens.background(context),
    child: DefaultTextStyle(
      style: CupertinoTheme.of(context).textTheme.textStyle,
      child: SafeArea(
        child: Padding(
          // 外壳不随键盘缩小：垫上键盘高度，输入框才不会被挡住。
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 6, 24, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: NeteaseLoginView(
                  session: session,
                  onBack: () => Navigator.of(context).pop(),
                  onDone: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
