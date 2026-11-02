// 易盾反作弊令牌：在一个看不见的 WebView 里运行易盾官方 SDK（与 api-enhanced 用 jsdom 的做法等价）。
// 只在需要令牌的操作（收藏歌单）时才创建，用完一段时间后销毁，平时不占资源。
import 'dart:async';
import 'dart:io';

import 'package:webview_flutter/webview_flutter.dart';
import '../platform/windows_script_browser.dart';

class AntiCheat {
  static const _product = 'YD00000558929251';
  static const _business = 'bd5d2f973ef74cd2a61325a412ae54d9';
  static const _toolJs = 'https://acstatic-dun.126.net/tool.min.js';
  static const _idle = Duration(minutes: 1);

  WebViewController? _web;
  WindowsScriptBrowser? _windows;
  Future<void>? _loading;
  Completer<String>? _waiting;
  Timer? _closer;

  /// 取一个新令牌；失败返回空串（请求仍会发出，由网易云决定是否放行）。
  Future<String> token() async {
    _closer?.cancel();
    try {
      await _ready();
      final waiting = _waiting = Completer<String>();
      if (Platform.isWindows) {
        await _windows!.runJavaScript('window.dymuseToken();');
      } else {
        await _web!.runJavaScript('window.dymuseToken();');
      }
      return await waiting.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => '',
      );
    } catch (_) {
      _drop();
      return '';
    } finally {
      _closer = Timer(_idle, _drop);
    }
  }

  Future<void> _ready() async {
    if (Platform.isWindows) {
      if (_windows == null) {
        final browser = _windows = WindowsScriptBrowser(onMessage: _receive);
        _loading = browser.loadHtml(_page);
      }
      await _loading;
      return;
    }
    final existing = _web;
    if (existing != null) {
      await _loading;
      return;
    }
    final web = _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'Dymuse',
        onMessageReceived: (message) {
          _receive(message.message);
        },
      );
    final loaded = Completer<void>();
    await web.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (_) {
          if (!loaded.isCompleted) loaded.complete();
        },
      ),
    );
    _loading = loaded.future.timeout(const Duration(seconds: 20));
    await web.loadHtmlString(_page, baseUrl: 'https://music.163.com/');
    await _loading;
  }

  void _receive(String message) {
    final waiting = _waiting;
    if (waiting != null && !waiting.isCompleted) waiting.complete(message);
  }

  void _drop() {
    _closer?.cancel();
    final browser = _windows;
    _windows = null;
    if (browser != null) unawaited(browser.dispose().catchError((_) {}));
    _web = null;
    _loading = null;
    _waiting = null;
  }

  static const _page =
      '''
<!doctype html><html><head><meta charset="UTF-8"></head><body>
<script src="$_toolJs"></script>
<script>
var wm = null, pending = false;
function ensure(cb) {
  if (wm) return cb();
  initWatchman({
    auto: true,
    productNumber: '$_product',
    onload: function (instance) { wm = instance; cb(); },
    onerror: function () { Dymuse.postMessage(''); }
  });
}
window.dymuseToken = function () {
  ensure(function () {
    var once = false;
    function go() {
      if (once) return;
      once = true;
      wm.getToken('$_business', function (tk) {
        Dymuse.postMessage(typeof tk === 'string' ? tk : '');
      });
    }
    try { wm.getInstance().I(go); } catch (e) { go(); }
    setTimeout(go, 8000);
  });
};
</script></body></html>''';
}
