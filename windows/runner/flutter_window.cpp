#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {

const flutter::EncodableValue* Field(const flutter::EncodableMap& map,
                                     const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

std::string StringField(const flutter::EncodableMap& map, const char* key) {
  const auto* value = Field(map, key);
  if (value == nullptr) return {};
  const auto* text = std::get_if<std::string>(value);
  return text == nullptr ? std::string() : *text;
}

int64_t IntField(const flutter::EncodableMap& map, const char* key) {
  const auto* value = Field(map, key);
  if (value == nullptr) return 0;
  if (const auto* v = std::get_if<int32_t>(value)) return *v;
  if (const auto* v = std::get_if<int64_t>(value)) return *v;
  return 0;
}

bool BoolField(const flutter::EncodableMap& map, const char* key) {
  const auto* value = Field(map, key);
  if (value == nullptr) return false;
  const auto* flag = std::get_if<bool>(value);
  return flag != nullptr && *flag;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetUpNowPlaying();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::SetUpNowPlaying() {
  system_media_ = SystemMedia::Create(GetHandle());
  now_playing_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "dymuse/now_playing",
          &flutter::StandardMethodCodec::GetInstance());
  now_playing_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "update") {
          result->NotImplemented();
          return;
        }
        if (system_media_) {
          const auto* map =
              call.arguments() == nullptr
                  ? nullptr
                  : std::get_if<flutter::EncodableMap>(call.arguments());
          if (map == nullptr) {
            system_media_->Update(nullptr);
          } else {
            SystemMediaInfo info;
            info.title = StringField(*map, "title");
            info.artist = StringField(*map, "artist");
            info.album = StringField(*map, "album");
            info.artwork = StringField(*map, "artwork");
            info.duration_ms = IntField(*map, "durationMs");
            info.position_ms = IntField(*map, "positionMs");
            info.playing = BoolField(*map, "playing");
            info.loading = BoolField(*map, "loading");
            system_media_->Update(&info);
          }
        }
        result->Success();
      });
  if (system_media_) {
    ::SetTimer(GetHandle(), SystemMedia::kTimer, SystemMedia::kTimerMs,
               nullptr);
  }
}

void FlutterWindow::SendMediaCommand(SystemMediaCommand command,
                                     int64_t value) {
  if (!now_playing_channel_) return;
  switch (command) {
    case SystemMediaCommand::kPlay:
      now_playing_channel_->InvokeMethod("play", nullptr);
      break;
    case SystemMediaCommand::kPause:
      now_playing_channel_->InvokeMethod("pause", nullptr);
      break;
    case SystemMediaCommand::kToggle:
      now_playing_channel_->InvokeMethod("toggle", nullptr);
      break;
    case SystemMediaCommand::kNext:
      now_playing_channel_->InvokeMethod("next", nullptr);
      break;
    case SystemMediaCommand::kPrevious:
      now_playing_channel_->InvokeMethod("previous", nullptr);
      break;
    case SystemMediaCommand::kSeek:
      now_playing_channel_->InvokeMethod(
          "seek", std::make_unique<flutter::EncodableValue>(value));
      break;
  }
}

void FlutterWindow::OnDestroy() {
  ::KillTimer(GetHandle(), SystemMedia::kTimer);
  system_media_ = nullptr;
  now_playing_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // System media buttons, posted from a WinRT worker thread.
  if (message == SystemMedia::kMessage) {
    SendMediaCommand(static_cast<SystemMediaCommand>(wparam),
                     static_cast<int64_t>(lparam));
    return 0;
  }
  if (message == WM_TIMER && wparam == SystemMedia::kTimer) {
    if (system_media_) system_media_->Tick();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
