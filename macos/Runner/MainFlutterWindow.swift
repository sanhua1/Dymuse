import Cocoa
import FlutterMacOS
import MediaPlayer
import window_manager

/// Flutter 内容透明绘制在系统侧栏材质之上；侧栏区域露出原生 NSVisualEffectView，
/// 内容区由 Flutter 绘制不透明背景。降低透明度等系统设置由材质自身处理。
class MainFlutterWindow: NSWindow {
  private(set) var windowChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    flutterViewController.backgroundColor = .clear
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    let material = NSVisualEffectView(frame: flutterViewController.view.bounds)
    material.material = .sidebar
    material.blendingMode = .behindWindow
    material.state = .followsWindowActiveState
    material.autoresizingMask = [.width, .height]
    flutterViewController.view.addSubview(material, positioned: .below, relativeTo: nil)
    isOpaque = false
    backgroundColor = .clear

    // 应用内强制浅色/深色时，原生材质与窗口按钮使用同一外观；退出前保存也经此通道。
    let channel = FlutterMethodChannel(
      name: "dymuse/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setAppearance":
        switch call.arguments as? String {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        self?.layoutWindowButtons()
        result(nil)
      case "enterMenuBar":
        (NSApp.delegate as? AppDelegate)?.enterMenuBar()
        result(nil)
      case "leaveMenuBar":
        (NSApp.delegate as? AppDelegate)?.showMainWindow()
        result(nil)
      case "layoutWindowButtons":
        self?.layoutWindowButtons()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    windowChannel = channel

    // 系统在缩放、切换全屏和激活时会重排标题栏，每次重排后恢复按钮位置。
    for name in [
      NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
      NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
    ] {
      NotificationCenter.default.addObserver(
        forName: name, object: self, queue: .main
      ) { [weak self] _ in self?.layoutWindowButtons() }
    }

    NowPlayingBridge.shared.attach(
      FlutterMethodChannel(
        name: "dymuse/now_playing",
        binaryMessenger: flutterViewController.engine.binaryMessenger
      )
    )

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  // window_manager：首帧就绪前保持隐藏，避免启动闪烁。
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
    layoutWindowButtons()
  }

  /// 红黄绿按钮放进内嵌侧栏的左上角（与“音乐”一致：首个按钮中心距窗口左上 25pt），
  /// 按钮间距沿用系统值。全屏时按钮由系统放在菜单栏区域，不调整。
  private static let buttonCenter = NSPoint(x: 25, y: 25)
  private var buttonSpacing: CGFloat?

  func layoutWindowButtons() {
    guard !styleMask.contains(.fullScreen),
      let close = standardWindowButton(.closeButton),
      let mini = standardWindowButton(.miniaturizeButton),
      let zoom = standardWindowButton(.zoomButton),
      let titlebar = close.superview,
      let container = titlebar.superview
    else { return }
    let spacing = buttonSpacing ?? (mini.frame.minX - close.frame.minX)
    buttonSpacing = spacing
    let size = close.frame.size
    let center = Self.buttonCenter
    // 标题栏容器只加高到容纳按钮，避免挡住下方 Flutter 控件的点击。
    let height = (center.y + size.height / 2 + 4).rounded(.up)
    var frame = container.frame
    if abs(frame.height - height) > 0.5 || abs(frame.maxY - self.frame.height) > 0.5 {
      frame.size.height = height
      frame.origin.y = self.frame.height - height
      container.frame = frame
      titlebar.frame = container.bounds
    }
    for (offset, button) in [close, mini, zoom].enumerated() {
      button.setFrameOrigin(
        NSPoint(
          x: center.x - size.width / 2 + CGFloat(offset) * spacing,
          y: height - center.y - size.height / 2
        ))
    }
  }
}

/// 控制中心“正在播放”、键盘媒体键与耳机按键；命令交回 Flutter 的同一播放控制器。
final class NowPlayingBridge {
  static let shared = NowPlayingBridge()
  private var channel: FlutterMethodChannel?
  private var artworkURL: String?
  private var artwork: MPMediaItemArtwork?

  func attach(_ channel: FlutterMethodChannel) {
    self.channel = channel
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.addTarget { [weak self] _ in self?.send("play"); return .success }
    center.pauseCommand.addTarget { [weak self] _ in self?.send("pause"); return .success }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.send("toggle"); return .success }
    center.nextTrackCommand.addTarget { [weak self] _ in self?.send("next"); return .success }
    center.previousTrackCommand.addTarget { [weak self] _ in self?.send("previous"); return .success }
    center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      self?.send("seek", event.positionTime * 1000)
      return .success
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "update" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.update(call.arguments as? [String: Any])
      result(nil)
    }
  }

  private func send(_ method: String, _ arguments: Any? = nil) {
    DispatchQueue.main.async { self.channel?.invokeMethod(method, arguments: arguments) }
  }

  private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

  private func update(_ info: [String: Any]?) {
    let center = MPNowPlayingInfoCenter.default()
    guard let info, let title = info["title"] as? String else {
      center.nowPlayingInfo = nil
      center.playbackState = .stopped
      return
    }
    let playing = info["playing"] as? Bool ?? false
    var data: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: info["artist"] as? String ?? "",
      MPMediaItemPropertyAlbumTitle: info["album"] as? String ?? "",
      MPMediaItemPropertyPlaybackDuration: number(info["durationMs"]) / 1000,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: number(info["positionMs"]) / 1000,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
    ]
    let url = info["artwork"] as? String
    let changed = url != artworkURL
    if changed {
      artworkURL = url
      artwork = nil
    }
    // 私人曲库封面需要会话鉴权，由应用下载后直接传图片数据，系统不再自己请求。
    if artwork == nil, let bytes = (info["artworkData"] as? FlutterStandardTypedData)?.data,
      let image = NSImage(data: bytes)
    {
      artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
    if let artwork { data[MPMediaItemPropertyArtwork] = artwork }
    center.nowPlayingInfo = data
    center.playbackState = playing ? .playing : .paused
    guard changed, artwork == nil, let url, url.hasPrefix("http"),
      let link = URL(string: url)
    else { return }
    URLSession.shared.dataTask(with: link) { [weak self] body, _, _ in
      guard let body, let image = NSImage(data: body) else { return }
      DispatchQueue.main.async {
        guard let self, self.artworkURL == url else { return }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        self.artwork = artwork
        var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        current[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = current
      }
    }.resume()
  }
}
