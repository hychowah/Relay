#ifndef RUNNER_SCREEN_FILL_H_
#define RUNNER_SCREEN_FILL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Desktop only (Windows). The window drops its frame and covers its whole
// monitor, taskbar included, then gets its frame, place and size back. It
// does so for a Browser tab's fullscreen page, through `fillScreen` on the
// `app.relay/browser` channel as on the Mac, and for the whole app while the
// user has turned it on with F11, as the Mac's own full screen does.
class ScreenFill {
 public:
  ScreenFill(flutter::BinaryMessenger* messenger, HWND window);
  ~ScreenFill();

  // Handles the window message the F11 key posts, and watches the keyboard
  // while Relay is the active app; true if the message needs nothing more.
  bool Handle(UINT message, WPARAM wparam);

 private:
  static LRESULT CALLBACK KeyHook(int code, WPARAM wparam, LPARAM lparam);
  void Watch(bool on);
  void Update();

  HWND window_;
  HHOOK hook_ = nullptr;
  bool f11_down_ = false;
  bool page_ = false;
  bool app_ = false;
  bool filled_ = false;
  bool maximized_ = false;
  LONG style_ = 0;
  LONG ex_style_ = 0;
  RECT frame_{};
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_SCREEN_FILL_H_
