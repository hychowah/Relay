# Presentation explanations

2026-11-17. The user authorized implementing a short explanation attached to
`app_present`, following the prompt-first evaluation. The app stays full-screen;
there is no fixed conversation pane. Drawing and resolving discussion points
remain future work.

## Implementation

Optional `ViewIntent.explanation` contains nonblank plain text, at most 600
characters. The prompt asks supporting apps to present the evidence, finding and
qualifications together. Apps advertise support and resolve a native DOM target;
the shared bridge owns one dismissible note and its lifecycle. Research and Room
opt in. Applied acknowledgement waits for the app and note render frames. Manual
input, pending cancellation, failure, disposal or another presentation removes it.
Reading inside the note preserves it. Notes are transient; tool history retains
the intent but saved-source reopening does not recreate a note.

## Live-provider evidence

Three real `deepseek-flash` low-effort turns used the configured private key,
actual OpenCode harness and Relay browser on isolated ports 3231/3232/8786.
App evidence was synthetic; no real user conversation or research data was used.

| Turn | Observed result |
| --- | --- |
| Room work area | Discovered, inspected and presented desk/lamp with the new explanation field. Note gave 140×70 and 35×35 cm measurements and the absent height qualification. |
| Newly selected sofa | Used manually selected Rest/sofa context for “this one.” Presented 190×85 cm, with height/seat dimensions explicitly unknown. |
| Research H1 | Read the fictional manufacturer record and presented both DoF and price fields. Note preserved 16 total/8 active DoF, converted ~¥20,000 pricing, kit/shipping qualification and unknown configuration/load. |

All three presentations were acknowledged applied with the note visible inside
the app while chat was collapsed. Research initially returned no search hits for
the over-specific query; the agent broadened it and read the matching record.
Some routine retrieval narration persisted. These observations establish that
the actual agent uses the interface, not statistical answer reliability.

## Checks and limits

- Relay build and all 66 tests passed. Focused bridge/protocol cases cover text
  safety, validation, unsupported/missing targets, manual input and cancellation.
- Research baseline/final `make check` and six focused adapter tests passed.
- Browser layouts at 1280×800, 390×844 and 390×430 kept the note in-frame without
  horizontal overflow. A placement correction avoids covering the second field
  on normal phone/desktop views. Very short screens can still overlap secondary
  evidence; the note is scrollable and dismissible.
- Native Research cancellation during a deliberately lengthened real animation
  returned stale with no note. Reduced motion applied without animation. Reading,
  dismissal and manual cleanup worked in the actual native UI.
- No physical Android or second-device check. Fixture console errors concerned
  omitted image assets; no JavaScript error was observed. Raw output/screenshots
  are ignored under `tmp/live-discussion/`.
- The isolated evaluation left production unchanged. At the user's subsequent
  request, live activation restarted Relay's user service and Research's installed
  launcher on 2026-11-17. The old Research listener required an explicit stop before
  the replacement could bind. Normal supervisor/publication behavior remains.
  Research startup regenerated the served entry revision; source research and
  feedback were not edited. Existing Relay conversation identities were preserved.
- Live local HTTP checks confirmed explanation discovery, both bridge assets and
  the native view. Windows Tailscale forwards 10001/10002 also returned the updated
  bridge/discovery. Relay's browser shell loaded; this tool browser could not load
  the tailnet Research frame during activation. A later border-style check found
  Chromium local-network permission was blocking the frame. Granting it for the
  local test origin allowed live desktop/phone presentation checks. Research
  backgrounds are now unchanged, with a rotating border light and static
  reduced-motion border; applied and manual cleanup passed. Physical Android
  and a new production model-driven discussion remain unverified.

## PDF preview correction

The user reported missing inline PDF previews. Research's adapters had replaced
iframes with links because the outer sandbox blocked Chromium's native viewer.
Removed that conversion in v1/v2 and added operator-only `trustedNative: true`
registration support. Research alone opts in on this instance; its iframe uses
ordinary cross-origin privileges, with the distinct-origin check retained.
Default app sandboxes and saved-snapshot restrictions remain unchanged.

Relay build/66 tests and Research baseline/final checks passed. Actual served
paper/v2 and patent/v1 pages retained their PDF iframe with Chromium viewer load
success; the paper page, toolbar and thumbnails were visually checked. Relay was
restarted with no active runs, and live descriptor/React iframe checks confirmed
the Research sandbox omission. Research serves the changed adapters without a
restart or publication rebuild. No model turn was needed for this embedding fix.

## Next

Evaluate this interaction in the running Research workspace and on Android.
Use feedback to decide whether persistent remarks, drawing or resolved points
are the next useful capability.
