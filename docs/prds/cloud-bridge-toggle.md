---
Status: shipped (v0.3.11)
owner: delegated to Sonnet agent
priority: P1 — quality unlock via user-owned trapdoor
---

# PRD — Cloud Bridge Toggle (Claude Code / Codex / Gemini CLI)

## Goal

Add an opt-in toggle that lets Pace route planner calls through a
sibling project at `http://localhost:3456` (a Node SSE bridge — see
`../local-ai/`) which spawns the user's already-authenticated
**Claude Code**, **Codex**, or **Gemini CLI** as the upstream.

This is the **only** intentional break of the no-cloud-LLM
principle, and it is owned by the user via an explicit consent
dialog and a persistent indicator while active. Default is **off**.

## Why this PRD exists

Pace's headline differentiator is "fully on-device." This toggle
dilutes that. It must therefore land with:

- A one-time consent dialog the user has to actively accept.
- A persistent visual indicator (notch capsule color shift) while
  the bridge is active.
- This PRD as the durable record of the architectural tradeoff,
  cited in CLAUDE.md and the privacy section of README.

Without those guardrails, this becomes silent cloud telemetry.
With them, the user owns the choice — same posture as `download_file`,
the other deliberate trapdoor.

## Scope (v1)

Two routing modes, picked in Settings:

1. **Off (default)** — current behavior. Pace uses `LocalPlannerClient`
   against LM Studio. No code path touches the bridge.

2. **Hybrid (recommended on)** — Local planner stays default for
   action turns and the multi-step agent loop (latency-sensitive).
   Bridge is reserved for what Pace today routes as
   `PaceFMIntentKind.phoneLargeModel` — turns the local planner
   currently rejects with a "local-only" message. Toggle flips that
   rejection into "hand off to bridge."

3. **Always-bridge** — Every planner call routes through the
   bridge. Highest quality, highest latency, max cloud egress.
   Off by default; surfaced only after the user has used Hybrid
   for at least a day (Pace tracks `cloudBridgeFirstUsedAt` and
   only reveals this option in Settings ≥24h later).

Out of scope for v1: VLM through bridge (the bridge doesn't accept
images), TTS through bridge, embeddings through bridge, fallback
ladder when bridge is down (just fall back to LM Studio and log).

## Bridge protocol

From `../local-ai/README.md`:

```http
POST http://localhost:3456/chat
Content-Type: application/json

{
  "provider": "claude" | "codex" | "gemini",
  "model": "sonnet" (or CLI default),
  "messages": [{"role": "user", "content": "..."}],
  "systemPrompt": "..."
}
```

Response is **Server-Sent Events**. Each event is one of:

- `event: chunk\ndata: {"text": "..."}` — token stream
- `event: done\ndata: {}` — stream complete
- `event: error\ndata: {"message": "..."}` — upstream error

This is a different SSE shape from OpenAI's
`data: {"choices":[{"delta":{"content":"..."}}]}` — needs a
dedicated parser. **Do not** try to reuse `LocalPlannerClient`'s
parse path verbatim.

## Architecture

### New file: `leanring-buddy/CloudBridgePlannerClient.swift` (~280 lines)

Conforms to `BuddyPlannerClient`. Mirror the shape of
`LocalPlannerClient` for the streaming + retry skeleton, but with
a bridge-specific request body and SSE parser.

Key responsibilities:

- Build the request JSON from `BuddyPlannerRequest` — flatten
  `systemPrompt` + `userPrompt` + `conversationHistory` into the
  bridge's `messages` array. Bridge expects: system as
  `systemPrompt` field, all other turns as `messages`.
- Discard image inputs (mirror `LocalPlannerClient`'s behavior —
  the bridge has no image support).
- Issue the POST with `Accept: text/event-stream`.
- Parse the bridge's `event: chunk / data: {"text": "..."}` lines.
  Emit each `text` field as a streaming token to the
  `BuddyPlannerStreamingCallback`.
- On `event: error` — surface as a thrown
  `PaceCloudBridgeError.upstream(message:)`. **No silent retry on
  upstream errors.** This is a paid model call; retrying once on
  network errors is acceptable, but if Claude/Codex/Gemini
  themselves errored, fail fast.
- On `event: done` — finalize.
- Loopback-guarded by `PaceLocalEndpointGuard` (the endpoint itself
  is loopback; the fact that local-ai then fans out to cloud is
  the user's consented choice — Pace's guard layer cares about
  what *Pace* sent traffic to).
- `displayName` returns
  `"Claude Code (\(model))"` / `"Codex (\(model))"` /
  `"Gemini CLI (\(model))"` for status surfaces.
- `supportsImageInput` returns false.

### New file: `leanring-buddy/PaceCloudBridgeConsent.swift` (~120 lines)

Pure decision/state module. Holds:

```swift
enum PaceCloudBridgeMode: String, Equatable, Codable {
    case off
    case hybrid
    case alwaysBridge
}

enum PaceCloudBridgeUpstream: String, Equatable, Codable {
    case claude
    case codex
    case gemini
}

struct PaceCloudBridgeConfiguration: Equatable {
    let mode: PaceCloudBridgeMode
    let upstream: PaceCloudBridgeUpstream
    let model: String
    let baseURL: URL
    let hasUserAcceptedConsent: Bool
    let firstUsedAt: Date?
}

enum PaceCloudBridgeConsent {
    static func loadConfiguration() -> PaceCloudBridgeConfiguration
    static func saveMode(_:)
    static func saveUpstream(_:)
    static func saveModel(_:)
    static func acceptConsent()
    static func markFirstUsedIfUnset(now:)
    static func canEnableAlwaysBridge(now:) -> Bool
}
```

All keys persist in `UserDefaults` with the `pace.cloudBridge.` prefix.
The 24-hour wait for `alwaysBridge` is enforced by
`canEnableAlwaysBridge(now:)` — compare `firstUsedAt` against now.

### Modify: `leanring-buddy/Info.plist`

Add the following keys (all optional; defaults documented in code):

| Key | Type | Default | Purpose |
|---|---|---|---|
| `CloudBridgeBaseURL` | String | `http://localhost:3456` | Bridge endpoint. Must be loopback. |
| `CloudBridgeDefaultUpstream` | String | `claude` | First-run upstream. |
| `CloudBridgeDefaultModel` | String | `sonnet` | First-run model. |

Mode + consent live in UserDefaults, not Info.plist.

### Modify: `leanring-buddy/PaceLocalEndpointGuard.swift`

Add a **separate validator** `validatedCloudBridgeURL(from:)` that
checks the URL is loopback (same rule as the existing planner
guard) but lives behind its own function so the security category
is explicit in code. Calls into the existing validator under the
hood. Reason for the separate function: when a future change
"tightens" the planner guard, the cloud-bridge entry won't
accidentally lock down.

### Modify: `leanring-buddy/BuddyPlannerClient.swift`

The planner factory currently returns either `LocalPlannerClient`
or `AppleFoundationModelsPlannerClient` based on
`PlannerProvider`. Update factory to:

1. Read `PaceCloudBridgeConsent.loadConfiguration()`.
2. If mode is `.alwaysBridge` AND consent is accepted, return
   `CloudBridgePlannerClient`.
3. If mode is `.hybrid` AND consent is accepted, return a small
   `HybridPlannerClient` wrapper that holds both
   `LocalPlannerClient` and `CloudBridgePlannerClient`, and picks
   per `BuddyPlannerRequest.routingHint`. Define a new optional
   `routingHint: PaceLargeModelHint?` field on
   `BuddyPlannerRequest` (`.preferLocal`, `.preferLarge`); when
   not set, default to local.
4. Otherwise return the existing local planner.

### Modify: `leanring-buddy/CompanionManager.swift`

- Add three published flags + setters mirroring the existing
  `PaceUserPreferencesStore` pattern:
  `cloudBridgeMode`, `cloudBridgeUpstream`, `cloudBridgeModel`.
- New private function `requestCloudBridgeConsentIfNeeded()` —
  shows an NSAlert with the consent text below, returns the
  user's accept/reject. Persists via `PaceCloudBridgeConsent.acceptConsent()`.
- Add a turn-routing hook: when `PaceIntentClassifier` returns
  `.phoneLargeModel` (which today routes to the local-only
  rejection message), check the bridge configuration. If
  hybrid+accepted+upstream-reachable, route the turn to the
  planner with `routingHint = .preferLarge`.
- On every bridge-routed turn, call
  `PaceCloudBridgeConsent.markFirstUsedIfUnset(now:)` so the
  24-hour timer starts.

### Consent dialog text

NSAlert (modal, blocks until user responds). Text exact:

> **Send data outside Pace?**
>
> The cloud bridge sends your transcript and the planner system
> prompt to the upstream CLI you choose (Claude Code, Codex, or
> Gemini CLI), which in turn calls Anthropic, OpenAI, or Google
> servers respectively. Their data-handling policies apply.
>
> Pace will show an indicator in the menu-bar capsule whenever a
> bridge call is in flight. Push-to-talk text-only turns still
> default to your local planner; the bridge is used only for
> turns Pace would otherwise refuse as "too hard locally."
>
> You can turn this off at any time in Settings → Cloud bridge.

Buttons: **Use the bridge** (default) / **Keep local only**.

### Modify: `leanring-buddy/PaceMenuBarOverlay.swift`

When a bridge call is actively streaming, tint the right-icon
slot accent to a distinct hue (suggestion: amber `#FFB347`
instead of the default cool tone). Drop back when the stream
finishes. Implementation: new `@Published var isCloudBridgeCallActive: Bool`
on `CompanionManager`, set true at request start and false on
stream end (success or error).

### Modify: `leanring-buddy/PaceSettingsWindow.swift`

New "Cloud bridge" section (renders BELOW the existing Voice
section). Contents:

- Mode picker (Off / Hybrid / Always bridge). Always-bridge row
  is disabled with a tooltip explaining the 24-hour wait if
  `PaceCloudBridgeConsent.canEnableAlwaysBridge(now:)` is false.
- Upstream picker (Claude Code / Codex / Gemini CLI).
- Model text field (free-form; placeholder = "sonnet" / "gpt-4-1106-preview" / "gemini-2.0-flash").
- Bridge URL row (read-only, shows `CloudBridgeBaseURL` from plist).
- Reachability status: ping `GET http://localhost:3456/health` on
  Settings open. Show green/red + last-checked timestamp.
- "Revoke consent" button — clears all bridge state, sets mode
  back to `.off`.

When mode is toggled from `.off` to anything else AND
`hasUserAcceptedConsent` is false, fire the consent dialog. If
the user rejects, reset mode back to `.off`.

### Modify: `leanring-buddy/PaceTurnHUDState.swift`

Today, `phoneLargeModel` intent produces the local-only
unsupported state with text like "that needs a larger model than
i have here." When bridge is hybrid+accepted, replace that with a
routing message "thinking with claude code…" (or codex / gemini),
and let the turn proceed through the planner.

### Modify: `leanring-buddy/CLAUDE.md` (== `AGENTS.md`)

Update the architecture section's "Planner" line — add a
paragraph after the existing two-conformer description:

> **Optional cloud bridge** (opt-in, default off, consent-gated):
> The `CloudBridgePlannerClient` routes turns through
> `http://localhost:3456`, a sibling Node project (`../local-ai/`)
> that spawns the user's already-authenticated Claude Code,
> Codex, or Gemini CLI. The CLI then contacts its respective
> cloud provider. This is the ONLY intentional break of the
> no-cloud-LLM principle, owned by the user via an NSAlert
> consent dialog. While a bridge call is in flight, the menu-bar
> capsule tints amber to make egress visible. See PRD:
> `docs/prds/cloud-bridge-toggle.md`.

Also add the Key Files row for `CloudBridgePlannerClient.swift`
and `PaceCloudBridgeConsent.swift`.

## Acceptance criteria

- [ ] All 382 existing tests still pass via `bash scripts/test-pace.sh`.
- [ ] New `CloudBridgePlannerClientTests` covers SSE chunk parsing,
      error event handling, image-input discard, and the
      `BuddyPlannerRequest` → bridge body shape.
- [ ] New `PaceCloudBridgeConsentTests` covers config load/save,
      24-hour wait gate for `alwaysBridge`, and consent persistence
      across "restart" (fresh load).
- [ ] Settings → Cloud bridge section renders. Mode picker
      changes are persisted across an app restart.
- [ ] First time the user picks a non-`off` mode, the consent
      NSAlert fires. Accepting persists. Rejecting reverts to
      `.off`.
- [ ] When mode is `.hybrid` and the user asks Pace something
      that would have triggered `phoneLargeModel` (e.g. "write me
      a 200-line essay on the history of jazz"), Pace routes to
      the bridge. Verify with the menu-bar tint and a console log
      `"📡 Pace planner via cloud bridge"`.
- [ ] When mode is `.off`, every existing local-planner test path
      remains unchanged — no bridge code touched at runtime.
- [ ] `validateForAppStartup` does not error on the new
      `cloudBridge` enum cases / config keys.
- [ ] CLAUDE.md / AGENTS.md updated with the architecture note
      and the new Key Files rows.

## Testing strategy

- Stand up a tiny stdlib HTTP fixture in
  `scripts/cloud-bridge-fixture-server.py` (mirror
  `scripts/tts-fixture-server.py`) that serves the bridge SSE
  shape: `chunk` events for canned tokens, then `done`. Used by
  `CloudBridgePlannerClientIntegrationTests`.
- `PaceCloudBridgeConsent` is pure — straightforward unit tests
  in a new `PaceCloudBridgeConsentTests.swift`.
- Reachability ping in Settings: gate behind an injectable
  `URLSessionProtocol` so tests can stub. (If too much overhead
  for v1, omit reachability tests and document the gap.)

## Risks and mitigations

- **Principle dilution.** Mitigated by consent dialog, persistent
  indicator, default-off, and this PRD.
- **Bridge process crashes mid-stream.** SSE connection drops; the
  planner client surfaces a generic "the bridge stopped responding"
  message and Pace's existing fallback (which is "try local") kicks
  in. Don't auto-restart the Node process — that's outside Pace's
  scope.
- **User toggles `alwaysBridge` and uses Pace heavily** — could
  rack up Anthropic API costs. v1 ships without per-turn cost
  tracking; flag this in the consent dialog (it does today). v2
  can add a daily-call counter in Settings.
- **CLI auth expires** — Claude Code, Codex, and Gemini CLI all
  need re-auth periodically. The bridge surfaces a 401 → Pace
  shows the upstream error verbatim. Don't try to handle re-auth.

## Effort estimate

~600 lines (client + consent + settings + HUD wiring + tests +
fixture). 1 focused session. Within reach of a Sonnet agent
given the file-by-file specifics above.

## Implementation order (suggested for the agent)

1. `PaceCloudBridgeConsent.swift` + its tests (pure, smallest
   blast radius).
2. `CloudBridgePlannerClient.swift` + integration test against
   `scripts/cloud-bridge-fixture-server.py`.
3. `PaceLocalEndpointGuard` extension.
4. `BuddyPlannerClient` factory update.
5. `CompanionManager` published flags + consent dialog +
   bridge-routing hook.
6. Settings UI.
7. Menu-bar overlay tint.
8. CLAUDE.md / AGENTS.md updates.
9. Run `bash scripts/test-pace.sh` — must show 382+N passed.
10. Commit with a single feat commit. Do **not** run release-pace.sh.

## What NOT to do

- Do NOT remove the existing no-cloud guarantee from the README
  or CLAUDE.md. Add the bridge as a documented opt-in exception,
  don't soften the headline.
- Do NOT use the bridge for VLM, embeddings, or TTS in v1.
- Do NOT call `bash scripts/release-pace.sh` — leave the commit
  ready for the human to ship.
- Do NOT touch `Info.plist`'s `PlannerProvider` default — it
  stays `local`. The bridge is selected via UserDefaults mode.
- Do NOT try to make the bridge work without
  `hasUserAcceptedConsent`. The dialog is the gate.

Where in code: `leanring-buddy/CloudBridgePlannerClient.swift` (SSE client),
`leanring-buddy/PaceCloudBridgeConsent.swift` (consent + mode + 24h soak),
`leanring-buddy/HybridPlannerClient.swift` routing (in `BuddyPlannerClient.swift`).
Tier-picker integration lives in `leanring-buddy/PacePlannerTierStore.swift`.
