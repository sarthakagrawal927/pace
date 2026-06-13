---
Status: shipped (v0.3.12)
owner: future Pace-repo agent
priority: P1 — needs restraint-policy to land first
---

# PRD — Proactive Nudges (Pace volunteers thoughts)

## Goal

Pace already watches the screen (watch mode) and tracks app usage. It
should be allowed to occasionally volunteer an observation when one
adds value — "you've been on this Figma file for an hour, want a
break?" / "your 3 pm meeting is in 5 minutes." Today Pace only speaks
when the user presses PTT.

This PRD adds the framework + a small set of v1 nudge generators.

## Why now

Without proactive nudges, Pace's "ambient companion" claim is just
"voice search." Nudges are the difference between "tool I summon" and
"presence I share a desk with."

## Hard prerequisite

[restraint-policy](restraint-policy.md) MUST land first. Without it,
this feature is annoying. Don't ship one without the other.

## Scope (v1)

Three nudge generators, all off by default, each toggled
independently in Settings:

1. **Focus-fatigue nudge.** Triggered by `PaceAppUsageTracker` when
   the same app has had foreground for ≥45 continuous minutes AND
   the user is NOT on a call AND the user has touched input in the
   last 10 minutes (so they're not AFK). Cooldown ≥90 min after any
   focus nudge. Phrasing: short — "you've been on Figma for an
   hour. quick break?"
2. **Calendar pre-meeting nudge.** Triggered 5 min before any
   Calendar event whose title contains a keyword set (meeting,
   call, sync, review, 1:1). Cooldown: one nudge per event. Phrasing:
   names the event + time-until.
3. **Watch-mode observation nudge.** Triggered by `PaceScreenWatchMode`
   events when the screen-classifier detects an error dialog,
   stack-trace pattern, or "build failed" content. The VLM
   description must contain the trigger phrase; OCR fallback also
   counts. Cooldown 10 min. Phrasing: "looks like a build failed
   over there — want me to look at the error?"

Out of scope for v1: nudge ranking when multiple compete (just FCFS),
user-customized nudge generators, ML-trained nudge timing.

## Architecture

### New file: `PaceProactiveNudgeFramework.swift` (~250 lines)

- Protocol `PaceProactiveNudgeGenerator`:
  ```swift
  protocol PaceProactiveNudgeGenerator: AnyObject {
      var identifier: String { get }
      var settingsKey: PaceUserPreferencesKey { get }
      func subscribe(to manager: CompanionManager,
                     restraintGate: PaceRestraintGate.Type,
                     emit: @escaping (PaceProactiveUtterance) -> Void)
  }
  ```
- Three concrete generators implementing this. Manager registers them
  on `start()`.
- `PaceProactiveUtterance` carries `spokenText`, `source: PaceProactiveSource`,
  `confidence`, `relevanceWindowExpiresAt`.

### New files: `PaceFocusFatigueNudgeGenerator.swift`,
`PaceCalendarPreMeetingNudgeGenerator.swift`,
`PaceWatchModeObservationNudgeGenerator.swift` (~120 lines each)

Each subscribes to the relevant source (`PaceAppUsageTracker`,
`PaceCalendarRetrievalConnector`, `PaceScreenWatchModeController`) and
generates nudges. Each calls `restraintGate.decide(...)` before
emitting.

### Modify: `CompanionManager`

- Owns the three generator instances. Wires `emit` to:
  ```swift
  Task { @MainActor in
      try? await self.ttsClient.speakText(utterance.spokenText)
      // Also log to retrieval as a `paceHistory` doc so "what did you
      // tell me about?" can recall.
  }
  ```

### Modify: `PaceSettingsWindow`

- New "Nudges" section: per-generator toggle (off by default), one
  "Talkative / Balanced / Reserved" slider feeding the restraint
  policy.

## Acceptance criteria

- [ ] Focus-fatigue: simulate 50-min foreground in Figma → nudge fires
      ONCE. Continue another 30 min → second nudge suppressed by
      cooldown.
- [ ] Calendar: fixture event "Design review" at +5 min → nudge fires
      at T-5. Fixture event "Take dog out" → no nudge (no keyword).
- [ ] Watch-mode: fixture screen with "Build Failed" in OCR text →
      nudge offered.
- [ ] All generators off by default. Settings toggle persists.
- [ ] Restraint gate respected — Zoom frontmost suppresses every
      generator.

## Testing strategy

- One test file per generator. Inject a stub restraint gate, drive
  source events, assert utterance emission/suppression.
- Integration test in `PaceProactiveNudgeIntegrationTests` — register
  all three, feed a synthetic NSWorkspace timeline, assert correct
  fire order.

## Privacy posture

- Nudges are 100% local. No screen text or calendar content leaves the
  Mac.
- Every nudge is logged to `paceHistory` so the user can see "what
  did Pace say today" in Settings → Activity.

## Risks

- **Annoyance.** The single biggest risk. Mitigated by: opt-in
  defaults, restraint policy, the slider, and the per-source toggle.
- **Calendar keyword matching is crude.** Fine for v1; iterate after
  usage data.
- **Focus-fatigue could fire during deep flow** — Pace can't tell
  "I am in flow" from "I am stuck". Cooldown + the slider are the
  v1 mitigations; v2 explores adaptive timing from acceptance rate.

## Effort estimate

~600 lines (framework + 3 generators + tests). 2-3 days.

Where in code: `leanring-buddy/PaceProactiveNudgeFramework.swift` (protocol + utterance type),
`leanring-buddy/PaceFocusFatigueNudgeGenerator.swift`,
`leanring-buddy/PaceCalendarPreMeetingNudgeGenerator.swift`,
`leanring-buddy/PaceWatchModeObservationNudgeGenerator.swift`,
`leanring-buddy/PaceProactiveNudges.swift` (CompanionManager wiring).
