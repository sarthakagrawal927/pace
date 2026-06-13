---
Status: shipped (v0.3.11)
owner: future Pace-repo agent
priority: P0 — biggest blocker between "works for the builder" and "works for anyone"
---

# PRD — First-Run Experience (default planner + discovery)

## Goal

A first-time user installs Pace and within five minutes:

1. Hears Pace respond to push-to-talk — without installing LM Studio first.
2. Knows what to ask (3-5 concrete starter prompts visible somewhere).
3. Knows what Pace can actually do (a complete, source-of-truth skill list).

Today none of those hold. The user opens Pace, presses PTT, gets silence (because LM Studio isn't installed) and has no surface that tells them what Pace can do anyway.

## Three changes, one PRD

These changes are coupled — each amplifies the others. Splitting them would ship a confusing first-run.

### Change 1 — Apple FM is the default planner (no external install)

Today `PacePlannerTier` defaults to `.local` (LM Studio). For a first-run user with nothing installed, that immediately breaks. Flip the default so on a clean install with no UserDefaults state, the tier resolves to `.appleFoundationModels`.

- If Apple Intelligence is available on the device (macOS 15+ on Apple Silicon with FM enabled), `AppleFoundationModelsPlannerClient` becomes the active planner.
- If Apple Intelligence is NOT available, fall back to a clearly-labeled "no planner configured" status surface that explains the situation and points to the Settings → Planner tier picker (which now becomes the natural upgrade path).
- Users with existing UserDefaults state (existing installs) see ZERO behavior change — they keep `.local` because their key is already set.

**Implementation note:** `PacePlannerTierStore.loadConfiguration()` already reads from UserDefaults and falls back to a default. Change the default branch to detect Apple Intelligence availability and pick `.appleFoundationModels` when available, `.local` otherwise. The actual planner construction in `BuddyPlannerClientFactory` should already route correctly because all four tiers exist.

**Settings UX:**
- Settings → Planner header shows the active tier with one of three states: "Apple Foundation Models (in-process, no install)" / "Local — LM Studio at <url>" / "Direct API / CLI bridge" — each with a one-line description of latency + quality trade-off.
- A small "Upgrade to Local for better quality" prompt appears under the FM row when LM Studio is detectable but not yet selected, with a single button that opens Settings → Planner with `.local` pre-selected.

### Change 2 — "Try these" starter panel

A first-run-only panel in the notch dropdown (shown for the first 24 hours after onboarding completion) with 6 starter prompts. Each prompt is one-tap "speak this for me" — clicking it submits the text through the same `submitChatTranscriptFromDeepLink(_:)` hook the deeplink + chat surface use, so it's a real turn through the planner.

**The 6 starter prompts (deterministic, no LLM call to generate):**

| Slot | Prompt | Why this one |
|---|---|---|
| 1 | "what's on my calendar today?" | Exercises Calendar retrieval — the most common first ask. |
| 2 | "set a five minute timer" | Exercises the `start_timer` tool — fastest "wow" moment. |
| 3 | "open Safari to anthropic.com" | Exercises action layer — shows Pace can *do* not just *say*. |
| 4 | "what's on my screen right now?" | Exercises VLM + OCR — shows screen awareness. |
| 5 | "remember that I prefer Safari as my browser" | Teaches the user that Pace has memory. |
| 6 | "what did I do today?" | Exercises retrieval over app-usage + screen-watch journals. |

Each row shows the prompt text + a small "ask" button. Tapping submits the prompt. After tapping, the prompt is checked off (visually) — so the user knows what they've already tried. State persists in UserDefaults under `pace.firstRun.starterPromptsTriedAt` (a dictionary keyed by prompt slug).

Auto-dismisses after 24h OR when the user has tried at least 4 of the 6. Settings → "Show starter prompts again" un-dismisses.

### Change 3 — Skills tab in PaceMainWindow

A new "Skills" sidebar entry in `PaceMainWindow` showing every tool Pace can run, generated from `PaceToolRegistry.localTools` + `PaceMCPClient` configured servers. Single source of truth — drift-proof by construction.

Layout: searchable table. Columns: Skill name (from `canonicalName`), what it does (from `description`), example utterance (NEW — see below), risk level (from `riskLevel.displayName`).

The "example utterance" column is the ONE addition to existing data. Add a new field `exampleUtterance: String` to `PaceLocalToolDefinition`, populated for every tool. Examples:
- `click` → "click the Save button"
- `start_timer` → "set a 5 minute timer for tea"
- `mail` → "draft an email to Alex saying I'll be late"
- `calendar` → "what's on my calendar this week"
- `download_file` → "download the report at example.com/report.pdf"
- (and so on for every kind)

Bundled v10 registry JSON gets the same field. Startup validation requires non-empty example utterances for every tool — drift between Skills tab and reality is forbidden.

MCP servers from `~/.config/pace/mcp-servers.json` appear below local tools, grouped by server. Each MCP tool shows the server name + tool name + description (from the MCP `tools/list` if the server is alive at Skills-tab open time, else a "server not running" placeholder).

## Scope (out for v1)

- Onboarding flow rewrite. Keep the existing 3-permission onboarding; this PRD adds surfaces AFTER onboarding completes.
- A bundled in-process Qwen3-4B (`MLX-swift`). Tempting, but big binary + first-launch download UX is its own PRD. Apple FM is the right v1 default precisely because it has zero install cost.
- Telemetry on which starter prompts users try most. No telemetry, period — Pace's no-cloud principle. The local UserDefaults state is the only thing tracked, and only for the dismissal logic.

## Architecture

### Modify: `leanring-buddy/PacePlannerTierStore.swift`

- `loadConfiguration()` default tier logic: detect Apple Intelligence availability via `SystemLanguageModel.default.availability` (already used by `AppleFoundationModelsPlannerClient` — read it for the pattern). Cache the answer for the session.
- New static `defaultTierForFirstLaunch(appleIntelligenceAvailable:) -> PacePlannerTier` — pure function, testable.

### Modify: `leanring-buddy/BuddyPlannerClient.swift`

`BuddyPlannerClientFactory.makeDefault()` already dispatches on tier. The only change is that `appleFoundationModels` is now the default-default. No new conformer needed.

### New file: `leanring-buddy/PaceStarterPromptCatalog.swift` (~120 lines)

Pure module. Holds the 6 prompt structs (slug, displayText, suggestedCategoryHint), exposes `PaceStarterPromptStore` (UserDefaults persistence: tried-at timestamps, dismissed-at timestamp, helper `isVisible(now:) -> Bool`). No UI here — view code reads the store.

### Modify: `leanring-buddy/CompanionPanelView.swift`

Add a starter-prompt card at the TOP of the panel, shown only when `PaceStarterPromptStore.isVisible(now:)` returns true. Render: 6 rows, each with text + "ask" button + checkmark when tried. A small "Hide for now" link in the corner sets the dismissed-at timestamp.

The "ask" button calls `companionManager.submitChatTranscriptFromDeepLink(_:)` with the prompt text. After submission, the store gets `markTried(slug:)`.

### Modify: `leanring-buddy/PaceToolRegistry.swift`

- Add `exampleUtterance: String` to `PaceLocalToolDefinition`.
- Fill in an utterance for every existing tool.
- Startup validation: require non-empty utterance for every tool.

### Modify: `leanring-buddy/Resources/v10-actions/registry.json`

Add `exampleUtterance` to every action entry. The startup validator already drift-checks this artifact against `localTools`; update both together.

### New file: `leanring-buddy/PaceSkillsView.swift` (~200 lines)

SwiftUI view rendered as a new sidebar entry in `PaceMainWindow`. Reads:
- `PaceToolRegistry.localTools` for local skills.
- `PaceMCPClient.configuredServers()` + a probe of each server's `tools/list` for MCP skills.

Searchable. Per-row: copy-to-clipboard for the example utterance.

### Modify: `leanring-buddy/PaceMainView.swift`

Add `case skills` to the sidebar selection enum + the corresponding view rendering. Sidebar label: "Skills" with an SF Symbol like `square.grid.2x2`.

### Modify: `leanring-buddy/PaceSettingsWindow.swift`

In the Planner tab, restructure the "active tier" surface to show the three planner states explicitly. Add an "Upgrade to Local" prompt under the FM row when applicable.

### Modify: `AGENTS.md`

- Add Key Files rows for `PaceStarterPromptCatalog.swift` and `PaceSkillsView.swift`.
- Update the Planner architecture section: "Default tier on clean install is `appleFoundationModels` when Apple Intelligence is available, `local` otherwise. Existing users see no behavior change because their UserDefaults already pins a tier."

## Acceptance criteria

- [ ] All existing tests pass + new tests cover: starter-prompt visibility windowing (24h dismissal), tried-set persistence, Apple-FM-default-on-clean-install resolution.
- [ ] Fresh install with no UserDefaults state + Apple Intelligence available → planner tier resolves to `.appleFoundationModels`.
- [ ] Fresh install with no UserDefaults state + Apple Intelligence unavailable → planner tier resolves to `.local`, Settings shows "no planner configured" status with the upgrade path.
- [ ] Existing install (UserDefaults already populated) → no tier change.
- [ ] Notch panel shows the starter-prompt card for the first 24h after onboarding.
- [ ] Tapping a starter prompt submits the turn through the same path as voice/chat — TTS plays, response renders.
- [ ] After 4+ prompts tried, the card auto-dismisses.
- [ ] Skills tab in PaceMainWindow renders every local tool + every configured MCP server's tools with example utterances.
- [ ] Startup validation rejects a tool definition with an empty `exampleUtterance`.
- [ ] `bash scripts/test-pace.sh` ends green (modulo the pre-existing cloud-bridge consent flake).

## Testing strategy

- `PaceStarterPromptStoreTests` — pure state; tried-set persistence, 24h dismissal, 4-of-6 auto-dismiss.
- `PacePlannerTierStoreTests` — extend with the new default-resolution function (mock the Apple-Intelligence availability bool).
- `PaceToolRegistryTests` — extend with the new validation for non-empty `exampleUtterance` (one fixture with empty utterance must produce a validation issue).
- Manual smoke: fresh defaults → open PaceMainWindow → see Skills tab populated; open notch panel → see starter card.

## Risks

- **Apple FM is meaningfully worse on hard action plans.** Mitigation: it's the default for first-launch only. The "Upgrade to Local" prompt is one click away. Users who don't care about complex actions stay on FM forever — that's fine.
- **Apple FM availability gating is platform-version-dependent.** Read availability via `SystemLanguageModel.default.availability`, not by checking macOS version directly. Pace already calls this elsewhere.
- **Starter prompts could become stale.** They're hardcoded; we should re-evaluate every release. Acceptable for v1.
- **Skills tab is wide.** MCP servers' tool counts vary. Cap rendering at 100 tools per server with "show more" link.

## Implementation order

1. `PaceStarterPromptCatalog.swift` + tests.
2. `exampleUtterance` field on `PaceLocalToolDefinition`, fill all entries, update bundled JSON, extend startup validation.
3. `PaceSkillsView.swift` + sidebar wiring in `PaceMainView.swift`.
4. Default-planner-tier resolution change.
5. Notch-panel starter card.
6. Settings → Planner status restructure.
7. AGENTS.md update.
8. `bash scripts/test-pace.sh` green. Commit. Do NOT release.

## What NOT to do

- Don't change behavior for existing users. Default-tier logic must check "is there ANY existing UserDefaults state under `pace.planner.tier.`?" before applying the new default.
- Don't bundle a model file in v1. The Apple FM path is the right starting point.
- Don't add telemetry to track starter-prompt usage. Local state only.
- Don't merge Skills tab into the existing Conversations tab. New sidebar entry.

Where in code: `leanring-buddy/PacePlannerTierStore.swift`
(`hasAnyPlannerTierUserDefaultsState()` + `defaultTierForFirstLaunch(...)`),
`leanring-buddy/PaceStarterPromptCatalog.swift` (6-prompt deterministic catalog),
`leanring-buddy/PaceSkillsView.swift` (PaceMainWindow sidebar tab),
`exampleUtterance` field validated in `leanring-buddy/PaceToolRegistry.swift`.
