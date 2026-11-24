# 0003 — Read-only shared folders and Browser form filling

On 2026-11-24 the user asked the agent to read and search folders they choose
in WSL, and to fill online forms with personal details found there.

## Choices

- Folders are listed in **Workspace menu → Shared folders** and exposed as the
  built-in Files app. Access is read-only: text files and PDF text; other files
  by name only. Only names starting with a dot are hidden below a shared
  folder; what the user shares, such as a Windows profile with AppData, is
  the user's choice.
- File text the agent reads goes to the model provider.
- A chat with no bot gets every app, Files and Browser included. The user
  accepted that a page or file could steer the agent to read shared files and
  send them out through the Browser: "normal chat also have access to the
  folder. fine for read only. that is user issue".
- Read-only file access runs inside the service before the Compose executor
  boundary exists. Writing, moving, deleting or running anything still waits
  for that boundary.
- The agent fills fields only; the user presses Submit. There is no
  confirmation before a fill, because the user starts each fill from chat.
  The site's scripts see a value as soon as it is filled, and a page's own
  handler can still submit or navigate after a change.

## Evidence

Source checks on WSL: Relay and page-script tests in Chromium, the build,
`flutter analyze` and `flutter test`. A first-principles review of each feature
and an independent bug review by the orchestrator session led to the fixes:
visibility tests a person would agree with, a fill tied to its form read, a
refusal for tabs hidden or covered by the expanded conversation, outlines kept
across fills, PDF text read in a worker thread with a hard deadline, and the
Host and Origin checks on the folder settings.

## Consequences

Not yet checked: the Mac WKWebView, the live backend, a real provider and
Windows WebView2. The Mac checks after deploy are item 22 of the
[Flutter plan's Next section](../../../../flutter/master-plan.md#next).
