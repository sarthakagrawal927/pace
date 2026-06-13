---
Status: shipped (v0.3.11)
owner: future Pace-repo agent
priority: P1 — first user-facing escape valve from "must run LM Studio" friction
---

# PRD — Planner Tier Picker (Local / CLI bridge / Direct API BYO / Apple FM)

## Goal

Expose, in Settings → Planner, a single picker that lets the user pick
exactly one of four backend "tiers" for Pace's main planner:

1. **Local** — current default. LM Studio at `localhost:1234` running
   `qwen/qwen3-30b-a3b`. Free. Requires LM Studio to be installed and
   the model loaded.
2. **CLI bridge** — already shipped (`099fc24`). Pace's
   `CloudBridgePlannerClient` routes through the sibling `../local-ai/`
   Node SSE bridge, which spawns the user's already-authenticated
   Claude Code / Codex / Gemini CLI. Free if the user already pays for
   the CLI.
3. **Direct API (BYO)** — NEW. User pastes their own API key for
   Anthropic / OpenAI / OpenRouter / a custom OpenAI-compatible
   endpoint. Pace streams against the OpenAI-compatible
   `/v1/chat/completions` shape via a new `DirectAPIPlannerClient`.
4. **Apple FM only** — Apple Foundation Models becomes the sole
   planner (today it is only the short-answer fast path). Graceful
   degradation for users who have neither LM Studio installed nor any
   API key handy.

Same `CompanionSystemPrompt` block flows through all four tiers so
Pace's persona, tool dialect, and action vocabulary stay identical
regardless of which model is doing the reasoning.

## Why now / why this PRD exists

Today, choosing a planner means editing `Info.plist`. Two of the four
tiers (Local default, Apple FM via `PlannerProvider=appleFoundationModels`)
require a build edit; the CLI bridge requires a hidden UserDefaults
mode + a separate consent dialog that the user has to know exists. We
have effectively shipped four planner runtimes but only one is
surfaced as a "first-class choice" in Settings.

The Direct API (BYO) tier is the missing fourth — and the only tier
that lets a new user try Pace's full reasoning capability without
either (a) installing LM Studio and downloading 19GB, or (b)
configuring Claude Code locally. Pasting an Anthropic key is the
shortest path from `Pace.app` → working planner for most users.

The PRD also exists to lock down the **Keychain-only** policy for API
keys before the BYO tier ships. Once a key has been written to
UserDefaults or a plist, that decision is essentially un-revocable
across the install base, so the policy must land in the same commit
as the surface.

## Scope (v1)

In:

- A `Settings → Planner` tab restructure: one tier picker (radio /
  segmented control) with one sub-section per tier.
- New file: `DirectAPIPlannerClient.swift` (OpenAI-compatible
  streaming over an arbitrary cloud endpoint).
- New file: `PacePlannerTierStore.swift` (pure tier state +
  persistence).
- New file: `PaceKeychainStore.swift` (minimal `kSecClassGenericPassword`
  wrapper).
- "Test" round-trip button per tier — one canned 1-token "hi" turn,
  surfaces success/failure verbatim.
- Audit log file `PaceAPIAuditLog` — every Direct API call logs
  provider + model + token-count + turn-id (NO message content).
- Amber capsule tint extended to cover **any non-Local tier in
  flight** (today it only fires for the bridge).
- Default tier on first launch = `local` (matches current behavior;
  zero behavior change for existing users).

Out:

- Multi-tier fallback ladders (single tier per turn in v1; one opt-in
  toggle for cloud→local on failure, otherwise fail loud).
- Per-provider model search/listing (free-form text field for
  model identifier in v1).
- Cost estimation / token-spend dashboard (audit log records counts;
  the UI surface is v2).
- VLM tier picking (VLM stays loopback-only — local-VLM via LM Studio
  is the only supported VLM path in v1).
- Embeddings tier picking (same — embeddings stay loopback).
- Key import from environment variables or shell config (Keychain is
  the only entry point; the user pastes once).
- Per-tier conversation history isolation (history is shared across
  the active session regardless of which tier handled which turn).

## Architecture

### New file: `leanring-buddy/PaceKeychainStore.swift` (~120 lines)

Minimal wrapper over Security framework `kSecClassGenericPassword`.
Pace's only API-key entry point — nothing else in the codebase may
read/write API key material.

```swift
enum PaceKeychainStore {
    /// Pace-scoped service identifier. Distinct from any other
    /// keychain entries the user may have so revoking Pace's keys
    /// never touches their other apps.
    static let serviceIdentifier = "com.pace.app.plannerAPIKeys"

    /// Account names follow `directAPI.<provider>.apiKey`:
    ///   directAPI.anthropic.apiKey
    ///   directAPI.openai.apiKey
    ///   directAPI.openrouter.apiKey
    ///   directAPI.custom.apiKey
    /// One account = one key. Switching providers does not delete
    /// other providers' keys; deleting a tier choice does not delete
    /// its key (so re-selecting the tier reuses the saved key).
    static func keychainAccountName(for provider: PaceDirectAPIProvider) -> String

    @discardableResult
    static func storeAPIKey(_ apiKey: String, for provider: PaceDirectAPIProvider) -> Bool

    /// Returns nil if the user has not stored a key for this provider.
    /// Never logs the returned value. Callers must keep the returned
    /// string in-process only — never write it to disk, plist, or log.
    static func loadAPIKey(for provider: PaceDirectAPIProvider) -> String?

    @discardableResult
    static func deleteAPIKey(for provider: PaceDirectAPIProvider) -> Bool

    /// Convenience: which providers currently have a stored key. Used
    /// by Settings UI to show a green checkmark next to a saved provider.
    static func providersWithStoredKeys() -> Set<PaceDirectAPIProvider>
}
```

Key implementation rules:

- Use `kSecAttrSynchronizable = kCFBooleanFalse` — keys must NOT sync
  via iCloud Keychain. They are local to this Mac only.
- Use `kSecAttrAccessible = kSecAttrAccessibleWhenUnlocked` —
  unavailable while screen is locked (Pace turns can't fire then
  anyway).
- Never log the returned string. Never `print` it. Never include it
  in audit log entries. Errors log status codes, never values.
- `storeAPIKey` overwrites in place via `SecItemUpdate` if the
  account already exists (otherwise `SecItemAdd`). This is the only
  legal write path.

### New file: `leanring-buddy/PacePlannerTierStore.swift` (~150 lines)

Pure state module. Mirrors `PaceCloudBridgeConsent.swift`'s shape.
All preferences persist in `UserDefaults` under the
`pace.planner.tier.` prefix.

```swift
enum PacePlannerTier: String, Equatable, Codable, CaseIterable {
    case local              // LM Studio (existing default)
    case cliBridge          // CloudBridgePlannerClient (existing)
    case directAPI          // NEW: BYO key, cloud endpoint
    case appleFoundationModels  // Apple FM as sole planner
}

enum PaceDirectAPIProvider: String, Equatable, Codable, CaseIterable {
    case anthropic
    case openai
    case openrouter
    case custom

    var displayLabel: String { ... }
    var defaultEndpointURLString: String { ... }
    var defaultModelIdentifier: String { ... }
    var requiresHTTPS: Bool { self != .custom }
}

struct PacePlannerTierConfiguration: Equatable {
    let tier: PacePlannerTier
    let directAPIProvider: PaceDirectAPIProvider
    let directAPIModelIdentifier: String
    let directAPICustomEndpointURLString: String  // ignored unless .custom
    let fallsBackToLocalOnCloudFailure: Bool      // default false
}

enum PacePlannerTierStore {
    static func loadConfiguration() -> PacePlannerTierConfiguration
    static func saveTier(_ tier: PacePlannerTier)
    static func saveDirectAPIProvider(_ provider: PaceDirectAPIProvider)
    static func saveDirectAPIModelIdentifier(_ identifier: String)
    static func saveDirectAPICustomEndpointURL(_ urlString: String)
    static func saveFallsBackToLocalOnCloudFailure(_ enabled: Bool)
}
```

UserDefaults keys (all prefixed `pace.planner.tier.`):

| Key | Type | Default | Notes |
|---|---|---|---|
| `pace.planner.tier.selectedTier` | String | `local` | First-launch default. Zero behavior change for existing users. |
| `pace.planner.tier.directAPI.provider` | String | `anthropic` | |
| `pace.planner.tier.directAPI.model` | String | `claude-sonnet-4-5-20251001` | Provider-default; user-editable. |
| `pace.planner.tier.directAPI.customEndpointURL` | String | empty | Used only when provider = `custom`. |
| `pace.planner.tier.directAPI.fallsBackToLocalOnFailure` | Bool | `false` | Opt-in: when true, 401/network errors retry once via local. |

API keys do **NOT** live here. They live in Keychain via
`PaceKeychainStore`. The store module never touches the keychain
directly — it returns the `PacePlannerTierConfiguration` only.
`DirectAPIPlannerClient` is the only caller of `PaceKeychainStore.loadAPIKey`.

### New file: `leanring-buddy/DirectAPIPlannerClient.swift` (~300 lines)

`BuddyPlannerClient` conformer. Streams against an OpenAI-compatible
`/v1/chat/completions` SSE endpoint. Mirrors `LocalPlannerClient`'s
streaming + retry skeleton but:

- Endpoint is **NOT** loopback. Validated via the new
  `PaceLocalEndpointGuard.validatedDirectAPIURL(from:)` (see below).
- API key is loaded from `PaceKeychainStore` at request time. If no
  key is present, throws `PaceDirectAPIError.missingAPIKey(provider:)`
  BEFORE attempting the request. Never sends an unauthenticated
  request — that would surface as a generic 401 and confuse users.
- Sets `Authorization: Bearer <key>` for OpenAI/OpenRouter/Custom.
  Sets `x-api-key: <key>` + `anthropic-version: 2023-06-01` for
  Anthropic (their OAI-compat endpoint still wants the native
  Anthropic header convention as of this writing — confirm at
  implementation time against current Anthropic docs).
- Sends the same `messages` shape `LocalPlannerClient` does:
  `[{role:"system", content:<systemPrompt>}, …history…,
  {role:"user", content:<userPrompt>}]`.
- Discards images (matches `LocalPlannerClient` behavior; v1 keeps
  cloud planner text-only because the local VLM already serializes
  the screen into a text element map upstream).
- Parses OpenAI-format SSE: `data: {"choices":[{"delta":{"content":"..."}}]}` /
  `data: [DONE]`. Different from the bridge's `data: {"text":"..."}`
  shape — so `DirectAPIPlannerClient` and `CloudBridgePlannerClient`
  do NOT share a parser.
- Strips `<think>…</think>` blocks via the same helper
  `LocalPlannerClient.stripThinkingBlocks` uses (extract to a shared
  free function during implementation if it isn't already).
- On HTTP error → throws `PaceDirectAPIError.httpError(statusCode,
  bodyExcerpt)`. The full upstream body excerpt is surfaced verbatim
  to the user via the panel's recent-error surface so they see "401
  invalid x-api-key" instead of "something went wrong."
- On HTTP 401 → throws `.invalidAPIKey(provider:)` (a 401-specific
  variant for nicer UI copy).
- Logs an audit entry on every call via `PaceAPIAuditLog.record(…)`
  with provider + model + estimated input/output token counts +
  per-turn UUID. **No prompt or response content** in the audit log.

```swift
@MainActor
final class DirectAPIPlannerClient: BuddyPlannerClient {
    let displayName: String
    let supportsImageInput = false   // v1: text-only

    init(provider: PaceDirectAPIProvider,
         endpointURL: URL,
         modelIdentifier: String,
         keychainStore: PaceKeychainStore.Type = PaceKeychainStore.self,
         urlSession: URLSession = .shared)

    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)
}

enum PaceDirectAPIError: LocalizedError {
    case missingAPIKey(provider: PaceDirectAPIProvider)
    case invalidAPIKey(provider: PaceDirectAPIProvider)
    case httpError(statusCode: Int, bodyExcerpt: String)
    case malformedSSEPayload(rawLine: String)
    case unexpectedNonHTTPResponse
}
```

**Difference from `LocalPlannerClient` at a glance** (for the
implementer):

| Property | LocalPlannerClient | DirectAPIPlannerClient |
|---|---|---|
| Endpoint guard | loopback-only via `validatedLocalOpenAICompatibleBaseURL` | cloud-allowed via `validatedDirectAPIURL` |
| Auth | none | Bearer / x-api-key from Keychain |
| Retry on empty stream | yes (existing prompt-caching disable + non-stream fallback) | no — paid call; one shot per turn |
| Audit log entry | no | yes (provider + model + tokens + turn-id) |
| Image input | discarded | discarded (v1) |
| Capsule tint | normal | amber (matches bridge) |

### Modify: `leanring-buddy/PaceLocalEndpointGuard.swift`

Add a separate `validatedDirectAPIURL(from:)` function — DOES NOT
share a code path with the loopback guard. Rules:

- Scheme must be `http` or `https`.
- **`https` allowed for any host** (this is cloud egress on purpose).
- `http` is rejected unless the host is loopback (so a local proxy
  for testing still works, but accidental plaintext to a remote host
  fails closed).
- Host must be present and non-empty.
- Returns the validated URL on success; throws
  `PaceLocalEndpointGuardError` on failure (called from Settings save
  path so the user sees the rejection inline).

Why a separate function instead of a flag: future tightening of the
planner guard (e.g. adding allowed-port restrictions, blocking
private IP ranges) must not accidentally affect the Direct API
entry point, and vice versa. They are categorically different
security contracts.

### Modify: `leanring-buddy/BuddyPlannerClient.swift`

Update `BuddyPlannerClientFactory.makeDefault()` to dispatch on tier
first, then fall through to the existing CLI-bridge / local / FM
logic:

```
1. Load PacePlannerTierConfiguration.
2. Switch on configuration.tier:
   - .local                  → makeLocalOrFoundationModelsPlanner()  // existing path; tier=local maps to local default
   - .cliBridge              → existing cloud-bridge planner construction (move the bridge-on logic into this branch)
   - .directAPI              → DirectAPIPlannerClient(configuration: ...)
   - .appleFoundationModels  → makeFoundationModelsPlannerOrFallback()  // existing path
3. If .directAPI is selected but no API key is in keychain for the
   selected provider, log a one-line warning and fall back to local
   so Pace stays usable. (No silent failure — the panel shows a
   yellow "Direct API: no key set" status row that links to Settings.)
```

The existing CLI-bridge mode/consent UserDefaults remain — they are
now read ONLY when `tier == .cliBridge`. The 24-hour soak gate on
`alwaysBridge` and the existing consent dialog still apply.

`makeFastTextOnlyPlannerOrFallback()` (the short-answer fast path)
stays unchanged in v1 — it always prefers Apple FM. Direct API
turns therefore only affect the main planner, not the FM fast path.

### Modify: `leanring-buddy/CompanionManager.swift`

- New `@Published var activePlannerTier: PacePlannerTier` — published
  for panel + capsule binding.
- New `@Published var isOffDeviceTurnInFlight: Bool` — true whenever
  the active turn is being served by `cliBridge` or `directAPI`.
  Existing `isCloudBridgeCallActive` becomes a subset of this. Both
  flags can stay during the v1 cycle to minimize blast radius; the
  capsule observes the new flag.
- Setter `setActivePlannerTier(_ tier:)` — calls
  `PacePlannerTierStore.saveTier`, rebuilds the active planner via
  `BuddyPlannerClientFactory.makeDefault()`, logs the switch.
- Setters for Direct API provider/model/custom URL/fallback toggle
  mirror the existing preference setter pattern in this file.
- On every Direct API turn, wrap the planner call in:
  ```
  defer { isOffDeviceTurnInFlight = false }
  isOffDeviceTurnInFlight = true
  ```
  Same wrapping for bridge turns (or unify both call sites — they
  already share the `BuddyPlannerClient` protocol).
- "Fall back to local on cloud failure" handling: if
  `fallsBackToLocalOnCloudFailure` is true AND the Direct API call
  throws a network/401 error, retry the same turn against
  `LocalPlannerClient.makeFromInfoPlist()`, log the fallback, and
  surface a calm "fell back to local" notice in the panel. If the
  flag is false (default), surface the upstream error verbatim and
  do not retry.

### Modify: `leanring-buddy/PaceMenuBarOverlay.swift`

Extend the amber-tint condition from `isCloudBridgeCallActive` to
`isOffDeviceTurnInFlight`. Same hue, same animation, same drop-back.
The amber tint is the user's one consistent visual cue that
something just left the machine — it must fire for every non-Local
tier, not just the bridge.

### Modify: `leanring-buddy/PaceSettingsWindow.swift`

The "Cloud bridge" subsection gets folded into a new "Planner" tab
restructured around the tier picker:

```
Planner tab
├─ Tier picker (segmented control: Local | CLI bridge | Direct API | Apple FM)
├─ Active tier description (one-line)
├─ Local tier panel
│   └─ LM Studio status row (existing) + "open LM Studio" deeplink
├─ CLI bridge tier panel
│   └─ Existing cloud-bridge UI (mode picker, upstream, model, revoke consent)
├─ Direct API tier panel
│   ├─ Provider picker (Anthropic | OpenAI | OpenRouter | Custom)
│   ├─ API key field (secure text, masked, "stored in Keychain" caption)
│   ├─ "Save key" button → writes via PaceKeychainStore.storeAPIKey
│   ├─ "Delete key" button → wipes the Keychain entry for the current provider
│   ├─ Model identifier text field (provider default placeholder)
│   ├─ Custom endpoint URL field (shown only when provider = Custom)
│   ├─ "Fall back to local on cloud failure" toggle (default off)
│   ├─ "Test" button (1-token round trip — see section below)
│   └─ Last test result row (green check + echoed model, or red error verbatim)
└─ Apple FM tier panel
    └─ Apple Intelligence availability row (uses existing
       SystemLanguageModel.default.availability check)
```

On tier change to Direct API: if no key is stored for the currently
selected provider, the API key field gets focus and the Test button
is disabled.

On tier change to CLI bridge for the first time AND no consent
recorded yet: the existing NSAlert fires (unchanged from
`cloud-bridge-toggle.md`).

On tier change to anything else: no extra dialog. The picker is the
consent — the user is explicitly opting into a known posture.

### Modify: `leanring-buddy/CLAUDE.md` (== `AGENTS.md`)

Architecture-section update: replace the existing two-conformer
description in the **Planner** bullet with:

> The active planner is chosen by the user in Settings → Planner via
> `PacePlannerTier` (Local / CLI bridge / Direct API / Apple FM
> only). Default is `local` (LM Studio + qwen3-30b-a3b). The factory
> in `BuddyPlannerClient.swift` dispatches on tier. Direct API uses
> a BYO key stored in macOS Keychain via `PaceKeychainStore` —
> never UserDefaults, never a plist. While a non-Local tier is
> serving a turn, the menu-bar capsule tints amber via
> `isOffDeviceTurnInFlight`. See PRD:
> `docs/prds/planner-tier-picker.md`.

Add Key Files rows:

| File | Lines | Purpose |
|---|---|---|
| `DirectAPIPlannerClient.swift` | ~300 | BuddyPlannerClient conformer for BYO-key cloud endpoints (Anthropic / OpenAI / OpenRouter / Custom). OpenAI-compatible SSE streaming, Authorization header from PaceKeychainStore, per-call PaceAPIAuditLog entry, fail-loud on 401/quota unless `fallsBackToLocalOnCloudFailure` is on. |
| `PacePlannerTierStore.swift` | ~150 | Pure state module for the planner tier picker. PacePlannerTier enum, PaceDirectAPIProvider enum, configuration snapshot, UserDefaults persistence under `pace.planner.tier.` prefix. Does not touch keychain. |
| `PaceKeychainStore.swift` | ~120 | Minimal `kSecClassGenericPassword` wrapper. Service `com.pace.app.plannerAPIKeys`, account names `directAPI.<provider>.apiKey`. Never logs key material. `kSecAttrSynchronizable = false`, `kSecAttrAccessibleWhenUnlocked`. Only legal entry point for API keys in the codebase. |
| `PaceAPIAuditLog.swift` | ~80 | JSON-line audit log for every Direct API turn. Records provider + model + estimated token counts + turn UUID + timestamp. NEVER message content. Rolling file under Application Support; cap at 1MB then rotate. |

Update the Planner bullet to mention `PacePlannerTier.local`,
`.cliBridge`, `.directAPI`, `.appleFoundationModels`. Update the
local-mode setup table: replace `PlannerProvider=local|appleFoundationModels`
with a pointer to the tier picker, but keep the plist key as a
build-time override for power users (tier picker always wins at
runtime if both are set).

## Tier descriptions in PRD detail

### 1. Local (default)

Settings panel shows:
- "Local — LM Studio (qwen/qwen3-30b-a3b)"
- LM Studio reachability status row (existing)
- Estimated cost per turn: **free**
- Required setup: install LM Studio + load the configured model
- Privacy: "Nothing leaves your Mac."

Picking this tier is a no-op for existing users — same code path
they're on today.

### 2. CLI bridge (existing shipped feature)

Settings panel shows the existing cloud-bridge UI (mode picker,
upstream, model, revoke consent, reachability ping). Picking this
tier for the first time still triggers the existing NSAlert consent
dialog from `cloud-bridge-toggle.md`. No copy change to that dialog.

Estimated cost per turn: **free if user already has CLI auth;
otherwise see provider pricing.**

### 3. Direct API (BYO) — NEW

Settings panel shows provider picker, key field, model field, custom
URL field (conditional), fallback toggle, and Test button. Picking
this tier triggers a one-time NSAlert consent dialog:

> **Send your turns to a cloud model?**
>
> Direct API mode sends your transcript and the planner system
> prompt directly to the provider you choose, using an API key you
> paste here. The key is stored in your Mac's Keychain — never in
> Pace's preferences or any file on disk.
>
> Pace will tint the menu-bar capsule amber whenever a turn is being
> handled by the cloud, so you always know when something is leaving
> your Mac. Charges accrue on the provider's account associated with
> your key, not on Pace.
>
> You can switch back to Local any time in Settings → Planner.

Buttons: **Use Direct API** (default) / **Keep Local only**.

Rejection reverts the tier to `.local`. Acceptance is persistent —
the dialog does not re-fire on subsequent restarts.

### 4. Apple FM only

Settings panel shows the existing `SystemLanguageModel.default.availability`
status row and one of:
- "Apple Intelligence is enabled — using on-device 3B model" (green)
- "Apple Intelligence not enabled — open System Settings"
  (deeplink button) (yellow)
- "This Mac isn't eligible for Apple Intelligence" (red — Pace
  forces tier back to `.local` and shows a one-line note)

Estimated cost per turn: **free**. Privacy: "Nothing leaves your Mac."

Same `CompanionSystemPrompt` flows through Apple FM; the `@Generable`
typed-output envelope at `PaceFMTurnResponse.swift` continues to
shape the FM response.

## Provider presets for Direct API

The provider picker defaults to these endpoint URL templates. Each
preset hard-codes the OpenAI-compatible chat-completions path —
users do not edit the URL except for the `custom` provider.

| Provider | Endpoint URL | Default model id | Auth header |
|---|---|---|---|
| Anthropic | `https://api.anthropic.com/v1/chat/completions` | `claude-sonnet-4-5-20251001` | `x-api-key: <key>` + `anthropic-version: 2023-06-01` |
| OpenAI | `https://api.openai.com/v1/chat/completions` | `gpt-4o-mini` | `Authorization: Bearer <key>` |
| OpenRouter | `https://openrouter.ai/api/v1/chat/completions` | `anthropic/claude-sonnet-4` | `Authorization: Bearer <key>` |
| Custom | user-provided URL | user-provided | `Authorization: Bearer <key>` |

Custom URL rules (enforced by `validatedDirectAPIURL(from:)`):
- Must be `http://` only when host is loopback; otherwise `https://`
  required.
- Must be a complete URL including scheme and host.
- Path may be any path — Pace appends nothing. The user pastes the
  full `/v1/chat/completions`-equivalent endpoint.

Default model identifiers are advisory — the model field is a
free-form text input pre-filled with the provider default. Users who
want `gpt-4o` or `anthropic/claude-opus-4-7` can simply type it.

## "Test" round-trip button

Located in the Direct API tier panel. Clicking sends a single
synthetic turn:

```
system:  "You are a connectivity-test echo. Respond with the model
          identifier you are, in exactly one word."
user:    "hi"
```

with `max_tokens=8` (the minimum each provider accepts in practice).

Success:
- Shows green checkmark.
- Shows echoed first 60 chars of model response next to the
  checkmark (provider self-identification is the most actionable
  confirmation — "i'm claude-sonnet-4-5" is more useful than just
  "ok").
- Logs the test turn into `PaceAPIAuditLog` exactly like a real
  turn (same provider+model+tokens+turn-id record), tagged
  `kind=test`.

Failure:
- Shows red X.
- Shows the raw upstream error string verbatim — e.g.
  `"401 Unauthorized: invalid x-api-key"`, `"400 Bad Request:
  model 'claude-foo-7' does not exist"`, `"DNS failure: could not
  resolve api.anthropic.com"`. No translation, no friendly
  rewriting. Users debugging API issues need the exact upstream
  error to find it in provider docs.

The button is disabled when no key is stored for the current
provider (Save key first). It does NOT change the active planner
tier — it can be tested before committing the tier choice.

## Audit logging — `PaceAPIAuditLog.swift`

New file (~80 lines). Single-purpose: produce a privacy-respecting
record of every off-device call, so the user can audit egress.

Schema (one JSON object per line, appended to a rolling file under
`~/Library/Application Support/Pace/api-audit.jsonl`):

```json
{
  "ts": "2026-06-12T08:14:22.110Z",
  "turnId": "5C7E6F7E-...",
  "tier": "directAPI",
  "provider": "anthropic",
  "model": "claude-sonnet-4-5-20251001",
  "inputTokensApprox": 412,
  "outputTokensApprox": 87,
  "durationMs": 1834,
  "kind": "turn"
}
```

Rules:
- **Never** include `systemPrompt`, `userPrompt`,
  `conversationHistory`, or `responseText`. The audit log records
  the fact of egress, not the content.
- Token counts are estimated locally (the existing tokenizer
  heuristic Pace already uses for prompt-budget calculations is
  sufficient — exact provider counts are not the point).
- File rotates at 1MB → `api-audit.1.jsonl`, `api-audit.2.jsonl`,
  capped at 3 rotations. User can delete at any time; absence is
  not an error.
- Surfaced in Settings → Planner under a small "View audit log"
  button that opens the file in `Console.app` (or Finder reveal
  for users who'd rather inspect it themselves).
- CLI bridge calls log to the same file with `tier: "cliBridge"`
  (retrofit existing bridge call site to call into this log too —
  one extra line in `CloudBridgePlannerClient.generateResponseStreaming`).

Audit log is NOT a debugging log. The existing `print(…)` and
`PaceTelemetryLog` calls stay — they keep their normal verbose
content, including model output. The audit log is the user-facing
trust artifact.

## Acceptance criteria

- [ ] All existing tests still pass via `bash scripts/test-pace.sh`.
- [ ] First launch after upgrade keeps existing users on Local tier
      (no surprise prompt, no behavior change). Verified by
      `PacePlannerTierStoreTests.testFirstLaunchDefaultsToLocal`.
- [ ] Switching to Direct API with no key set surfaces a "no key
      stored" state and falls back to Local at the planner factory
      (no broken planner).
- [ ] Pasting a key, saving, hitting Test → green check + model echo
      against a fixture server.
- [ ] Pasting a bad key, saving, hitting Test → red X + verbatim
      "401" error string. No silent retry.
- [ ] `PaceKeychainStoreTests` confirms: store / load round-trip,
      overwrite-in-place, delete removes the entry, and
      `providersWithStoredKeys()` reflects current state.
- [ ] The Keychain entry has `kSecAttrSynchronizable = false` and
      uses the `com.pace.app.plannerAPIKeys` service identifier
      (verified by inspecting an entry via `security find-generic-password`
      in a manual smoke).
- [ ] During a Direct API call, the menu-bar capsule tints amber.
      During a Local-tier call, it does not.
- [ ] Audit log gets one new line per off-device call (Direct API
      AND CLI bridge), containing no message content.
- [ ] CLI bridge tier continues to work as it did before this PRD,
      including its 24-hour soak gate and consent dialog.
- [ ] CLAUDE.md / AGENTS.md updated with the architecture paragraph
      and the four new Key Files rows.

## Testing strategy

- **`PaceKeychainStoreTests`** — round-trip store/load/delete,
  overwrite in place, missing-account returns nil, multi-provider
  isolation (storing an Anthropic key does not affect the OpenAI
  account). These tests use a per-test service identifier suffix
  to avoid polluting the real Pace keychain.

- **`PacePlannerTierStoreTests`** — default tier on cold install is
  `.local`, persistence round-trip for every preference key,
  provider-default model identifiers match the table above, custom
  endpoint URL persists empty unless explicitly set.

- **`DirectAPIPlannerClientTests`** — against a new
  `scripts/direct-api-fixture-server.py` (mirror of
  `scripts/cloud-bridge-fixture-server.py`) that speaks the
  OpenAI-compatible SSE shape on a configurable port. Cases:
  - happy path (3 chunks + `[DONE]` → accumulated text)
  - 401 → `PaceDirectAPIError.invalidAPIKey`
  - 429 → `PaceDirectAPIError.httpError(statusCode: 429, …)`
  - malformed line → `.malformedSSEPayload`
  - empty stream → returns empty text without throwing (matches
    `LocalPlannerClient` behavior)
  - audit log records exactly one line per call

- **`DirectAPIPlannerClientHeaderTests`** — pure-Swift test that
  building the request for each provider produces the right
  Authorization header (`x-api-key` for Anthropic + version header,
  `Authorization: Bearer` for the others), without actually firing
  a request.

- **`PaceLocalEndpointGuardTests` additions** — `validatedDirectAPIURL`
  accepts `https://api.anthropic.com`, rejects `http://api.anthropic.com`
  (non-loopback over plaintext), accepts `http://localhost:8000` (local
  proxy testing), rejects scheme-less / host-less strings.

- **Manual smoke** (documented in SETUP_LOCAL.md):
  1. Settings → Planner → Direct API → pick Anthropic → paste real
     key → Save → Test → green check.
  2. Speak a normal turn — capsule tints amber while response
     streams.
  3. Tail `api-audit.jsonl` — one line with the right provider,
     model, and turn-id; no message content.

## Risks and mitigations

- **API key leakage** — mitigated by Keychain-only storage, no
  logging of key material, `kSecAttrSynchronizable = false`, and a
  per-PR grep gate that fails CI if any new file references
  UserDefaults for a key matching `*APIKey*`. (The gate is a
  follow-up task; this PRD does not block on it.)
- **Quota surprise** — mitigated by Test-button-first workflow, the
  amber-capsule indicator on every off-device turn, the audit log
  surfacing the call volume, and no auto-retry on 401/quota errors
  by default. The "fall back to local" toggle is opt-in.
- **Provider drift** — provider presets cap divergence (one URL +
  one default model per provider). When a provider deprecates a
  default model, Pace's only change is the default model identifier
  string in `PaceDirectAPIProvider.defaultModelIdentifier` — users
  who pinned a specific model are unaffected.
- **Custom-endpoint phishing** — the user might paste an attacker
  URL into the Custom provider. Mitigated by the https-only rule
  (loopback http excluded) — Pace cannot be coerced into sending an
  API key in plaintext to a non-loopback host.
- **Persona drift across tiers** — mitigated by the requirement
  that all four tiers consume the same `CompanionSystemPrompt`
  block. Enforced by routing all four conformers through the same
  factory and never letting any per-tier override into the planner
  protocol surface. The test
  `BuddyPlannerClientFactoryTests.testAllTiersReceiveIdenticalSystemPrompt`
  diffs the system prompt that each tier's `generateResponseStreaming`
  would receive given the same input — must be byte-identical.

## Implementation order

Small slices. Keychain first so every later slice has the storage
contract available.

1. **`PaceKeychainStore.swift` + `PaceKeychainStoreTests`** —
   smallest blast radius. Verify Keychain entries get created with
   the right attributes. No other file changes.
2. **`PacePlannerTierStore.swift` + `PacePlannerTierStoreTests`** —
   pure state; trivial unit tests.
3. **`PaceLocalEndpointGuard.validatedDirectAPIURL` extension** +
   tests. Self-contained guard change.
4. **`PaceAPIAuditLog.swift`** + tests. Pure JSONL appender.
5. **`DirectAPIPlannerClient.swift`** +
   `scripts/direct-api-fixture-server.py` + integration tests. This
   slice is the largest single file but is fully testable against
   the fixture.
6. **`BuddyPlannerClient.swift` factory update** — wire tier into
   the existing factory; old paths untouched when tier == `.local`.
7. **`CompanionManager.swift`** — published flags, setters, and the
   off-device-in-flight wrapper.
8. **`PaceMenuBarOverlay.swift`** — extend amber tint condition.
9. **`PaceSettingsWindow.swift`** — Planner tab restructure. Largest
   UI change; lands last so all wiring beneath it is already tested.
10. **`CLAUDE.md` / `AGENTS.md` updates** — architecture paragraph
    + four new Key Files rows. Update Local-mode setup table to
    point at the tier picker.
11. Retrofit the CLI bridge call site to write to `PaceAPIAuditLog`
    too (one line added to `CloudBridgePlannerClient`).
12. Run `bash scripts/test-pace.sh` — must end green.
13. Commit as a single feat commit. **Do not run release-pace.sh.**

## What NOT to do

- **No API key storage outside Keychain.** Not UserDefaults, not
  Info.plist, not Application Support, not a `.env`, not a log line,
  not a comment, not an exception message. The key is read into a
  local variable in `DirectAPIPlannerClient.generateResponseStreaming`,
  attached to the request, and dropped on stack exit. Nowhere else.
- **No silent tier switching.** Tier is changed only via the
  Settings picker or `setActivePlannerTier(_:)`. The planner never
  flips itself based on availability heuristics (with one bounded
  exception: missing-key-on-startup-for-directAPI falls back to
  local with a yellow status row — that is loud, not silent).
- **No breaking the existing Local default for upgraders.**
  `PacePlannerTierStore.loadConfiguration()` MUST return
  `tier=.local` when no key is set in UserDefaults. Verified by
  test.
- **No mixing the loopback guard with the cloud guard.** The two
  validators stay separate functions with separate names and
  separate test files. Conflating them is the single biggest
  exfiltration risk in this change.
- **No image input on Direct API in v1.** `supportsImageInput =
  false`. Adding it later is one config flag flip + a multi-part
  request body, but doing it in v1 expands the attack surface for
  no immediate user benefit (the local VLM already serializes the
  screen into text for the planner).
- **No `release-pace.sh`.** Commit only. The release pass is the
  user's call.

Where in code: `leanring-buddy/PacePlannerTierStore.swift` (tier enum + persistence),
`leanring-buddy/DirectAPIPlannerClient.swift` (BYO-key SSE client),
`leanring-buddy/PaceKeychainStore.swift` (Keychain wrapper),
`leanring-buddy/PaceLocalEndpointGuard.swift` (`validatedDirectAPIURL(from:)`),
factory dispatch in `leanring-buddy/BuddyPlannerClient.swift`.
