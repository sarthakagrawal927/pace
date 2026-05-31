# Laptop Service Handoff - 2026-05-31

Branch: `codex/pace-service-handoff-20260531`

Purpose: preserve the local Pace / learning-buddy work before this Mac goes in
for service. This branch is intentionally separate from `main` because the work
is broad and still needs manual runtime verification before it should be merged.

## Product State

Pace is now centered around the menu-bar/notch surface instead of the older
cursor-local listening UI. The black notch capsule is the always-visible app
surface, and voice-state animation belongs there.

The intended runtime model is still fully local:

- Apple Speech for on-device STT.
- LM Studio VLM + OCR for screen context.
- LM Studio planner for tool planning and responses.
- `AVSpeechSynthesizer` for TTS.
- Local macOS APIs for actions.

## Included Work

### Notch surface

- Added `PaceMenuBarOverlay.swift`, a custom non-activating `NSPanel` that
  visually extends the MacBook notch/menu bar.
- The notch has balanced left and right icon slots, with a simpler state-aware
  avatar on the left and audio bars on the right during voice turns.
- The old cursor-near voice pill remains reusable, but the active conversation
  indicator is now the top notch surface.
- `leanring_buddyApp.swift` wires up `PaceMenuBarOverlayManager` during app
  launch.
- `MenuBarPanelManager.swift` can anchor the companion panel to the menu-bar
  overlay instead of relying only on a standard status item.

### Cursor annotation preference

- Added `areCursorAnnotationsEnabled` to `PaceUserPreferencesStore.swift`.
- Added a `Cursor Annotations` toggle in `CompanionPanelView.swift`.
- `CompanionResponseOverlay.swift` and `OverlayWindow.swift` now respect the
  preference so the user can turn off cursor-local text/annotation surfaces.

### Tool-call planning and local actions

- `CompanionSystemPrompt.swift` now asks the planner to prefer:

  ```text
  <tool_calls>
  [
    [{"tool":"open_url","url":"https://example.com"}],
    [{"tool":"volume","direction":"down","amount":2}]
  ]
  </tool_calls>
  ```

- The outer array is sequential. Each inner array is a parallel group.
- Legacy action tags are still supported.
- `PaceActionExecutor.swift` now parses and executes grouped tool plans,
  returns tool observations, and feeds observations back into the plan-act-
  observe loop.
- Added or documented local tools for:
  - clicking, double-clicking, typing, keypresses, and scrolling
  - opening apps and URLs
  - Music controls
  - volume and brightness controls
  - calendar reads
  - reminder creation
- Added EventKit permission usage strings to `Info.plist`.

### Screen-change diffing

- Added `PaceScreenImageDiffer.swift`.
- It downsamples screenshots into grayscale fingerprints and reports mean pixel
  delta plus changed-pixel ratio.
- This is the first piece needed for watch mode: only re-analyze the screen when
  there is meaningful visual change.
- Added `PaceScreenImageDifferTests.swift`.

### TTS and eval updates

- `StreamingSentenceTTSPipeline.swift` strips complete and partial
  `<tool_calls>` blocks before text is spoken.
- Parser tests cover grouped tool calls, calendar/reminder tools, and TTS
  stripping.
- Eval docs and fixtures were updated so pure Q&A and action-off cases do not
  expect tool-call blocks.

## Key Files

- `leanring-buddy/PaceMenuBarOverlay.swift`: top notch capsule and voice-state
  animation.
- `leanring-buddy/MenuBarPanelManager.swift`: floating panel anchoring and
  click handling.
- `leanring-buddy/leanring_buddyApp.swift`: menu-bar overlay lifecycle wiring.
- `leanring-buddy/CompanionManager.swift`: plan-act-observe loop integration and
  cursor annotation preference state.
- `leanring-buddy/PaceActionExecutor.swift`: tool-call parsing, grouped action
  execution, EventKit tools, Music/URL/app/volume/brightness actions.
- `leanring-buddy/CompanionSystemPrompt.swift`: planner contract for tool calls.
- `leanring-buddy/PaceScreenImageDiffer.swift`: screenshot diff primitive for
  watch mode.
- `leanring-buddy/StreamingSentenceTTSPipeline.swift`: TTS cleanup for tool-call
  markup.
- `leanring-buddyTests/*`: parser and image-diff coverage.
- `AGENTS.md`: architecture notes and updated file responsibilities.

## Build And Run

Do not run terminal `xcodebuild` for this repo because it can disturb macOS TCC
permissions. Use Xcode or AppleScript against Xcode instead:

```bash
open leanring-buddy.xcodeproj
osascript -e 'tell application "Xcode" to build active workspace document'
```

For a quick visual relaunch during handoff, open the built Debug app outside the
debugger:

```bash
open ~/Library/Developer/Xcode/DerivedData/leanring-buddy-*/Build/Products/Debug/Pace.app
```

The app expects LM Studio at `http://localhost:1234/v1` when local VLM/planner
features are enabled. Connection-refused logs are expected if LM Studio is not
running.

## Validation Already Performed

- `swiftc -parse -parse-as-library` over the modified Swift files passed.
- `plutil -lint leanring-buddy/Info.plist` passed.
- `jq empty evals/fixtures/action-mode-off.json evals/fixtures/qa-no-screen.json`
  passed.
- `git diff --check` passed.
- Xcode build via AppleScript succeeded.
- The app was launched from the built Debug app for visual smoke testing.

Known warnings from the validated build:

- The project still warns that Copy Bundle Resources contains `Info.plist`.
- Swift 6 concurrency warnings still exist in unrelated known-warning areas.

## Not Yet Fully Verified

- The Xcode test action was attempted, but the test run did not start reliably
  in this machine state. Parser/image-diff tests are committed but should be run
  from Xcode on the next machine.
- Synthetic AppleScript clicks on the notch did not conclusively verify panel
  opening. Physical click/tap behavior should be manually checked.
- Calendar and Reminder tools will need first-run macOS permission prompts.
- `EnableActions` must be treated carefully. With it enabled, Pace can post real
  local input and system actions.
- The plan-act-observe loop has the new tool observation path, but needs a full
  manual end-to-end pass with LM Studio loaded.

## Suggested Next Pass

1. Build and run from Xcode on the repaired or replacement Mac.
2. Verify notch idle, listening, processing, and responding states.
3. Confirm the notch opens and dismisses the companion panel on physical clicks.
4. Toggle `Cursor Annotations` and confirm cursor-local text disappears.
5. Run the parser and image-diff tests from Xcode.
6. Start LM Studio with the configured VLM and planner, then test:
   - screen-aware Q&A
   - open app
   - open URL
   - volume/brightness
   - Music controls
   - calendar query
   - reminder creation
7. Decide whether this branch should be cleaned into smaller PRs before merge.

## Exclusions

- `default.profraw` profiler output is excluded.
- No secrets, environment files, SSH keys, cloud credentials, or production
  configs are included.
- No deploy, release, migration, or production push was performed.
