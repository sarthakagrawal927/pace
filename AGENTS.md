# Pace - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS menu-bar/notch surface (no dock icon, no main window). Clicking the black menu-bar/notch capsule opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it on-device via Apple's `SFSpeechRecognizer`, optionally analyses the cursor screen with a local VLM (LM Studio), and sends the transcript + element map to a local reasoner (LM Studio). The planner streams a response with optional `[POINT:...]`, grouped `<tool_calls>` JSON blocks, or legacy input-action tags (`[CLICK:...]`, `[TYPE:...]`, etc.); spoken text is played via `AVSpeechSynthesizer` and actions are posted via local macOS APIs.

**Fully on-device.** No cloud LLM, no cloud STT, no cloud TTS, no Cloudflare Worker call paths, and no cloud telemetry. Every byte stays on the user's Mac. This is the product's headline differentiator — speed + zero operating cost — and the architecture is built to protect it. One scoped exception: the `download_file` tool fetches a user-named http(s) URL into `~/Downloads` when the user explicitly asks — approval-gated, fetch-only, sends nothing. The privacy posture is now visibly surfaced in PaceMainWindow → Privacy (`PacePrivacyDashboardView`), which reads the existing local `PaceAPIAuditLog` JSONL — no new tracking — and renders a "0 bytes sent off this Mac" headline that turns into "X KB to <target>" the moment any off-device tier (cloud bridge, direct API) actually fires.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu-bar panel, notch capsule overlay, and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **Planner**: main screen/action planning uses the local OpenAI-compatible LM Studio reasoner (`qwen/qwen3-30b-a3b` MoE default — ~18.6 GB at Q4 but only 3B active params, so it runs roughly as fast as a dense 3B while reasoning at 30B scale). Chosen empirically: with `scripts/eval-planners.py`, qwen3-30b-a3b scored 15/15 on the FM-fixture set with 925ms mean latency, beating both Apple Foundation Models (13/15, 1555ms) and qwen3-14b (15/15, 2156ms). Pure-knowledge text-only turns prefer `AppleFoundationModelsPlannerClient` when Apple Intelligence is available, falling back to LM Studio otherwise, because short answers are latency-sensitive and do not need the larger action planner. Pair the LM Studio planner with the VLM in max-loaded-models=2 setting so neither evicts the other. `<think>…</think>` blocks stripped before TTS and action-tag parsing. No cloud LLM. **First-launch tier default (docs/prds/first-run-experience.md):** on a brand-new install with no `pace.planner.tier.` UserDefaults state at all, `PacePlannerTierStore.loadConfiguration()` checks `SystemLanguageModel.default.availability` and resolves to `.appleFoundationModels` when Apple Intelligence is available, `.local` otherwise. Apple FM is preferred for first-launch because it ships in-process with zero external install — the user can talk to Pace immediately without LM Studio. Existing users (anyone who has ever opened Settings → Planner) see ZERO behavior change: `hasAnyPlannerTierUserDefaultsState()` gates the new Apple-FM-first default behind a fresh-install check, so their pinned `.local` tier (or any other persisted value) loads exactly as before.
- **Speech-to-Text**: Apple **`SFSpeechRecognizer`** (on-device, `requiresOnDeviceRecognition=true`) is the default active provider — instant, no model download. `TranscriptionProvider=whisperKit` is accepted as a scaffolded local provider selection, but falls back to Apple Speech until the real WhisperKit streaming bridge lands. All cloud STT providers have been removed.
- **Text-to-Speech**: two on-device conformers of `BuddyTTSClient`. Default runtime path is **`LocalServerTTSClient`** — Kokoro-82M served by a loopback OpenAI-compatible `/v1/audio/speech` sidecar (`scripts/start-tts-server.sh`, mlx-audio on port 8880; ~150 ms warm synthesis per sentence; sentence N+1 renders while N plays). Endpoint is loopback-guarded; ANY sidecar failure falls back per-utterance to **`LocalTTSClient`** (`AVSpeechSynthesizer`, Premium > Enhanced > compact `LocalTTSVoiceIdentifier`), with a 30 s outage memo so a missing sidecar costs nothing. `TTSProvider=apple` opts out entirely. Cloud TTS has been removed.
- **Local Vision-Language Model (optional)**: LM Studio at `http://localhost:1234/v1` (OpenAI-compatible). When `UseLocalVLMForScreenContext=true`, the cursor-screen screenshot is sent to the local VLM (Qwen3-VL-8B by default) and its structured element map is prepended to the local planner prompt. Planner/VLM HTTP roots are guarded by `PaceLocalEndpointGuard` and must be loopback-only; remote or LAN hosts fall back to localhost instead of sending data off-machine. **VLM-skip heuristic** in `PaceTagParsers.transcriptIsLikelyScreenReferential` bypasses the call for pure-Q&A transcripts; override via `AlwaysRunLocalVLMRegardlessOfTranscript=true`.
- **Planner (`BuddyPlannerClient`)**: the active planner is chosen by the user in Settings → Planner via `PacePlannerTier` (Local / CLI bridge / Direct API / Apple FM). Default is `.local` (LM Studio + qwen3-30b-a3b) — existing users see zero behavior change on upgrade. `BuddyPlannerClientFactory.makeDefault()` dispatches on tier: `LocalPlannerClient` for `.local` and as a fallback for missing/invalid configs; `AppleFoundationModelsPlannerClient` for `.appleFoundationModels` (also the preferred fast pure-knowledge answer planner when Apple Intelligence is available); `CloudBridgePlannerClient` (existing) for `.cliBridge` with the same NSAlert consent + 24-hour soak gate; `DirectAPIPlannerClient` for `.directAPI` BYO-key turns. The same `CompanionSystemPrompt` flows through every tier so persona and tool dialect stay byte-identical. Direct-API keys live in macOS Keychain via `PaceKeychainStore` — never UserDefaults, never a plist, never a log line. While ANY non-Local tier is serving a turn, the menu-bar capsule tints amber via `isOffDeviceTurnInFlight`. Failures fail loud; the `directAPIFallsBackToLocalOnCloudFailure` opt-in toggle (default off) is the one path to silent fallback. See PRDs: `docs/prds/planner-tier-picker.md`, `docs/prds/cloud-bridge-toggle.md`.
- **Two-tier in-context memory**: every planner call carries the last K=4 turns verbatim (`PaceThreadMemory.verbatimWindow()`) AND a rolling summary of everything older (`injectionPrefix()`, rendered into the system prompt as `<conversation_so_far>...</conversation_so_far>`). The summary is refreshed by a detached Apple FM call after each turn via `PaceThreadSummarizer`; the user-facing path never blocks on summarization. Race-safety lives in a monotonic `summaryVersion` snapshot captured before each detached call, so out-of-order arrivals are dropped at `applySummaryUpdate`. In-session a 20-minute idle threshold still drops the live state (or Settings → Memory → Reset thread). The conversation now SURVIVES quit/relaunch: `PaceThreadMemory.snapshot(now:)`/`restore(from:)` are pure value-type accessors and `PaceThreadMemoryStore` persists a single on-device JSON (`~/Library/Application Support/Pace/thread-memory.json`, atomic write) after every turn/summary/reset; `CompanionManager.start()` rehydrates it. Policy is "resume always, until reset" — no staleness expiry; the file is wiped only on an explicit thread reset or when thread memory is disabled. The summary is still never journaled to `paceHistory` (only session id + lifecycle events are). Durable facts go through episodic memory instead. See PRD: `docs/prds/conversational-thread-memory.md`.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Voice Input UI**: Right-end sound animation in `PaceMenuBarOverlay.swift`; active voice turns show audio-reactive bars in the right icon slot, or static active-state bars when macOS Reduce Motion is enabled. The old cursor-local voice pill is retained as a reusable view but is not the active conversation surface.
- **Cursor**: Codex-style arrow (`CodexArrowShape`) with linear-gradient fill, white highlight stroke, dual shadow.
- **Element Pointing**: the planner embeds `[POINT:x,y:label:screenN]` tags in its response. The overlay parses these, maps coordinates to the correct monitor, and animates the cursor along a bezier arc to the target.
- **Action Layer (agent mode)**: the planner should prefer `<tool_calls>` JSON blocks where the outer array is sequential steps and each inner array is a parallel group. Tool metadata lives in `PaceToolRegistry` so prompt docs, aliases, and risk labels share one source of truth; the local registry validates at app startup so schema examples, aliases, and enum coverage cannot silently drift. Legacy tags are still accepted: `[CLICK:x,y]`, `[DOUBLE_CLICK:x,y]`, `[TYPE:text]`, `[KEY:cmd+s]`, `[SCROLL:up:3]`, `[OPEN_APP:Safari]`, `[OPEN_URL:https://example.com]`, `[MUSIC:play]`, `[VOLUME:up:2]`, `[BRIGHTNESS:down:3]`, `[CALENDAR:today]`, and `[REMINDER:send invoice]`. `PaceActionTagParser` extracts them; `CompanionManager` asks for user approval only for higher-risk non-undoable or external actions when the `Approve Risky Actions` preference is on, and the approval alert defaults to Cancel. Routine local actions such as click, scroll, window snap, app/URL open, media, volume, brightness, clipboard read, and undo can execute without the popup; blocking preflight issues still surface before execution. `PaceActionApproval` keeps the allow/cancel decision testable; `PaceActionExecutor` posts events after TTS playback starts. Single-clicks try `PaceAXTargeter` first (AX-tree press), falling back to CGEvent. AX set-value edits are logged in a session-local mutation log and can be restored with `Undo.last` / "undo that". App launch/URLs use `NSWorkspace`; volume, brightness, media, and clipboard reads use local macOS APIs; Calendar/Reminders use EventKit for reads and creation. Mail recipient names can resolve through Contacts before composing a draft. Finder/Notes/Mail/Things/Shortcuts/Messages have first-pass local integrations. `download_file` downloads a user-named http(s) URL into `~/Downloads` with URL validation, filename sanitization, and Finder-style collision suffixes — always approval-gated. Gated by `EnableActions=true` in Info.plist. Runtime smoke hooks are disabled unless `PACE_ENABLE_SMOKE_HOOKS=1`.
- **Trust surfaces (visible undo + reply replay + failure narration)**: every reversible mutation (`createNote`, `appendNote`, `createReminder`, `createCalendarEvent`, `composeMail`, `createThingsToDo`, `runShortcut`, `downloadFile`, `recordFlow`/`runFlow`, `setTextValue`/`editSelectedText`, `openMessages` with body, and generic `mcp`) raises a 5-second floating `PaceUndoBanner` next to the cursor; tapping it submits `Undo.last` through the executor. After every assistant turn finishes speaking, the notch panel renders a 30-second reply-replay button driven by the same post-processed string that flowed through TTS — replay does NOT re-stream the planner. Plain-language failures (planner offline, missing permission, click missed, sidecar TTS offline, MCP server not configured, cloud-bridge upstream error) are composed deterministically by `PaceFailureNarrator` (no LLM call) and routed through `PaceRestraintGate.decide(...)` so failure speech stays silent during a Zoom/active call. Reversibility uses the same set as `PaceActionApprovalPolicy.actionIsReversibleMutation` returns true for, and the click-missed narrator is wired to the all-fail click observation in `PaceActionExecutor`. See PRD `docs/prds/trust-and-failures.md`.
- **Recipe library**: Pace ships a small library of pre-built `PaceRecordedFlow` definitions ("recipes") under `Resources/recipes/<slug>.json` — morning-standup-setup, weekly-review-draft, email-zero, focus-mode-on, end-of-day-shutdown. Voice commands ("install the morning standup recipe") or the Settings → Flows tab copy a recipe into `PaceFlowStore` so the existing `run_flow` tool can execute it. `PaceRecipeLibrary` validates bundled JSON at startup via `PaceToolRegistry.validateForAppStartup`; `PaceRecipeCommandParser` routes install/uninstall/list voice commands before the planner. Recipes that need user state (e.g. preferred focus playlist) declare `requiredPreferences` and refuse install with a clear "set this preference first" message.
- **MCP Integration Layer**: broad external integrations should use OSS Model Context Protocol servers instead of being rebuilt inside Pace. `PaceMCPClient` loads stdio server definitions from `~/.config/pace/mcp-servers.json` or `~/.pace/mcp-servers.json`, accepts common `mcpServers` config shape, runs MCP `initialize` + `tools/call`, and returns observations through the same approval/result loop. Planner MCP calls use either `{"tool":"mcp","server":"altic","name":"notes_create","arguments":{...}}` or `{"tool":"notes_search","server":"altic","query":"..."}` for server-native names. Missing configured server names are surfaced by `PaceToolPreflight` before approval. The bridge speaks newline-delimited JSON-RPC and is validated end-to-end by `PaceMCPClientIntegrationTests` against the in-repo `scripts/mcp-fixture-server.py`; `mcp-servers.example.json` curates popular OSS servers (filesystem, fetch, github, applescript) as ready-made connectors. **Bundled one-tap catalog** (Settings → MCP): `PaceMCPServerCatalog` ships a fixed six-server list (filesystem, fetch, github, applescript, slack, linear) installable with a click. `PaceMCPCatalogInstaller.install/uninstall(_:into:)` performs an atomic JSON merge into `mcp-servers.json` — temp file + rename — that preserves every user-added entry. Catalog is bundled with each Pace release; no remote fetch of the server list at runtime.
- **Watch mode**: `PaceScreenWatchModeController` is the explicit watch-loop primitive. It samples screenshots, uses `PaceScreenImageDiffer`, and emits typed events only when a screen has meaningful visual change (`majorScreenChange`, `contentUpdate`, `focusedRegionChange`). The companion panel exposes a `Watch Mode` toggle, and explicit voice commands such as "watch my screen" / "stop watching" route through `PaceWatchModeCommandParser` before the planner. Watch events also journal into the local retrieval index (`PaceScreenWatchJournal`, source `screenWatchHistory`) so "what did I do today?" questions answer from local history.
- **Time understanding (journals)**: two passive retrieval sources power Dayflow-style recall. The screen watch journal records watch-mode events (timestamp, change category, frontmost app, cached VLM description when fresh) into day-per-screen documents; the app usage journal (`PaceAppUsageTracker` + `PaceAppUsageJournal`, source `appUsageHistory`) tracks foreground app minutes and switch counts through permission-free NSWorkspace notifications even when watch mode is off. Both keep 7 days, dedupe/cap entries, rehydrate across restarts, and honor per-source enable/clear in Settings.
- **Proactive features (opt-in)**: the menu-bar app exposes a small set of proactive surfaces gated by `PaceRestraintGate` (active-call check, proactive cooldown, intent confidence). Posture watch (`PacePostureMonitor`), focus-fatigue nudges, calendar pre-meeting nudges, watch-mode observation nudges, and the daily weekday **morning brief** (`PaceMorningTriageScheduler` + `PaceMorningBriefBuilder`) all default OFF and become inert until the user enables them in Settings. When restraint says "stay quiet" the morning brief is parked on a panel card so the user never misses it.
- **Deeplinks (`pace://`)**: external launchers (Raycast, Shortcuts) can trigger Pace via `pace://listen`, `pace://chat?text=...`, `pace://watch?enabled=true|false`, and `pace://panel`. `PaceDeepLinkParser` is a pure reject-on-ambiguity parser (500-char chat cap); commands are dropped unless the voice state is idle, and chat/listen turns run the normal intent/approval pipeline, so a deeplink can do nothing the user's own voice couldn't. URL types registered via `CFBundleURLTypes`; handled in `CompanionAppDelegate.application(_:open:)` with pre-launch buffering.
- **Intent routing**: `PaceIntentClassifier` is a tiny rule-based local classifier. It routes chitchat to a canned response, pure-knowledge to a text-only planner path, and labels screen-read, tool-action, phone-large-model, and unknown turns for the full pipeline.
- **Plan-act-observe loop**: `CompanionManager.sendTranscriptToPlannerWithScreenshot` runs a multi-step loop. Each step re-screenshots, re-invokes the VLM (heuristic permitting) and the planner, executes grouped tool calls/actions, returns tool observations to the next planner step, and continues until the planner emits `[DONE]`, emits no tool calls/action tags, or hits `AgentMaxSteps` (default 8).
- **Speculative planner race (first step only)**: on a screen-action / screen-description FIRST step, when `CompanionManager.speculativeRaceShouldFire` passes (race toggle on, local VLM configured, Apple FM available), `performFirstStepSpeculativePlannerRace` runs `PaceSpeculativePlannerRace.raceSpeculative`: the in-process Apple FM "lite" planner (transcript + thread-memory only, NO VLM) races the full VLM-fed planner. The full path's VLM+OCR+AX prep is deferred into the race's lazy builder so it runs concurrently with lite — lite produces audio in ~150 ms while a cold VLM (2–3 s) is still resolving. Whichever streams first wins TTS; the full path supersedes the lite stream if its first token lands within 500 ms / 60 spoken chars (`prepareForSupersedingStreamWithinTurn` resets the pipeline so the new stream replays cleanly). **Action parsing ALWAYS uses the full planner's complete text, never lite** — the lite path is spoken-feedback only and can't emit a real action; when lite wins the audio, the lite text becomes the spoken/bubble/memory string so `flushFinal` can't double-speak. `bothFailed` routes to `PaceFailureNarrator`. Gate false (and every multi-step turn) keeps the single-planner path byte-identical. Toggle: `PaceUserPreferencesStore.enableSpeculativePlannerRace` (default ON, opt-out in Settings → Planner).
- **Walking avatar (optional)**: `PaceAvatarOverlay` paints a small SwiftUI character at the bottom of the cursor screen in its own tiny `NSPanel`, but it is not attached at app launch. The default always-visible surface is the menu-bar/notch capsule.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: local-only no-op/timing-safe hooks via `PaceAnalytics.swift`; no cloud analytics SDK is linked.

### Local-mode setup

See `SETUP_LOCAL.md` for the full recipe. The complete Info.plist switch reference (local VLM / planner / TTS-sidecar / transcription-provider knobs and their defaults) lives in **[`docs/info-plist-switches.md`](docs/info-plist-switches.md)**.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: `PaceMenuBarOverlayManager` owns the visible black menu-bar/notch capsule in a top-level non-activating `NSPanel`. `MenuBarPanelManager` owns the floating companion panel and anchors it to the notch overlay frame, with a centered top-of-screen fallback for launch-time onboarding. No visible `NSStatusItem` is created. This gives full control over appearance and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Settings Window Pattern**: `PaceSettingsWindowManager` owns a normal titled `NSWindow` for configuration that has outgrown the notch panel: MCP server config, permissions, voice, preferences, memory, and action history. The notch panel keeps a gear button that opens this window. Pace still runs as `LSUIElement=true`; the settings window is AppKit-managed and explicitly activates the app when shown.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. Cursor flight, response text placement, and pointing animations render in this overlay via SwiftUI through `NSHostingView`; listening/thinking animation lives in the notch bar.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Transient Cursor Mode**: When "Show Pace" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

The per-file reference table (every source file, script, and bundled resource with line counts + purpose) is maintained in **[`docs/key-files.md`](docs/key-files.md)**. When you add, delete, or significantly resize a file, update that table per the Self-Update Instructions below.

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
