#ifndef RUNNER_SYSTEM_MEDIA_H_
#define RUNNER_SYSTEM_MEDIA_H_

#include <windows.h>

#include <cstdint>
#include <memory>
#include <string>

// Windows System Media Transport Controls (media flyout, media keys, lock
// screen). Implemented with C++/WinRT in system_media.cpp, which is built as a
// separate target; this header stays free of WinRT types.

// What is playing now; strings are UTF-8.
struct SystemMediaInfo {
  std::string title;
  std::string artist;
  std::string album;
  std::string artwork;
  int64_t duration_ms = 0;
  int64_t position_ms = 0;
  bool playing = false;
  // Between tracks: silent, but about to play (shown as "changing").
  bool loading = false;
};

// Commands posted back to the window; names match lib/platform/now_playing.dart.
enum class SystemMediaCommand : int { kPlay, kPause, kToggle, kNext, kPrevious, kSeek };

class SystemMedia {
 public:
  // Posted to the window when a system button is pressed (from a WinRT worker
  // thread). WPARAM is a SystemMediaCommand, LPARAM the seek target in ms.
  static constexpr UINT kMessage = WM_APP + 0x51;
  // Window timer that refreshes the timeline while playing.
  static constexpr UINT_PTR kTimer = 0x5149;
  static constexpr UINT kTimerMs = 5000;

  // Returns nullptr when the system controls are unavailable.
  static std::unique_ptr<SystemMedia> Create(HWND window);

  virtual ~SystemMedia() = default;

  // nullptr clears the controls (nothing is playing).
  virtual void Update(const SystemMediaInfo* info) = 0;

  // Called by kTimer.
  virtual void Tick() = 0;
};

#endif  // RUNNER_SYSTEM_MEDIA_H_
