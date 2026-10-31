import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 与“音乐”一致：关闭最后一个窗口不退出，音乐继续播放。
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  /// 点按程序坞图标（或再次启动应用）时重新显示已关闭的主窗口。
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { showMainWindow() }
    return true
  }

  private var statusItem: NSStatusItem?

  /// 设置里开启“关闭窗口后只留在菜单栏”时，窗口关闭后隐藏程序坞图标并放入菜单栏图标。
  func enterMenuBar() {
    guard statusItem == nil else { return }
    NSApp.setActivationPolicy(.accessory)
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      // 用应用 Logo 的单色轮廓做模板图像，由系统按菜单栏明暗自动着色。
      let image = NSImage(named: "MenuBarIcon")
      image?.size = NSSize(width: 18, height: 18)
      image?.isTemplate = true
      button.image = image
      button.setAccessibilityLabel("Dymuse")
      button.target = self
      button.action = #selector(statusItemClicked)
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    statusItem = item
  }

  /// 恢复程序坞图标并显示主窗口，菜单栏图标随之移除。
  func showMainWindow() {
    if let item = statusItem {
      NSStatusBar.system.removeStatusItem(item)
      statusItem = nil
    }
    NSApp.setActivationPolicy(.regular)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// 左键直接打开窗口；右键（或按住 Control 点按）弹出“打开 / 退出”。
  @objc private func statusItemClicked() {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      let menu = NSMenu()
      menu.addItem(withTitle: "打开 Dymuse", action: #selector(openFromMenu), keyEquivalent: "").target = self
      menu.addItem(.separator())
      menu.addItem(withTitle: "退出 Dymuse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
      statusItem?.menu = menu
      statusItem?.button?.performClick(nil)
      statusItem?.menu = nil
    } else {
      showMainWindow()
    }
  }

  @objc private func openFromMenu() { showMainWindow() }

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
