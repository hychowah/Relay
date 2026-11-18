# Discussion prompt evaluation

2026-11-17. The user authorized use of the configured DeepSeek key for testing.
Six real `deepseek-flash` turns at low effort used the actual OpenCode harness,
Relay service/browser and room-layout integration on isolated ports 3231/3232.
The app evidence was synthetic; the agent decisions and provider responses were
live. Provider credentials remained in service memory/environment. Real user
conversations, memories and app data were not used. No production restart.

## Change

The harness system prompt describes a shared-screen discussion: start from the
current selection, read quietly, explain a meaningful presentation, use published
targets, preserve qualifications and respect manual takeover. Examples cover a
selected value and a newly selected item. The `app_present` description reinforces
these semantics. No layout, tool schema or app capability was added in this pass.

## Observed behavior

| Turn | Observation |
| --- | --- |
| Work-area question | Discovered the app, inspected work, explained the presentation, highlighted desk/lamp, then answered after applied. Correct dimensions; added unsupported comfort/placement claims. |
| New manual sofa selection | Used new rest-zone/sofa context for “this one,” inspected rest and highlighted sofa rather than the previous desk. Added unsupported seating/comfort claims. |
| Work question after refinement | Correct tool sequence and dimensions; omitted comfort advice. Still announced routine discovery and inferred possible shape from equal dimensions. |
| Rest/desk comparison | Presented sofa; arithmetic differences were correct. First takeover attempt occurred after applied because reduced motion was enabled, so this did not establish stale handling. |
| Actual takeover during animation | With reduced motion disabled and fixture animation lengthened to 2.5s, manually switched to Work. Presentation became stale. Agent acknowledged failure and made no retry. |
| Circle and resolve request | Used a supported desk highlight; explicitly said it could neither draw a circle nor record a resolved point. Did not fake those actions. Leaked an unnecessary generation number into the answer and omitted a separate pre-presentation explanation. |

The refinement explicitly discourages routine retrieval announcements and
unsupported suitability/comfort claims. Five harness regression tests, TypeScript,
production build and records checks pass. Fixture tests verify mechanics; the
six live turns are the behavioral evidence, not a statistical reliability claim.
Raw isolated output is in ignored `tmp/live-discussion/`.

## Limits and next experiment

The prompt improves selection, target choice, evidence explanation and response
to a stale presentation. It does not fix the complete user experience: explanations
are still conversation messages, while app presentation collapses chat. A prompt
cannot place those words beside the target with the current tool schema.
Some unnecessary narration and unsupported inferences persisted. Research Web
answer quality, real-device layout, drawing, attached remarks and point completion
were not evaluated or implemented here. The subsequent [presentation explanation pass](presentation-explanations.md)
implements and evaluates that missing capability without a split layout.
Production activation remains separate from these isolated evaluations.
