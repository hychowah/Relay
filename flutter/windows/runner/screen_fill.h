#ifndef RUNNER_SCREEN_FILL_H_
#define RUNNER_SCREEN_FILL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Desktop only (Windows). Answers `fillScreen` on the `app.relay/browser`
// channel, as the Mac window does: for a Browser tab's fullscreen page the
// window drops its frame and covers its whole monitor, taskbar included, then
// gets its frame, place and size back.
class ScreenFill {
 public:
  ScreenFill(flutter::BinaryMessenger* messenger, HWND window);

 private:
  void Fill(bool on);

  HWND window_;
  bool filled_ = false;
  bool maximized_ = false;
  LONG style_ = 0;
  LONG ex_style_ = 0;
  RECT frame_{};
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_SCREEN_FILL_H_
