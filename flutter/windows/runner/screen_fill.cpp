#include "screen_fill.h"

#include <flutter/standard_method_codec.h>

namespace {

constexpr int kF11 = 1;

}  // namespace

ScreenFill::ScreenFill(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "app.relay/browser",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "fillScreen") {
      result->NotImplemented();
      return;
    }
    bool on = false;
    if (const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments())) {
      const auto found = args->find(flutter::EncodableValue("on"));
      if (found != args->end()) {
        if (const auto* value = std::get_if<bool>(&found->second)) on = *value;
      }
    }
    page_ = on;
    Update();
    result->Success();
  });
}

ScreenFill::~ScreenFill() { Watch(false); }

// A key pressed in a web page goes to WebView2's own process, so neither
// Flutter nor this window sees it. A hotkey reaches the window whatever has
// the keyboard; it is held only while Relay is the active app, so F11 stays
// with other programs. If another program holds F11, it does nothing here.
void ScreenFill::Watch(bool on) {
  if (on && !watching_) {
    watching_ = RegisterHotKey(window_, kF11, MOD_NOREPEAT, VK_F11) != FALSE;
  } else if (!on && watching_) {
    UnregisterHotKey(window_, kF11);
    watching_ = false;
  }
}

bool ScreenFill::Handle(UINT message, WPARAM wparam) {
  if (message == WM_ACTIVATEAPP) {
    Watch(wparam == TRUE);
    return false;
  }
  if (message != WM_HOTKEY || wparam != kF11) return false;
  // While a page's fullscreen alone covers the screen, F11 does nothing, so
  // that the window does not stay covered after the page's fullscreen ends.
  if (page_ && !app_) return true;
  app_ = !app_;
  Update();
  return true;
}

// As Chromium does for its own fullscreen: a maximized window is restored
// first, so the screen-sized frameless window is not held to the work area,
// and is maximized again afterwards.
void ScreenFill::Update() {
  const bool on = page_ || app_;
  if (on == filled_) return;
  if (on) {
    MONITORINFO monitor{sizeof(monitor)};
    if (!GetMonitorInfo(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST),
                        &monitor)) {
      return;
    }
    maximized_ = IsZoomed(window_);
    if (maximized_) SendMessage(window_, WM_SYSCOMMAND, SC_RESTORE, 0);
    style_ = GetWindowLong(window_, GWL_STYLE);
    ex_style_ = GetWindowLong(window_, GWL_EXSTYLE);
    GetWindowRect(window_, &frame_);
    SetWindowLong(window_, GWL_STYLE, style_ & ~(WS_CAPTION | WS_THICKFRAME));
    SetWindowLong(window_, GWL_EXSTYLE,
                  ex_style_ & ~(WS_EX_DLGMODALFRAME | WS_EX_WINDOWEDGE |
                                WS_EX_CLIENTEDGE | WS_EX_STATICEDGE));
    const RECT& screen = monitor.rcMonitor;
    SetWindowPos(window_, nullptr, screen.left, screen.top,
                 screen.right - screen.left, screen.bottom - screen.top,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  } else {
    SetWindowLong(window_, GWL_STYLE, style_);
    SetWindowLong(window_, GWL_EXSTYLE, ex_style_);
    SetWindowPos(window_, nullptr, frame_.left, frame_.top,
                 frame_.right - frame_.left, frame_.bottom - frame_.top,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    if (maximized_) SendMessage(window_, WM_SYSCOMMAND, SC_MAXIMIZE, 0);
  }
  filled_ = on;
}
