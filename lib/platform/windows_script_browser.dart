import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:webview_windows/webview_windows.dart';

/// Windows 上按需运行官方网页脚本，不接触播放器或个人登录凭证。
class WindowsScriptBrowser {
  WindowsScriptBrowser({required this.onMessage});
  final void Function(String message) onMessage;
  static Future<void>? _environment;
  WebviewController? _controller;
  StreamSubscription<dynamic>? _messages;
  bool _disposed = false;

  /// WebView2 数据留在应用缓存目录，不向安装目录或源码写入状态。
  static Future<void> _prepare() => _environment ??=
      (() async {
        if (await WebviewController.getWebViewVersion() == null) {
          throw StateError('需要 Microsoft Edge WebView2 Runtime。');
        }
        final cache = await getApplicationCacheDirectory();
        final profile = Directory.fromUri(cache.uri.resolve('webview2/'));
        await profile.create(recursive: true);
        await WebviewController.initializeEnvironment(
          userDataPath: profile.path,
        );
      })().catchError((Object error) {
        _environment = null;
        throw error;
      });

  /// 与 Apple 网页通道共用 Dymuse.postMessage 协议。
  Future<void> loadHtml(String html) async {
    await _prepare();
    if (_disposed) return;
    final controller = _controller = WebviewController();
    await controller.initialize();
    if (_disposed) {
      await controller.dispose();
      return;
    }
    await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
    _messages = controller.webMessage.listen((value) {
      if (!_disposed && value is String && value.length <= 16384) {
        onMessage(value);
      }
    }, onError: (_) {});
    final loaded = controller.loadingState
        .timeout(const Duration(seconds: 20))
        .firstWhere((state) => state == LoadingState.navigationCompleted)
        .then((_) {});
    const bridge =
        '<script>window.Dymuse={postMessage:function(value){'
        'window.chrome.webview.postMessage(value);}};</script>';
    await Future.wait<void>([
      loaded,
      controller.loadStringContent(
        html.replaceFirst('<head>', '<head>$bridge'),
      ),
    ], eagerError: true);
  }

  Future<void> runJavaScript(String script) async {
    if (!_disposed) await _controller?.executeScript(script);
  }

  /// 释放浏览器及消息订阅，保留缓存文件供后续排查。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _messages?.cancel();
    final controller = _controller;
    _controller = null;
    if (controller?.value.isInitialized == true) await controller!.dispose();
  }
}
