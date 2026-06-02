# Local Project State - 2026-06-02

This checkout is now treated as a local Pace project.

## Git State

- Active branch: `main`
- Remotes: none configured
- Published cleanup already done:
  - The accidental external draft PR is closed.
  - The exposed fork branches were deleted.
  - The old upstream/fork remotes were removed from this checkout.

Do not add a GitHub remote or push this project unless the target repository is
explicitly confirmed first.

## Current Product Work

The latest local `main` includes:

- Menu-bar/notch overlay as the primary always-visible Pace surface.
- Right-side voice animation in the notch during listening/processing/responding.
- Simpler left-side state icon in the notch.
- Cursor annotation preference and panel toggle.
- Grouped `<tool_calls>` parser where outer arrays are sequential and inner
  arrays are parallel.
- Local action tools for apps, URLs, Music, volume, brightness, Calendar, and
  Reminders.
- Local tool registry for planner docs, aliases, risk labels, approval
  summaries, and future MCP bridge work.
- First-pass Apple app tools: Finder, Notes, Mail drafts, Things, Shortcuts,
  and Messages opening.
- Action approval toggle and popup before local tools control the Mac.
- Screen image diffing plus explicit watch-mode controller and panel toggle for
  meaningful change events.
- Explicit watch-mode voice commands for "watch my screen" and "stop watching".
- Rule-based intent classifier routes chitchat, pure-knowledge, screen-read,
  tool-action, and phone-large-model turns.
- Parser, TTS-stripping, image-diff, watch-mode, registry, and intent tests.
- Updated `AGENTS.md` architecture notes.

## Validation Already Performed

- Swift parser checks over modified app files passed before the local merge.
- `plutil -lint leanring-buddy/Info.plist` passed.
- `jq empty evals/fixtures/action-mode-off.json evals/fixtures/qa-no-screen.json`
  passed.
- `git diff --check` passed.
- Xcode build via AppleScript succeeded before the local merge.
- Xcode test via AppleScript passed 112 tests after the stale test-target signing
  team was aligned with the app target.
- Latest Xcode result has no `Info.plist` resource warning and no watch-command
  actor-isolation warnings. Remaining warnings are the known Swift 6 concurrency
  warnings called out in `AGENTS.md`.

## Still Needs Manual Verification

- Physically click the notch capsule and confirm the companion panel opens and
  dismisses correctly.
- Test the `Cursor Annotations` toggle in the app.
- Start LM Studio with the configured VLM and planner, then smoke-test:
  - screen-aware Q&A
  - open app
  - open URL
  - volume and brightness controls
  - Music controls
  - Calendar reads
  - Reminder creation
  - Finder/Notes/Mail/Things/Shortcuts/Messages tools
- Treat `EnableActions` carefully because enabled action mode can post real
  local input and system actions.
- Keep `Approve Actions` on unless actively testing automation speed.
