# Browser VPN tabs
Status: complete

## Outcome

Each Browser tab in the Mac app can send its pages out of WSL through
NordVPN instead of the Mac's own network. The user asked for this on
2026-11-23. Both phases are in Stable since 0.0.19, and the closing of open
tunnels when NordVPN drops (V08) is live since `a796aa2` (2026-11-26). The
[Flutter README](../../../flutter/README.md) describes the switch, and the
[development guide](../../development.md) holds the patched package, the Mac
test and how the proxy works.

| ID | Behaviour delivered |
| --- | --- |
| V01 | Each Browser tab has a VPN switch, off for new tabs. App tabs always use the Mac's network. |
| V02 | A VPN tab's traffic, name lookups, popups and PDFs shown in Relay's viewer go from the Mac to the Relay backend over the tailnet, then out of WSL through NordVPN. |
| V03 | When NordVPN in WSL is off or the route fails, a VPN tab does not load and says the VPN route failed. Nothing falls back to the Mac's network. |
| V04 | VPN tabs share one browsing profile of their own; sign-ins persist and stay apart from normal tabs. |
| V05 | The switch is saved with the tab and restored on start. Switching reopens the current address in a new web view without its back history. |
| V06 | VPN tabs reach only public internet addresses. |
| V07 | Desktop only: the Windows build and the web page show no switch. |
| V08 | When NordVPN drops, the backend closes all open VPN tunnels within about 2 seconds and refuses new ones until it is back. |

V01, V03 and V04 were defaults chosen while planning; the user kept them.

## Lasting decisions

- **Route in the backend.** `server/browser-proxy.ts` answers HTTP CONNECT
  on the backend's existing port, attached in `tools/flutter-experiment.ts`
  beside the Browser socket. No new port, forward or service. It has
  Relay's own boundary, the tailnet, and no password of its own.
- **VPN check.** Each tunnel passes the same NordVPN check as model calls
  (`requireNordVPN`, which honours `RELAY_VPN_CHECK=off`), before any name
  lookup. Tunnels starting together share one check. While any tunnel is
  open the check repeats every 2 seconds; a failed check closes every tunnel.
- **Name lookups** go to public name servers (`1.1.1.1`, `8.8.8.8`) through
  NordVPN, IPv4 only, because WSL's own resolver asks Windows over the home
  network.
- **Address rule.** A tunnel is refused unless every address of the name is
  public, and it connects to the address it checked, so a page cannot reach
  WSL's local services through the tab.
- **Privacy.** The proxy logs no destinations.
- **Mac profile and proxy.** A patched copy of `webview_flutter_wkwebview`
  3.27.2 in `flutter/packages/` gives VPN tabs a named, persistent WebKit
  profile. Swift sets that profile's proxy before the first load, and the
  PDF viewer's download uses the same proxy. The Mac's own name check is
  skipped in VPN tabs. This needs macOS 14.
- **WebRTC** is off in VPN tabs through WebKit's private
  `_setPeerConnectionEnabled:`, because the tunnel carries only TCP and
  WebRTC's UDP would show the Mac's address.
- Rejected: NordVPN on the Mac (whole device, not per tab) and a separate
  proxy program in WSL (its own port, forward and service).

## Evidence

- Phase 1 (2026-11-23): `npm test` and `npm run build` passed. A scratch
  backend and the live service returned WSL's VPN address through the proxy,
  refused loopback, tailnet and home-network targets with 403, and logged no
  destinations.
- Phase 2 (2026-11-23): `flutter analyze` and `flutter test` passed. After an
  orchestrator review's three fixes, one MacBook run of
  `browser_vpn_test.dart` passed. A VPN tab's address differed from a normal
  tab's over https and plain http, WebRTC was gone from it, a closed page was
  blank at once, and a tab whose setup failed loaded nothing.
- V08 (2026-11-26): 143 backend tests passed. A scratch proxy with a stand-in
  `nordvpn` closed an open download within a second, refused the next request
  with 503 and accepted one after reconnecting. 300 real status checks 2
  seconds apart all said Connected within a second.
- By hand, reported by the user on 2026-11-26 with no problems reported:
  switching a tab both ways, a popup, a PDF, sign-in kept after a restart,
  and the VPN-down message with NordVPN in WSL off.

## Limits

- No proxy password: any tailnet device, and any local process that can
  reach the port, can send traffic out through WSL's NordVPN.
- NordVPN's Kill Switch is off in WSL. After a drop, open tunnels close at the
  next check, up to about 2 seconds later, or about 7 if `nordvpn status`
  hangs; until then their traffic can leave over the normal network. The user
  chose to leave this gap on 2026-11-26.
- A real NordVPN drop while a VPN tab downloads has not been tried; only the
  stand-in showed the close.
- Video calls do not work in VPN tabs.
- `RELAY_VPN_CHECK=off` makes the proxy a plain relay over WSL's network; the
  live service does not set it.
- A tunnel tries only the first address of a name, so a dead first address
  gives 502.
- Cloudflare and Google see the names VPN tabs visit, from the VPN's address.
- A switch in the first seconds, while a tab's first page is still getting
  ready, can time out after 20 s. After a tab's first page, a failing link,
  Reload or redirect shows no message, as in normal tabs. A VPN tab that fails
  at start may come back blank. A switch that fails on an unloaded tab leaves
  a blank start page; the user said this is intended.
- The update feed does not check the macOS 14 minimum.
- The Windows client ignores the saved flag and loads VPN tabs over Windows'
  network.
