# Records policy

Write each fact in one place. Standing documents describe the current system.
Active plans hold requirements and information needed to continue work.
Raw investigation output stays in ignored scratch storage.

## Record homes

| Kind | Home | Lifetime |
| --- | --- | --- |
| Standing documentation | README.md, AGENTS.md, docs/*.md | Permanent; update in place |
| Plan workspace | docs/plans/<initiative>/ | Active work; summarize and clean up at completion |
| Scratch | Ignored tmp/ | Local only; never committed |
| Runtime data | Ignored runtime/, .state/, or configured external volumes | User data; independent of source and scratch cleanup |
| Commit evidence | Git commit message | Permanent, concise |

Conversation history, memories, generated user outputs, and credentials are
runtime data, not agent engineering records. Never delete user runtime data
as part of plan close-out. Builds and dependency directories are generated
and remain untracked.

## Plan layout

```text
docs/plans/<initiative>/
  master-plan.md
  <contract>.md
  phases/phase-NN/
    README.md
    decisions/NNNN-title.md
    working/
```

Create optional files only when later work needs them. A master plan can hold
the handoff directly until separate phase records serve a real purpose.

| Record | Content | Limit |
| --- | --- | --- |
| Active master plan | Title, Status: active, goal, scope, phases, evidence, Next | 3,000 words |
| Complete master plan | Status: complete, outcome, lasting decisions, limits | 1,000 words |
| Contract document | An initiative's current contract | 3,000 words |
| Phase README | Scope, entry state, exits and evidence, limits, Next | 900 words |
| Decision record | One choice, evidence, consequences | 700 words |
| Working Markdown | Design, review, or handoff needed by another session | 3,000 words |
| Working JSON | Small structured working information | 64 KB |

Working directories contain only Markdown and small JSON. Fixtures belong
with tests. Logs, databases, screenshots, archives, and build outputs belong
outside tracked plan folders.

Replace stale records in place. Do not add attempt, retry, addendum, or
version copies. Update Next at each handoff.

## Standing instructions

AGENTS.md holds standing rules and links, not duplicated specifications,
dated status, chronology, or one-time authorization. Keep it below 3,000
words. If another agent instruction file is introduced, link to these
rules instead of duplicating them.

## Close-out

1. Move lasting contracts and operational knowledge into standing docs.
2. Rewrite the master plan as a summary with Status: complete.
3. Remove phase READMEs and working records once no later session needs them.
   Retain decisions still in force and current contracts.
4. Repair links and run the records check.

Do not perform close-out while the prototype is still being implemented.
Runtime user data is outside this cleanup.

## Enforcement

Run `python3 tools/check_records.py` for the working tree. Before every
commit, stage the intended change and run
`python3 tools/check_records.py --staged`.

The checker enforces plan shape, status and Next sections, the limits above,
a 1 MB general tracked-file cap, a tracked-log ban, ignored scratch storage,
relative links, and the standing-instruction limits. In staged mode, content
and link targets come from the Git index. Keep checker constants and this policy
consistent.
