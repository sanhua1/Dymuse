import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../core/api_client.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';

/// 设置页里的 B 站账号：扫码登录（网页端二维码），登录凭证只存本机安全存储。
/// 登录后可看到登录态下的收藏夹与更高音质；播放和订阅不登录也能用。
class BilibiliAccountPanel extends StatefulWidget {
  const BilibiliAccountPanel({super.key, required this.api, this.session});
  final ApiClient api;

  /// 同步（WebDAV）从其他设备带来登录时，会通知它刷新显示。
  final Listenable? session;
  @override
  State<BilibiliAccountPanel> createState() => _BilibiliAccountPanelState();
}

class _BilibiliAccountPanelState extends State<BilibiliAccountPanel> {
  Json? account;
  bool loading = true, busy = false;
  String? error, qrUrl, qrKey;
  int status = 86101;
  Timer? _timer;
  DateTime? _expires;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    widget.session?.addListener(_external);
    unawaited(_load());
  }

  void _external() {
    if (!mounted || busy) return;
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.session?.removeListener(_external);
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await widget.api.get('/bilibili/account') as Json;
      if (mounted) {
        setState(() {
          account = data;
          loading = false;
          error = null;
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          loading = false;
          error = readableError(failure);
        });
      }
    }
  }

  Future<void> _startQr() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await widget.api.post('/bilibili/auth/qr', {}) as Json;
      if (!mounted) return;
      setState(() {
        qrUrl = '${data['url']}';
        qrKey = '${data['key']}';
        status = 86101;
        _expires = DateTime.now().add(
          Duration(seconds: (data['expiresIn'] as num?)?.toInt() ?? 180),
        );
      });
      _timer?.cancel();
      _timer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_poll()),
      );
    } catch (failure) {
      if (mounted) setState(() => error = readableError(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _poll() async {
    final key = qrKey;
    if (key == null || _checking) return;
    if (_expires != null && DateTime.now().isAfter(_expires!)) {
      _timer?.cancel();
      setState(() => status = 86038);
      return;
    }
    _checking = true;
    try {
      final data =
          await widget.api.post('/bilibili/auth/qr/check', {'key': key})
              as Json;
      if (!mounted || qrKey != key) return;
      final code = (data['code'] as num?)?.toInt() ?? 86101;
      if (code == 0) {
        _timer?.cancel();
        setState(() {
          account = data['account'] as Json?;
          qrUrl = qrKey = null;
        });
        return;
      }
      if (code == 86038) _timer?.cancel();
      setState(() => status = code);
    } catch (failure) {
      if (mounted) setState(() => error = readableError(failure));
    } finally {
      _checking = false;
    }
  }

  Future<void> _logout() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.api.post('/bilibili/auth/logout', {});
      if (mounted) setState(() => account = {'loggedIn': false});
    } catch (failure) {
      if (mounted) setState(() => error = readableError(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String get _status => switch (status) {
    86090 => '已扫码，请在手机上确认登录',
    86038 => '二维码已过期，请重新获取',
    _ => '用哔哩哔哩 App 扫一扫登录',
  };

  @override
  Widget build(BuildContext context) {
    final secondary = DymuseTokens.secondary(context);
    final caption = DymuseTokens.caption.copyWith(
      color: secondary,
      height: 1.6,
    );
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: CupertinoActivityIndicator(),
      );
    }
    final signedIn = account?['loggedIn'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (signedIn)
          Row(
            children: [
              Artwork(
                url: '${account!['avatar'] ?? ''}'.isEmpty
                    ? null
                    : '${account!['avatar']}',
                size: 50,
                seed: '${account!['name']}',
                radius: 25,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${account!['name']}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      account!['offline'] == true
                          ? '暂时无法连接 B 站，显示的是上次的资料'
                          : '${account!['vip'] == true ? '大会员' : '普通用户'} · 登录只保存在这台设备',
                      style: caption,
                    ),
                  ],
                ),
              ),
              PanelButton(label: '退出登录', onPressed: busy ? null : _logout),
            ],
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  account?['expired'] == true ? 'B 站登录已失效，请重新扫码登录。' : '未登录',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (qrUrl == null || status == 86038)
                PanelButton(label: '扫码登录', onPressed: busy ? null : _startQr),
            ],
          ),
          if (qrUrl != null) ...[
            const SizedBox(height: 16),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: CupertinoColors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Opacity(
                  opacity: status == 86038 ? .18 : 1,
                  child: QrImageView(
                    data: qrUrl!,
                    size: 168,
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
            const SizedBox(height: 10),
            Center(child: Text(_status, style: caption)),
          ],
        ],
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(
            error!,
            style: const TextStyle(
              fontSize: 12,
              color: CupertinoColors.systemRed,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text('登录后可使用你账号里的收藏夹，并可能取得更高音质的音频。不登录也能搜索、订阅与播放。', style: caption),
      ],
    );
  }
}
