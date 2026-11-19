# Relay workspace instructions

Read the [prototype master plan](docs/plans/prototype/master-plan.md) before
planning or implementation. It is the single source for requirements, phase
status, assumptions, and the next step. Update its Next section at handoff.

## Working rules

- Follow the current user request. A saved plan describes work; it does not
  independently authorize its execution.
- Preserve agreed product behavior. Resolve routine technical choices from
  evidence; ask about material product changes or missing external access.
- Build the smallest thing a current requirement needs. Add an abstraction
  only when a current requirement needs it; no speculative infrastructure.
- Avoid extra gates and validation for rare cases outside current usage. Keep
  checks that protect user data, credentials, and the agreed app boundaries.
- Keep documentation current and concise. Add comments only when they explain
  a decision that future development needs; test important behavior without
  duplicating implementation details or covering speculative cases.
- Keep application-specific behavior in each app's own project, never in this
  repository. Relay holds only the generic protocol, its Browser and the Room
  example. Changes to another repository must follow that repository's
  instructions and source/runtime boundaries.
- Preserve unrelated changes and user data. Use synthetic fixtures for initial
  integration checks and distinguish source verification from live readiness.
- Keep credentials and private runtime data out of source control and logs.
  Preserve the plan's separation between service credentials and executable
  agent code.
- Run focused checks appropriate to the change. Record actual evidence and
  unverified behavior. Do not report a phase complete with required evidence
  missing.
- When a unit of work is complete and checked, commit it on your own branch
  with the `smart-commit` skill; do not wait to be asked. The skill audits the
  change and holds the commit when something needs the user's decision.
  Without the skill, check the diff yourself for stale documents, leftover
  files and secrets. Merge into `main` and push only when the user asks.
- Work in your own worktree and branch. Use the main checkout only to merge,
  and bring your branch up to date with `main` before you merge. Never edit in
  the checkout that runs the services, and never point a test backend at the
  live records. Retire feature worktrees with `tools/remove-worktree <path>`
  so their published Flutter previews are cleaned up.
- Build the Mac client with `tools/publish-flutter`, which leaves nothing on
  the Mac. Before you finish, remove anything else your session put on the Mac:
  build folders, test apps, and the settings and data of any test app.
- Keep machine paths, addresses and personal details out of tracked files.
  Local machine notes, when present, are in `~/.config/relay/machine.md`,
  outside the repository.

## Project records

Follow [docs/records-policy.md](docs/records-policy.md) for plans, records and
scratch files. Before every commit, stage the change and run
`python3 tools/check_records.py --staged`; do not commit if it fails.
