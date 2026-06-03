# Pace - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS menu-bar/notch surface (no dock icon, no main window). Clicking the black menu-bar/notch capsule opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it on-device via Apple's `SFSpeechRecognizer`, optionally analyses the cursor screen with a local VLM (LM Studio), and sends the transcript + element map to a local reasoner (LM Studio). The planner streams a response with optional `[POINT:...]`, grouped `<tool_calls>` JSON blocks, or legacy input-action tags (`[CLICK:...]`, `[TYPE:...]`, etc.); spoken text is played via `AVSpeechSynthesizer` and actions are posted via local macOS APIs.

**Fully on-device.** No cloud LLM, no cloud STT, no cloud TTS, no Cloudflare Worker call paths. Every byte stays on the user's Mac. This is the product's headline differentiator — speed + zero operating cost — and the architecture is built to protect it.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu-bar panel, notch capsule overlay, and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **Planner**: local OpenAI-compatible reasoner via LM Studio (`qwen/qwen3-30b-a3b` MoE default — ~18.6 GB at Q4 but only 3B active params, so it runs roughly as fast as a dense 3B while reasoning at 30B scale). Chosen empirically: with `scripts/eval-planners.py`, qwen3-30b-a3b scored 15/15 on the FM-fixture set with 925ms mean latency, beating both Apple Foundation Models (13/15, 1555ms) and qwen3-14b (15/15, 2156ms). Pair with the VLM in LM Studio's max-loaded-models=2 setting so neither evicts the other. `<think>…</think>` blocks stripped before TTS and action-tag parsing. No cloud LLM.
- **Speech-to-Text**: Apple **`SFSpeechRecognizer`** (on-device, `requiresOnDeviceRecognition=true`) — instant, no model download. All cloud STT providers have been removed.
- **Text-to-Speech**: On-device **`AVSpeechSynthesizer`** via `LocalTTSClient` — the only `BuddyTTSClient` conformer. Auto-prefers Premium > Enhanced > Default English voices, then uses the configured compact fallback (`LocalTTSVoiceIdentifier`, currently Rishi on this Mac) with softened rate/pitch/volume prosody. The panel shows active voice quality and whether a better Apple voice should be installed. Cloud TTS has been removed.
- **Local Vision-Language Model (optional)**: LM Studio at `http://localhost:1234/v1` (OpenAI-compatible). When `UseLocalVLMForScreenContext=true`, the cursor-screen screenshot is sent to the local VLM (Qwen3-VL-8B by default) and its structured element map is prepended to the planner prompt. Wraps the existing cloud path — falls back silently on error. **VLM-skip heuristic** in `PaceTagParsers.transcriptIsLikelyScreenReferential` bypasses the call for pure-Q&A transcripts; override via `AlwaysRunLocalVLMRegardlessOfTranscript=true`.
- **Planner (`BuddyPlannerClient`)**: two conformers ship today. `LocalPlannerClient` (the runtime default per Info.plist `PlannerProvider=local`) — a text-only OpenAI-compatible streaming client pointing at LM Studio. `AppleFoundationModelsPlannerClient` — uses Apple's on-device FM-3B with the `@Generable` typed-output path (`PaceFMTurnResponse`); opt-in via `PlannerProvider=appleFoundationModels`. Empirically Foundation Models is faster on cold-start (in-process, no HTTP) but loses on the harder fixtures, so the runtime default went back to LM Studio. The protocol shape stays so an alternate local runtime (Ollama, raw llama.cpp, MLX-swift in-process) can plug in via a new conformer. No cloud LLM.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Voice Input UI**: Right-end sound animation in `PaceMenuBarOverlay.swift`; active voice turns show audio-reactive bars in the right icon slot. The old cursor-local voice pill is retained as a reusable view but is not the active conversation surface.
- **Cursor**: Codex-style arrow (`CodexArrowShape`) with linear-gradient fill, white highlight stroke, dual shadow.
- **Element Pointing**: the planner embeds `[POINT:x,y:label:screenN]` tags in its response. The overlay parses these, maps coordinates to the correct monitor, and animates the cursor along a bezier arc to the target.
- **Action Layer (agent mode)**: the planner should prefer `<tool_calls>` JSON blocks where the outer array is sequential steps and each inner array is a parallel group. Tool metadata lives in `PaceToolRegistry` so prompt docs, aliases, risk labels, and future MCP bridging share one source of truth. Legacy tags are still accepted: `[CLICK:x,y]`, `[DOUBLE_CLICK:x,y]`, `[TYPE:text]`, `[KEY:cmd+s]`, `[SCROLL:up:3]`, `[OPEN_APP:Safari]`, `[OPEN_URL:https://example.com]`, `[MUSIC:play]`, `[VOLUME:up:2]`, `[BRIGHTNESS:down:3]`, `[CALENDAR:today]`, and `[REMINDER:send invoice]`. `PaceActionTagParser` extracts them; `CompanionManager` asks for user approval when the `Approve Actions` preference is on; `PaceActionApproval` keeps the allow/cancel decision testable; `PaceActionExecutor` posts events after TTS playback starts. Single-clicks try `PaceAXTargeter` first (AX-tree press), falling back to CGEvent. App launch/URLs use `NSWorkspace`; volume, brightness, and media use local macOS APIs; Calendar/Reminders use EventKit. Finder/Notes/Mail/Things/Shortcuts/Messages have first-pass local integrations. Gated by `EnableActions=true` in Info.plist. Runtime smoke hooks are disabled unless `PACE_ENABLE_SMOKE_HOOKS=1`.
- **Watch mode**: `PaceScreenWatchModeController` is the explicit watch-loop primitive. It samples screenshots, uses `PaceScreenImageDiffer`, and emits typed events only when a screen has meaningful visual change (`majorScreenChange`, `contentUpdate`, `focusedRegionChange`). The companion panel exposes a `Watch Mode` toggle, and explicit voice commands such as "watch my screen" / "stop watching" route through `PaceWatchModeCommandParser` before the planner.
- **Intent routing**: `PaceIntentClassifier` is a tiny rule-based local classifier. It routes chitchat to a canned response, pure-knowledge to a text-only planner path, and labels screen-read, tool-action, phone-large-model, and unknown turns for the full pipeline.
- **Plan-act-observe loop**: `CompanionManager.sendTranscriptToPlannerWithScreenshot` runs a multi-step loop. Each step re-screenshots, re-invokes the VLM (heuristic permitting) and the planner, executes grouped tool calls/actions, returns tool observations to the next planner step, and continues until the planner emits `[DONE]`, emits no tool calls/action tags, or hits `AgentMaxSteps` (default 8).
- **Walking avatar (optional)**: `PaceAvatarOverlay` paints a small SwiftUI character at the bottom of the cursor screen in its own tiny `NSPanel`, but it is not attached at app launch. The default always-visible surface is the menu-bar/notch capsule.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `PaceAnalytics.swift`

### Local-mode setup

See `SETUP_LOCAL.md` for the full recipe. Summary of the Info.plist switches:

| Key | Default | Effect when changed |
|---|---|---|
| `UseLocalVLMForScreenContext` | `true` | `false` to skip the VLM call and send the raw transcript to the planner. |
| `LocalVLMBaseURL` | `http://localhost:1234/v1` | OpenAI-compatible root for the local VLM |
| `LocalVLMModelIdentifier` | `ui-venus-1.5-2b` | Must match the model name loaded in LM Studio. 2B GUI specialist; the OCR layer fills in text fidelity the smaller model would miss. |
| `AlwaysRunLocalVLMRegardlessOfTranscript` | `false` | `true` → bypass the VLM-skip heuristic, run VLM on every turn |
| `LocalPlannerBaseURL` | `http://localhost:1234/v1` | OpenAI-compatible root for the local reasoner |
| `LocalPlannerModelIdentifier` | `qwen/qwen3-30b-a3b` | Must match the model name loaded in LM Studio for the planner role. 30B MoE with 3B active params is the eval-validated default; swap down to `qwen/qwen3-14b` (dense) or `qwen3-4b-instruct` for tighter RAM, or `gpt-oss-20b` to A/B against another dense model. |
| `EnableActions` | `true` | `false` → parse action tags but do not execute local macOS actions. Keep `Approve Actions` on when this is true. |
| `AgentMaxSteps` | `8` | Per-task ceiling for the plan-act-observe loop. `1` disables multi-step (loop exits after first response). |
| `PushToTalkShortcut` | `controlOption` | One of `controlOption`, `shiftFunction`, `shiftControl`, `controlOptionSpace`, `shiftControlSpace`. Swap if another global dictation tool (e.g. Wispr Flow) is on the same key. |

### Key Architecture Decisions

**Menu Bar Panel Pattern**: `PaceMenuBarOverlayManager` owns the visible black menu-bar/notch capsule in a top-level non-activating `NSPanel`. `MenuBarPanelManager` owns the floating companion panel and anchors it to the notch overlay frame, with a centered top-of-screen fallback for launch-time onboarding. No visible `NSStatusItem` is created. This gives full control over appearance and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. Cursor flight, response text placement, and pointing animations render in this overlay via SwiftUI through `NSHostingView`; listening/thinking animation lives in the notch bar.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Transient Cursor Mode**: When "Show Pace" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~147 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager`, `PaceMenuBarOverlayManager`, starts `CompanionManager`, and optionally installs runtime smoke hooks when `PACE_ENABLE_SMOKE_HOOKS=1`. No main window — the app lives entirely in menu-bar/notch surfaces. |
| `CompanionManager.swift` | ~2069 | Central state machine. Owns dictation, shortcut monitoring, screen capture, the active `BuddyPlannerClient`, the active `BuddyTTSClient`, the `LocalVLMClient`, the `PaceActionExecutor`, the `PaceVisionOCRClient`, the screen-context pre-warm task, the per-screen analysis cache, action approval, intent routing, watch-mode state, permission preflight state, recent action results, local-memory command routing, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, and cursor visibility. Coordinates the full push-to-talk → optional text-only/watch-mode/local-memory fast path → screenshot → (optional local VLM + OCR) → local planner → streaming TTS → optional approval → optional action execution → pointing pipeline. **Still oversized** — the agent loop body (~250 lines) and the screen-context service (~300 lines) are the next two splits. |
| `CompanionSystemPrompt.swift` | ~149 | The system prompt sent to the local planner on every turn. Extracted to its own file because it's a behavior contract — small wording changes here change end-to-end behavior, so it deserves its own diff-able artifact. Generates the available local-tool docs from `PaceToolRegistry`. |
| `PaceTagParsers.swift` | ~175 | Pure isolation-free parsers for the inline tag dialect the planner emits: `[POINT:x,y]`, `[DONE]`, the `transcriptIsLikelyScreenReferential` keyword heuristic, and `readMaxAgentStepCount`. Extracted from `CompanionManager` so each parser is unit-testable in isolation. The `PointingParseResult` struct also lives here. |
| `PaceUserPreferencesStore.swift` | ~60 | Typed key namespace + load/save helpers for boolean user preferences (`useLocalVLMForScreenContext`, `isWalkingAvatarEnabled`, `isPaceCursorEnabled`, `areCursorAnnotationsEnabled`, `requiresActionApproval`). Replaces hand-rolled `UserDefaults` patterns with stringly-typed keys. `@Published` properties still live on `CompanionManager`; this owns only the storage layer. |
| `PaceCursorShape.swift` | ~50 | `CodexArrowShape` — the SwiftUI `Shape` Pace renders as its on-screen cursor. Extracted from `OverlayWindow.swift` so the shape can be reused without dragging the whole overlay machinery along. |
| `PaceOverlayPillViews.swift` | ~155 | Reusable SwiftUI voice-state views (`WhisperFlowVoicePillView`, `BlueCursorSpinnerView`) retained for future cursor modes. The active conversation indicator now lives in `PaceMenuBarOverlay.swift`. |
| `DesignSystemButtonStyles.swift` | ~480 | The seven `DS*ButtonStyle` conformers (Primary / Secondary / Tertiary / Text / Outlined / Destructive / Icon). Pulled out of `DesignSystem.swift` so the tokens-and-namespace file stays focused. All styles share three rules — pointer cursor on hover, 0.97 scale on press, state colours from `DS.Colors`. |
| `MenuBarPanelManager.swift` | ~223 | Custom NSPanel lifecycle for the floating companion panel. Manages show/hide/position, anchors to the menu-bar overlay frame, exposes gated smoke-test show/hide hooks, and installs click-outside-to-dismiss monitor. Does not create a visible status item. |
| `PaceMenuBarOverlay.swift` | ~468 | Top menu-bar/notch `NSPanel` capsule that visually extends the MacBook notch. Uses a flat top edge with rounded lower corners, shows one fixed-width generic icon slot on each side, runs a right-side sound animation for voice turns, and toggles the existing companion panel when tapped. |
| `CompanionPanelView.swift` | ~1052 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, local model status, TTS voice quality, read-screen toggle, cursor annotation toggle, action approval toggle, watch-mode toggle, core permission rows, local-tool permission preflight rows, recent action results, local memory summary, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~741 | Full-screen transparent overlay hosting the blue cursor and response placement. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `PaceScreenImageDiffer.swift` | ~105 | Cheap image-diff gate for screen captures. Downsamples screenshots into grayscale fingerprints and reports mean pixel delta + changed-pixel ratio so Pace can reuse cached screen analysis when only trivial visual noise changed. |
| `PaceScreenWatchMode.swift` | ~173 | Explicit watch-mode primitive. Samples all screens at an interval, compares fingerprints, throttles repeated changes, classifies meaningful changes as major/content/focused-region events, and emits them for panel/voice watch mode. |
| `PaceWatchModeCommandParser.swift` | ~71 | Pure parser for explicit watch-mode voice commands. Routes start/stop phrases before the planner so mode changes stay local and cheap. |
| `PaceIntentClassifier.swift` | ~221 | Rule-based local classifier for routing turns into chitchat, pure knowledge, screen description, screen action, phone-large-model, or unknown. Pure-knowledge turns skip screen capture and use the text-only planner path. |
| `PacePushToTalkManager.swift` | ~899 | Push-to-talk voice pipeline (previously `BuddyDictationManager`). Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~50 | Protocol surface and provider factory for voice transcription backends. Today only `AppleSpeechTranscriptionProvider` ships; protocol stays generic so an alternate backend (WhisperKit, MLX-Whisper) can drop in as a sibling conformer. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Default on-device transcription provider backed by Apple's Speech framework (`SFSpeechRecognizer` with `requiresOnDeviceRecognition=true`). |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `LocalVLMClient.swift` | ~280 | OpenAI-compatible HTTP client for a local vision-language model (LM Studio by default at `http://localhost:1234/v1`). Sends one screenshot + structured prompt, parses a `LocalVLMScreenAnalysis` (description + element list with bboxes, roles, text). Falls back to regex JSON extraction when the model strays from strict JSON. |
| `PaceVisionOCRClient.swift` | ~210 | Apple Vision `VNRecognizeTextRequest` wrapper. Returns `[RecognizedTextBox]` in screenshot pixel space. `PaceScreenContextMerger.enrich` fuses VLM elements with OCR text by bbox overlap (>50%), appending up to 30 orphan OCR boxes as `static_text` elements. Lets the 2B VLM stay fast while the OCR layer guarantees verbatim text fidelity. |
| `BuddyPlannerClient.swift` | ~55 | Protocol the active planner conforms to (`generateResponseStreaming`, `displayName`, `supportsImageInput`) + factory that returns the configured planner. Today only `LocalPlannerClient` conforms; a `ClaudeAPI` conformer was removed when the project committed to no-cloud-LLM. |
| `LocalPlannerClient.swift` | ~230 | Text-only OpenAI-compatible chat-completions client for a local reasoner. SSE streaming, parses `choices[0].delta.content`. Discards images (logs a notice) — relies on upstream VLM element map being prepended to `userPrompt`. Defensive `stripThinkingBlocks` helper removes `<think>…</think>` from streamed content for thinking-mode models. |
| `BuddyTTSClient.swift` | ~30 | Protocol the active TTS conforms to (`speakText`, `isPlaying`, `stopPlayback`) + trivial factory returning `LocalTTSClient`. Protocol kept so a future on-device runtime (Kokoro/Piper-MLX) can plug in without touching `CompanionManager`. |
| `LocalTTSClient.swift` | ~226 | On-device TTS via `AVSpeechSynthesizer`. The sole `BuddyTTSClient` conformer. Uses `PaceTTSVoiceResolver`, applies Info.plist voice/prosody tuning for rate/pitch/volume/delays, and maintains its own `isCurrentlySpeakingOrPending` flag so the CompanionManager poll-loop sees playback as active from the moment `speak()` is invoked. Hops to MainActor inside the delegate callback. |
| `PaceTTSVoiceResolver.swift` | ~91 | Shared TTS voice selection and panel summary. Premium/Enhanced Apple voices win even when a compact fallback voice is configured, so installing a better voice automatically upgrades playback on restart. |
| `StreamingSentenceTTSPipeline.swift` | ~276 | Consumes planner streamed text and dispatches complete sentences to TTS as they arrive, instead of waiting for the full response. Cuts perceived time-to-first-spoken-word from ~3s to ~500ms. Strips `<think>` blocks + `<tool_calls>` + action tags + `[POINT]` before sentence segmentation. Owns `markIntentCommitted()` + TTFSW logging — called from `CompanionManager` at PTT-release. |
| `PaceTelemetryLog.swift` | ~50 | Single `os.Logger` (subsystem `com.pace.app`, category `metrics`) for performance metrics. Emits `TTFSW=NNNms` and `TTFT=NNNms` to the macOS unified log alongside the existing `print(…)` calls, so `scripts/benchmark_ttfsw.sh` can aggregate per-turn latency without scraping the Xcode console. |
| `PaceActionApproval.swift` | ~53 | Pure approval-gate helper for action execution. Builds popup copy from the risk-labelled action summary and makes allow-once vs cancel behavior unit-testable without posting real Mac actions. |
| `PaceRuntimeSmokeTestHooks.swift` | ~93 | Disabled-by-default DistributedNotificationCenter hooks for app-level smoke tests. Activated only by `PACE_ENABLE_SMOKE_HOOKS=1`; verifies panel show/hide, cursor annotation state, and real approval-popup cancellation without fragile coordinate clicks. |
| `PaceToolRegistry.swift` | ~325 | Typed local tool catalog. Defines canonical names, aliases, schema examples, descriptions, risk levels, execution summaries, observation summaries, and planner prompt generation. Notes supports create/append/search actions through the same registry entry. Future MCP-backed tools should bridge through this registry. |
| `PaceActionExecutor.swift` | ~1961 | Local action execution layer with screenshot-pixel → CG-global coordinate conversion (mirrors the pointing logic in CompanionManager). Single-clicks try `PaceAXTargeter` first; falls back to CGEvent. Also defines `PaceActionTagParser`, grouped `PaceActionExecutionPlan`, approval summaries, and tool-observation types that feed planner turns plus fallback user feedback. Parses `<tool_calls>` JSON plus legacy tags for clicks, typing, keys, scroll, app/URL opening, Music, volume, brightness, Calendar reads, Reminder creation, Finder, Notes create/append/search, Mail drafts, Things, Shortcuts, and Messages opening. URL opening honors local memory's preferred browser. Action execution is gated by Info.plist `EnableActions`. |
| `PaceActionResultCenter.swift` | ~94 | UI-friendly action run records for planned/completed/failed/denied/skipped local tool runs. CompanionManager stores the recent list and CompanionPanelView renders the latest entries. |
| `PaceToolPreflight.swift` | ~154 | Pure preflight checks for local tool plans. Reports disabled actions, missing Accessibility/Calendar/Reminders permissions, and Automation prompt warnings before approval/execution. |
| `PaceLocalMemoryStore.swift` | ~127 | UserDefaults-backed local memory for durable preferences such as preferred browser, preferred notes app, and default reminder list. Includes a small voice-command parser; preferred browser affects `open_url`. |
| `PaceAXTargeter.swift` | ~135 | Accessibility-tree pre-pass for single clicks. Given a CG global point, calls `AXUIElementCopyElementAtPosition`, climbs up to a pressable role (AXButton, AXLink, AXMenuItem, etc.), and fires `AXUIElementPerformAction(kAXPressAction)`. Returns false on miss so the executor falls back to CGEvent. |
| `PaceAvatarOverlay.swift` | ~340 | Small walking-character SwiftUI overlay in its own `NSPanel`. `PaceAvatarOverlayManager` owns lifecycle + position; `PaceAvatarWalkController` drives horizontal movement + idle pauses + mouth-open state based on `CompanionVoiceState`. Click triggers `paceAvatarTapped` which opens the menu-bar panel. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~420 | Design system tokens — colors, corner radii, animations, state layers. All UI references `DS.Colors`, `DS.CornerRadius`, etc. Button styles split into `DesignSystemButtonStyles.swift`. |
| `PaceAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~151 | Window placement helpers plus System Settings deep links for Accessibility, Screen Recording, Speech Recognition, Calendar, Reminders, and Automation permissions. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `scripts/benchmark_ttfsw.sh` | ~140 | Aggregates per-turn TTFSW + TTFT samples from the macOS unified log. Three modes: `--last 10m` (default 30m), `--live` (stream until Ctrl-C), `--file path` (parse a saved log). Outputs a markdown stats table — paste into PRs / landing page. |
| `scripts/smoke-runtime-hooks.sh` | ~83 | Launches the Debug app with `PACE_ENABLE_SMOKE_HOOKS=1` and verifies panel show/hide, cursor annotation off/on state, and approval-popup cancellation. Use after an Xcode Debug build; it avoids terminal `xcodebuild`. |
| `scripts/eval-fm.sh` | ~245 | Runs the Apple Foundation Models planner against every `evals/fm-fixtures/*.txt` fixture with the @Generable typed-output path. Compiles a Swift program once, then iterates fixtures so the FM state stays warm. Prints `spokenText`, `pointAtElementId`, `clickElementId` per fixture. Used as the FM baseline for `eval-planners.py`. |
| `scripts/eval-planners.py` | ~520 | Head-to-head planner comparison. Takes a list of model identifiers ("fm" delegates to eval-fm.sh; any other name is treated as an LM Studio model id loaded via `lms load`). Sends each through the same fixture set with the same JSON schema, scores against EXPECT_* fields, and emits a markdown scorecard. Pinning multiple LM Studio models needs LM Studio Settings → max-loaded-models ≥2. |
| `scripts/diag-pace.py` | ~620 | Pace runtime self-diagnostic. Exercises the exact LM Studio call pattern Pace uses every turn (VLM + planner alternating), measures TTFT, flags model thrashing, asserts VLM JSON decodes into LocalVLMScreenAnalysis. With `--eval` also runs the full FM-fixture set through the configured planner and folds the pass count + mean latency into the same PASS/FAIL board. Read Info.plist directly so it tests exactly what Pace will use at runtime. |
| `evals/fm-fixtures/*.txt` | — | Plain-text fixtures consumed by eval-fm.sh + eval-planners.py + diag-pace.py. Each declares USER:, ELEMENT: lines, plus optional EXPECT_POINT_ID / EXPECT_CLICK_ID / EXPECT_POINT_ID_ONE_OF / SPOKEN_MUST_CONTAIN / SPOKEN_MUST_NOT_CONTAIN / SPOKEN_MAX_WORDS scoring metadata. See `evals/fm-fixtures/README.md` for the full schema. |

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
