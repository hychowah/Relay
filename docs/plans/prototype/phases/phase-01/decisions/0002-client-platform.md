# 0002 — Flutter is the main Relay client

On 2026-11-18 the user chose Flutter for the MacBook, the main device today,
and for the long-term native Android app. Windows users open the React page in
an ordinary browser. Electron is retired because it cannot run on Android.

## Evidence

The project had three clients without a recorded platform choice. The two
full clients had already diverged. Each connected app is a website in its own
web view in either native shell, so the number of plugins does not favor either.

The only resource measurement was a WSL sample with Electron 45.3.3. Summed
process RSS was 476 MiB with chat alone, 1,043 MiB with Room and five static
pages, 1,040 MiB with the views hidden, and 519 MiB after closing the tabs.
The native view count returned to zero. Five switches took 21–42 ms. Summed
idle CPU was 0.02–0.10% in three-second samples. RSS can count shared memory twice.
The Flutter macOS release archive was 19.7 MB. That measures distribution
size. Relay had no Flutter runtime performance measurements when the platform was chosen.

The pinned webview_flutter 4.14.1 plugin supports Android, iOS and macOS. Relay
has no Windows platform folder. The plugin lacks subresource interception, a
download API and separate data stores. JavaScript channel reachability from
sandboxed subframes and behavior on a physical Android device are unverified.

## Consequences

- New client features go to Flutter. Maintain chat and app opening in the React
  fallback. Feature parity and redesign of the web page are outside the commitment.
- Remove Electron source from this branch. Its services and worktree were removed
  the same day.
- Rules shared by clients belong in the service. Each client presents their results.
- A Flutter Windows build and a physical Android trial each require a separate
  request. Phone work is deferred. Merging the web page's records with the
  Flutter app's also requires a separate request.
