---
Status: shipped (v0.3.12)
owner: future Pace-repo agent
priority: P0 — gate that every proactive feature lands on
---

# PRD — Restraint Policy ("silence is a feature")

## Goal

Pace should speak only when it adds something. Right now Pace is purely
reactive — it speaks only on PTT, so restraint is implicit. Once
[always-listening](always-listening-mode.md), [proactive
nudges](proactive-nudges.md), and [episodic memory](episodic-memory.md)
land, Pace gains many *opportunities* to speak. Without an explicit
restraint gate, it'll feel like a chatty toddler.

This PRD defines the rules + the gate every "should I speak now?"
decision flows through.

## Restraint rules (v1)

A response is **emitted** if and only if ALL of these hold:

1. **Adds non-obvious value.** Not restating the screen, not echoing
   the user's words, not announcing what Pace just did when the user
   can already see/hear it.
2. **Not in a busy moment.** Pace is silent when:
   - The user is actively typing/clicking (input within the last 3 sec).
   - The user is on a video/audio call (frontmost is Zoom/Meet/Teams/
     FaceTime/Slack-Huddle, or a Bluetooth headset shows active call).
   - The cursor is in a focused text input AND has been typing in the
     last 2 sec.
3. **Cooldown respected.** Proactive nudges: ≥10 min since last
   proactive utterance. Episodic-memory recall: ≥30 sec since last
   memory injection.
4. **Not low-confidence.** Wake-word triggers with confidence <0.7
   never reach the planner — Pace doesn't ask "did you say
   something?"

Explicit PTT presses **bypass all of the above** — the user asked, so
Pace answers.

## Scope (v1)

- New pure module: `PaceRestraintGate.swift`. Single static function
  `shouldSpeak(context:) -> RestraintDecision`. No I/O, no side effects.
  All inputs are passed in (frontmost app, time-since-last-utterance,
  recent input timing, confidence score, intent kind).
- Wire the gate at every "Pace is about to speak from a proactive
  source" site: wake-word post-classify, watch-mode nudges, episodic
  memory injection, timer fire (timers bypass — user-initiated).

## Architecture

### New file: `PaceRestraintGate.swift` (~150 lines)

```swift
struct PaceRestraintContext {
    let now: Date
    let lastProactiveUtteranceAt: Date?
    let lastEpisodicRecallAt: Date?
    let lastUserInputAt: Date?
    let frontmostAppBundleIdentifier: String?
    let isOnActiveCall: Bool
    let wakeWordConfidence: Double?
    let intentKind: PaceFMIntentKind
    let proactiveSource: PaceProactiveSource
}

enum PaceProactiveSource {
    case userPushToTalk
    case wakeWord
    case watchNudge
    case episodicRecall
    case timerFire
    case backgroundReminder
}

enum RestraintDecision {
    case speak
    case stayQuiet(reason: String)
    case queueUntilIdle
}

enum PaceRestraintGate {
    static func decide(_ context: PaceRestraintContext) -> RestraintDecision
}
```

The `reason` string is exposed in a debug overlay so behavior is
auditable — silence without explanation is a debugging nightmare.

### Modify: every proactive caller

Each caller constructs a `PaceRestraintContext` from current state and
calls `decide`. On `.stayQuiet`, the utterance is logged (count only)
and dropped. On `.queueUntilIdle`, the utterance enters a small in-
memory queue that drains when the gate's conditions clear.

### Modify: `CompanionManager`

- Track `lastProactiveUtteranceAt`, `lastUserInputAt`.
- New `lastUserInputAt` plumbed from CGEventTap (read-only) — gives a
  Mac-wide "user is actively interacting" signal without taking
  permissions Pace doesn't already have.
- Active-call detection: check frontmost bundle ID against a known
  list, plus `CMCallObserver` if the user has granted Phone
  permission (optional).

## Settings surface

- "Speak only when needed" — on by default for all proactive sources.
- Slider: "How quiet?" with three steps (Talkative / Balanced /
  Reserved). Tweaks cooldown windows and confidence thresholds.
- Per-source toggle: nudges / memory recall / timer announcements.

## Acceptance criteria

- [ ] PTT path bypasses every gate. Verified by unit test.
- [ ] Active call → all proactive sources silenced. Verified with
      fixture context where frontmost is "us.zoom.xos".
- [ ] Cooldown enforced on watch nudges. Two consecutive watch-events
      within 5 min: only the first speaks.
- [ ] `stayQuiet(reason:)` logged for every silenced utterance with the
      specific rule that fired.
- [ ] No re-prompts. A wake-word fire with confidence 0.5 produces
      no speech and no "did you say something?" prompt.

## Testing strategy

- `PaceRestraintGateTests` — table-driven coverage of every (source,
  context) combination. ~25 cases.
- Integration: simulate wake-word + idle screen → expect speech.
  Simulate wake-word + Zoom frontmost → expect silence.

## Risks

- **Too quiet → user thinks Pace is broken.** Mitigation: the debug
  log + the Settings slider. If Talkative is on, the slider relaxes
  cooldown to 2 min.
- **CGEventTap for input timing requires the Accessibility permission
  Pace already has.** Verify that the listen-only tap matches the
  existing PTT tap's permission scope (it does — same tap mode).

## Effort estimate

~200 lines + tests. 1 day of focused work. This PRD should land BEFORE
always-listening / nudges / episodic memory ship, because each of those
needs the gate to be live.

Where in code: `leanring-buddy/PaceRestraintGate.swift` (gate + `PaceRestraintContext`),
`leanring-buddy/PaceActiveCallDetector.swift` (call detection),
`leanring-buddy/PaceUserInputActivityMonitor.swift` (CGEventTap-based input timing).
