import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../core/session.dart';
import '../design_system/tokens.dart';
import '../features/sync_settings.dart';
import 'netease_login.dart';

/// 第一次打开（或登录结束后）的欢迎页：选一种方式开始使用。
class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key, required this.session});
  final Session session;
  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  bool _login = false;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 30),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: AnimatedSwitcher(
          duration: DymuseTokens.motion,
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, .02),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: _login
              ? NeteaseLoginView(
                  key: const ValueKey('login'),
                  session: widget.session,
                  onBack: () => setState(() => _login = false),
                )
              : _Choices(
                  key: const ValueKey('choices'),
                  session: widget.session,
                  onLogin: () => setState(() => _login = true),
                ),
        ),
      ),
    ),
  );
}

class _Choices extends StatelessWidget {
  const _Choices({super.key, required this.session, required this.onLogin});
  final Session session;
  final VoidCallback onLogin;

  static void _explain(BuildContext context, String title, String text) =>
      showCupertinoDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialog) => CupertinoAlertDialog(
          title: Text(title),
          content: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(text, textAlign: TextAlign.start),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('好'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final sync = session.sync;
    final notice = session.notice;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(19),
            child: Image.asset(
              'assets/brand/app_icon.png',
              width: 76,
              height: 76,
              semanticLabel: 'Dymuse',
            ),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          '开始使用 Dymuse',
          textAlign: TextAlign.center,
          style: DymuseTokens.heading,
        ),
        if (notice != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                notice,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: DymuseTokens.secondary(context),
                ),
              ),
            ),
          ),
        const SizedBox(height: 32),
        DecoratedBox(
          decoration: BoxDecoration(
            color: DymuseTokens.surface(context),
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Column(
              children: [
                _OptionRow(
                  icon: CupertinoIcons.person_fill,
                  color: const Color(0xFFE5484D),
                  title: '登录网易云账号',
                  onTap: onLogin,
                  info: () => _explain(
                    context,
                    '登录网易云账号',
                    '可以扫码、用密码或短信验证码登录。登录信息只保存在这台设备上，'
                        '歌曲、歌单和播放请求都由这台设备直接连接网易云。',
                  ),
                ),
                _OptionRow(
                  icon: CupertinoIcons.music_note_2,
                  color: const Color(0xFF3E82F7),
                  title: '不登录，直接使用',
                  divider: true,
                  onTap: () => unawaited(session.enterGuest()),
                  info: () => _explain(
                    context,
                    '不登录，直接使用',
                    '不登录也能搜索、浏览和播放；红心、我的歌单、推荐等功能需要登录。'
                        '之后随时可以在设置里登录。',
                  ),
                ),
                if (sync != null)
                  _OptionRow(
                    icon: CupertinoIcons.cloud_fill,
                    color: const Color(0xFF2FA9A1),
                    title: '从 WebDAV 同步数据',
                    divider: true,
                    onTap: () => showSyncForm(context, sync),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 一行选项：彩色图标 + 标题，右侧可选的说明按钮与箭头；悬停、按下和键盘焦点都有反馈。
class _OptionRow extends StatefulWidget {
  const _OptionRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.onTap,
    this.info,
    this.divider = false,
  });
  final IconData icon;
  final Color color;
  final String title;
  final VoidCallback onTap;
  final VoidCallback? info;
  final bool divider;
  @override
  State<_OptionRow> createState() => _OptionRowState();
}

class _OptionRowState extends State<_OptionRow> {
  bool _hover = false, _pressed = false, _focus = false;

  @override
  Widget build(BuildContext context) {
    final ink = DymuseTokens.ink(context);
    final secondary = DymuseTokens.secondary(context);
    return Semantics(
      button: true,
      label: widget.title,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: FocusableActionDetector(
          onShowFocusHighlight: (value) => setState(() => _focus = value),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onTap();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                color: ink.withValues(
                  alpha: _pressed
                      ? .12
                      : _hover || _focus
                      ? .06
                      : 0,
                ),
                border: widget.divider
                    ? Border(top: BorderSide(color: DymuseTokens.line(context)))
                    : null,
              ),
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
              child: Row(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: widget.color,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: SizedBox(
                      width: 34,
                      height: 34,
                      child: Icon(
                        widget.icon,
                        size: 19,
                        color: CupertinoColors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (widget.info != null)
                    Semantics(
                      button: true,
                      label: '${widget.title} 说明',
                      excludeSemantics: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.info,
                        child: SizedBox(
                          width: 36,
                          height: 36,
                          child: Center(
                            child: Icon(
                              CupertinoIcons.info_circle,
                              size: 17,
                              color: secondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  Icon(
                    CupertinoIcons.chevron_forward,
                    size: 15,
                    color: secondary,
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
