import AVFoundation
import Flutter
import MediaPlayer
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 后台与锁屏播放需要 playback 类别；打断（来电、其他音频）由 just_audio 处理。
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    NowPlayingBridge.shared.attach(
      FlutterMethodChannel(
        name: "dymuse/now_playing",
        binaryMessenger: engineBridge.applicationRegistrar.messenger()
      )
    )
  }
}

/// 锁屏、控制中心与耳机按键：MPNowPlayingInfoCenter + MPRemoteCommandCenter。
/// 所有系统命令回传 Flutter，由同一个 PlaybackController 执行。
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
      let image = UIImage(data: bytes)
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
      guard let body, let image = UIImage(data: body) else { return }
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
