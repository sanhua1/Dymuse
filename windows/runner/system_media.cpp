// 系统媒体传输控件（SMTC）：Windows 的媒体浮窗、键盘媒体键与锁屏显示。
// 按钮事件来自 WinRT 工作线程，这里只 PostMessage 回窗口，由界面线程转给 Dart。
#include "system_media.h"

#include <unknwn.h>  // 须在 winrt 头文件之前，启用经典 COM 接口支持
#include <SystemMediaTransportControlsInterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>

#include <chrono>

namespace {

using winrt::Windows::Foundation::TimeSpan;
using winrt::Windows::Foundation::Uri;
using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::PlaybackPositionChangeRequestedEventArgs;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;
using winrt::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs;
using winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties;
using winrt::Windows::Storage::Streams::RandomAccessStreamReference;

TimeSpan Ms(int64_t ms) {
  return std::chrono::duration_cast<TimeSpan>(std::chrono::milliseconds(ms));
}

void Post(HWND window, SystemMediaCommand command, int64_t value = 0) {
  ::PostMessage(window, SystemMedia::kMessage, static_cast<WPARAM>(command),
                static_cast<LPARAM>(value));
}

class SystemMediaImpl : public SystemMedia {
 public:
  SystemMediaImpl(HWND window, SystemMediaTransportControls controls)
      : controls_(controls) {
    controls_.IsPlayEnabled(true);
    controls_.IsPauseEnabled(true);
    controls_.IsNextEnabled(true);
    controls_.IsPreviousEnabled(true);
    controls_.IsEnabled(false);  // 有歌曲时才出现在媒体浮窗里
    button_ = controls_.ButtonPressed(
        winrt::auto_revoke,
        [window](auto&&,
                 SystemMediaTransportControlsButtonPressedEventArgs const& args) {
          switch (args.Button()) {
            case SystemMediaTransportControlsButton::Play:
              Post(window, SystemMediaCommand::kPlay);
              break;
            case SystemMediaTransportControlsButton::Pause:
              Post(window, SystemMediaCommand::kPause);
              break;
            case SystemMediaTransportControlsButton::Next:
              Post(window, SystemMediaCommand::kNext);
              break;
            case SystemMediaTransportControlsButton::Previous:
              Post(window, SystemMediaCommand::kPrevious);
              break;
            default:
              break;
          }
        });
    seek_ = controls_.PlaybackPositionChangeRequested(
        winrt::auto_revoke,
        [window](auto&&, PlaybackPositionChangeRequestedEventArgs const& args) {
          const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                              args.RequestedPlaybackPosition())
                              .count();
          Post(window, SystemMediaCommand::kSeek, ms);
        });
  }

  ~SystemMediaImpl() override {
    button_.revoke();
    seek_.revoke();
    try {
      controls_.IsEnabled(false);
    } catch (...) {
    }
  }

  void Update(const SystemMediaInfo* info) override {
    try {
      auto updater = controls_.DisplayUpdater();
      if (info == nullptr) {
        active_ = false;
        artwork_.clear();
        updater.ClearAll();
        updater.Update();
        controls_.PlaybackStatus(MediaPlaybackStatus::Closed);
        controls_.IsEnabled(false);
        return;
      }
      if (!controls_.IsEnabled()) controls_.IsEnabled(true);
      updater.Type(MediaPlaybackType::Music);
      auto music = updater.MusicProperties();
      music.Title(winrt::to_hstring(info->title));
      music.Artist(winrt::to_hstring(info->artist));
      music.AlbumTitle(winrt::to_hstring(info->album));
      if (info->artwork != artwork_) {
        artwork_ = info->artwork;
        // 封面是公开的 https 图片，由系统自行下载。
        updater.Thumbnail(artwork_.empty()
                              ? nullptr
                              : RandomAccessStreamReference::CreateFromUri(
                                    Uri(winrt::to_hstring(artwork_))));
      }
      updater.Update();
      controls_.PlaybackStatus(info->playing   ? MediaPlaybackStatus::Playing
                               : info->loading ? MediaPlaybackStatus::Changing
                                               : MediaPlaybackStatus::Paused);
      active_ = true;
      playing_ = info->playing;
      duration_ms_ = info->duration_ms;
      position_ms_ = info->position_ms;
      since_ = std::chrono::steady_clock::now();
      Timeline();
    } catch (...) {
      // 系统控件异常不影响播放。
    }
  }

  void Tick() override {
    if (!active_ || !playing_) return;
    try {
      Timeline();
    } catch (...) {
    }
  }

 private:
  // Dart 只在跳转、暂停等不连续变化时上报位置；播放中按经过的时间推算。
  void Timeline() {
    int64_t position = position_ms_;
    if (playing_) {
      position += std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now() - since_)
                      .count();
    }
    if (duration_ms_ > 0 && position > duration_ms_) position = duration_ms_;
    SystemMediaTransportControlsTimelineProperties timeline;
    timeline.StartTime(Ms(0));
    timeline.MinSeekTime(Ms(0));
    timeline.EndTime(Ms(duration_ms_));
    timeline.MaxSeekTime(Ms(duration_ms_));
    timeline.Position(Ms(position));
    controls_.UpdateTimelineProperties(timeline);
  }

  SystemMediaTransportControls controls_;
  SystemMediaTransportControls::ButtonPressed_revoker button_;
  SystemMediaTransportControls::PlaybackPositionChangeRequested_revoker seek_;
  std::string artwork_;
  bool active_ = false;
  bool playing_ = false;
  int64_t duration_ms_ = 0;
  int64_t position_ms_ = 0;
  std::chrono::steady_clock::time_point since_;
};

}  // namespace

std::unique_ptr<SystemMedia> SystemMedia::Create(HWND window) {
  try {
    auto interop = winrt::get_activation_factory<
        SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    SystemMediaTransportControls controls{nullptr};
    winrt::check_hresult(interop->GetForWindow(
        window, winrt::guid_of<SystemMediaTransportControls>(),
        winrt::put_abi(controls)));
    return std::make_unique<SystemMediaImpl>(window, controls);
  } catch (...) {
    return nullptr;
  }
}
