#include "screen_fill.h"

#include <flutter/standard_method_codec.h>

namespace {

constexpr UINT kToggleApp = WM_APP + 1;
ScreenFill* hooked = nullptr;

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
  hooked = this;
}

ScreenFill::~ScreenFill() {
  Watch(false);
  hooked = nullptr;
}

// A key pressed in a web page goes to WebView2's own process, so neither
// Flutter nor this window sees it; a low-level hook sees every key. It is set
// only while Relay is the active app, so other programs' typing never waits
// on Relay, and it acts only on F11 while this window is in front.
void ScreenFill::Watch(bool on) {
  if (on && !hook_) {
    hook_ = SetWindowsHookEx(WH_KEYBOARD_LL, KeyHook, GetModuleHandle(nullptr), 0);
  } else if (!on && hook_) {
    UnhookWindowsHookEx(hook_);
    hook_ = nullptr;
    f11_down_ = false;
  }
}

LRESULT CALLBACK ScreenFill::KeyHook(int code, WPARAM wparam, LPARAM lparam) {
  const auto* key = reinterpret_cast<const KBDLLHOOKSTRUCT*>(lparam);
  if (code == HC_ACTION && key->vkCode == VK_F11 && hooked) {
    // Holding the key repeats its press; only the first one counts.
    const bool down = wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN;
    const bool first = down && !hooked->f11_down_;
    hooked->f11_down_ = down;
    if (GetForegroundWindow() == hooked->window_) {
      // The window changes after the hook returns, which Windows needs soon.
      if (first) PostMessage(hooked->window_, kToggleApp, 0, 0);
      return 1;
    }
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

bool ScreenFill::Handle(UINT message, WPARAM wparam) {
  if (message == WM_ACTIVATEAPP) {
    Watch(wparam == TRUE);
    return false;
  }
  if (message != kToggleApp) return false;
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
