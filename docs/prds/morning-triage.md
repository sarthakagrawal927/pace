---
Status: shipped (v0.3.11)
owner: delegated to Sonnet agent
priority: P0 — closes the biggest gap to Del-style "AI exec assistant" positioning
---

# PRD — Daily Morning Triage

## Goal

At a user-set time each weekday morning, Pace proactively speaks (and
writes a card to the panel) a calm 30-second brief: "three things
today, two unanswered emails from yesterday, one reminder due at
noon, and you spent 4 hours in Xcode yesterday." Maps directly to
Del's headline feature — but on-device, opt-in, voice-first.

## Scope (v1)

A single proactive event per weekday, at a user-configured local
time, gated by the existing restraint policy (so it stays silent
during a Zoom call, etc). It speaks ONCE per day; if the user is
mid-turn or unreachable when the timer fires, the brief is queued
to the panel and a small badge appears on the menu-bar capsule.

Sources pulled (all local, all already wired in `PaceLocalRetrieval`):
- **Calendar today** — `PaceCalendarRetrievalConnector` → event titles
  + times for the next 24h.
- **Recent unread/flagged mail** — `PaceMailRetrievalConnector` →
  count + top sender/subject from the last 18h.
- **Open reminders due today** — `PaceRemindersRetrievalConnector` →
  count + top 1 by due time.
- **App-usage from yesterday** — `PaceAppUsageJournal` → top
  foreground app + minutes.
- **Watch-mode highlights from yesterday** —
  `PaceScreenWatchJournal` → most-active category if any.

Out of scope for v1: weekend variant, multi-time-of-day briefs
(evening recap is a v2 idea), per-source weighting, learned-
preference summarization style. Just: same time every weekday,
same shape of brief.

## Architecture

### New file: `leanring-buddy/PaceMorningTriageScheduler.swift` (~250 lines)

`@MainActor` class. Owns a single live `Timer` that fires at the
configured local time on weekdays. On fire:

1. Check restraint policy via `PaceRestraintGate.decide(...)` — if
   `.stayQuiet` or `.queueUntilIdle`, stash the brief into a
   `pendingMorningBriefCard` published property and exit.
2. Otherwise, build the brief by calling
   `PaceMorningBriefBuilder.build(now: Date, sources:)` (pure
   function — see below).
3. Speak the brief via the existing TTS pipeline (`ttsClient.speakText`).
4. Push the same brief into `paceHistory` retrieval so "what did
   you tell me this morning?" can recall.
5. Mark `lastBriefDeliveredAt` so re-fires same day are skipped.

Public API:

```swift
@MainActor
final class PaceMorningTriageScheduler {
    @Published private(set) var pendingMorningBriefCard: String?
    @Published private(set) var lastBriefDeliveredAt: Date?

    init(retriever: PaceRetriever,
         restraintGate: PaceRestraintGate.Type,
         ttsClient: any BuddyTTSClient,
         currentTimeProvider: @escaping () -> Date = Date.init)

    func start()  // arms the timer
    func stop()
    func deliverNowForTesting() async  // hook for the panel "preview"
    func dismissPendingCard()
}
```

The fire-time persistence + weekday gate is computed via
`Calendar.current.nextDate(after:matching:matchingPolicy:)`,
recomputed after each fire.

### New file: `leanring-buddy/PaceMorningBriefBuilder.swift` (~180 lines)

**Pure** brief-text composer. Takes typed inputs, returns one
spoken-ready paragraph. Unit-testable without TTS or timers.

```swift
struct PaceMorningBriefInputs {
    let now: Date
    let userFirstName: String?  // from PaceLocalMemoryStore, optional
    let todaysEvents: [CalendarBriefEvent]
    let unreadMailCount: Int
    let topMailSender: String?
    let topMailSubject: String?
    let openRemindersDueToday: Int
    let topReminderTitle: String?
    let topReminderDueText: String?  // "due at noon"
    let yesterdayTopApp: String?
    let yesterdayTopAppMinutes: Int?
    let yesterdayWatchHighlight: String?  // "lots of figma"
}

enum PaceMorningBriefBuilder {
    static func build(_ inputs: PaceMorningBriefInputs) -> String
}
```

Brief shape (deterministic template, no LLM call — keeps it cheap
and predictable):

> "good morning{, <firstName>}. {N} thing{s} on the calendar today
>  — {first event title} at {time}{, and {second event title} at
>  {time}}. {M} unread {message/messages} waiting{, including one
>  from <topMailSender> about <topMailSubject>}. {K} reminder{s}
>  due today{, the closest is <topReminderTitle> at <due>}.
>  yesterday you spent <minutes> minutes in <topApp>{, mostly
>  <watchHighlight>}."

Each clause is omitted if its source is empty. If ALL sources are
empty, the brief becomes a single-line "your morning's clear."

### Modify: `leanring-buddy/CompanionManager.swift`

- Create `morningTriageScheduler` lazy property (passes
  `localRetriever`, `PaceRestraintGate.self`, `ttsClient`).
- Add three `@Published` flags + setters mirroring the existing
  preference pattern:
  - `isMorningTriageEnabled` (default false)
  - `morningTriageHourOfDay: Int` (0–23, default 8)
  - `morningTriageMinuteOfHour: Int` (0–59, default 30)
- In `start()`, after the other proactive subsystems init: call
  `morningTriageScheduler.start()` IFF
  `isMorningTriageEnabled` is true.
- Wire the scheduler's `pendingMorningBriefCard` into a new panel
  card surface (see below).

### Modify: `leanring-buddy/PaceUserPreferencesStore.swift`

Add the three new keys (boolean + two Ints).

### Modify: `leanring-buddy/PaceRestraintGate.swift`

Add a new `PaceProactiveSource.morningTriage` case. The gate's
existing logic naturally covers it; the new case lets the gate
log which source the silence applied to.

### Modify: `leanring-buddy/CompanionPanelView.swift`

When `companionManager.morningTriageScheduler.pendingMorningBriefCard`
is non-nil, render a calm full-width card at the TOP of the panel
(above the existing turn HUD). Card has:
- "Morning brief" header
- The brief text body
- A small "play" button that calls
  `ttsClient.speakText(card)` for users who'd rather hear it later.
- A small "dismiss" X that calls `dismissPendingCard()`.

Style: matches `DS.Colors` — quiet, not alarming. No emoji.

### Modify: `leanring-buddy/PaceSettingsWindow.swift`

New "Morning brief" subsection under the General tab. Contents:
- Toggle: "Daily morning brief".
- Time picker (two pickers, hour + minute, 24h format).
- Preview button: "Send it now" → calls
  `morningTriageScheduler.deliverNowForTesting()`. Useful for
  users to tune the brief content without waiting 24 hours.

### Bundled retrieval source minimums

If any of the retrieval sources are DISABLED (per the existing
per-source toggles in Settings), the builder simply omits the
corresponding clause — no crash, no "i couldn't get your calendar"
narration. Brief degrades gracefully to whatever data is available.

## Acceptance criteria

- [ ] All existing 399 tests still pass.
- [ ] New `PaceMorningBriefBuilderTests` cover: empty inputs →
      "your morning's clear", full inputs → assembled paragraph,
      single-source-only fallbacks (cal-only, mail-only,
      reminders-only), name templating, pluralization.
- [ ] New `PaceMorningTriageSchedulerTests` cover (with injected
      time provider): timer fires at configured weekday time,
      Saturday/Sunday skip, restraint-stayQuiet queues to
      pendingCard, deliverNowForTesting respects nothing and
      always speaks (it's a user-initiated preview).
- [ ] Settings → Morning brief renders. Toggle persists across
      restart. "Send it now" speaks a brief built from current
      retrieval state.
- [ ] When the brief fires, the panel shows the card and the
      text appears in `paceHistory` retrieval (verify by querying
      `"this morning"` against the retriever post-fire).
- [ ] Default is OFF; user must explicitly enable.

## Risks

- **Wrong time-of-day at first run.** Mitigated by the "Send it
  now" preview button — user can verify the shape before turning
  on the timer.
- **Brief becomes annoying.** Mitigated by restraint policy +
  single-fire-per-day cap + dismissible card.
- **Calendar/Mail permission revoked between launches.** Builder
  gracefully omits those clauses; brief still ships from whatever
  is available.

## Effort estimate

~600 lines incl. tests. Reachable in one Sonnet pass.

## Implementation order (for the agent)

1. `PaceMorningBriefBuilder.swift` + its tests (pure, fast feedback).
2. `PaceMorningTriageScheduler.swift` + scheduler tests.
3. `PaceUserPreferencesStore` keys.
4. `CompanionManager` wiring + published flags.
5. `PaceRestraintGate` source enum extension.
6. Panel card UI.
7. Settings UI.
8. AGENTS.md update (Key Files rows for both new files; mention
   morning brief in the architecture-Planner section's proactive
   capabilities list).
9. Run `bash scripts/test-pace.sh` — must end green.

Where in code: `leanring-buddy/PaceMorningBriefBuilder.swift` (deterministic
clause composer) and `leanring-buddy/PaceMorningTriageScheduler.swift`
(@MainActor scheduler with weekday-skip + restraint gating).
10. Commit with the standard format. **Do not run release-pace.sh.**
