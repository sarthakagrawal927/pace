# Project Status

Last updated: 2026-06-08

## Current Scope

Pace is a local-only macOS menu-bar voice agent. It listens through on-device
speech recognition, can read the current screen through local OCR/VLM support,
answers through a local planner, speaks with Apple TTS, and can execute approved
macOS actions through local tools, Accessibility, EventKit, AppleScript-style
app integrations, and an MCP bridge.

The project may need fleet registry alignment if it is intended to be tracked
under a different product slug such as `space`; no current `foundry.projects.json`
entry was found for `clickyLocal`, `Pace`, or `space`.

## Done

- Menu-bar/notch companion surface, settings window, cursor overlay, and
  push-to-talk flow are implemented.
- Local planner, local VLM screen analysis, Apple Vision OCR, Apple Speech STT,
  and Apple TTS are the documented runtime path; cloud LLM/STT/TTS paths are out.
- Agent mode supports approved local tool execution, AX-first clicking, grouped
  tool calls, plan-act-observe loops, watch mode, action result history, and
  local preference memory.
- First-pass Apple app integrations exist for Calendar, Reminders, Notes,
  Finder, Mail drafts, Things, Shortcuts, Messages, browser opening, volume,
  brightness, and media controls.
- MCP substrate is implemented for configured stdio servers.
- Local tests and runtime smoke hooks are documented, with the latest snapshot
  reporting Xcode tests and smoke checks passing on 2026-06-03.

## Planned Next

1. Resolve fleet registry identity: either add this repo as `clickyLocal` /
   `pace` / `space`, or document why it remains outside the fleet registry.
2. Install and validate one live OSS MCP server, preferably Altic MCP, then
   update the MCP status from pending live install to verified.
3. Complete live panel review for permission preflight, action result center,
   and voice-quality rows.
4. Pick up `docs/prds/click-executor-improvements.md` once the tool-caller
   readiness gate is satisfied: center-of-bbox click audit, top-K candidate
   scoring, and click verification/retry.
5. Keep `CompanionManager.swift` decomposition scoped to the documented next
   splits: agent loop body and screen-context service.

## Deferred / Parked

- Cloud LLM, cloud STT, and cloud TTS are out of scope for the current product
  direction.
- Planner v7 SFT for top-K click candidates belongs on the TinyGPT side before
  Pace depends on it.
- Running `xcodebuild` from terminal is intentionally avoided because it can
  invalidate local TCC permissions.
