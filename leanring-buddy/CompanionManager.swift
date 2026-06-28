//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import AppKit
import Combine
import Contacts
import CryptoKit
import EventKit
import Foundation
import ScreenCaptureKit
import Speech
import SwiftUI

// Per-screen VLM analysis cache key + entry types moved into
// `PaceScreenContextService.swift` as `PaceScreenAnalysisCacheIdentity`
// and `PaceCachedScreenAnalysis` during the Wave 7b refactor. The
// prewarm-task envelope (formerly `PrewarmedScreenContext`) lives
// there too as `PaceScreenContextPrewarmedSnapshot`. CompanionManager
// now talks to that service for everything screen-context related.

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published var voiceState: CompanionVoiceState = .idle
    @Published var lastTranscript: String?
    /// Timestamp of the most recent PTT press, used to measure STT
    /// latency (time from key press → final transcript arrival).
    var pttPressedAt: Date?
    /// The live speech transcript shown as an in-progress user bubble in the
    /// chat panel while the user is talking. Holds the streaming partial
    /// during listening, then the final transcript through the turn, and is
    /// cleared once the committed user message lands in the chat transcript.
    @Published var liveSpeechDraft: String = ""

    /// Most recent partial transcript from the active dictation session.
    /// Used by the post-release safety net so a slow WhisperKit finalize
    /// doesn't lose the user's words — if no final transcript arrives
    /// within the timeout but a partial exists, we treat the partial as
    /// the final instead of dropping the whole turn as "no audio detected".
    var lastPartialTranscriptFromActiveDictation: String?
    @Published var currentAudioPowerLevel: CGFloat = 0
    @Published var hasAccessibilityPermission = false
    @Published var hasScreenRecordingPermission = false
    @Published var hasMicrophonePermission = false
    @Published var hasSpeechRecognitionPermission = false
    @Published var hasScreenContentPermission = false
    @Published var hasCalendarPermission = false
    @Published var hasRemindersPermission = false
    @Published var shouldRequestCalendarPermission = false
    @Published var shouldRequestRemindersPermission = false
    @Published var recentActionResults: [PaceActionRunRecord] = []
    /// Per-turn tool-call debug captures for Settings → Debug. Surfaces the
    /// raw planner output + parsed tool calls + dispatch outcome so a turn
    /// that spoke but did nothing becomes legible. Newest first.
    @Published var recentToolCallDebugRecords: [PaceToolCallDebugRecord] = []
    /// Element-map line count from the most recent planner prompt, stashed by
    /// `logFirstElementsOfPromptForDiagnostics` so the post-execution debug
    /// capture can report whether the planner actually saw the screen.
    var lastPlannerElementLineCountForDebug: Int?
    @Published var localMemorySummary: String = PaceLocalMemoryStore.summaryText
    @Published var localRetrievalSummary: String = "Retrieval: local preferences and Pace history"
    @Published var localRetrievalSourceStatuses: [PaceRetrievalSourceStatus] = []
    @Published var localRetrievalFileRootPaths: [String] = PaceLocalRetrievalFileRootPreferences
        .rootPaths(for: PaceLocalRetrievalFileRootPreferences.userSelectedRootURLs())
    @Published var currentTurnHUDState: PaceTurnHUDState = .idle

    // MARK: - Trust surfaces (undo banner + reply replay)
    //
    // See PRD `docs/prds/trust-and-failures.md`. These three published
    // fields drive the visible undo banner (cursor overlay) and the
    // reply-replay button (notch panel). They are intentionally simple
    // timestamp + payload pairs so SwiftUI views can compute "is the
    // window still open?" without subscribing to a separate clock.

    /// Timestamp of the most recent reversible action Pace executed
    /// (a mutation from `PaceActionApprovalPolicy.actionIsReversibleMutation`).
    /// The cursor overlay shows the undo banner when this is within
    /// the last 5 seconds and `mostRecentReversibleActionSummary` is
    /// set. Cleared explicitly by `clearReversibleActionUndoState()`.
    @Published var mostRecentReversibleActionAt: Date?

    /// Short summary of the most recent reversible action, used as the
    /// undo-banner label (e.g. "Created note", "Started mail draft").
    @Published var mostRecentReversibleActionSummary: String?

    /// Post-processed spoken text from the most recent assistant turn.
    /// Identical to what flowed through TTS — `<think>` blocks, tool
    /// calls, action tags, and `[POINT:…]` already stripped. The reply
    /// replay button replays exactly this text.
    @Published var lastSpokenReplyText: String?

    /// Timestamp of when `lastSpokenReplyText` was set. The notch
    /// panel surfaces the replay button when this is within 30 seconds.
    @Published var lastSpokenReplyAt: Date?

    /// Latest plain-language failure narration Pace surfaced. Carried
    /// on the manager so the panel can render the typed suggestion
    /// (Settings deep-link, configure-MCP hint, etc.) without
    /// re-deriving it from a stringly-typed history record.
    @Published var lastFailureNarration: PaceFailureNarration?

    /// Timestamp of the last sidecar-TTS-offline narration so the
    /// "switched to system voice" message fires at most once per
    /// outage window rather than on every sentence. Resets when the
    /// sidecar recovers.
    var lastSidecarTTSOfflineNarratedAt: Date?

    var pendingIntentClarification: PacePendingIntentClarification?

    /// Set when the executor's click-candidate scoring found multiple
    /// near-tied, distinguishable targets and Pace paused to ask one
    /// short HUD question instead of guessing (PRD
    /// docs/prds/hud-intent-disambiguator.md). Holds the original
    /// candidate set + screen captures so resolving an option clicks the
    /// chosen target directly — it never re-runs the planner.
    var pendingClickTargetClarification: PacePendingClickTargetClarification?

    let activeTTSVoiceSummary: PaceTTSVoiceSummary = PaceTTSVoiceSummary.current()

    /// True when the configured LM Studio (or compatible) HTTP server
    /// responds within a short timeout. Polled periodically so the panel
    /// can show a "LM Studio not running" hint without the user having to
    /// push-to-talk and watch for silent failure.
    @Published var isLMStudioReachable = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    /// Tuition-mode annotation layer: shapes the planner has drawn on
    /// the screen for teaching, plus the lifecycle timer that auto-fades
    /// them after 30 s. `BlueCursorView` observes
    /// `annotationOverlayController.activeAnnotations` directly to
    /// render the layer. Lifecycle: cleared at every PTT-release, on
    /// `clear_annotations` (tool or voice command), and on the 30 s
    /// timer. See PRD tuition-mode annotations.
    let annotationOverlayController = PaceAnnotationOverlayController()

    let buddyDictationManager = PacePushToTalkManager()
    /// Wave 2b — always-listening wake-word spotter (Apple Speech,
    /// on-device, ANE-backed). Lifecycled by
    /// `bindWakeWordSpotterObservation`: starts when
    /// `isAlwaysListeningEnabled` flips true, stops when it flips
    /// false. Holds its own short-lived `AVAudioEngine` because the
    /// PTT manager only installs its tap during an active turn —
    /// the spotter needs to listen during idle and pauses itself
    /// when PTT engages to avoid mic contention.
    let wakeWordSpotter: any PaceWakeWordSpotterProtocol = PaceAppleSpeechWakeWordSpotter()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    /// System-wide listener for the chat-input shortcut (default
    /// `cmd+shift+P`). Brings the notch panel forward and focuses the
    /// chat input — the keystroke entry point for typists who don't
    /// want to open the main window first.
    let globalChatShortcutMonitor = GlobalChatShortcutMonitor()

    /// Stamps the timestamp of the most recent user mouse / keyboard /
    /// scroll event. Read by `buildMorningTriageRestraintContext`,
    /// `buildFailureRestraintContext`, and `drainProactiveQueueIfIdle`
    /// so a proactive nudge that lands while the user is mid-input
    /// gets queued instead of barging in. Lifecycle is tied to the
    /// monitor / detector pair below — both start in `start()` and
    /// stop in `stop()`.
    let userInputActivityMonitor = PaceUserInputActivityMonitor()

    /// Polls running applications for known call-app bundle
    /// identifiers (Zoom, Teams, FaceTime, Slack) every five seconds.
    /// Combined with the input-activity monitor, this gives the
    /// restraint gate a "user is busy" signal without permission cost.
    let activeCallDetector = PaceActiveCallDetector()
    /// Drives the chat input visibility inside the notch panel. Set
    /// `true` when the chat shortcut fires; the panel renders a
    /// TextField bound to `@FocusState` keyed on this flag. Cleared
    /// once the input is submitted or dismissed.
    @Published var isNotchChatInputFocused: Bool = false
    let overlayWindowManager = OverlayWindowManager()
    /// Screen-edge glow border that shifts color with voice state.
    /// Inspired by ORB's glow border phase indicator. Gated by the
    /// `isGlowBorderEnabled` preference (default ON).
    let glowBorderManager = GlowBorderManager()

    /// Tooltip-style bubble that follows the cursor and shows what's
    /// happening through the voice turn: "listening…", interim
    /// transcript, the planner's streaming text. Replaces the pure-
    /// spinner UX so users can see the pipeline is alive when something
    /// (Whisper download, slow LM Studio cold-start, network) is taking
    /// a while.
    lazy var responseOverlayManager: CompanionResponseOverlayManager = {
        let manager = CompanionResponseOverlayManager()
        manager.setAnnotationsEnabled(areCursorAnnotationsEnabled)
        manager.setStopButtonCallback { [weak self] in
            self?.handleStopButtonTapped()
        }
        return manager
    }()

    /// Sentence-by-sentence TTS dispatcher. As the planner streams its
    /// reply, completed sentences get queued to AVSpeechSynthesizer
    /// before the response is finished generating — cuts perceived
    /// time-to-first-spoken-word from ~3s to ~500ms.
    ///
    /// `internal` access so the in-window chat surface can observe its
    /// `@Published inFlightStreamedText` for live streaming display
    /// without us routing the planner stream through a second publisher
    /// in `CompanionManager`. The pipeline owns the per-turn lifecycle
    /// already; reusing its publisher keeps the streaming wire-up DRY.
    lazy var streamingSentenceTTSPipeline: StreamingSentenceTTSPipeline = {
        return StreamingSentenceTTSPipeline(ttsClient: ttsClient)
    }()

    /// Backing store for the in-window chat transcript. Lazy so it
    /// only builds the local history reader on first use (the main
    /// window opens on demand, not at launch). Persistence runs
    /// through `paceHistory` retrieval — there is no parallel chat
    /// storage layer. See `PaceChatSession.swift`.
    lazy var chatSession: PaceChatSession = {
        return PaceChatSession(
            historySource: PaceLocalChatHistoryReader(),
            transcriptSubmitter: companionManagerChatSubmitterAdapter
        )
    }()

    /// Adapter that lets `PaceChatSession` call back into the manager
    /// without holding a strong reference. Forwards to
    /// `submitChatTranscriptFromChatSession(_:)`, which is the chat-mode
    /// twin of the deeplink submit path.
    lazy var companionManagerChatSubmitterAdapter: PaceChatSessionSubmitterAdapter = {
        return PaceChatSessionSubmitterAdapter(owner: self)
    }()

    /// Per-turn flag set by `submitChatTranscriptFromChatSession` to the
    /// session's `isChatTTSMuted` snapshot at submission time. The
    /// streaming pipeline reads it through `setMutedForCurrentTurn`
    /// every turn boundary; we don't store this anywhere persistent.
    var isChatModeMutedForCurrentTurn: Bool = false

    /// Classifies the user's transcript into pureKnowledge /
    /// screenDescription / screenAction / chitchat so the pipeline
    /// can skip work the turn doesn't need. Chitchat bypasses the
    /// planner entirely; pure knowledge takes a text-only planner path.
    /// The rule-based backend ships now; a tiny model can replace it
    /// once it beats these rules on local fixtures.
    lazy var intentClassifier: any PaceIntentClassifying = {
        return PaceIntentClassifierFactory.makeDefault()
    }()

    // Main reasoning/planning model for screen and action turns.
    // Runtime default remains LocalPlannerClient pointing at LM Studio
    // because the larger local model wins the harder planner fixtures.
    lazy var plannerClient: any BuddyPlannerClient = {
        return BuddyPlannerClientFactory.makeDefault()
    }()

    // Fast answer planner for pure-knowledge turns. Apple Foundation
    // Models runs in-process when Apple Intelligence is ready; otherwise
    // the factory falls back to the configured local planner.
    lazy var textOnlyPlannerClient: any BuddyPlannerClient = {
        return BuddyPlannerClientFactory.makeFastTextOnlyPlannerOrFallback()
    }()

    lazy var localRetriever: PaceLocalRetriever = {
        let retriever = PaceLocalRetriever()
        localRetrievalSourceStatuses = retriever.sourceStatuses
        localRetrievalSummary = localRetrievalSummaryText(from: retriever.sourceStatuses)
        return retriever
    }()

    lazy var screenTimeRetrievalConnector = PaceScreenTimeRetrievalConnector()

    lazy var postureMonitor: PacePostureMonitor = {
        let monitor = PacePostureMonitor()
        monitor.onPostureEvent = { [weak self] postureEvent in
            self?.handlePostureEvent(postureEvent)
        }
        return monitor
    }()

    lazy var appUsageTracker: PaceAppUsageTracker? = PaceAppUsageTracker(
        rehydratedJournal: localRetriever.rehydratedAppUsageJournal(),
        onFlushedDocument: { [weak self] flushedDocument in
            guard let self else { return }
            self.localRetriever.recordAppUsageDocument(flushedDocument)
            self.refreshLocalRetrievalPublishedState()
        }
    )

    lazy var calendarRetrievalConnector: PaceCalendarRetrievalConnector = {
        return PaceCalendarRetrievalConnector(eventStore: permissionEventStore)
    }()

    lazy var remindersRetrievalConnector: PaceRemindersRetrievalConnector = {
        return PaceRemindersRetrievalConnector(eventStore: permissionEventStore)
    }()

    lazy var contactsRetrievalConnector: PaceContactsRetrievalConnector = {
        return PaceContactsRetrievalConnector()
    }()

    lazy var notesRetrievalConnector: PaceNotesRetrievalConnector = {
        return PaceNotesRetrievalConnector()
    }()

    lazy var mailRetrievalConnector: PaceMailRetrievalConnector = {
        return PaceMailRetrievalConnector()
    }()

    lazy var spotlightRetrievalConnector: PaceSpotlightRetrievalConnector = {
        return PaceSpotlightRetrievalConnector(rootURLs: PaceLocalRetrievalFileRootPreferences.configuredRootURLs())
    }()

    // Always the on-device AVSpeechSynthesizer-backed client. Protocol
    // kept so a future local TTS runtime (Kokoro/Piper-MLX) can plug in.
    lazy var ttsClient: any BuddyTTSClient = {
        return BuddyTTSClientFactory.makeDefault()
    }()

    // The action executor synthesises real mouse/keyboard events on the
    // user's behalf. Gated behind Info.plist EnableActions — when false,
    // every method here logs and returns without posting anything.
    lazy var actionExecutor: PaceActionExecutor = {
        return PaceActionExecutor()
    }()

    // MARK: - Demonstration flow recording / replay
    //
    // The flow store, recorder, and replayer compose the Wave 3
    // demonstration-replay surface. We construct them lazily because
    // (a) `PaceFlowRecorder` / `PaceFlowReplayer` are `@MainActor` and
    // (b) the recorder installs a CGEventTap on `start(...)` — the
    // store and replayer themselves are cheap and can be hot, but we
    // keep them all lazy so the construction cost is paid the first
    // time the user actually uses a flow command, not at app launch.
    let flowStore = PaceFlowStore()
    lazy var flowRecorder: PaceFlowRecorder = PaceFlowRecorder()
    lazy var flowReplayer: PaceFlowReplayer = PaceFlowReplayer()

    /// Session-scoped approval cache for `run_flow`. First replay of a
    /// given flow name requires explicit user approval; subsequent
    /// replays in the same session bypass the approval popup. Cleared
    /// on session reset by `resetFlowReplayApprovalCacheForSession()`.
    var flowNamesApprovedForReplayThisSession: Set<String> = []
    /// Deterministic v1 pattern extractor. Fires inline because it is
    /// pure-Swift, sub-millisecond, and catches the obvious preference
    /// / family-health / work-deadline cases without any model call.
    let episodicPatternExtractor = PaceEpisodicPatternFactExtractor()
    /// LLM-backed extractor (Apple FM preferred, LM Studio fallback)
    /// for everything the pattern extractor misses. Fires from a
    /// DETACHED task — never blocks the user-facing turn.
    let episodicLLMFactExtractor: PaceEpisodicFactExtractor = PaceEpisodicFactExtractorFactory.makeDefault()
    /// In-memory store enforcing the dedup, tombstone, and 200-fact
    /// LRU cap from PRD episodic-memory.md. Both extractors funnel
    /// here before facts reach the retrieval index, so the same
    /// gates apply regardless of which extractor produced the fact.
    let episodicFactStore = PaceEpisodicFactStore()
    /// Last-seen intent for the turn currently completing. Set from
    /// the intent classifier site, read by
    /// `recordConversationTurn` so episodic extraction only fires
    /// for `.pureKnowledge | .screenDescription | .chitchat` turns
    /// per the PRD. Defaults to `.unknown` so a missing intent
    /// classifier doesn't silently disable episodic extraction.
    var lastIntentRouteForEpisodicExtraction: PaceIntent = .unknown

    /// Native macOS OCR. Runs in parallel with the VLM, both pre-warmed
    /// at PTT-press so neither shows up in perceived latency. The VLM
    /// identifies elements; OCR delivers verbatim text — merged by
    /// bbox overlap. Cheap (~50-200ms), no model load.
    let visionOCRClient = PaceVisionOCRClient()
    let permissionEventStore = EKEventStore()
    lazy var screenWatchModeController: PaceScreenWatchModeController = {
        PaceScreenWatchModeController()
    }()

    /// Fast-tier screen reader. AX tree of the focused window in 5-50ms,
    /// vs 800ms-3s for the VLM. If AX returns ≥1 element we use it +
    /// OCR enrichment and skip the VLM entirely — the common path on
    /// AppKit / SwiftUI / Catalyst apps. VLM is the fallback only when
    /// AX returns nothing useful (Electron-without-AX, games, web
    /// content with broken AX hints).
    let axScreenReader = PaceAXScreenReader()

    // Screen-context coordinator: owns the per-screen VLM cache, the
    // PTT-press prewarm task, and the AX + OCR + VLM merge logic.
    // Extracted from CompanionManager during Wave 7b — behavior is
    // byte-identical to the pre-extraction code. The `isReadMyScreenEnabled`
    // closure reads the live `@Published` value so toggling the
    // preference in Settings takes effect immediately without a
    // service restart.
    lazy var screenContextService: PaceScreenContextService = {
        PaceScreenContextService(
            screenAnalysisClient: PaceScreenAnalysisClientFactory.makeDefaultClient(),
            visionOCRClient: visionOCRClient,
            axScreenReader: axScreenReader,
            isReadMyScreenEnabled: { [weak self] in
                self?.useLocalVLMForScreenContext ?? false
            }
        )
    }()

    /// User-facing toggle for "read my screen". Backed by UserDefaults so
    /// it survives launches; first launch seeds from Info.plist
    /// `UseLocalVLMForScreenContext`. Wired to a Switch in CompanionPanelView.
    @Published var useLocalVLMForScreenContext: Bool = PaceUserPreferencesStore
        .boolWithInfoPlistSeed(.useLocalVLMForScreenContext, infoPlistKey: "UseLocalVLMForScreenContext")

    func setUseLocalVLMForScreenContext(_ enabled: Bool) {
        useLocalVLMForScreenContext = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .useLocalVLMForScreenContext)
    }

    /// Wave 4 speed lever: when ON, screen-action / screen-description
    /// turns race Apple FM (lite, text-only) against the full VLM-fed
    /// local planner. RAM-neutral because FM is in-process. Default ON
    /// — this is a hot feature, users opt OUT in Settings → Planner.
    @Published var isSpeculativePlannerRaceEnabled: Bool = PaceUserPreferencesStore
        .bool(.enableSpeculativePlannerRace, default: true)

    func setSpeculativePlannerRaceEnabled(_ enabled: Bool) {
        isSpeculativePlannerRaceEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .enableSpeculativePlannerRace)
    }

    /// Wave 4 gate: pure predicate the speculative-race wiring uses to
    /// decide whether THIS turn qualifies for the race. Centralized in
    /// one method so the gating rules are testable as a unit and can be
    /// audited in one place. Returns true only when EVERY gate passes:
    ///
    /// - intent is screenAction OR screenDescription (the slow paths)
    /// - the speculative-race toggle is ON
    /// - the VLM is configured to run this turn (otherwise lite vs full
    ///   is the same input shape — no race value)
    /// - Apple FM availability is `.available` (lite path needs it)
    ///
    /// CompanionManager calls this inline; tests call it through the
    /// nonisolated static helper below.
    func speculativeRaceShouldFire(
        intent: PaceIntent,
        appleFoundationModelsIsAvailable: Bool
    ) -> Bool {
        Self.speculativeRaceShouldFire(
            intent: intent,
            isToggleEnabled: isSpeculativePlannerRaceEnabled,
            isLocalVLMConfigured: useLocalVLMForScreenContext,
            appleFoundationModelsIsAvailable: appleFoundationModelsIsAvailable
        )
    }

    /// Pure form of `speculativeRaceShouldFire(intent:appleFoundation
    /// ModelsIsAvailable:)` so unit tests can exercise the gate without
    /// constructing a full CompanionManager. The four flags are the only
    /// inputs to the decision — kept explicit so the call site is auditable.
    nonisolated static func speculativeRaceShouldFire(
        intent: PaceIntent,
        isToggleEnabled: Bool,
        isLocalVLMConfigured: Bool,
        appleFoundationModelsIsAvailable: Bool
    ) -> Bool {
        guard isToggleEnabled else { return false }
        guard isLocalVLMConfigured else { return false }
        guard appleFoundationModelsIsAvailable else { return false }
        switch intent {
        case .screenAction, .screenDescription:
            return true
        case .pureKnowledge, .chitchat, .phoneLargeModel, .research, .unknown:
            // Research turns drive a heavyweight planner with a
            // larger step budget; the speculative race over a local
            // Apple FM lite path isn't relevant to them.
            return false
        }
    }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    ///
    /// Thin facade over `threadMemory.verbatimWindow()` when thread
    /// memory is enabled (the default). Existing unrelated callers
    /// (smoke tests, debug logs) keep working; the source of truth is
    /// the verbatim window inside `threadMemory`.
    var conversationHistory: [(userTranscript: String, assistantResponse: String)] {
        return threadMemory.verbatimWindow().map { turnPair in
            (userTranscript: turnPair.userText, assistantResponse: turnPair.assistantText)
        }
    }

    /// Two-tier in-context memory: verbatim window of the last K
    /// turn pairs + rolling summary of everything older. See PRD
    /// docs/prds/conversational-thread-memory.md. Configured from
    /// `PaceUserPreferencesStore` so the picker controls in Settings
    /// can change the window size / idle threshold without a relaunch.
    lazy var threadMemory: PaceThreadMemory = {
        let isEnabled = PaceUserPreferencesStore.bool(.isThreadMemoryEnabled, default: true)
        let configuredVerbatimWindowSize = PaceUserPreferencesStore.clampedInt(
            .threadMemoryVerbatimWindowSize,
            default: 4,
            in: 1...8
        )
        let configuredIdleMinutes = PaceUserPreferencesStore.clampedInt(
            .threadMemoryIdleMinutes,
            default: 20,
            in: 5...60
        )
        // When the master switch is off we still construct the module
        // (so the facade `conversationHistory` keeps working) but with
        // a window size of 1 so nothing leaks into the planner beyond
        // the immediate prior turn. Toggling back on just requires a
        // relaunch — the next `start()` reads the preference fresh.
        let effectiveWindowSize = isEnabled ? configuredVerbatimWindowSize : 1
        return PaceThreadMemory(
            configuration: PaceThreadMemoryConfiguration(
                verbatimWindowSize: effectiveWindowSize,
                sessionIdleThreshold: TimeInterval(configuredIdleMinutes) * 60,
                summaryMaxTokenEstimate: PaceThreadMemoryConfiguration.default.summaryMaxTokenEstimate
            )
        )
    }()

    /// Detached FM call producing the next rolling summary. Lazy so
    /// the FM session is created only when the first turn falls off
    /// the verbatim window. See PRD section "Latency budget detail
    /// (the race)" for the version-snapshot contract.
    lazy var threadSummarizerClient: PaceThreadSummarizerClient = {
        PaceThreadSummarizerClientFactory.makeDefault()
    }()

    /// On-device persistence for `threadMemory` so a conversation
    /// survives quit/relaunch ("resume always, until reset"). Only the
    /// store touches disk; `threadMemory` stays I/O-free.
    let threadMemoryStore = PaceThreadMemoryStore()

    /// Whether thread memory (and therefore its persistence) is active.
    /// When off, we neither restore nor write the conversation to disk,
    /// and we clear any existing file so disabling the feature honors
    /// the user's privacy intent.
    var isThreadMemoryEnabled: Bool {
        PaceUserPreferencesStore.bool(.isThreadMemoryEnabled, default: true)
    }

    /// Persist the current thread-memory state. Best-effort and cheap;
    /// called after every mutation (turn recorded, summary updated,
    /// session reset). No-op (and clears the file) when the feature is
    /// disabled so a stale conversation can't linger on disk.

    // MARK: - Unified memory (Phase 2: dual-write) — stored state; methods in CompanionManager+UnifiedMemoryDualWrite.swift

    /// The single unified memory index (docs/prds/unified-memory.md). In
    /// Phase 2 it is DUAL-WRITTEN alongside the existing thread/episodic/
    /// retrieval stores — those stay authoritative; this ships dark and
    /// nothing reads it yet. Phase 3 cuts recall over to it behind a flag.
    let memoryIndex = PaceMemoryIndex()
    let memoryStore = PaceMemoryStore()
    /// One-way mirror into the system CoreSpotlight index so memories
    /// are discoverable from Cmd+Space and other Spotlight surfaces.
    /// Best-effort: any framework failure is silently absorbed by the
    /// indexer — Spotlight mirroring never blocks a user-facing turn.
    let spotlightMemoryIndexer = PaceSpotlightMemoryIndexer()
    /// macOS Focus state monitor. Feeds `isInUserFocusMode` into every
    /// `PaceRestraintContext` we build, so proactive surfaces (morning
    /// brief, posture, failure narrations) defer cleanly while the
    /// user has a system Focus active. Starts itself in `start()`;
    /// denied permission silently degrades to "never focused" so a
    /// missing permission can't lock Pace out of talking.
    let focusModeMonitor = PaceFocusModeMonitor()
    /// Thermal-state advisor. Subscribes to
    /// `ProcessInfo.thermalStateDidChangeNotification` and exposes a
    /// typed `currentRecommendation` (unrestricted → dampen race →
    /// dampen background loops → suspend background). Used as a gate
    /// at the speculative-race site, watch-mode scheduler, and
    /// prewarm task so a hot MacBook doesn't get hotter from Pace's
    /// own concurrent workload.
    let thermalStateAdvisor = PaceThermalStateAdvisor()

    /// Phase 3 recall: semantically ranks the unified index for the
    /// LOCAL CONTEXT block. Gated by `useUnifiedMemoryRecall` (default
    /// off) at the call site; falls back to lexical recall when the
    /// embedding endpoint is unavailable. Reads the sensitive-topic
    /// opt-in live so a Settings change takes effect without relaunch.
    lazy var memoryRetriever = PaceMemoryRetriever(
        memoryIndex: memoryIndex,
        embeddingClient: PaceChainedTextEmbeddingClient.makePaceDefault(),
        shouldInjectSensitiveTopics: {
            PaceUserPreferencesStore.bool(.injectSensitiveEpisodicTopics, default: false)
        }
    )

    /// Off-hot-path embedding scheduler — extracted into its own
    /// module so each memory write site is a one-line call. Created
    /// lazily so the embedding client factory only runs after the
    /// first write that needs it. See PaceLazyEmbeddingScheduler.
    lazy var lazyEmbeddingScheduler = PaceLazyEmbeddingScheduler(
        memoryIndex: memoryIndex,
        embeddingClientFactory: { PaceChainedTextEmbeddingClient.makePaceDefault() },
        onEmbeddingsPersisted: { [weak self] in self?.persistUnifiedMemory() }
    )

    /// Throttle so the connector resync runs at most once a minute even
    /// though `refreshLocalRetrievalPublishedState()` fires after every
    /// retrieval write.
    var lastUnifiedMemoryConnectorSyncAt: Date?
    static let unifiedMemoryConnectorSyncMinimumInterval: TimeInterval = 60

    /// Low-frequency idle sweep so the menu-bar surface can drop
    /// "session live" indicators without needing a new user turn.
    var threadMemoryIdleSweepTimer: Timer?

    // Per-screen VLM analysis cache lives inside `screenContextService`
    // (Wave 7b extraction). All cache reads in CompanionManager go
    // through `screenContextService.cachedDescriptionIfFresh(...)` or
    // through the planner-prompt path on the service itself.

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    var currentResponseTask: Task<Void, Never>?

    var shortcutTransitionCancellable: AnyCancellable?
    var chatShortcutCancellable: AnyCancellable?
    var voiceStateCancellable: AnyCancellable?
    var audioPowerCancellable: AnyCancellable?

    /// Wave 1c barge-in plumbing. The VAD is a mutable struct; we hold
    /// it through a class wrapper-style storage (the `var` here works
    /// because CompanionManager is itself a class) so the subscription
    /// path can call `observe(...)` mutably. The subscription is
    /// attached only when both gates fire — `voiceState == .responding`
    /// AND `isAlwaysListeningEnabled == true` — and is torn down the
    /// instant either flips, so the VAD never sees stale audio.
    var bargeInVAD = PaceBargeInVAD()
    var bargeInAudioLevelCancellable: AnyCancellable?
    var bargeInGatePropertyCancellable: AnyCancellable?

    /// Wave 2b — bindings for the wake-word spotter. The toggle
    /// cancellable observes `isAlwaysListeningEnabled` and flips the
    /// spotter on/off; the detection cancellable forwards each
    /// `PaceWakeWordDetection` into `handleWakeWordDetected(_:)`.
    var wakeWordToggleCancellable: AnyCancellable?
    var wakeWordDetectionCancellable: AnyCancellable?
    /// PTT-engagement bindings. When PTT starts recording the spotter
    /// pauses so the two audio paths don't fight over the mic; when
    /// PTT releases the spotter resumes if always-listening is still
    /// on. Done as a separate cancellable from the toggle bind so the
    /// two policies (toggle and PTT) compose cleanly.
    var wakeWordPTTBridgeCancellable: AnyCancellable?
    var accessibilityCheckTimer: Timer?
    var lmStudioReachabilityCheckTimer: Timer?
    var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    var lastCalendarRetrievalRefreshAt: Date?
    var lastCalendarRetrievalAuthorizationStatus: EKAuthorizationStatus?
    var lastRemindersRetrievalRefreshAt: Date?
    var lastRemindersRetrievalAuthorizationStatus: EKAuthorizationStatus?
    var remindersRetrievalRefreshTask: Task<Void, Never>?
    var lastContactsRetrievalRefreshAt: Date?
    var lastContactsRetrievalAuthorizationStatus: CNAuthorizationStatus?
    var contactsRetrievalRefreshTask: Task<Void, Never>?
    var lastFileRetrievalRefreshAt: Date?
    var fileRetrievalRefreshTask: Task<Void, Never>?
    var lastNotesRetrievalRefreshAt: Date?
    var notesRetrievalRefreshTask: Task<Void, Never>?
    var lastMailRetrievalRefreshAt: Date?
    var mailRetrievalRefreshTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    var transientHideTask: Task<Void, Never>?
    /// Safety task scheduled when the user releases PTT. Fires after 5s
    /// and resets the overlay if no transcript arrived. Cancelled if a
    /// transcript shows up first.
    var transcriptSafetyTask: Task<Void, Never>?

    /// Set to true inside `submitDraftText` so the safety task can tell
    /// whether the transcription delivered. Reset on each new press.
    var transcriptArrivedSinceRelease: Bool = false

    /// Flipped to true when the active transcription provider has
    /// finished any background model load. Apple Speech / cloud
    /// providers report ready immediately; WhisperKit reports ready
    /// after CoreML compile (~15s first run, instant once cached).
    /// PTT presses while this is false are rejected with a "model
    /// loading" message so they don't hang the audio engine.
    @Published var isTranscriptionModelReady: Bool = false

    /// How the current voice turn was triggered. Drives where the response
    /// bubble pins itself: `.keyboard` anchors it next to the system
    /// cursor (so it visually rides with the Codex arrow); `.avatar`
    /// anchors it next to the walking character. Cleared back to
    /// `.keyboard` when the turn ends.
    enum DictationTrigger { case keyboard, avatar }
    var currentDictationTrigger: DictationTrigger = .keyboard

    /// Weak reference set by the app delegate after the avatar overlay
    /// manager attaches. Lets the response overlay's `.nearPoint` anchor
    /// callback ask for the avatar's current frame.
    weak var avatarOverlayManager: PaceAvatarOverlayManager?

    /// True when the core voice/screen permissions are granted. App-control
    /// permissions like Calendar, Reminders, and Automation are surfaced
    /// separately because they are only needed when the user asks for those
    /// local tools.
    var allPermissionsGranted: Bool {
        // Apple Speech permission only gates readiness when the ACTIVE
        // transcription provider uses the Speech framework. WhisperKit
        // transcribes without it, and requiring it anyway made the panel
        // nag for a permission the app never requests.
        let speechPermissionSatisfied = !buddyDictationManager
            .transcriptionProvider.requiresSpeechRecognitionPermission
            || hasSpeechRecognitionPermission
        return hasAccessibilityPermission
            && hasScreenRecordingPermission
            && hasMicrophonePermission
            && speechPermissionSatisfied
            && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published var isOverlayVisible: Bool = false

    @Published var isRequestingScreenContent = false

    /// Pace skips the upstream first-run flow entirely — no welcome video,
    /// no email gate, no demo pointing animation. The cursor overlay shows
    /// as soon as all permissions are granted. This constant exists only
    /// so the panel UI's existing conditional branch stays simple.
    let hasCompletedOnboarding: Bool = true

    /// Read-only display name of the active planner — surfaced in the
    /// menu-bar panel so users can see which local model is wired up.
    /// Updates only on app restart since planner-swap requires Info.plist
    /// edit + rebuild.
    var activePlannerDisplayName: String {
        plannerClient.displayName
    }

    var activeTextOnlyPlannerDisplayName: String {
        textOnlyPlannerClient.displayName
    }

    /// User preference for whether the walking avatar overlay is shown
    /// on the bottom of the cursor screen. Defaults to ON so first-run
    /// users see the character; toggleable from the menu-bar panel.
    @Published var isWalkingAvatarEnabled: Bool = PaceUserPreferencesStore
        .bool(.isWalkingAvatarEnabled, default: true)

    func setWalkingAvatarEnabled(_ enabled: Bool) {
        isWalkingAvatarEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .isWalkingAvatarEnabled)
    }

    /// User preference for whether the Pace cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isPaceCursorEnabled: Bool = PaceUserPreferencesStore
        .bool(.isPaceCursorEnabled, default: true)

    /// User preference for whether cursor-adjacent annotation bubbles are
    /// shown. Turning this off keeps the cursor/tool flow active but hides
    /// the transcript/response bubble and the small pointer labels.
    @Published var areCursorAnnotationsEnabled: Bool = PaceUserPreferencesStore
        .bool(.areCursorAnnotationsEnabled, default: true)

    func setCursorAnnotationsEnabled(_ enabled: Bool) {
        areCursorAnnotationsEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .areCursorAnnotationsEnabled)
        responseOverlayManager.setAnnotationsEnabled(enabled)
    }

    /// User preference for the screen-edge glow border. When toggled
    /// at runtime, the glow border manager shows/hides immediately.
    @Published var isGlowBorderEnabled: Bool = PaceUserPreferencesStore
        .bool(.isGlowBorderEnabled, default: true)

    func setGlowBorderEnabled(_ enabled: Bool) {
        isGlowBorderEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .isGlowBorderEnabled)
        glowBorderManager.setEnabled(
            enabled,
            screens: NSScreen.screens,
            companionManager: self
        )
    }

    func smokeSetCursorAnnotationsEnabled(_ enabled: Bool) -> Bool {
        setCursorAnnotationsEnabled(enabled)
        return areCursorAnnotationsEnabled
    }

    /// Tuition mode: when ON, the planner is told (via a system-prompt
    /// block) to TEACH rather than DO — emit `draw_annotation` and
    /// narrate, instead of `click`/`type`. The `draw_annotation` and
    /// `clear_annotations` tools are ALWAYS available regardless of this
    /// flag; the toggle only changes the planner's bias. See PRD
    /// tuition-mode annotations.
    @Published var isTuitionModeEnabled: Bool = PaceUserPreferencesStore
        .bool(.isTuitionModeEnabled, default: false)

    func setIsTuitionModeEnabled(_ enabled: Bool) {
        isTuitionModeEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .isTuitionModeEnabled)
        // Drop any visible annotations when switching modes — they
        // were generated under different planner bias and would feel
        // stale once the mode flips.
        if !enabled {
            annotationOverlayController.clear(reason: "tuition mode disabled")
        }
    }

    /// Mascot mode: the top-right perch + panel are the only conversation
    /// surfaces, so silence BOTH cursor-level overlays — the blue cursor
    /// companion and the response text bubble — so nothing renders near the
    /// mouse pointer. Does not touch the user's persisted toggles (it's a
    /// runtime surface choice, not a preference change).
    func suppressCursorOverlaysForMascotMode() {
        mascotModeActive = true
        overlayWindowManager.isSuppressed = true
        overlayWindowManager.hideOverlay()
        isOverlayVisible = false
        responseOverlayManager.setAnnotationsEnabled(false)
    }

    /// True when the top-right mascot perch + panel are the conversation
    /// surface. Gates legacy behaviors that assumed the response shows near
    /// the cursor — notably dismissing the panel on push-to-talk.
    var mascotModeActive = false

    /// User preference for whether Pace asks before higher-risk local tools.
    /// Routine reversible or visible actions auto-run; non-undoable app
    /// mutations, external tools, and blocking preflight issues still prompt.
    @Published var requiresActionApproval: Bool = PaceUserPreferencesStore
        .bool(.requiresActionApproval, default: true)

    func setRequiresActionApproval(_ enabled: Bool) {
        requiresActionApproval = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .requiresActionApproval)
    }

    // MARK: - Cloud bridge published state — stored state; methods in CompanionManager+CloudBridge.swift

    /// The user's chosen bridge routing mode. Persisted via `PaceCloudBridgeConsent`.
    @Published var cloudBridgeMode: PaceCloudBridgeMode = {
        PaceCloudBridgeConsent.loadConfiguration().mode
    }()

    /// Which CLI upstream the bridge should use (Claude Code / Codex / Gemini).
    @Published var cloudBridgeUpstream: PaceCloudBridgeUpstream = {
        PaceCloudBridgeConsent.loadConfiguration().upstream
    }()

    /// Model identifier string forwarded to the bridge (e.g. "sonnet").
    @Published var cloudBridgeModel: String = {
        PaceCloudBridgeConsent.loadConfiguration().model
    }()

    /// Set to true when a cloud-bridge SSE stream is actively in progress.
    /// Observed by `PaceMenuBarOverlay` to tint the right-icon slot amber.
    @Published var isCloudBridgeCallActive: Bool = false

    // MARK: - Planner tier picker state — stored state; methods in CompanionManager+PlannerTierPicker.swift

    /// The user's chosen planner tier from Settings → Planner. Default is
    /// `.local` for existing users — no UserDefaults state means the
    /// factory returns the same LM Studio planner as before.
    @Published var activePlannerTier: PacePlannerTier = {
        PacePlannerTierStore.loadConfiguration().tier
    }()

    /// The provider Direct-API turns will target when tier == .directAPI.
    @Published var directAPIProvider: PaceDirectAPIProvider = {
        PacePlannerTierStore.loadConfiguration().directAPIProvider
    }()

    /// The model identifier sent in the Direct-API request body.
    @Published var directAPIModelIdentifier: String = {
        PacePlannerTierStore.loadConfiguration().directAPIModelIdentifier
    }()

    /// The user-pasted endpoint URL string, used only when provider == .custom.
    @Published var directAPICustomEndpointURLString: String = {
        PacePlannerTierStore.loadConfiguration().directAPICustomEndpointURLString
    }()

    /// Opt-in: when true AND a Direct-API turn errors, Pace retries the
    /// SAME turn against LM Studio. Default is OFF so failures fail loud.
    @Published var directAPIFallsBackToLocalOnCloudFailure: Bool = {
        PacePlannerTierStore.loadConfiguration().fallsBackToLocalOnCloudFailure
    }()

    /// True when ANY non-Local tier (cliBridge OR directAPI) is actively
    /// streaming. The menu-bar capsule observes this for the amber tint
    /// so EVERY off-device turn is visible, not just bridge calls.
    /// `isCloudBridgeCallActive` remains as a subset for backward compat
    /// during the v1 cycle and continues to set/reset alongside this flag.
    @Published var isOffDeviceTurnInFlight: Bool = false



    @Published var isAlwaysListeningEnabled: Bool = PaceUserPreferencesStore
        .bool(.isAlwaysListeningEnabled, default: false)


    @Published var areFocusFatigueNudgesEnabled: Bool = PaceUserPreferencesStore
        .bool(.areFocusFatigueNudgesEnabled, default: false)


    @Published var areCalendarNudgesEnabled: Bool = PaceUserPreferencesStore
        .bool(.areCalendarNudgesEnabled, default: false)


    @Published var areWatchObservationNudgesEnabled: Bool = PaceUserPreferencesStore
        .bool(.areWatchObservationNudgesEnabled, default: false)


    // MARK: - Proactivity profile — stored state; setters in CompanionManager+ProactivitySettings.swift

    /// User-tunable proactive-speech assertiveness. Default `.balanced`
    /// matches the PRD's original cooldown values; `.talkative`
    /// shortens cooldowns; `.reserved` lengthens them. The picker
    /// lives in Settings → Proactive. Read by the proactive context
    /// builders so the gate's `cooldownSeconds(forProfile:...)` table
    /// applies the user's preference on every gate decision.
    @Published var proactivityProfile: PaceProactivityProfile = PaceUserPreferencesStore.proactivityProfile() {
        didSet {
            guard oldValue != proactivityProfile else { return }
            PaceUserPreferencesStore.setProactivityProfile(proactivityProfile)
        }
    }


    // MARK: - Proactive pipeline (Wave 7a extraction) — pipeline + forwarders split; forwarders in CompanionManager+ProactivePipeline.swift
    //
    // The ≤3 ring buffer, 10s drain timer, three nudge generators,
    // orchestrator wiring, and live restraint-context construction
    // all live in `PaceProactivityPipeline`. CompanionManager keeps
    // tiny forwarders so the test surface
    // (`enqueueProactiveUtterance`, `proactiveUtteranceQueueSnapshot`,
    // `drainProactiveQueueIfIdle`) stays byte-identical for callers.

    lazy var proactivityPipeline: PaceProactivityPipeline = {
        // Use the same generator-identifier literals the generators
        // themselves declare. Kept inline so the pipeline construction
        // doesn't add a new generator-side static API.
        let initiallyEnabledGeneratorIdentifiers: Set<String> = {
            var enabledGeneratorIdentifiers: Set<String> = []
            if areFocusFatigueNudgesEnabled {
                enabledGeneratorIdentifiers.insert("focus-fatigue")
            }
            if areCalendarNudgesEnabled {
                enabledGeneratorIdentifiers.insert("calendar-pre-meeting")
            }
            if areWatchObservationNudgesEnabled {
                enabledGeneratorIdentifiers.insert("watch-mode-observation")
            }
            return enabledGeneratorIdentifiers
        }()
        return PaceProactivityPipeline(
            userInputActivityMonitor: userInputActivityMonitor,
            activeCallDetector: activeCallDetector,
            proactivityProfileProvider: { [weak self] in
                return self?.proactivityProfile ?? .balanced
            },
            currentVoiceStateProvider: { [weak self] in
                return self?.voiceState ?? .idle
            },
            speakUtterance: { [weak self] utterance in
                // Mirrors the pre-extraction `speakProactiveNudge`
                // shape exactly: `Task { try? speakText }` with
                // print-on-failure so a TTS error never escapes here.
                guard let self else { return }
                Task { @MainActor [weak self] in
                    do {
                        try await self?.ttsClient.speakText(utterance.spokenText)
                    } catch {
                        print("⚠️ Proactive nudge TTS failed: \(error.localizedDescription)")
                    }
                }
            },
            journalProactiveNudge: { [weak self] utterance in
                // paceHistory breadcrumb so "what did you tell me
                // earlier?" can recall the nudge later. Pre-existing
                // journal-style surface, no new index.
                guard let self else { return }
                self.localRetriever.recordPaceHistory(
                    userTranscript: "(system) proactive nudge",
                    assistantResponse: utterance.spokenText
                )
                self.refreshLocalRetrievalPublishedState()
            },
            cachedScreenDescriptionProvider: { [weak self] screenLabel in
                self?.screenContextService.cachedDescriptionIfFresh(screenLabel: screenLabel)
            },
            watchModeEventPublisher: screenWatchModeController.eventPublisher.eraseToAnyPublisher(),
            calendarRetrievalConnector: calendarRetrievalConnector,
            initiallyEnabledGeneratorIdentifiers: initiallyEnabledGeneratorIdentifiers
        )
    }()


    // MARK: - Morning triage (daily brief) — stored state; methods in CompanionManager+MorningTriage.swift

    /// User-facing master switch for the daily weekday morning brief.
    /// Default OFF — the scheduler stays inert until the user
    /// explicitly enables this in Settings. See PRD
    /// docs/prds/morning-triage.md.
    @Published var isMorningTriageEnabled: Bool = PaceUserPreferencesStore
        .bool(.isMorningTriageEnabled, default: false)


    /// Hour-of-day at which the brief fires on weekdays. Clamped 0...23
    /// on read so a corrupted UserDefaults value can't break the timer.
    @Published var morningTriageHourOfDay: Int = PaceUserPreferencesStore
        .clampedInt(.morningTriageHourOfDay, default: 8, in: 0...23)


    /// Minute-of-hour at which the brief fires. Clamped 0...59 on read.
    @Published var morningTriageMinuteOfHour: Int = PaceUserPreferencesStore
        .clampedInt(.morningTriageMinuteOfHour, default: 30, in: 0...59)


    /// Scheduler instance that owns the daily fire timer and the
    /// pending-card surface. Lazy so it captures the lazy retriever /
    /// ttsClient without forcing them on app launch when the feature
    /// is off.
    lazy var morningTriageScheduler: PaceMorningTriageScheduler = {
        let scheduler = PaceMorningTriageScheduler(
            retriever: localRetriever,
            ttsClient: ttsClient,
            inputsProvider: { [weak self] context in
                guard let self else {
                    return PaceMorningBriefInputs(now: context.now)
                }
                return self.buildMorningBriefInputs(forNow: context.now)
            },
            restraintContextProvider: { [weak self] context in
                guard let self else {
                    return PaceRestraintContext(
                        now: context.now,
                        lastProactiveUtteranceAt: nil,
                        lastEpisodicRecallAt: nil,
                        lastUserInputAt: nil,
                        frontmostAppBundleIdentifier: nil,
                        isOnActiveCall: false,
                        wakeWordConfidence: nil,
                        intent: .pureKnowledge,
                        proactiveSource: .morningTriage,
                        profile: .balanced
                    )
                }
                return self.buildMorningTriageRestraintContext(forNow: context.now)
            }
        )
        scheduler.setFireTime(
            hourOfDay: morningTriageHourOfDay,
            minuteOfHour: morningTriageMinuteOfHour
        )
        return scheduler
    }()

    @Published var isWatchModeEnabled: Bool = false
    @Published var latestWatchModeSummary: String?

    // MARK: - Posture watch (stored state; methods in CompanionManager+PostureWatch.swift)

    @Published var isPostureWatchEnabled: Bool = PaceUserPreferencesStore.bool(
        .isPostureWatchEnabled,
        default: false
    )
    @Published var latestPostureStatus: String?

}

/// Weak-back-reference shim that lets `PaceChatSession` forward typed
/// chat submissions into `CompanionManager.submitChatTranscriptFromChatSession`
/// without owning the manager. Kept outside the class body so it can
/// hold the `weak var` without inheriting `@MainActor`-isolation friction
/// inside `CompanionManager`'s own initializer chain.
@MainActor
final class PaceChatSessionSubmitterAdapter: PaceChatTranscriptSubmitting {
    private weak var owner: CompanionManager?

    init(owner: CompanionManager) {
        self.owner = owner
    }

    func submitChatTranscript(_ transcript: String) {
        owner?.submitChatTranscriptFromChatSession(transcript)
    }
}
