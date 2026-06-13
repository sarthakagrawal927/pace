# HUD and intent disambiguator

Status: partial (actionable). Turn HUD state, route feedback,
clarification handling, action progress, local-only unsupported routing, and
panel status are wired. Panel option-click clarification resolution is wired
for the existing edit/destructive clarification types, the cursor overlay and
notch voice surface now honor macOS Reduce Motion by snapping element pointing
and suppressing decorative bubble/notch animation, and disabled-by-default
runtime smoke hooks can synthesize and resolve a clarification after an Xcode
Debug build. Visual target ambiguity resolution and full manual runtime smoke
remain queued.

Remaining v1 scope:
- Add a visual target ambiguity clarification path (multi-candidate click
  scenarios surface a panel option-list, not just the existing edit/destructive
  clarifications) using the executor's top-K candidate output.
- Promote the existing runtime smoke hooks into a full manual smoke flow that
  exercises every HUD state once.

## Goal

Make Pace feel immediate and controlled:

- Show what Pace thinks the user is doing before the full planner finishes.
- Ask short clarifying questions for ambiguous commands.
- Show action progress and failure states without verbose speech.
- Keep the menu-bar/notch surface as the primary always-visible control.

## Current State

Pace has a notch capsule, a floating panel, a cursor overlay, response bubbles,
watch mode, approval popups, and a rule-based `PaceIntentClassifier`. The
planner still carries some responsibility for deciding whether a turn is
answer/action/dictate/edit, but the hot path now exposes local route state
before the planner completes.

Implementation note, 2026-06-09: `PaceTurnHUDState` tracks listening,
understanding, acting, clarification, done, failed, and unsupported states.
`CompanionManager` sets route/progress state before planner calls, shows
clarifications for ambiguous edit/destructive-pronoun commands, and now
short-circuits explicit cloud/large-model requests with a local-only unsupported
response instead of falling into the planner. The panel renders the current HUD
state and resolves clarification option clicks by rewriting the original
ambiguous transcript into an explicit target before re-entering the normal
pipeline. `OverlayWindow` reads the SwiftUI reduce-motion environment and
`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` so cursor flight,
bubble scale, character streaming, welcome animation, and overlay fade-outs are
removed when the user requests less motion. `PaceMenuBarOverlay` also switches
voice bars and the avatar glyph from wave/pulse animation to static active-state
indicators. Approval popups still take precedence over execution.

## Scope

In scope:

- A small intent-disambiguation layer before planner dispatch.
- HUD states for listening, understood intent, acting, needs-clarification,
  done, and failed.
- Minimal clarification UI in the panel/overlay.
- Action progress display for typed executor calls.
- No-animation fallback for accessibility/reduce-motion.

Out of scope:

- A marketing landing page.
- A full chat transcript UI.
- Replacing the settings window.
- Multi-agent task planning.
- Cloud escalation.

## Intent Disambiguator

Inputs:

- Stable ASR partials and final transcript.
- Current focus/selection availability.
- Screen-reference heuristic.
- Local RAG availability.
- Recent user command history.

Outputs:

```swift
enum PaceTurnRoute {
    case answer
    case screenRead
    case action
    case dictate
    case edit
    case clarification(question: String, options: [String])
    case unsupported(reason: String)
}
```

Current implementation uses `PaceIntentClassifier` plus
`PaceIntentClarifier` / `PaceIntentUnsupportedDetector` rather than a single
combined enum. The behavior maps to the PRD route shape.

The first implementation can extend `PaceIntentClassifier`. A future tiny model
can replace the rules only after it beats the rule scaffold on local fixtures.

## Clarification Policy

Ask only when acting would be risky or likely wrong:

- Multiple matching targets and no strong focus/cursor signal.
- Edit command with no selected or focused editable text.
- Compose command with unresolved recipient and no safe fallback.
- Destructive action without explicit object.

Do not ask for routine answer-only or read-screen turns.

Clarification copy should be short:

- "Which Save button?"
- "Edit the selected text or the whole field?"
- "I found two Johns. Which one?"

## HUD States

| State | Surface | Behavior |
|---|---|---|
| Idle | Notch capsule | Quiet. |
| Listening | Notch capsule | Audio-reactive right slot. |
| Understanding | Notch capsule/cursor | Short thinking state, no large panel. |
| Acting | Cursor/HUD | Show target/action name when useful. |
| Needs clarification | Panel or small overlay | Present short options. |
| Done | Cursor/HUD | Brief confirmation or action result. |
| Failed | Cursor/HUD | Clear local failure reason. |

Use visual feedback instead of speech for routine actions where the action
itself is visible.

## Product Rules

- The notch capsule remains the main surface.
- The panel remains a control/status surface, not a chat app.
- Response text should not cover the target UI.
- Hover/click affordances must match existing SwiftUI/AppKit conventions.
- Reduce-motion settings should disable cursor flight and nonessential motion.

## Latency Targets

| Milestone | Target |
|---|---|
| Listening state after hotkey | Immediate. |
| First inferred route after stable partial | <= 100 ms. |
| Clarification shown after final transcript | <= 200 ms. |
| Action progress visible after dispatch | <= 100 ms. |
| Failure reason visible after executor failure | <= 100 ms. |

## Tests

Unit tests:

- Ambiguous target returns clarification.
- Edit with no selection/focus returns clarification or unsupported.
- Pure answer routes without screen capture.
- Screen-read phrases route to screen path.
- Action route includes expected risk hints.

Current coverage: `PaceIntentClassifierTests` covers pure answer, screen read,
screen action, chitchat, large-model route, ambiguous edit clarification,
ambiguous destructive clarification, clarification option rewriting/rejection,
and local-only unsupported responses.

Runtime smoke:

- Panel can show and dismiss clarification. Partial: smoke hooks can synthesize
  and resolve a clarification through app state; manual UI click-through remains
  queued.
- Approval popup still takes precedence over HUD progress.
- Cursor annotations can be disabled without breaking route state.
- Reduce Motion can be verified after a Debug build by enabling the macOS
  setting and triggering element pointing; the cursor should snap instead of
  flying, and the notch voice surface should show static active indicators
  instead of pulsing/waving. Manual runtime smoke remains queued.

## Done When

- Route decisions are visible in local state before planner completion.
  Implemented for classifier routes and action progress.
- Ambiguous commands ask one short question instead of guessing. Partial:
  ambiguous edit and destructive-pronoun commands are covered and panel option
  clicks resolve those choices; visual target ambiguity resolution remains
  queued.
- Reduce-motion settings should disable cursor flight and nonessential motion.
  Implemented for the cursor overlay, pointer bubble, welcome animation,
  overlay fade-out path, and notch voice/avatar animation.
- Routine actions can complete with minimal or no speech.
- Existing panel, settings, approval, and cursor tests continue to pass.
- No new main-window or dock-icon surface is introduced.

## References

- `leanring-buddy/PaceIntentClassifier.swift`
- `leanring-buddy/PaceMenuBarOverlay.swift`
- `leanring-buddy/CompanionPanelView.swift`
- `leanring-buddy/OverlayWindow.swift`
- `leanring-buddy/PaceActionResultCenter.swift`
- `docs/architecture.md`
