# Local Project State - 2026-06-03

This is the current handoff snapshot for the local Pace project. The machine
needed RAM kept free during this pass, so LM Studio was stopped and no model
diagnostics or live app automation were run.

## Git State

- Active branch: `main`
- Remotes: none configured
- Latest local commits before this note:
  - `7557089 Declare automation permission and tune voice`
  - `9484290 Confirm local action results`
  - `78213f3 Tune local voice and action routing`

## Completed Since The Last Snapshot

- Added `NSAppleEventsUsageDescription` so macOS can prompt Pace for Automation
  permission when tools control apps like Notes.
- Reset the stale Apple Events denial for `com.pace.app` after that change.
- Switched compact TTS fallback to the installed Rishi voice and lowered rate /
  pitch / volume for less harsh playback.
- Added deterministic post-action feedback so successful tools do not end
  silently when the planner emits only `[DONE]`.
- Tightened planner instructions so note creation uses the `notes` tool with a
  `body`, not `open_app Notes`.
- Added permission preflight state for Speech Recognition, Calendar, and
  Reminders.
- Added panel rows for core permissions plus local-tool permissions:
  Automation, Calendar, and Reminders.
- Added System Settings deep links for Speech Recognition, Calendar, Reminders,
  and Automation.
- Added Action Result Center state and panel rows for recent planned/completed/
  failed/denied/skipped tool runs.
- Added pure tool preflight checks for disabled actions, missing Accessibility,
  Calendar, Reminders, and Automation prompts.
- Added Watch Mode v2 event categories: major screen change, content update,
  focused-region change.
- Expanded Apple Notes skill support to create, append, and search notes.
- Added local memory for preferred browser, including voice commands and
  `open_url` execution behavior.
- Added TTS voice resolver so Premium/Enhanced Apple voices override compact
  fallback config, plus a panel voice-quality row.

## Low-Memory Validation Performed

- Quit the debug Pace app.
- Stopped LM Studio and its helper processes to keep RAM free.
- `swiftc -parse -parse-as-library leanring-buddy/WindowPositionManager.swift`
  passed.
- `swiftc -parse -parse-as-library leanring-buddy/AppBundleConfiguration.swift
  leanring-buddy/PaceUserPreferencesStore.swift leanring-buddy/CompanionManager.swift`
  passed.
- `swiftc -parse -parse-as-library leanring-buddy/DesignSystem.swift
  leanring-buddy/WindowPositionManager.swift leanring-buddy/CompanionPanelView.swift`
  passed.
- `git diff --check` passed.

Additional lightweight checks after the feature batch:

- `swiftc -parse -parse-as-library` over action/preflight/result/memory/watch/
  TTS files passed.
- `swiftc -parse -parse-as-library` over CompanionManager plus its new support
  files passed.
- `swiftc -parse -parse-as-library` over CompanionPanelView plus UI support
  files passed.

## Not Run During This Pass

- LM Studio diagnostics were intentionally skipped because they reload models.
- Live Notes/Calendar/Reminders/Automation prompts were intentionally skipped.
- Visual review of the taller panel was skipped.
- Manual app launch was skipped after tests to avoid leaving Pace/model runtime
  processes alive.

## Latest Xcode Test

- Xcode test action succeeded on 2026-06-03.
- Latest result bundle: `Test-leanring-buddy-2026.06.03_14-14-49-+0530.xcresult`
- Result count: 129 tests, 266 warnings, no reported error count.

## Manual Review Checklist

When RAM is available again:

1. Open `leanring-buddy.xcodeproj` and run from Xcode with Cmd+R.
2. Open the Pace panel and confirm the permission rows fit cleanly:
   Microphone, Speech Recognition, Accessibility, Screen Recording, Screen
   Content, Automation, Calendar, Reminders.
3. Try: "create a note called pace test with text hello from pace."
4. Approve the native Automation prompt for Pace controlling Notes.
5. Confirm Pace speaks/shows `Created note: pace test`.
6. Try a Calendar read and Reminder creation once their panel rows show granted.
7. Run Xcode tests from Xcode and update this note with the result count.
