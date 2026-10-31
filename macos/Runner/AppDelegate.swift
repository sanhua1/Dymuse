import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 与“音乐”一致：关闭最后一个窗口不退出，音乐继续播放。
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  /// 点按程序坞图标时重新显示已关闭的主窗口。
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { mainFlutterWindow?.makeKeyAndOrderFront(nil) }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// 退出前请 Flutter 保存播放进度与收听记录；最多等待 3 秒，不阻止退出。
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let window = mainFlutterWindow as? MainFlutterWindow, let channel = window.windowChannel else {
      return .terminateNow
    }
    var replied = false
    let reply = {
      if replied { return }
      replied = true
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    channel.invokeMethod("willTerminate", arguments: nil) { _ in reply() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: reply)
    return .terminateLater
  }
}
