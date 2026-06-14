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
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    /// The live speech transcript shown as an in-progress user bubble in the
    /// chat panel while the user is talking. Holds the streaming partial
    /// during listening, then the final transcript through the turn, and is
    /// cleared once the committed user message lands in the chat transcript.
    @Published private(set) var liveSpeechDraft: String = ""

    /// Most recent partial transcript from the active dictation session.
    /// Used by the post-release safety net so a slow WhisperKit finalize
    /// doesn't lose the user's words — if no final transcript arrives
    /// within the timeout but a partial exists, we treat the partial as
    /// the final instead of dropping the whole turn as "no audio detected".
    private var lastPartialTranscriptFromActiveDictation: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasSpeechRecognitionPermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var hasCalendarPermission = false
    @Published private(set) var hasRemindersPermission = false
    @Published private(set) var shouldRequestCalendarPermission = false
    @Published private(set) var shouldRequestRemindersPermission = false
    @Published private(set) var recentActionResults: [PaceActionRunRecord] = []
    /// Per-turn tool-call debug captures for Settings → Debug. Surfaces the
    /// raw planner output + parsed tool calls + dispatch outcome so a turn
    /// that spoke but did nothing becomes legible. Newest first.
    @Published private(set) var recentToolCallDebugRecords: [PaceToolCallDebugRecord] = []
    /// Element-map line count from the most recent planner prompt, stashed by
    /// `logFirstElementsOfPromptForDiagnostics` so the post-execution debug
    /// capture can report whether the planner actually saw the screen.
    private var lastPlannerElementLineCountForDebug: Int?
    @Published private(set) var localMemorySummary: String = PaceLocalMemoryStore.summaryText
    @Published private(set) var localRetrievalSummary: String = "Retrieval: local preferences and Pace history"
    @Published private(set) var localRetrievalSourceStatuses: [PaceRetrievalSourceStatus] = []
    @Published private(set) var localRetrievalFileRootPaths: [String] = PaceLocalRetrievalFileRootPreferences
        .rootPaths(for: PaceLocalRetrievalFileRootPreferences.userSelectedRootURLs())
    @Published private(set) var currentTurnHUDState: PaceTurnHUDState = .idle

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
    @Published private(set) var mostRecentReversibleActionAt: Date?

    /// Short summary of the most recent reversible action, used as the
    /// undo-banner label (e.g. "Created note", "Started mail draft").
    @Published private(set) var mostRecentReversibleActionSummary: String?

    /// Post-processed spoken text from the most recent assistant turn.
    /// Identical to what flowed through TTS — `<think>` blocks, tool
    /// calls, action tags, and `[POINT:…]` already stripped. The reply
    /// replay button replays exactly this text.
    @Published private(set) var lastSpokenReplyText: String?

    /// Timestamp of when `lastSpokenReplyText` was set. The notch
    /// panel surfaces the replay button when this is within 30 seconds.
    @Published private(set) var lastSpokenReplyAt: Date?

    /// Latest plain-language failure narration Pace surfaced. Carried
    /// on the manager so the panel can render the typed suggestion
    /// (Settings deep-link, configure-MCP hint, etc.) without
    /// re-deriving it from a stringly-typed history record.
    @Published private(set) var lastFailureNarration: PaceFailureNarration?

    /// Timestamp of the last sidecar-TTS-offline narration so the
    /// "switched to system voice" message fires at most once per
    /// outage window rather than on every sentence. Resets when the
    /// sidecar recovers.
    private var lastSidecarTTSOfflineNarratedAt: Date?

    private var pendingIntentClarification: PacePendingIntentClarification?

    /// Set when the executor's click-candidate scoring found multiple
    /// near-tied, distinguishable targets and Pace paused to ask one
    /// short HUD question instead of guessing (PRD
    /// docs/prds/hud-intent-disambiguator.md). Holds the original
    /// candidate set + screen captures so resolving an option clicks the
    /// chosen target directly — it never re-runs the planner.
    private var pendingClickTargetClarification: PacePendingClickTargetClarification?

    let activeTTSVoiceSummary: PaceTTSVoiceSummary = PaceTTSVoiceSummary.current()

    /// True when the configured LM Studio (or compatible) HTTP server
    /// responds within a short timeout. Polled periodically so the panel
    /// can show a "LM Studio not running" hint without the user having to
    /// push-to-talk and watch for silent failure.
    @Published private(set) var isLMStudioReachable = false

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

    /// Tooltip-style bubble that follows the cursor and shows what's
    /// happening through the voice turn: "listening…", interim
    /// transcript, the planner's streaming text. Replaces the pure-
    /// spinner UX so users can see the pipeline is alive when something
    /// (Whisper download, slow LM Studio cold-start, network) is taking
    /// a while.
    private lazy var responseOverlayManager: CompanionResponseOverlayManager = {
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
    private lazy var companionManagerChatSubmitterAdapter: PaceChatSessionSubmitterAdapter = {
        return PaceChatSessionSubmitterAdapter(owner: self)
    }()

    /// Per-turn flag set by `submitChatTranscriptFromChatSession` to the
    /// session's `isChatTTSMuted` snapshot at submission time. The
    /// streaming pipeline reads it through `setMutedForCurrentTurn`
    /// every turn boundary; we don't store this anywhere persistent.
    private var isChatModeMutedForCurrentTurn: Bool = false

    /// Classifies the user's transcript into pureKnowledge /
    /// screenDescription / screenAction / chitchat so the pipeline
    /// can skip work the turn doesn't need. Chitchat bypasses the
    /// planner entirely; pure knowledge takes a text-only planner path.
    /// The rule-based backend ships now; a tiny model can replace it
    /// once it beats these rules on local fixtures.
    private lazy var intentClassifier: any PaceIntentClassifying = {
        return PaceIntentClassifierFactory.makeDefault()
    }()

    // Main reasoning/planning model for screen and action turns.
    // Runtime default remains LocalPlannerClient pointing at LM Studio
    // because the larger local model wins the harder planner fixtures.
    private lazy var plannerClient: any BuddyPlannerClient = {
        return BuddyPlannerClientFactory.makeDefault()
    }()

    // Fast answer planner for pure-knowledge turns. Apple Foundation
    // Models runs in-process when Apple Intelligence is ready; otherwise
    // the factory falls back to the configured local planner.
    private lazy var textOnlyPlannerClient: any BuddyPlannerClient = {
        return BuddyPlannerClientFactory.makeFastTextOnlyPlannerOrFallback()
    }()

    private lazy var localRetriever: PaceLocalRetriever = {
        let retriever = PaceLocalRetriever()
        localRetrievalSourceStatuses = retriever.sourceStatuses
        localRetrievalSummary = localRetrievalSummaryText(from: retriever.sourceStatuses)
        return retriever
    }()

    private lazy var screenTimeRetrievalConnector = PaceScreenTimeRetrievalConnector()

    private lazy var postureMonitor: PacePostureMonitor = {
        let monitor = PacePostureMonitor()
        monitor.onPostureEvent = { [weak self] postureEvent in
            self?.handlePostureEvent(postureEvent)
        }
        return monitor
    }()

    private lazy var appUsageTracker: PaceAppUsageTracker? = PaceAppUsageTracker(
        rehydratedJournal: localRetriever.rehydratedAppUsageJournal(),
        onFlushedDocument: { [weak self] flushedDocument in
            guard let self else { return }
            self.localRetriever.recordAppUsageDocument(flushedDocument)
            self.refreshLocalRetrievalPublishedState()
        }
    )

    private lazy var calendarRetrievalConnector: PaceCalendarRetrievalConnector = {
        return PaceCalendarRetrievalConnector(eventStore: permissionEventStore)
    }()

    private lazy var remindersRetrievalConnector: PaceRemindersRetrievalConnector = {
        return PaceRemindersRetrievalConnector(eventStore: permissionEventStore)
    }()

    private lazy var contactsRetrievalConnector: PaceContactsRetrievalConnector = {
        return PaceContactsRetrievalConnector()
    }()

    private lazy var notesRetrievalConnector: PaceNotesRetrievalConnector = {
        return PaceNotesRetrievalConnector()
    }()

    private lazy var mailRetrievalConnector: PaceMailRetrievalConnector = {
        return PaceMailRetrievalConnector()
    }()

    private lazy var spotlightRetrievalConnector: PaceSpotlightRetrievalConnector = {
        return PaceSpotlightRetrievalConnector(rootURLs: PaceLocalRetrievalFileRootPreferences.configuredRootURLs())
    }()

    // Always the on-device AVSpeechSynthesizer-backed client. Protocol
    // kept so a future local TTS runtime (Kokoro/Piper-MLX) can plug in.
    private lazy var ttsClient: any BuddyTTSClient = {
        return BuddyTTSClientFactory.makeDefault()
    }()

    // The action executor synthesises real mouse/keyboard events on the
    // user's behalf. Gated behind Info.plist EnableActions — when false,
    // every method here logs and returns without posting anything.
    private lazy var actionExecutor: PaceActionExecutor = {
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
    private lazy var flowRecorder: PaceFlowRecorder = PaceFlowRecorder()
    private lazy var flowReplayer: PaceFlowReplayer = PaceFlowReplayer()

    /// Session-scoped approval cache for `run_flow`. First replay of a
    /// given flow name requires explicit user approval; subsequent
    /// replays in the same session bypass the approval popup. Cleared
    /// on session reset by `resetFlowReplayApprovalCacheForSession()`.
    private var flowNamesApprovedForReplayThisSession: Set<String> = []
    /// Deterministic v1 pattern extractor. Fires inline because it is
    /// pure-Swift, sub-millisecond, and catches the obvious preference
    /// / family-health / work-deadline cases without any model call.
    private let episodicPatternExtractor = PaceEpisodicPatternFactExtractor()
    /// LLM-backed extractor (Apple FM preferred, LM Studio fallback)
    /// for everything the pattern extractor misses. Fires from a
    /// DETACHED task — never blocks the user-facing turn.
    private let episodicLLMFactExtractor: PaceEpisodicFactExtractor = PaceEpisodicFactExtractorFactory.makeDefault()
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
    private let visionOCRClient = PaceVisionOCRClient()
    private let permissionEventStore = EKEventStore()
    private lazy var screenWatchModeController: PaceScreenWatchModeController = {
        PaceScreenWatchModeController()
    }()

    /// Fast-tier screen reader. AX tree of the focused window in 5-50ms,
    /// vs 800ms-3s for the VLM. If AX returns ≥1 element we use it +
    /// OCR enrichment and skip the VLM entirely — the common path on
    /// AppKit / SwiftUI / Catalyst apps. VLM is the fallback only when
    /// AX returns nothing useful (Electron-without-AX, games, web
    /// content with broken AX hints).
    private let axScreenReader = PaceAXScreenReader()

    // Screen-context coordinator: owns the per-screen VLM cache, the
    // PTT-press prewarm task, and the AX + OCR + VLM merge logic.
    // Extracted from CompanionManager during Wave 7b — behavior is
    // byte-identical to the pre-extraction code. The `isReadMyScreenEnabled`
    // closure reads the live `@Published` value so toggling the
    // preference in Settings takes effect immediately without a
    // service restart.
    private lazy var screenContextService: PaceScreenContextService = {
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
        case .pureKnowledge, .chitchat, .phoneLargeModel, .unknown:
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
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] {
        return threadMemory.verbatimWindow().map { turnPair in
            (userTranscript: turnPair.userText, assistantResponse: turnPair.assistantText)
        }
    }

    /// Two-tier in-context memory: verbatim window of the last K
    /// turn pairs + rolling summary of everything older. See PRD
    /// docs/prds/conversational-thread-memory.md. Configured from
    /// `PaceUserPreferencesStore` so the picker controls in Settings
    /// can change the window size / idle threshold without a relaunch.
    private lazy var threadMemory: PaceThreadMemory = {
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
    private lazy var threadSummarizerClient: PaceThreadSummarizerClient = {
        PaceThreadSummarizerClientFactory.makeDefault()
    }()

    /// Low-frequency idle sweep so the menu-bar surface can drop
    /// "session live" indicators without needing a new user turn.
    private var threadMemoryIdleSweepTimer: Timer?

    // Per-screen VLM analysis cache lives inside `screenContextService`
    // (Wave 7b extraction). All cache reads in CompanionManager go
    // through `screenContextService.cachedDescriptionIfFresh(...)` or
    // through the planner-prompt path on the service itself.

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var chatShortcutCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?

    /// Wave 1c barge-in plumbing. The VAD is a mutable struct; we hold
    /// it through a class wrapper-style storage (the `var` here works
    /// because CompanionManager is itself a class) so the subscription
    /// path can call `observe(...)` mutably. The subscription is
    /// attached only when both gates fire — `voiceState == .responding`
    /// AND `isAlwaysListeningEnabled == true` — and is torn down the
    /// instant either flips, so the VAD never sees stale audio.
    private var bargeInVAD = PaceBargeInVAD()
    private var bargeInAudioLevelCancellable: AnyCancellable?
    private var bargeInGatePropertyCancellable: AnyCancellable?

    /// Wave 2b — bindings for the wake-word spotter. The toggle
    /// cancellable observes `isAlwaysListeningEnabled` and flips the
    /// spotter on/off; the detection cancellable forwards each
    /// `PaceWakeWordDetection` into `handleWakeWordDetected(_:)`.
    private var wakeWordToggleCancellable: AnyCancellable?
    private var wakeWordDetectionCancellable: AnyCancellable?
    /// PTT-engagement bindings. When PTT starts recording the spotter
    /// pauses so the two audio paths don't fight over the mic; when
    /// PTT releases the spotter resumes if always-listening is still
    /// on. Done as a separate cancellable from the toggle bind so the
    /// two policies (toggle and PTT) compose cleanly.
    private var wakeWordPTTBridgeCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var lmStudioReachabilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    private var lastCalendarRetrievalRefreshAt: Date?
    private var lastCalendarRetrievalAuthorizationStatus: EKAuthorizationStatus?
    private var lastRemindersRetrievalRefreshAt: Date?
    private var lastRemindersRetrievalAuthorizationStatus: EKAuthorizationStatus?
    private var remindersRetrievalRefreshTask: Task<Void, Never>?
    private var lastContactsRetrievalRefreshAt: Date?
    private var lastContactsRetrievalAuthorizationStatus: CNAuthorizationStatus?
    private var contactsRetrievalRefreshTask: Task<Void, Never>?
    private var lastFileRetrievalRefreshAt: Date?
    private var fileRetrievalRefreshTask: Task<Void, Never>?
    private var lastNotesRetrievalRefreshAt: Date?
    private var notesRetrievalRefreshTask: Task<Void, Never>?
    private var lastMailRetrievalRefreshAt: Date?
    private var mailRetrievalRefreshTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?
    /// Safety task scheduled when the user releases PTT. Fires after 5s
    /// and resets the overlay if no transcript arrived. Cancelled if a
    /// transcript shows up first.
    private var transcriptSafetyTask: Task<Void, Never>?

    /// Set to true inside `submitDraftText` so the safety task can tell
    /// whether the transcription delivered. Reset on each new press.
    private var transcriptArrivedSinceRelease: Bool = false

    /// Flipped to true when the active transcription provider has
    /// finished any background model load. Apple Speech / cloud
    /// providers report ready immediately; WhisperKit reports ready
    /// after CoreML compile (~15s first run, instant once cached).
    /// PTT presses while this is false are rejected with a "model
    /// loading" message so they don't hang the audio engine.
    @Published private(set) var isTranscriptionModelReady: Bool = false

    /// How the current voice turn was triggered. Drives where the response
    /// bubble pins itself: `.keyboard` anchors it next to the system
    /// cursor (so it visually rides with the Codex arrow); `.avatar`
    /// anchors it next to the walking character. Cleared back to
    /// `.keyboard` when the turn ends.
    enum DictationTrigger { case keyboard, avatar }
    private(set) var currentDictationTrigger: DictationTrigger = .keyboard

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
    @Published private(set) var isOverlayVisible: Bool = false

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

    func smokeSetCursorAnnotationsEnabled(_ enabled: Bool) -> Bool {
        setCursorAnnotationsEnabled(enabled)
        return areCursorAnnotationsEnabled
    }

    /// User preference for whether Pace asks before higher-risk local tools.
    /// Routine reversible or visible actions auto-run; non-undoable app
    /// mutations, external tools, and blocking preflight issues still prompt.
    @Published var requiresActionApproval: Bool = PaceUserPreferencesStore
        .bool(.requiresActionApproval, default: true)

    func setRequiresActionApproval(_ enabled: Bool) {
        requiresActionApproval = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .requiresActionApproval)
    }

    // MARK: - Cloud bridge published state

    /// The user's chosen bridge routing mode. Persisted via `PaceCloudBridgeConsent`.
    @Published private(set) var cloudBridgeMode: PaceCloudBridgeMode = {
        PaceCloudBridgeConsent.loadConfiguration().mode
    }()

    /// Which CLI upstream the bridge should use (Claude Code / Codex / Gemini).
    @Published private(set) var cloudBridgeUpstream: PaceCloudBridgeUpstream = {
        PaceCloudBridgeConsent.loadConfiguration().upstream
    }()

    /// Model identifier string forwarded to the bridge (e.g. "sonnet").
    @Published private(set) var cloudBridgeModel: String = {
        PaceCloudBridgeConsent.loadConfiguration().model
    }()

    /// Set to true when a cloud-bridge SSE stream is actively in progress.
    /// Observed by `PaceMenuBarOverlay` to tint the right-icon slot amber.
    @Published private(set) var isCloudBridgeCallActive: Bool = false

    // MARK: - Planner tier picker state

    /// The user's chosen planner tier from Settings → Planner. Default is
    /// `.local` for existing users — no UserDefaults state means the
    /// factory returns the same LM Studio planner as before.
    @Published private(set) var activePlannerTier: PacePlannerTier = {
        PacePlannerTierStore.loadConfiguration().tier
    }()

    /// The provider Direct-API turns will target when tier == .directAPI.
    @Published private(set) var directAPIProvider: PaceDirectAPIProvider = {
        PacePlannerTierStore.loadConfiguration().directAPIProvider
    }()

    /// The model identifier sent in the Direct-API request body.
    @Published private(set) var directAPIModelIdentifier: String = {
        PacePlannerTierStore.loadConfiguration().directAPIModelIdentifier
    }()

    /// The user-pasted endpoint URL string, used only when provider == .custom.
    @Published private(set) var directAPICustomEndpointURLString: String = {
        PacePlannerTierStore.loadConfiguration().directAPICustomEndpointURLString
    }()

    /// Opt-in: when true AND a Direct-API turn errors, Pace retries the
    /// SAME turn against LM Studio. Default is OFF so failures fail loud.
    @Published private(set) var directAPIFallsBackToLocalOnCloudFailure: Bool = {
        PacePlannerTierStore.loadConfiguration().fallsBackToLocalOnCloudFailure
    }()

    /// True when ANY non-Local tier (cliBridge OR directAPI) is actively
    /// streaming. The menu-bar capsule observes this for the amber tint
    /// so EVERY off-device turn is visible, not just bridge calls.
    /// `isCloudBridgeCallActive` remains as a subset for backward compat
    /// during the v1 cycle and continues to set/reset alongside this flag.
    @Published private(set) var isOffDeviceTurnInFlight: Bool = false

    func setActivePlannerTier(_ newTier: PacePlannerTier) {
        activePlannerTier = newTier
        PacePlannerTierStore.saveTier(newTier)
        // Rebuild planner so the next turn uses the freshly-picked tier
        // without requiring an app restart.
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    func setDirectAPIProvider(_ newProvider: PaceDirectAPIProvider) {
        directAPIProvider = newProvider
        PacePlannerTierStore.saveDirectAPIProvider(newProvider)
        // When the provider changes, also seed the model field with that
        // provider's default — the user can immediately overwrite it but
        // most users want a sensible starting model identifier.
        let savedModelForProvider = PacePlannerTierStore.loadConfiguration().directAPIModelIdentifier
        let modelIdentifierLooksEmptyOrStale = savedModelForProvider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if modelIdentifierLooksEmptyOrStale {
            setDirectAPIModelIdentifier(newProvider.defaultModelIdentifier)
        }
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    func setDirectAPIModelIdentifier(_ newModelIdentifier: String) {
        directAPIModelIdentifier = newModelIdentifier
        PacePlannerTierStore.saveDirectAPIModelIdentifier(newModelIdentifier)
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    func setDirectAPICustomEndpointURLString(_ newCustomEndpointURLString: String) {
        directAPICustomEndpointURLString = newCustomEndpointURLString
        PacePlannerTierStore.saveDirectAPICustomEndpointURL(newCustomEndpointURLString)
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    func setDirectAPIFallsBackToLocalOnCloudFailure(_ enabled: Bool) {
        directAPIFallsBackToLocalOnCloudFailure = enabled
        PacePlannerTierStore.saveFallsBackToLocalOnCloudFailure(enabled)
    }

    /// Whether the active planner tier is one that leaves the Mac.
    /// Cliff-edge gates: cliBridge requires consent AND a non-off mode;
    /// directAPI requires a stored key. Both checks mirror the factory
    /// so the UI flag stays honest.
    var activePlannerTierIsOffDevice: Bool {
        switch activePlannerTier {
        case .local, .appleFoundationModels:
            return false
        case .cliBridge:
            let bridgeConfiguration = PaceCloudBridgeConsent.loadConfiguration()
            return bridgeConfiguration.hasUserAcceptedConsent
                && bridgeConfiguration.mode != .off
        case .directAPI:
            return PaceKeychainStore.loadAPIKey(for: directAPIProvider) != nil
        }
    }

    /// Verifies that the configured Direct-API provider, model, and key
    /// can complete a single round trip. Builds a one-off
    /// `DirectAPIPlannerClient` rather than reusing the active
    /// `plannerClient` so the test does not disturb live state and is
    /// not blocked by the tier choice. Surfaces the upstream error
    /// verbatim on failure — users debugging API issues need to see the
    /// provider's actual error string to find it in provider docs.
    func runDirectAPITestRoundTrip() async -> Result<String, Error> {
        let configurationAtTestTime = PacePlannerTierStore.loadConfiguration()
        let resolvedEndpointURLString = PacePlannerTierStore
            .resolvedDirectAPIEndpointURLString(for: configurationAtTestTime)

        let validatedEndpointURL: URL
        do {
            validatedEndpointURL = try PaceLocalEndpointGuard.validatedDirectAPIURL(
                from: resolvedEndpointURLString
            )
        } catch {
            return .failure(error)
        }

        let testOnlyPlannerClient = DirectAPIPlannerClient(
            provider: configurationAtTestTime.directAPIProvider,
            endpointURL: validatedEndpointURL,
            modelIdentifier: configurationAtTestTime.directAPIModelIdentifier
        )

        do {
            let (responseText, _) = try await testOnlyPlannerClient.generateResponseStreaming(
                images: [],
                systemPrompt: "You are a connectivity-test echo. Respond with the model identifier you are, in exactly one word.",
                conversationHistory: [],
                userPrompt: "hi",
                onTextChunk: { _ in }
            )
            let trimmedResponseText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(String(trimmedResponseText.prefix(60)))
        } catch {
            return .failure(error)
        }
    }

    /// Stores the user-pasted API key for the active Direct-API provider
    /// and rebuilds the planner so the new key is picked up on the next
    /// turn. The key value is passed straight to `PaceKeychainStore` and
    /// is never persisted anywhere else.
    @discardableResult
    func saveDirectAPIKey(_ apiKey: String, for provider: PaceDirectAPIProvider) -> Bool {
        let didStore = PaceKeychainStore.storeAPIKey(apiKey, for: provider)
        if didStore {
            plannerClient = BuddyPlannerClientFactory.makeDefault()
        }
        return didStore
    }

    /// Removes the stored API key for the given provider and rebuilds the
    /// planner so the next turn either falls back to local (when no other
    /// key is present) or picks up a different stored provider.
    @discardableResult
    func deleteDirectAPIKey(for provider: PaceDirectAPIProvider) -> Bool {
        let didDelete = PaceKeychainStore.deleteAPIKey(for: provider)
        if didDelete {
            plannerClient = BuddyPlannerClientFactory.makeDefault()
        }
        return didDelete
    }

    /// Snapshot of which providers currently have an API key in Keychain.
    /// Settings UI calls this to show a green checkmark next to a saved
    /// provider.
    func providersWithStoredDirectAPIKeys() -> Set<PaceDirectAPIProvider> {
        return PaceKeychainStore.providersWithStoredKeys()
    }

    func setCloudBridgeMode(_ mode: PaceCloudBridgeMode) {
        cloudBridgeMode = mode
        PaceCloudBridgeConsent.saveMode(mode)
        // Rebuild the planner so the new mode takes effect on the next turn
        // without requiring an app restart.
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    func setCloudBridgeUpstream(_ upstream: PaceCloudBridgeUpstream) {
        cloudBridgeUpstream = upstream
        PaceCloudBridgeConsent.saveUpstream(upstream)
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    func setCloudBridgeModel(_ model: String) {
        cloudBridgeModel = model
        PaceCloudBridgeConsent.saveModel(model)
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    /// Shows the one-time cloud-bridge consent NSAlert.
    /// Returns true if the user tapped "Use the bridge", false if they cancelled.
    /// Persists acceptance via `PaceCloudBridgeConsent.acceptConsent()` on approval.
    func requestCloudBridgeConsentIfNeeded() -> Bool {
        let currentConfiguration = PaceCloudBridgeConsent.loadConfiguration()
        guard !currentConfiguration.hasUserAcceptedConsent else {
            // Already accepted — no dialog needed.
            return true
        }

        let consentAlert = NSAlert()
        consentAlert.alertStyle = .warning
        consentAlert.messageText = "Send data outside Pace?"
        consentAlert.informativeText = """
The cloud bridge sends your transcript and the planner system \
prompt to the upstream CLI you choose (Claude Code, Codex, or \
Gemini CLI), which in turn calls Anthropic, OpenAI, or Google \
servers respectively. Their data-handling policies apply.

Pace will show an indicator in the menu-bar capsule whenever a \
bridge call is in flight. Push-to-talk text-only turns still \
default to your local planner; the bridge is used only for \
turns Pace would otherwise refuse as "too hard locally."

You can turn this off at any time in Settings → Cloud bridge.
"""
        consentAlert.addButton(withTitle: "Use the bridge")
        consentAlert.addButton(withTitle: "Keep local only")

        NSApp.activate(ignoringOtherApps: true)
        let userResponse = consentAlert.runModal()
        let userAccepted = userResponse == .alertFirstButtonReturn

        if userAccepted {
            PaceCloudBridgeConsent.acceptConsent()
        }
        return userAccepted
    }

    @Published var isAlwaysListeningEnabled: Bool = PaceUserPreferencesStore
        .bool(.isAlwaysListeningEnabled, default: false)

    func setAlwaysListeningEnabled(_ enabled: Bool) {
        isAlwaysListeningEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .isAlwaysListeningEnabled)
    }

    @Published var areFocusFatigueNudgesEnabled: Bool = PaceUserPreferencesStore
        .bool(.areFocusFatigueNudgesEnabled, default: false)

    func setFocusFatigueNudgesEnabled(_ enabled: Bool) {
        areFocusFatigueNudgesEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .areFocusFatigueNudgesEnabled)
        proactivityPipeline.setGeneratorEnabled(
            identifier: proactivityPipeline.focusFatigueNudgeGeneratorIdentifier,
            enabled: enabled
        )
    }

    @Published var areCalendarNudgesEnabled: Bool = PaceUserPreferencesStore
        .bool(.areCalendarNudgesEnabled, default: false)

    func setCalendarNudgesEnabled(_ enabled: Bool) {
        areCalendarNudgesEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .areCalendarNudgesEnabled)
        proactivityPipeline.setGeneratorEnabled(
            identifier: proactivityPipeline.calendarPreMeetingNudgeGeneratorIdentifier,
            enabled: enabled
        )
    }

    @Published var areWatchObservationNudgesEnabled: Bool = PaceUserPreferencesStore
        .bool(.areWatchObservationNudgesEnabled, default: false)

    func setWatchObservationNudgesEnabled(_ enabled: Bool) {
        areWatchObservationNudgesEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .areWatchObservationNudgesEnabled)
        proactivityPipeline.setGeneratorEnabled(
            identifier: proactivityPipeline.watchModeObservationNudgeGeneratorIdentifier,
            enabled: enabled
        )
    }

    // MARK: - Proactivity profile

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

    func setProactivityProfile(_ profile: PaceProactivityProfile) {
        proactivityProfile = profile
    }

    // MARK: - Proactive pipeline (Wave 7a extraction)
    //
    // The ≤3 ring buffer, 10s drain timer, three nudge generators,
    // orchestrator wiring, and live restraint-context construction
    // all live in `PaceProactivityPipeline`. CompanionManager keeps
    // tiny forwarders so the test surface
    // (`enqueueProactiveUtterance`, `proactiveUtteranceQueueSnapshot`,
    // `drainProactiveQueueIfIdle`) stays byte-identical for callers.

    private lazy var proactivityPipeline: PaceProactivityPipeline = {
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

    /// Thin forwarder. Tests and the morning-triage scheduler call
    /// this to park an utterance for the idle drain.
    func enqueueProactiveUtterance(_ utterance: PaceProactiveUtterance) {
        proactivityPipeline.enqueueProactiveUtterance(utterance)
    }

    /// Test seam preserved from the pre-extraction surface.
    func proactiveUtteranceQueueSnapshot() -> [PaceProactiveUtterance] {
        return proactivityPipeline.proactiveUtteranceQueueSnapshot()
    }

    /// Test seam preserved from the pre-extraction surface. Lets the
    /// HerArc tests trigger a drain attempt without waiting for the
    /// 10-second timer to fire.
    func drainProactiveQueueIfIdle(now: Date = Date()) {
        proactivityPipeline.drainProactiveQueueIfIdle(now: now)
    }

    // MARK: - Morning triage (daily brief)

    /// User-facing master switch for the daily weekday morning brief.
    /// Default OFF — the scheduler stays inert until the user
    /// explicitly enables this in Settings. See PRD
    /// docs/prds/morning-triage.md.
    @Published var isMorningTriageEnabled: Bool = PaceUserPreferencesStore
        .bool(.isMorningTriageEnabled, default: false)

    func setMorningTriageEnabled(_ enabled: Bool) {
        isMorningTriageEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .isMorningTriageEnabled)
        if enabled {
            morningTriageScheduler.start()
        } else {
            morningTriageScheduler.stop()
        }
    }

    /// Hour-of-day at which the brief fires on weekdays. Clamped 0...23
    /// on read so a corrupted UserDefaults value can't break the timer.
    @Published var morningTriageHourOfDay: Int = PaceUserPreferencesStore
        .clampedInt(.morningTriageHourOfDay, default: 8, in: 0...23)

    func setMorningTriageHourOfDay(_ hourOfDay: Int) {
        let clampedHourOfDay = min(max(hourOfDay, 0), 23)
        morningTriageHourOfDay = clampedHourOfDay
        PaceUserPreferencesStore.setInt(clampedHourOfDay, for: .morningTriageHourOfDay)
        morningTriageScheduler.setFireTime(
            hourOfDay: clampedHourOfDay,
            minuteOfHour: morningTriageMinuteOfHour
        )
    }

    /// Minute-of-hour at which the brief fires. Clamped 0...59 on read.
    @Published var morningTriageMinuteOfHour: Int = PaceUserPreferencesStore
        .clampedInt(.morningTriageMinuteOfHour, default: 30, in: 0...59)

    func setMorningTriageMinuteOfHour(_ minuteOfHour: Int) {
        let clampedMinuteOfHour = min(max(minuteOfHour, 0), 59)
        morningTriageMinuteOfHour = clampedMinuteOfHour
        PaceUserPreferencesStore.setInt(clampedMinuteOfHour, for: .morningTriageMinuteOfHour)
        morningTriageScheduler.setFireTime(
            hourOfDay: morningTriageHourOfDay,
            minuteOfHour: clampedMinuteOfHour
        )
    }

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

    /// Pulls compact typed inputs from currently-indexed retrieval
    /// documents. Calendar / mail / reminders / app-usage all come
    /// from the same retriever the rest of the app uses, so the brief
    /// degrades gracefully to whatever is enabled without crashing.
    private func buildMorningBriefInputs(forNow now: Date) -> PaceMorningBriefInputs {
        let calendarBriefEvents = todaysCalendarBriefEvents(forNow: now)
        let (unreadMailCount, topMailSender, topMailSubject) = morningMailSummary()
        let (openRemindersDueToday, topReminderTitle, topReminderDueText) = morningRemindersSummary(forNow: now)
        let (yesterdayTopApp, yesterdayTopAppMinutes) = yesterdayAppUsageSummary(forNow: now)
        let yesterdayWatchHighlight = yesterdayWatchHighlightSummary(forNow: now)

        return PaceMorningBriefInputs(
            now: now,
            userFirstName: nil,
            todaysEvents: calendarBriefEvents,
            unreadMailCount: unreadMailCount,
            topMailSender: topMailSender,
            topMailSubject: topMailSubject,
            openRemindersDueToday: openRemindersDueToday,
            topReminderTitle: topReminderTitle,
            topReminderDueText: topReminderDueText,
            yesterdayTopApp: yesterdayTopApp,
            yesterdayTopAppMinutes: yesterdayTopAppMinutes,
            yesterdayWatchHighlight: yesterdayWatchHighlight
        )
    }

    /// Lightweight today-only view of indexed calendar events. We don't
    /// hit EventKit here — the retriever already mirrors calendar state
    /// through its per-source refresh, and the brief only needs title +
    /// start time to compose the spoken paragraph.
    private func todaysCalendarBriefEvents(forNow now: Date) -> [CalendarBriefEvent] {
        guard localRetriever.isSourceEnabled(.calendar) else { return [] }
        // The connector keeps the start date on the document's
        // `modifiedAt` field, so we filter by same-day there to find
        // today's events without re-parsing the indexed text body.
        let calendarUserCalendar = Calendar.current
        let documentsWithStartDate: [(document: PaceRetrievalDocument, startDate: Date)] = localRetriever
            .documents(forSource: .calendar)
            .compactMap { document in
                guard let documentModifiedAt = document.modifiedAt else { return nil }
                return (document, documentModifiedAt)
            }
            .filter { calendarUserCalendar.isDate($0.startDate, inSameDayAs: now) }
            .sorted { $0.startDate < $1.startDate }
        return documentsWithStartDate
            .prefix(2)
            .map { documentAndStartDate in
                CalendarBriefEvent(
                    title: documentAndStartDate.document.title,
                    startDate: documentAndStartDate.startDate,
                    isAllDay: false
                )
            }
    }

    /// Best-effort unread-mail summary. v1: counts indexed mail
    /// documents touched in the last 18 hours. A v2 connector could
    /// expose a richer typed snapshot.
    private func morningMailSummary() -> (count: Int, topSender: String?, topSubject: String?) {
        guard localRetriever.isSourceEnabled(.mail) else { return (0, nil, nil) }
        let recentMailDocuments = localRetriever
            .documents(forSource: .mail)
            .sorted { firstDocument, secondDocument in
                let firstModifiedAt = firstDocument.modifiedAt ?? .distantPast
                let secondModifiedAt = secondDocument.modifiedAt ?? .distantPast
                return firstModifiedAt > secondModifiedAt
            }
            .prefix(20)
        let topDocument = recentMailDocuments.first
        return (recentMailDocuments.count, nil, topDocument?.title)
    }

    /// Best-effort reminders summary. v1: counts indexed reminder
    /// documents whose modifiedAt sits today.
    private func morningRemindersSummary(forNow now: Date) -> (count: Int, topTitle: String?, topDueText: String?) {
        guard localRetriever.isSourceEnabled(.reminders) else { return (0, nil, nil) }
        let calendarUserCalendar = Calendar.current
        let documentsWithDueDate: [(document: PaceRetrievalDocument, dueDate: Date)] = localRetriever
            .documents(forSource: .reminders)
            .compactMap { document in
                guard let documentModifiedAt = document.modifiedAt else { return nil }
                return (document, documentModifiedAt)
            }
            .filter { calendarUserCalendar.isDate($0.dueDate, inSameDayAs: now) }
            .sorted { $0.dueDate < $1.dueDate }
        let topPair = documentsWithDueDate.first
        let topDueText: String?
        if let topPairDueDate = topPair?.dueDate {
            let dueDateFormatter = DateFormatter()
            dueDateFormatter.dateStyle = .none
            dueDateFormatter.timeStyle = .short
            dueDateFormatter.locale = Locale(identifier: "en_US_POSIX")
            topDueText = "due at \(dueDateFormatter.string(from: topPairDueDate).lowercased())"
        } else {
            topDueText = nil
        }
        return (documentsWithDueDate.count, topPair?.document.title, topDueText)
    }

    /// Best-effort yesterday app-usage summary. We let the journal
    /// formatter render its own line; the brief only needs the top
    /// app name + minutes, so we parse the first usage line.
    private func yesterdayAppUsageSummary(forNow now: Date) -> (topApp: String?, minutes: Int?) {
        guard localRetriever.isSourceEnabled(.appUsageHistory) else { return (nil, nil) }
        let calendarUserCalendar = Calendar.current
        guard let yesterday = calendarUserCalendar.date(byAdding: .day, value: -1, to: now) else {
            return (nil, nil)
        }
        let yesterdayUsageDocument = localRetriever
            .documents(forSource: .appUsageHistory)
            .first { document in
                guard let documentModifiedAt = document.modifiedAt else { return false }
                return calendarUserCalendar.isDate(documentModifiedAt, inSameDayAs: yesterday)
            }
        guard let yesterdayUsageDocumentText = yesterdayUsageDocument?.text else {
            return (nil, nil)
        }
        return parseYesterdayTopAppUsageLine(yesterdayUsageDocumentText)
    }

    /// Pulls the top-app + minutes from the first usage line written
    /// by `PaceAppUsageJournal`. Done as a tiny pure parser so it
    /// can be unit-checked separately if the journal format changes.
    private func parseYesterdayTopAppUsageLine(_ usageDocumentText: String) -> (topApp: String?, minutes: Int?) {
        // The journal lines look like: "Xcode — 240 min · 14 switches".
        // We only need the first meaningful line; the doc may include
        // a date header on line 0.
        let candidateLines = usageDocumentText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for candidateLine in candidateLines {
            guard candidateLine.contains("min") else { continue }
            let separatorRange = candidateLine.range(of: " — ")
                ?? candidateLine.range(of: " - ")
                ?? candidateLine.range(of: ":")
            guard let separatorRange else { continue }
            let topAppName = String(candidateLine[..<separatorRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let remainderText = candidateLine[separatorRange.upperBound...]
            guard let digitsStartIndex = remainderText.firstIndex(where: { $0.isNumber }) else {
                continue
            }
            let digitsRemainder = remainderText[digitsStartIndex...]
            let digitsEndIndex = digitsRemainder.firstIndex(where: { !$0.isNumber }) ?? digitsRemainder.endIndex
            guard let parsedMinutes = Int(digitsRemainder[..<digitsEndIndex]) else { continue }
            return (topAppName.isEmpty ? nil : topAppName, parsedMinutes)
        }
        return (nil, nil)
    }

    /// Best-effort yesterday watch-mode highlight. v1: returns the first
    /// non-empty line from yesterday's watch-journal document.
    private func yesterdayWatchHighlightSummary(forNow now: Date) -> String? {
        guard localRetriever.isSourceEnabled(.screenWatchHistory) else { return nil }
        let calendarUserCalendar = Calendar.current
        guard let yesterday = calendarUserCalendar.date(byAdding: .day, value: -1, to: now) else {
            return nil
        }
        let yesterdayWatchDocument = localRetriever
            .documents(forSource: .screenWatchHistory)
            .first { document in
                guard let documentModifiedAt = document.modifiedAt else { return false }
                return calendarUserCalendar.isDate(documentModifiedAt, inSameDayAs: yesterday)
            }
        return yesterdayWatchDocument?.title
    }

    /// Plays the queued morning-brief card aloud and clears it.
    /// Wired to the small play button on the brief card so users who
    /// missed the spoken brief can hear it on demand.
    func playPendingMorningBrief() {
        guard let pendingMorningBriefText = morningTriageScheduler.pendingMorningBriefCard else { return }
        Task { @MainActor in
            try? await self.ttsClient.speakText(pendingMorningBriefText)
            self.morningTriageScheduler.dismissPendingCard()
        }
    }

    /// User-initiated preview entry point used by Settings → "Send it now".
    /// Wraps `morningTriageScheduler.deliverNowForTesting()` so the
    /// SwiftUI button can call a synchronous-looking API.
    func deliverMorningBriefPreviewNow() {
        Task { @MainActor in
            await self.morningTriageScheduler.deliverNowForTesting()
        }
    }

    /// Builds the gate context for a morning-brief fire. Uses
    /// conservative defaults — the gate's main job for this source
    /// is the active-call check.
    private func buildMorningTriageRestraintContext(forNow now: Date) -> PaceRestraintContext {
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: userInputActivityMonitor.lastUserInputAt,
            frontmostAppBundleIdentifier: frontmostBundleIdentifier,
            isOnActiveCall: activeCallDetector.isOnActiveCall,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .morningTriage,
            profile: proactivityProfile
        )
    }

    @Published private(set) var isWatchModeEnabled: Bool = false
    @Published private(set) var latestWatchModeSummary: String?

    func setWatchModeEnabled(_ enabled: Bool) {
        guard enabled != isWatchModeEnabled else { return }
        isWatchModeEnabled = enabled

        if enabled {
            latestWatchModeSummary = "Watching for screen changes"
            screenWatchModeController.startWatching { [weak self] event in
                await self?.handleWatchModeEvent(event)
            }
        } else {
            screenWatchModeController.stopWatching()
            latestWatchModeSummary = nil
        }
    }

    // MARK: - Posture watch

    @Published private(set) var isPostureWatchEnabled: Bool = PaceUserPreferencesStore.bool(
        .isPostureWatchEnabled,
        default: false
    )
    @Published private(set) var latestPostureStatus: String?

    func setPostureWatchEnabled(_ enabled: Bool) {
        guard enabled != isPostureWatchEnabled else { return }
        isPostureWatchEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .isPostureWatchEnabled)
        if enabled {
            latestPostureStatus = "Calibrating — sit how you'd like to sit"
            postureMonitor.start()
        } else {
            postureMonitor.stop()
            latestPostureStatus = nil
        }
    }

    func recalibratePostureWatch() {
        guard isPostureWatchEnabled else { return }
        postureMonitor.recalibrate()
        latestPostureStatus = "Calibrating — sit how you'd like to sit"
    }

    private func handlePostureEvent(_ postureEvent: PacePostureEvent) {
        switch postureEvent {
        case .calibrated:
            latestPostureStatus = "Watching posture"
            print("📷 Posture watch calibrated")
        case .alert(let assessment):
            latestPostureStatus = "Nudged: \(assessment.displayName)"
            print("📷 Posture alert: \(assessment.displayName)")
            // Speak only when no turn is in flight — a posture nudge should
            // never talk over an answer the user asked for.
            guard voiceState == .idle else { return }
            Task {
                await streamingSentenceTTSPipeline.flushFinal(
                    finalSpokenText: assessment.spokenNudge
                )
            }
        }
    }

    private func handleWatchModeEvent(_ event: PaceScreenWatchEvent) async {
        let summary = "\(event.category.displayName): \(event.screenLabel)"
        latestWatchModeSummary = summary
        print("👀 Watch mode: \(summary) meanDelta=\(String(format: "%.2f", event.diff.meanPixelDelta)) changedRatio=\(String(format: "%.3f", event.diff.changedPixelRatio))")

        // Journal before the idle guard — that guard only exists to avoid
        // speaking over an in-flight turn, but history should be captured
        // regardless of what the voice pipeline is doing.
        recordWatchModeEventInJournal(event)

        guard voiceState == .idle else { return }

        responseOverlayManager.showOverlayAndBeginStreaming()
        let spokenWatchModeSummary = "i noticed a \(event.category.displayName)."
        responseOverlayManager.updateStreamingText(spokenWatchModeSummary)
        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenWatchModeSummary)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
        }
    }

    private func recordWatchModeEventInJournal(_ event: PaceScreenWatchEvent) {
        // Frontmost app name is a cheap synchronous NSWorkspace read — the
        // same source the ASR contextual-phrase builder uses.
        let frontmostApplicationName = NSWorkspace.shared.frontmostApplication?.localizedName
        // Reuse the per-screen VLM cache only while it is fresh enough to
        // still describe roughly what the user is looking at. Never run the
        // VLM from here — journaling must stay free.
        let freshCachedScreenDescription = screenContextService.cachedDescriptionIfFresh(
            screenLabel: event.screenLabel,
            maxAgeSeconds: 120,
            referenceDate: event.detectedAt
        )
        localRetriever.recordScreenWatchObservation(
            screenLabel: event.screenLabel,
            categoryDisplayName: event.category.displayName,
            frontmostApplicationName: frontmostApplicationName,
            screenDescription: freshCachedScreenDescription,
            now: event.detectedAt
        )
        refreshLocalRetrievalPublishedState()
    }

    private func requestUserApprovalForActionPlan(
        _ actionExecutionPlan: PaceActionExecutionPlan,
        preflightIssues: [PaceToolPreflightIssue] = [],
        smokeAutoCancelAfter: TimeInterval? = nil
    ) -> Bool {
        let hasBlockingPreflightIssue = preflightIssues.contains { $0.severity == .blocking }
        let shouldRequestApproval = hasBlockingPreflightIssue
            || (
                requiresActionApproval
                    && PaceActionApprovalPolicy.requiresExplicitApproval(
                        for: actionExecutionPlan
                    )
            )
        let approvalRequest = PaceActionApprovalRequest(
            approvalSummary: actionExecutionPlan.approvalSummary,
            preflightSummary: PaceToolPreflightIssue.formatForApproval(preflightIssues),
            requiresActionApproval: shouldRequestApproval
        )
        guard let approvalRequest else {
            return PaceActionApprovalPolicy.shouldExecuteActions(
                request: nil,
                decision: .allowOnce
            )
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = approvalRequest.messageText
        alert.informativeText = approvalRequest.informativeText
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Allow Once")

        if let smokeAutoCancelAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + smokeAutoCancelAfter) {
                alert.window.close()
                NSApp.abortModal()
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        let approvalDecision: PaceActionApprovalDecision =
            alert.runModal() == .alertSecondButtonReturn ? .allowOnce : .cancel
        return PaceActionApprovalPolicy.shouldExecuteActions(
            request: approvalRequest,
            decision: approvalDecision
        )
    }

    func smokeRequestApprovalForSyntheticActionPlan() -> Bool {
        let syntheticActionPlan = PaceActionExecutionPlan.serial(actions: [
            .composeMail(PaceMailDraft(
                recipients: ["smoke@example.com"],
                subject: "Pace approval smoke",
                body: "Synthetic draft used only to verify approval cancellation."
            ))
        ])
        return requestUserApprovalForActionPlan(
            syntheticActionPlan,
            smokeAutoCancelAfter: 0.5
        )
    }

    func smokeShowSyntheticClarification() -> Bool {
        let clarification = PaceIntentClarification(
            question: "Edit selected text or the focused field?",
            options: ["Selected text", "Focused field"]
        )
        pendingIntentClarification = PacePendingIntentClarification(
            originalTranscript: "rewrite that",
            clarification: clarification
        )
        currentTurnHUDState = .clarification(
            question: clarification.question,
            options: clarification.options
        )
        return currentTurnHUDState.status == .needsClarification
    }

    func smokeResolveSyntheticClarification() -> String? {
        guard let pendingIntentClarification else { return nil }
        guard let clarifiedTranscript = PaceIntentClarificationResolver.clarifiedTranscript(
            for: pendingIntentClarification,
            selectedOption: "Selected text"
        ) else {
            return nil
        }

        self.pendingIntentClarification = nil
        currentTurnHUDState = .done("clarified")
        return clarifiedTranscript
    }

    private func appendActionResult(_ actionResult: PaceActionRunRecord) {
        var updatedActionResults = recentActionResults
        updatedActionResults.insert(actionResult, at: 0)
        if updatedActionResults.count > 8 {
            updatedActionResults.removeLast(updatedActionResults.count - 8)
        }
        recentActionResults = updatedActionResults

        switch actionResult.status {
        case .planned:
            currentTurnHUDState = .acting(actionResult.title)
        case .completed:
            currentTurnHUDState = .done(actionResult.title)
        case .failed, .skipped:
            currentTurnHUDState = .failed(actionResult.detail)
        case .denied:
            currentTurnHUDState = .failed("Action cancelled")
        }
    }

    /// Append one tool-call debug capture for Settings → Debug. Newest
    /// first, capped so the buffer never grows unbounded. Purely an
    /// observability sink — never affects routing, speech, or execution.
    private func recordToolCallDebug(_ record: PaceToolCallDebugRecord) {
        var updatedDebugRecords = recentToolCallDebugRecords
        updatedDebugRecords.insert(record, at: 0)
        let maximumRetainedDebugRecords = 25
        if updatedDebugRecords.count > maximumRetainedDebugRecords {
            updatedDebugRecords.removeLast(updatedDebugRecords.count - maximumRetainedDebugRecords)
        }
        recentToolCallDebugRecords = updatedDebugRecords
        // Persist to the JSONL trace file so the history survives restarts
        // and can be inspected outside the app (off the main actor).
        PaceToolCallDebugTrace.append(record)
    }

    /// Clear the Settings → Debug tool-call capture buffer AND the persisted
    /// trace file.
    func clearToolCallDebugRecords() {
        recentToolCallDebugRecords = []
        PaceToolCallDebugTrace.clear()
    }

    /// Seed the in-memory debug list from the persisted trace file so the
    /// Debug tab shows history from previous sessions, not just this one.
    private func loadPersistedToolCallDebugRecords() {
        recentToolCallDebugRecords = PaceToolCallDebugTrace.loadRecent(limit: 25)
    }

    /// One line per parsed tool call, e.g. "open_url: Open URL:
    /// https://google.com". "no actions parsed" means the planner produced
    /// only spoken text — which is exactly the "opening the browser menu did
    /// nothing" signature.
    /// True when the streamed planner text is the v10 JSON envelope rather
    /// than free prose. The main (action) planner is decode-constrained to
    /// emit `{spokenText,…}`, so its stream must NOT be spoken raw — the
    /// parsed `spokenText` is flushed at turn end instead. Free prose
    /// (answers, descriptions, the lite race path) never starts with "{".
    nonisolated static func streamedPlannerTextIsStructuredEnvelope(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
    }

    private static func toolCallDebugSummary(
        for executionPlan: PaceActionExecutionPlan
    ) -> String {
        let parsedActions = executionPlan.flattenedActions
        guard !parsedActions.isEmpty else { return "no actions parsed" }
        return parsedActions
            .map { "\($0.auditOperationName): \($0.approvalDescription)" }
            .joined(separator: "\n")
    }

    // MARK: - Trust surfaces (undo banner + reply replay)

    /// Returns the first click candidate's text label (if known) from
    /// the supplied plan, used to make the click-missed narration
    /// concrete ("I couldn't find a save button…"). Falls back to nil
    /// for coordinate-only clicks; the narrator then emits generic
    /// copy.
    private static func firstClickCandidateLabel(
        in actionExecutionPlan: PaceActionExecutionPlan
    ) -> String? {
        for action in actionExecutionPlan.flattenedActions {
            if case .clickCandidates(let candidateSet) = action {
                for candidate in candidateSet.candidates {
                    if let label = candidate.label?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !label.isEmpty {
                        return label
                    }
                }
            }
        }
        return nil
    }

    /// Records that a reversible action just executed. Called from the
    /// post-action site in the agent loop / fast-action path. The
    /// cursor overlay observes the published fields and shows the
    /// undo banner for the next 5 seconds.
    private func noteReversibleActionExecuted(
        in actionExecutionPlan: PaceActionExecutionPlan
    ) {
        guard PaceActionApprovalPolicy.planContainsReversibleMutation(actionExecutionPlan) else {
            return
        }
        let summary = PaceActionApprovalPolicy.firstReversibleSummary(actionExecutionPlan)
            ?? "Last action"
        mostRecentReversibleActionSummary = summary
        mostRecentReversibleActionAt = Date()
    }

    /// Test-friendly entry point that lets unit tests assert the
    /// undo-banner flags after a synthetic plan. Has the same effect
    /// as `noteReversibleActionExecuted` when called with a plan that
    /// contains a reversible mutation.
    func notePostActionExecutionForTrustSurface(
        actionExecutionPlan: PaceActionExecutionPlan
    ) {
        noteReversibleActionExecuted(in: actionExecutionPlan)
    }

    /// Clears the undo-banner state. Called by the cursor overlay
    /// after the 5-second window expires, or after the user taps
    /// "undo" so the banner doesn't linger.
    func clearReversibleActionUndoState() {
        mostRecentReversibleActionAt = nil
        mostRecentReversibleActionSummary = nil
    }

    /// Submits an `Undo.last` action through the executor. Called
    /// from the cursor overlay's undo button. Runs out-of-band of the
    /// planner loop because the user explicitly asked for undo.
    func triggerUndoLastMutation() {
        clearReversibleActionUndoState()
        Task { @MainActor in
            let undoPlan = PaceActionExecutionPlan.serial(actions: [.undoLastMutation])
            let observations = await actionExecutor.executeActionPlan(
                undoPlan,
                screenCaptures: []
            )
            if !observations.isEmpty {
                appendActionResult(.completed(observations: observations))
            }
        }
    }

    /// Notes that an assistant turn just finished speaking, so the
    /// notch panel can render the reply-replay button for the next 30
    /// seconds. The text passed in is the already-post-processed
    /// spoken text (think blocks + action tags stripped), so replay
    /// speaks the same syllables the user just missed.
    private func noteLastSpokenReply(_ spokenText: String) {
        let trimmedSpokenText = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSpokenText.isEmpty else { return }
        lastSpokenReplyText = trimmedSpokenText
        lastSpokenReplyAt = Date()
    }

    /// Clears the replay state. Called when a new turn begins so the
    /// button never lingers past the next push-to-talk press.
    private func clearLastSpokenReplyState() {
        lastSpokenReplyText = nil
        lastSpokenReplyAt = nil
    }

    /// Replays the most recent spoken reply through TTS. Wired to the
    /// notch panel's replay button. Reuses the SAME text that already
    /// went through TTS — doesn't re-stream the planner.
    func replayLastSpokenReply() {
        guard let textToReplay = lastSpokenReplyText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !textToReplay.isEmpty else {
            return
        }
        Task { @MainActor in
            do {
                try await ttsClient.speakText(textToReplay)
            } catch {
                print("⚠️ Replay TTS failed: \(error.localizedDescription)")
            }
        }
    }

    /// Composes and speaks a plain-language failure message for one of
    /// the documented `PaceFailureKind` cases. Flows through
    /// `PaceRestraintGate.decide(...)` so failure speech respects
    /// active-call mute and the proactive cooldown.
    ///
    /// `context` is a free-form short string used only as a debug
    /// breadcrumb (e.g. "agent loop step 3") — never spoken.
    func speakPlainLanguageFailure(
        _ kind: PaceFailureKind,
        context: String? = nil
    ) {
        let narration = PaceFailureNarrator.compose(kind)
        lastFailureNarration = narration

        let restraintDecision = PaceRestraintGate.decide(
            buildFailureRestraintContext(forNow: Date())
        )
        switch restraintDecision {
        case .speak:
            print("⚠️ Failure narration (\(context ?? "no-context")): \(narration.spokenText)")
            Task { @MainActor in
                do {
                    try await ttsClient.speakText(narration.spokenText)
                } catch {
                    print("⚠️ Failure narration TTS failed: \(error.localizedDescription)")
                }
            }
        case .stayQuiet(let reason):
            print("🔇 Suppressed failure narration (\(reason)): \(narration.spokenText)")
        case .queueUntilIdle(let reason):
            // First-class queueing isn't wired for failure narration in
            // v1 — failures should be loud when they happen, and if the
            // user is mid-input the panel still shows lastFailureNarration.
            print("⏳ Skipping queued failure narration (\(reason)): \(narration.spokenText)")
        }

        // Write a paceHistory breadcrumb so "what did you tell me
        // about earlier?" can recall the failure event later.
        localRetriever.recordPaceHistory(
            userTranscript: "(system) failure event",
            assistantResponse: "Pace surfaced a failure: \(narration.spokenText)"
        )
        refreshLocalRetrievalPublishedState()
    }

    /// Builds the gate context for a failure narration. Failures
    /// inherit the `watchNudge` semantics — they're proactive speech
    /// the user didn't directly request, so the gate applies the
    /// active-call check.
    private func buildFailureRestraintContext(forNow now: Date) -> PaceRestraintContext {
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: userInputActivityMonitor.lastUserInputAt,
            frontmostAppBundleIdentifier: frontmostBundleIdentifier,
            isOnActiveCall: activeCallDetector.isOnActiveCall,
            wakeWordConfidence: nil,
            // Failures are always meaningful intent for the gate's
            // confidence check; the active-call gate is the real
            // filter we care about here.
            intent: .pureKnowledge,
            proactiveSource: .watchNudge,
            profile: proactivityProfile
        )
    }

    /// Maps a blocking preflight issue onto a failure narration. Used
    /// by the agent loop when actions auto-execute (no approval popup)
    /// and a preflight issue blocks the path silently.
    func speakFailureForBlockingPreflightIfApplicable(
        preflightIssues: [PaceToolPreflightIssue]
    ) {
        guard let blockingKind = PaceToolPreflight
            .firstBlockingIssueKind(in: preflightIssues) else {
            return
        }
        switch blockingKind {
        case .actionsDisabled:
            // EnableActions=false is an Info.plist condition; the user
            // already saw the panel banner. Don't speak.
            return
        case .accessibilityPermissionMissing:
            speakPlainLanguageFailure(
                .missingPermission(permission: .accessibility),
                context: "preflight"
            )
        case .calendarPermissionMissing:
            speakPlainLanguageFailure(
                .missingPermission(permission: .calendar),
                context: "preflight"
            )
        case .remindersPermissionMissing:
            speakPlainLanguageFailure(
                .missingPermission(permission: .reminders),
                context: "preflight"
            )
        case .mcpServerNotConfigured(let serverName):
            speakPlainLanguageFailure(
                .mcpServerNotConfigured(name: serverName),
                context: "preflight"
            )
        }
    }

    /// Inspects post-execution observations for the all-click-fail
    /// signal and, if found, speaks the templated click-missed message.
    /// The observation's `summary` already documents "Click failed:" in
    /// `clickBestCandidate`, so we match on that prefix.
    func speakFailureForClickMissedIfApplicable(
        observations: [PaceActionExecutionObservation],
        clickTargetLabel: String?
    ) {
        let hasClickAllFail = observations.contains { observation in
            observation.summary.lowercased().contains("click failed")
        }
        guard hasClickAllFail else { return }
        speakPlainLanguageFailure(
            .clickMissed(targetLabel: clickTargetLabel),
            context: "click-all-fail"
        )
    }

    /// Sidecar-TTS-offline narration. Fired by the agent loop on the
    /// FIRST turn after the sidecar starts failing, then suppressed
    /// for `sidecarTTSOfflineCooldown` so the user doesn't hear the
    /// memo every sentence.
    func speakSidecarTTSFallbackMemoIfNeeded(
        isSidecarUnreachable: Bool,
        now: Date = Date()
    ) {
        guard isSidecarUnreachable else {
            // Sidecar recovered — clear the cooldown so a future
            // outage will speak again.
            lastSidecarTTSOfflineNarratedAt = nil
            return
        }
        let sidecarTTSOfflineCooldown: TimeInterval = 30 * 60
        if let lastNarratedAt = lastSidecarTTSOfflineNarratedAt,
           now.timeIntervalSince(lastNarratedAt) < sidecarTTSOfflineCooldown {
            return
        }
        lastSidecarTTSOfflineNarratedAt = now
        speakPlainLanguageFailure(.sidecarTTSOffline, context: "tts-fallback")
    }

    private func routeHUDDetail(for intentPrediction: PaceIntentPrediction) -> String {
        switch intentPrediction.route {
        case .chitchatFastPath:
            return "quick reply"
        case .answerDirectly:
            return "answering without screen"
        case .readScreen:
            return "reading screen"
        case .executeTool:
            return "planning local action"
        case .phoneLargeModel:
            return "local-only fallback"
        case .fullPipeline:
            return "checking screen and tools"
        }
    }

    private func recordConversationTurn(
        userTranscript: String,
        assistantResponse: String
    ) {
        // The committed user message is about to land in the chat transcript,
        // so retire the live in-progress speech bubble (no duplicate).
        liveSpeechDraft = ""
        let recordedAt = Date()
        let stableTurnId = "turn-\(Int(recordedAt.timeIntervalSince1970))-\(abs(userTranscript.hashValue))"

        // Push the turn into the verbatim window. If the window
        // overflowed, the displaced pair is what feeds the next
        // detached summarizer call.
        let displacedTurnPair = threadMemory.record(
            userTurn: userTranscript,
            assistantTurn: assistantResponse,
            turnId: stableTurnId,
            now: recordedAt
        )

        localRetriever.recordPaceHistory(
            userTranscript: userTranscript,
            assistantResponse: assistantResponse
        )
        // Mirror the same turn into the in-window chat surface so the
        // Conversations tab stays aligned with the canonical
        // `paceHistory` write — voice turns appear in chat history,
        // and chat turns dedupe against the optimistic user row that
        // PaceChatSession.submitUserMessage already inserted.
        chatSession.appendCompletedTurn(
            userTranscript: userTranscript,
            assistantResponse: assistantResponse,
            recordedAt: recordedAt
        )
        let frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        // 1. Fast pattern extractor — inline, sub-millisecond.
        let patternExtractedFacts = episodicPatternExtractor.extractFacts(
            from: userTranscript,
            assistantText: assistantResponse,
            frontmostApplicationName: frontmostAppName,
            sourceTurnId: stableTurnId
        )
        recordExtractedEpisodicFacts(patternExtractedFacts, turnId: stableTurnId)
        refreshLocalRetrievalPublishedState()

        // 2. LLM-backed extractor — DETACHED. Never awaited by the
        //    user-facing pipeline. Apple FM is in-process, ~0 RAM
        //    delta. LM Studio fallback is loopback-only. Either
        //    failure is silent — episodic memory is best-effort.
        scheduleDetachedEpisodicLLMExtractionCall(
            userTranscript: userTranscript,
            assistantSpokenText: assistantResponse,
            frontmostAppName: frontmostAppName,
            turnId: stableTurnId,
            intentRoute: lastIntentRouteForEpisodicExtraction
        )

        guard let displacedTurnPair else { return }
        scheduleDetachedThreadSummarizationCall(
            displacedTurnPair: displacedTurnPair,
            recordedAt: recordedAt
        )
    }

    /// Mirrors the existing detached episodic-fact-extractor pattern:
    /// summarization is fire-and-forget on a utility-priority detached
    /// task. The user-facing planner turn NEVER awaits this. The
    /// version snapshot captured BEFORE the FM call lets
    /// `PaceThreadMemory.applySummaryUpdate` drop out-of-order arrivals
    /// when the user fires multiple turns faster than the summarizer
    /// completes.
    private func scheduleDetachedThreadSummarizationCall(
        displacedTurnPair: PaceThreadTurnPair,
        recordedAt: Date
    ) {
        let priorSummaryForCall = threadMemory.currentSummaryText()
        let reservedSummaryVersion = threadMemory.reserveNextSummaryVersion()
        let summarizerInput = PaceThreadSummarizerInput(
            priorSummary: priorSummaryForCall,
            displacedTurnPair: displacedTurnPair,
            sessionStartedAt: recordedAt,
            frontmostApplicationName: NSWorkspace.shared.frontmostApplication?.localizedName
        )
        let summarizerForThisCall = threadSummarizerClient
        Task.detached(priority: .utility) { [weak self] in
            do {
                let updatedSummaryText = try await summarizerForThisCall.updatedSummary(
                    for: summarizerInput
                )
                await MainActor.run { [weak self] in
                    self?.threadMemory.applySummaryUpdate(
                        summary: updatedSummaryText,
                        summaryVersion: reservedSummaryVersion,
                        updatedAt: Date()
                    )
                }
            } catch {
                // Summarizer failure leaves the prior summary in
                // place. No retry storm — the next turn will trigger
                // a fresh call with the next displaced pair.
                print("⚠️ Thread summarizer call failed: \(error)")
            }
        }
    }

    /// Passes a batch of newly-extracted facts through the
    /// `PaceEpisodicFactStore` (dedup + tombstone gates + 200-fact
    /// LRU cap) and writes the surviving documents into the local
    /// retrieval index. Confidence threshold ≥0.7 is applied here so
    /// callers don't have to.
    func recordExtractedEpisodicFacts(
        _ rawFacts: [PaceEpisodicFact],
        turnId: String
    ) {
        let highConfidenceFacts = rawFacts.filter { $0.confidence >= 0.7 }
        guard !highConfidenceFacts.isEmpty else { return }
        let appliedOutcomes = episodicFactStore.applyBatch(highConfidenceFacts)
        let survivingFacts = appliedOutcomes.compactMap { (fact, outcome) -> PaceEpisodicFact? in
            switch outcome {
            case .inserted, .replaced, .appended:
                return fact
            case .skippedBecauseOfTombstone:
                return nil
            }
        }
        // For replacements, drop the previous fact's retrieval doc
        // so the store never carries two `(subject, predicate)`
        // rows when the dedup policy said "replace".
        for (_, outcome) in appliedOutcomes {
            if case .replaced(let previousFactId) = outcome {
                localRetriever.removeEpisodicFactDocument(withId: previousFactId)
            }
        }
        if !survivingFacts.isEmpty {
            localRetriever.recordEpisodicFacts(survivingFacts)
        }
    }

    /// Fires the LLM-backed episodic extractor on a DETACHED utility
    /// task. The user-facing TTS/planner pipeline NEVER awaits this.
    /// Apple FM is in-process and adds ~0 RAM delta; LM Studio is
    /// loopback-only via `PaceLocalEndpointGuard`. Per the PRD only
    /// `.pureKnowledge | .screenDescription | .chitchat` turns are
    /// extracted from — `.screenAction` and `.phoneLargeModel` turns
    /// are commands, not durable facts.
    private func scheduleDetachedEpisodicLLMExtractionCall(
        userTranscript: String,
        assistantSpokenText: String,
        frontmostAppName: String?,
        turnId: String,
        intentRoute: PaceIntent
    ) {
        let intentIsEligibleForExtraction: Bool
        switch intentRoute {
        case .pureKnowledge, .screenDescription, .chitchat, .unknown:
            // `.unknown` runs the full pipeline anyway; we let it
            // through so an unclassified turn doesn't silently drop
            // an extractable fact.
            intentIsEligibleForExtraction = true
        case .screenAction, .phoneLargeModel:
            intentIsEligibleForExtraction = false
        }
        guard intentIsEligibleForExtraction else { return }
        let extractorForThisCall = episodicLLMFactExtractor
        Task.detached(priority: .utility) { [weak self] in
            let extractedFacts = await extractorForThisCall.extract(
                userTranscript: userTranscript,
                assistantSpokenText: assistantSpokenText,
                frontmostAppName: frontmostAppName,
                turnId: turnId
            )
            guard !extractedFacts.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.recordExtractedEpisodicFacts(extractedFacts, turnId: turnId)
                self?.refreshLocalRetrievalPublishedState()
            }
        }
    }

    /// User-facing API for Settings → Memory → Delete fact. Adds a
    /// 30-day tombstone (via `PaceEpisodicFactStore`) AND removes
    /// the retrieval document so the LOCAL CONTEXT block stops
    /// showing the fact immediately.
    func deleteEpisodicFact(withIdentifier factId: String) {
        guard let _ = episodicFactStore.deleteFact(withIdentifier: factId) else { return }
        localRetriever.removeEpisodicFactDocument(withId: factId)
        refreshLocalRetrievalPublishedState()
    }

    /// User-facing API for Settings → Memory → Reset all. Tombstones
    /// every currently-stored fact for 30 days and clears the
    /// retrieval bucket.
    func resetAllEpisodicMemory() {
        episodicFactStore.resetAll()
        localRetriever.clearDocuments(forSource: .episodicMemory)
        refreshLocalRetrievalPublishedState()
    }

    /// Drops state if the idle threshold elapsed AND journals one
    /// line into `paceHistory` so "what did we talk about earlier?"
    /// can recall via the existing keyword retriever. The summary
    /// text itself is NEVER journaled — only the session id and the
    /// lifecycle cause.
    private func evaluateThreadIdleAndResetIfNeeded(now: Date) {
        guard let sessionEndCause = threadMemory.sessionDidIdle(now: now) else {
            return
        }
        let endingSessionId = threadMemory.currentSessionId
        threadMemory.resetSession(cause: sessionEndCause, now: now)
        let causeDisplayName: String
        switch sessionEndCause {
        case .idleTimeout:
            causeDisplayName = "idleTimeout"
        case .userReset:
            causeDisplayName = "userReset"
        }
        localRetriever.recordPaceHistory(
            userTranscript: "session ended (cause: \(causeDisplayName))",
            assistantResponse: "session \(endingSessionId) ended",
            now: now
        )
        refreshLocalRetrievalPublishedState()
    }

    /// Public surface for the Settings "Reset thread now" button.
    func resetThreadMemoryNow() {
        let now = Date()
        let endingSessionId = threadMemory.currentSessionId
        threadMemory.resetSession(cause: .userReset, now: now)
        localRetriever.recordPaceHistory(
            userTranscript: "session ended (cause: userReset)",
            assistantResponse: "session \(endingSessionId) ended",
            now: now
        )
        refreshLocalRetrievalPublishedState()
    }

    /// Settings debug surface: returns the raw summary text + version
    /// counter so the user can audit what the planner is being told.
    func currentThreadMemorySummarySnapshot() -> (summaryText: String?, summaryVersion: Int) {
        return (
            summaryText: threadMemory.currentSummaryText(),
            summaryVersion: threadMemory.currentSummaryVersionValue()
        )
    }

    private func appendLocalRetrievalContext(
        to userPrompt: String,
        query: String,
        route: PaceIntentRoute,
        isFirstPlannerStep: Bool = true
    ) async -> String {
        guard isFirstPlannerStep else { return userPrompt }
        guard PaceRetrievalContextPolicy.shouldQueryLocalContext(
            forTranscript: query,
            route: route
        ) else {
            return userPrompt
        }

        let retrievalQuery = PaceRetrievalQuery(
            text: query,
            maximumResultCount: 3,
            maximumSnippetCharacters: 180
        )
        defer {
            refreshLocalRetrievalPublishedState()
        }
        // Embedding-reranked when the local embeddings endpoint responds in
        // time; degrades to plain lexical order otherwise.
        guard let localContextBlock = await localRetriever.rerankedLocalContextBlock(
            for: retrievalQuery
        ) else {
            return userPrompt
        }
        return "\(localContextBlock)\n\nUSER REQUEST\n\(userPrompt)"
    }

    private func localRetrievalSummaryText(
        from sourceStatuses: [PaceRetrievalSourceStatus],
        lastQueryDurationMilliseconds: Int? = nil
    ) -> String {
        let activeSourceSummaries = sourceStatuses
            .filter { $0.documentCount > 0 }
            .map { "\($0.displayName): \($0.documentCount)" }

        guard !activeSourceSummaries.isEmpty else {
            return "Retrieval: no local context indexed"
        }
        var summary = "Retrieval: " + activeSourceSummaries.joined(separator: " · ")
        if let lastQueryDurationMilliseconds {
            summary += " · Query: \(lastQueryDurationMilliseconds)ms"
        }
        return summary
    }

    private func refreshLocalRetrievalPublishedState() {
        let sourceStatuses = localRetriever.sourceStatuses
        localRetrievalSourceStatuses = sourceStatuses
        localRetrievalSummary = localRetrievalSummaryText(
            from: sourceStatuses,
            lastQueryDurationMilliseconds: localRetriever.lastQueryDurationMilliseconds
        )
    }

    func addLocalRetrievalFileRootURLs(_ rootURLs: [URL]) {
        let safeNewRootURLs = rootURLs
            .map { URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL }
            .filter { !PaceSecretPathExclusionPolicy.shouldExclude(localURL: $0) }

        let existingRootURLs = PaceLocalRetrievalFileRootPreferences.userSelectedRootURLs()
        let mergedRootURLs = PaceLocalRetrievalFileRootPreferences.mergedRootURLs(
            existingRootURLs: existingRootURLs,
            addingRootURLs: safeNewRootURLs
        )
        saveLocalRetrievalUserSelectedFileRootURLs(mergedRootURLs)
    }

    func removeLocalRetrievalFileRootPath(_ rootPath: String) {
        let rootURLToRemove = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let remainingRootURLs = PaceLocalRetrievalFileRootPreferences
            .userSelectedRootURLs()
            .filter { $0.path != rootURLToRemove.path }
        saveLocalRetrievalUserSelectedFileRootURLs(remainingRootURLs)
    }

    func clearLocalRetrievalFileRootPaths() {
        saveLocalRetrievalUserSelectedFileRootURLs([])
    }

    private func saveLocalRetrievalUserSelectedFileRootURLs(_ rootURLs: [URL]) {
        PaceLocalRetrievalFileRootPreferences.saveUserSelectedRootURLs(rootURLs)
        localRetrievalFileRootPaths = PaceLocalRetrievalFileRootPreferences.rootPaths(for: rootURLs)
        handleLocalRetrievalFileRootConfigurationChanged()
    }

    private func handleLocalRetrievalFileRootConfigurationChanged() {
        fileRetrievalRefreshTask?.cancel()
        fileRetrievalRefreshTask = nil
        lastFileRetrievalRefreshAt = nil
        spotlightRetrievalConnector = PaceSpotlightRetrievalConnector(
            rootURLs: PaceLocalRetrievalFileRootPreferences.configuredRootURLs()
        )
        localRetriever.clearDocuments(forSource: .file)
        refreshFileRetrievalDocumentsIfAllowed(force: true)
        refreshLocalRetrievalPublishedState()
        currentTurnHUDState = .done("file retrieval folders updated")
    }

    func setLocalRetrievalSourceEnabled(_ isEnabled: Bool, for source: PaceRetrievalSource) {
        localRetriever.setSourceEnabled(isEnabled, for: source)
        refreshLocalRetrievalPublishedState()

        if source == .appUsageHistory, !isEnabled {
            appUsageTracker?.stop()
        }
        guard isEnabled else { return }
        switch source {
        case .calendar:
            refreshCalendarRetrievalDocumentsIfAllowed(force: true)
        case .reminders:
            refreshRemindersRetrievalDocumentsIfAllowed(force: true)
        case .contacts:
            refreshContactsRetrievalDocumentsIfAllowed(force: true)
        case .notes:
            refreshNotesRetrievalDocumentsIfAllowed(force: true)
        case .mail:
            refreshMailRetrievalDocumentsIfAllowed(force: true)
        case .localPreference:
            localRetriever.refreshPreferenceDocuments()
            refreshLocalRetrievalPublishedState()
        case .competitiveResearch:
            localRetriever.refreshCompetitiveResearchDocuments()
            refreshLocalRetrievalPublishedState()
        case .file:
            refreshFileRetrievalDocumentsIfAllowed(force: true)
        case .paceHistory, .screenWatchHistory, .episodicMemory:
            // Both are recorded passively as turns/watch events happen —
            // nothing to refresh on re-enable.
            break
        case .appUsageHistory:
            appUsageTracker?.start()
        case .screenTime:
            refreshScreenTimeRetrievalDocumentsIfAllowed(force: true)
        }
    }

    /// Reads macOS's own Screen Time database into the retrieval index.
    /// No prompt is ever shown: without Full Disk Access the read fails and
    /// the source row shows the repair hint instead.
    private func refreshScreenTimeRetrievalDocumentsIfAllowed(force: Bool = false) {
        guard localRetriever.isSourceEnabled(.screenTime) else {
            refreshLocalRetrievalPublishedState()
            return
        }
        let connector = screenTimeRetrievalConnector
        Task.detached(priority: .utility) { [weak self] in
            let outcome: Result<[PaceRetrievalDocument], Error> = Result {
                try connector.loadScreenTimeDocuments()
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch outcome {
                case .success(let documents):
                    self.localRetriever.replaceDocuments(
                        documents,
                        forSource: .screenTime,
                        status: .enabled(
                            source: .screenTime,
                            displayName: PaceRetrievalSource.screenTime.displayName,
                            documentCount: documents.count
                        )
                    )
                    print("🔎 Screen Time retrieval: \(documents.count) day(s) indexed")
                case .failure(let error):
                    self.localRetriever.replaceDocuments(
                        [],
                        forSource: .screenTime,
                        status: .skipped(
                            source: .screenTime,
                            displayName: PaceRetrievalSource.screenTime.displayName,
                            reason: (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription
                        )
                    )
                    print("🔎 Screen Time retrieval skipped: \(error.localizedDescription)")
                }
                self.refreshLocalRetrievalPublishedState()
            }
        }
    }

    func isLocalRetrievalSourceEnabled(_ source: PaceRetrievalSource) -> Bool {
        localRetriever.isSourceEnabled(source)
    }

    func clearLocalRetrievalSource(_ source: PaceRetrievalSource) {
        localRetriever.clearDocuments(forSource: source)
        refreshLocalRetrievalPublishedState()
        currentTurnHUDState = .done("\(source.displayName.lowercased()) retrieval cleared")
        print("🔎 Local retrieval source cleared: \(source.displayName)")
    }

    private func refreshCalendarRetrievalDocumentsIfAllowed(force: Bool = false) {
        guard localRetriever.isSourceEnabled(.calendar) else {
            refreshLocalRetrievalPublishedState()
            return
        }
        let calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        let authorizationStatusChanged = lastCalendarRetrievalAuthorizationStatus != calendarAuthorizationStatus
        lastCalendarRetrievalAuthorizationStatus = calendarAuthorizationStatus

        guard PaceCalendarRetrievalConnector.canReadCalendarEvents(calendarAuthorizationStatus) else {
            guard force || authorizationStatusChanged else { return }
            localRetriever.replaceDocuments(
                [],
                forSource: .calendar,
                status: PaceCalendarRetrievalConnector.skippedStatus(for: calendarAuthorizationStatus)
            )
            lastCalendarRetrievalRefreshAt = nil
            refreshLocalRetrievalPublishedState()
            return
        }

        let now = Date()
        if !force,
           !authorizationStatusChanged,
           let lastCalendarRetrievalRefreshAt,
           now.timeIntervalSince(lastCalendarRetrievalRefreshAt) < 300 {
            return
        }

        let result = calendarRetrievalConnector.loadDocuments()
        localRetriever.replaceDocuments(
            result.documents,
            forSource: .calendar,
            status: result.status
        )
        lastCalendarRetrievalRefreshAt = now
        refreshLocalRetrievalPublishedState()
        print("🔎 Calendar retrieval refreshed: \(result.documents.count) event(s)")
    }

    private func refreshRemindersRetrievalDocumentsIfAllowed(force: Bool = false) {
        guard localRetriever.isSourceEnabled(.reminders) else {
            refreshLocalRetrievalPublishedState()
            return
        }
        let reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        let authorizationStatusChanged = lastRemindersRetrievalAuthorizationStatus != reminderAuthorizationStatus
        lastRemindersRetrievalAuthorizationStatus = reminderAuthorizationStatus

        guard PaceRemindersRetrievalConnector.canReadReminders(reminderAuthorizationStatus) else {
            guard force || authorizationStatusChanged else { return }
            remindersRetrievalRefreshTask?.cancel()
            remindersRetrievalRefreshTask = nil
            localRetriever.replaceDocuments(
                [],
                forSource: .reminders,
                status: PaceRemindersRetrievalConnector.skippedStatus(for: reminderAuthorizationStatus)
            )
            lastRemindersRetrievalRefreshAt = nil
            refreshLocalRetrievalPublishedState()
            return
        }

        let now = Date()
        if !force,
           !authorizationStatusChanged,
           let lastRemindersRetrievalRefreshAt,
           now.timeIntervalSince(lastRemindersRetrievalRefreshAt) < 300 {
            return
        }

        lastRemindersRetrievalRefreshAt = now
        remindersRetrievalRefreshTask?.cancel()
        remindersRetrievalRefreshTask = Task { [weak self] in
            guard let self else { return }
            let result = await remindersRetrievalConnector.loadDocuments()
            guard !Task.isCancelled else { return }

            localRetriever.replaceDocuments(
                result.documents,
                forSource: .reminders,
                status: result.status
            )
            refreshLocalRetrievalPublishedState()
            print("🔎 Reminders retrieval refreshed: \(result.documents.count) reminder(s)")
        }
    }

    private func refreshContactsRetrievalDocumentsIfAllowed(force: Bool = false) {
        guard localRetriever.isSourceEnabled(.contacts) else {
            refreshLocalRetrievalPublishedState()
            return
        }
        let contactsAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        let authorizationStatusChanged = lastContactsRetrievalAuthorizationStatus != contactsAuthorizationStatus
        lastContactsRetrievalAuthorizationStatus = contactsAuthorizationStatus

        guard PaceContactsRetrievalConnector.canReadContacts(contactsAuthorizationStatus) else {
            guard force || authorizationStatusChanged else { return }
            contactsRetrievalRefreshTask?.cancel()
            contactsRetrievalRefreshTask = nil
            localRetriever.replaceDocuments(
                [],
                forSource: .contacts,
                status: PaceContactsRetrievalConnector.skippedStatus(for: contactsAuthorizationStatus)
            )
            lastContactsRetrievalRefreshAt = nil
            refreshLocalRetrievalPublishedState()
            return
        }

        let now = Date()
        if !force,
           !authorizationStatusChanged,
           let lastContactsRetrievalRefreshAt,
           now.timeIntervalSince(lastContactsRetrievalRefreshAt) < 300 {
            return
        }

        lastContactsRetrievalRefreshAt = now
        contactsRetrievalRefreshTask?.cancel()
        contactsRetrievalRefreshTask = Task { [weak self] in
            guard let self else { return }
            let result = contactsRetrievalConnector.loadDocuments()
            guard !Task.isCancelled else { return }

            localRetriever.replaceDocuments(
                result.documents,
                forSource: .contacts,
                status: result.status
            )
            refreshLocalRetrievalPublishedState()
            print("🔎 Contacts retrieval refreshed: \(result.documents.count) contact(s)")
        }
    }

    private func refreshNotesRetrievalDocumentsIfAllowed(force: Bool = false) {
        guard localRetriever.isSourceEnabled(.notes) else {
            refreshLocalRetrievalPublishedState()
            return
        }

        let now = Date()
        if !force,
           let lastNotesRetrievalRefreshAt,
           now.timeIntervalSince(lastNotesRetrievalRefreshAt) < 300 {
            return
        }

        lastNotesRetrievalRefreshAt = now
        notesRetrievalRefreshTask?.cancel()
        notesRetrievalRefreshTask = Task { [weak self] in
            guard let self else { return }
            let result = notesRetrievalConnector.loadDocuments()
            guard !Task.isCancelled else { return }

            localRetriever.replaceDocuments(
                result.documents,
                forSource: .notes,
                status: result.status
            )
            refreshLocalRetrievalPublishedState()
            print("🔎 Notes retrieval refreshed: \(result.documents.count) note(s)")
        }
    }

    private func refreshMailRetrievalDocumentsIfAllowed(force: Bool = false) {
        guard localRetriever.isSourceEnabled(.mail) else {
            refreshLocalRetrievalPublishedState()
            return
        }

        let now = Date()
        if !force,
           let lastMailRetrievalRefreshAt,
           now.timeIntervalSince(lastMailRetrievalRefreshAt) < 300 {
            return
        }

        lastMailRetrievalRefreshAt = now
        mailRetrievalRefreshTask?.cancel()
        mailRetrievalRefreshTask = Task { [weak self] in
            guard let self else { return }
            let result = mailRetrievalConnector.loadDocuments()
            guard !Task.isCancelled else { return }

            localRetriever.replaceDocuments(
                result.documents,
                forSource: .mail,
                status: result.status
            )
            refreshLocalRetrievalPublishedState()
            print("🔎 Mail retrieval refreshed: \(result.documents.count) message(s)")
        }
    }

    private func refreshFileRetrievalDocumentsIfAllowed(force: Bool = false) {
        guard localRetriever.isSourceEnabled(.file) else {
            refreshLocalRetrievalPublishedState()
            return
        }

        let now = Date()
        if !force,
           let lastFileRetrievalRefreshAt,
           now.timeIntervalSince(lastFileRetrievalRefreshAt) < 300 {
            return
        }

        lastFileRetrievalRefreshAt = now
        fileRetrievalRefreshTask?.cancel()
        fileRetrievalRefreshTask = Task { [weak self] in
            guard let self else { return }
            let result = spotlightRetrievalConnector.loadDocuments()
            guard !Task.isCancelled else { return }

            localRetriever.replaceDocuments(
                result.documents,
                forSource: .file,
                status: result.status
            )
            refreshLocalRetrievalPublishedState()
            print("🔎 File retrieval refreshed: \(result.documents.count) file(s)")
        }
    }

    func resetLocalRetrievalIndex() {
        localRetriever.resetIndex(preservePreferences: true)
        refreshFileRetrievalDocumentsIfAllowed(force: true)
        refreshCalendarRetrievalDocumentsIfAllowed(force: true)
        refreshRemindersRetrievalDocumentsIfAllowed(force: true)
        refreshContactsRetrievalDocumentsIfAllowed(force: true)
        refreshNotesRetrievalDocumentsIfAllowed(force: true)
        refreshMailRetrievalDocumentsIfAllowed(force: true)
        refreshLocalRetrievalPublishedState()
        currentTurnHUDState = .done("retrieval reset")
        print("🔎 Local retrieval index reset")
    }

    private func handleRememberSiteCommand(
        _ command: PaceRememberSiteCommand,
        transcript: String
    ) {
        let spokenText: String
        switch command {
        case .forget(let name):
            let didForget = PaceNamedDestinationStore.shared.forget(displayName: name)
            spokenText = didForget
                ? "forgotten."
                : "i don't have a saved site called \(name)."
        case .remember(let requestedName):
            if let captured = PaceBrowserURLReader.currentTab() {
                let displayName = requestedName
                    ?? PaceBrowserURLReader.defaultName(forURL: captured.url)
                PaceNamedDestinationStore.shared.save(
                    displayName: displayName,
                    url: captured.url
                )
                spokenText = "got it — i'll remember \(displayName)."
            } else {
                // Frontmost app isn't a scriptable browser, or the read failed.
                spokenText = "i couldn't read this page's address — make sure the site is open in your browser and try again."
            }
        }

        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(spokenText)
        recordConversationTurn(userTranscript: transcript, assistantResponse: spokenText)
        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
            currentTurnHUDState = .done("done")
        }
    }

    private func handleLocalMemoryCommand(_ command: PaceLocalMemoryCommand) {
        let spokenText: String
        switch command {
        case .set(let key, let value):
            PaceLocalMemoryStore.setString(value, for: key)
            spokenText = "remembered \(value)."
        case .forget(let key):
            PaceLocalMemoryStore.setString(nil, for: key)
            spokenText = "forgot that preference."
        }

        localMemorySummary = PaceLocalMemoryStore.summaryText
        localRetriever.refreshPreferenceDocuments()
        refreshLocalRetrievalPublishedState()
        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(spokenText)
        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
        }
    }

    private func handleAlwaysListeningCommand(_ command: PaceAlwaysListeningCommand, transcript: String) {
        let spokenText: String
        switch command {
        case .start:
            setAlwaysListeningEnabled(true)
            spokenText = "always listening is on."
        case .stop:
            setAlwaysListeningEnabled(false)
            spokenText = "always listening is off."
        }
        handleImmediateLocalModeResponse(transcript: transcript, spokenText: spokenText)
    }

    private func handleFlowCommand(_ command: PaceFlowCommand, transcript: String) {
        switch command {
        case .startRecording(let name):
            let spokenText = startFlowRecordingFromVoiceCommand(flowName: name)
            handleImmediateLocalModeResponse(transcript: transcript, spokenText: spokenText)

        case .stopRecording:
            let spokenText = stopFlowRecordingFromVoiceCommand()
            handleImmediateLocalModeResponse(transcript: transcript, spokenText: spokenText)

        case .run(let name):
            // For voice-triggered replay we mark the flow as approved
            // for the current session (the voice command IS the
            // approval). Same-session subsequent runs of the same flow
            // bypass any further approval prompt.
            guard let storedFlow = flowStore.load(named: name) else {
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "i couldn't find a flow named \(name)."
                )
                return
            }
            flowNamesApprovedForReplayThisSession.insert(storedFlow.name)
            handleImmediateLocalModeResponse(
                transcript: transcript,
                spokenText: "replaying \(storedFlow.name) now."
            )
            beginFlowReplay(storedFlow)

        case .delete(let name):
            let spokenText: String
            do {
                try flowStore.delete(named: name)
                spokenText = "deleted \(name)."
            } catch {
                spokenText = "i couldn't delete \(name)."
            }
            handleImmediateLocalModeResponse(transcript: transcript, spokenText: spokenText)
        }
    }

    /// Begin recording into a fresh flow named `flowName`. Returns the
    /// spoken-ready confirmation copy so the caller can route it
    /// through `handleImmediateLocalModeResponse(...)` (voice command)
    /// or back to the planner observation loop (`record_flow` tool).
    @discardableResult
    func startFlowRecordingFromVoiceCommand(flowName: String) -> String {
        let trimmedFlowName = flowName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFlowName.isEmpty else {
            return "flow recording needs a name."
        }
        flowRecorder.start(flowName: trimmedFlowName)
        return "recording \(trimmedFlowName). say stop recording when you're done."
    }

    /// Stop the live recorder and persist whatever was captured. Public
    /// so the `record_flow` tool observation, the Settings UI, and the
    /// voice command parser can all share one save site.
    @discardableResult
    func stopFlowRecordingFromVoiceCommand() -> String {
        let assembledFlow = flowRecorder.stop(reason: .userCommand)
        guard let assembledFlow else {
            return "no recording was in progress."
        }
        do {
            try flowStore.save(assembledFlow)
            return "saved \(assembledFlow.name) with \(assembledFlow.steps.count) step\(assembledFlow.steps.count == 1 ? "" : "s")."
        } catch {
            return "i recorded \(assembledFlow.name) but couldn't save it: \(error.localizedDescription)"
        }
    }

    /// Drive the live replayer. Speaks completion or failure copy via
    /// the existing TTS path; the replayer itself is fully `await`-
    /// driven and yields back to the run loop between steps.
    func beginFlowReplay(_ storedFlow: PaceRecordedFlow) {
        let replayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.flowReplayer.play(
                storedFlow,
                onProgress: { stepIndex in
                    print("🔁 PaceFlowReplayer: completed step \(stepIndex + 1) of \(storedFlow.steps.count)")
                },
                onCompletion: { [weak self] outcome in
                    guard let self else { return }
                    Task { @MainActor in
                        self.speakFlowReplayOutcome(outcome, flowName: storedFlow.name)
                    }
                }
            )
        }
        _ = replayTask // task lifetime is tied to MainActor; no need to retain
    }

    /// Compose + speak the per-outcome line. Failure paths route
    /// through the deterministic failure narrator so the message
    /// reads in the same voice as the other plain-language failures.
    private func speakFlowReplayOutcome(
        _ outcome: PaceFlowReplayOutcome,
        flowName: String
    ) {
        let spokenText: String
        switch outcome {
        case .completed:
            spokenText = "done with \(flowName)."
        case .stoppedBeforeSendStep:
            spokenText = "ready to send the \(flowName) flow — say go ahead."
        case .failedToFindTarget(let stepIndex, let axLabel):
            // Reuse the click-missed narration shape so the user hears
            // the same "I couldn't find X" phrasing they get from a
            // failed planner click.
            let narration = PaceFailureNarrator.compose(
                .clickMissed(targetLabel: axLabel)
            )
            spokenText = "\(narration.spokenText) (step \(stepIndex + 1) of \(flowName))"
        case .userCancelled:
            spokenText = "stopped \(flowName)."
        }
        Task { @MainActor in
            try? await self.ttsClient.speakText(spokenText)
        }
    }

    /// Clear the per-session approval cache. Wired into the existing
    /// session-reset path so a thread-memory wipe also resets the
    /// "this flow is approved" memory.
    func resetFlowReplayApprovalCacheForSession() {
        flowNamesApprovedForReplayThisSession.removeAll()
    }

    /// Helper exposed for the `run_flow` tool callback the executor
    /// invokes. Returns true if the replay actually kicked off; false
    /// when the flow needs explicit user approval that hasn't been
    /// granted this session yet (the executor's observation distinguishes
    /// the two for the planner-loop summary).
    @discardableResult
    func runFlowFromExecutorTool(_ storedFlow: PaceRecordedFlow) -> Bool {
        // Approval cache: planner-driven `run_flow` calls go through
        // here. Same-session subsequent runs of the same flow skip the
        // approval popup. First-time runs in a session would normally
        // surface the approval popup via PaceActionExecutor's existing
        // gate — that path is already in place for record_flow/run_flow
        // because both are flagged risky in PaceToolRegistry.
        if flowNamesApprovedForReplayThisSession.contains(storedFlow.name) {
            beginFlowReplay(storedFlow)
            return true
        }
        // Mark approved now (the executor only invokes this callback
        // after its own approval gate has cleared the action).
        flowNamesApprovedForReplayThisSession.insert(storedFlow.name)
        beginFlowReplay(storedFlow)
        return true
    }

    private func handleRecipeCommand(_ command: PaceRecipeCommand, transcript: String) {
        let flowStore = PaceFlowStore()
        let bundledRecipes = PaceRecipeLibrary.loadBundledRecipes()
        let spokenText: String

        switch command {
        case .install(let displayName):
            guard let matchedRecipe = matchBundledRecipe(displayName: displayName, in: bundledRecipes) else {
                spokenText = "i don't have a recipe called \(displayName)."
                break
            }
            do {
                try PaceRecipeLibrary.install(matchedRecipe, into: flowStore)
                spokenText = "installed \(matchedRecipe.name)."
            } catch PaceRecipeInstallError.missingRequiredPreference(let requiredPreferenceKey) {
                spokenText = "i need \(requiredPreferenceKey) set first."
            } catch PaceRecipeInstallError.alreadyInstalled {
                spokenText = "\(matchedRecipe.name) is already installed."
            } catch {
                spokenText = "i couldn't install that recipe."
            }
        case .uninstall(let displayName):
            guard let matchedRecipe = matchBundledRecipe(displayName: displayName, in: bundledRecipes) else {
                spokenText = "i don't have a recipe called \(displayName)."
                break
            }
            if !PaceRecipeLibrary.isInstalled(matchedRecipe, in: flowStore) {
                spokenText = "\(matchedRecipe.name) isn't installed."
                break
            }
            PaceRecipeLibrary.uninstall(slug: matchedRecipe.slug, from: flowStore)
            spokenText = "removed \(matchedRecipe.name)."
        case .list:
            if bundledRecipes.isEmpty {
                spokenText = "i don't have any recipes bundled."
            } else {
                let displayNames = bundledRecipes.map { $0.name }.joined(separator: ", ")
                spokenText = "available recipes: \(displayNames)."
            }
        }

        handleImmediateLocalModeResponse(transcript: transcript, spokenText: spokenText)
    }

    /// Case-insensitive lookup of a bundled recipe by display name OR
    /// slug. Lets the user say "morning standup setup" or
    /// "morning-standup-setup" and get the same recipe.
    private func matchBundledRecipe(
        displayName: String,
        in bundledRecipes: [PaceBundledRecipe]
    ) -> PaceBundledRecipe? {
        let normalizedDisplayName = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return bundledRecipes.first(where: { recipe in
            recipe.name.lowercased() == normalizedDisplayName
                || recipe.slug.lowercased() == normalizedDisplayName
        })
    }

    private func handleImmediateLocalModeResponse(transcript: String, spokenText: String) {
        currentTurnHUDState = .done(spokenText)
        recordConversationTurn(userTranscript: transcript, assistantResponse: spokenText)
        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(spokenText)
        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
        }
    }

    private func currentToolPreflightEnvironment() -> PaceToolPreflightEnvironment {
        PaceToolPreflightEnvironment(
            actionsAreEnabled: actionExecutor.actionsAreEnabled,
            hasAccessibilityPermission: hasAccessibilityPermission,
            hasCalendarPermission: hasCalendarPermission,
            hasRemindersPermission: hasRemindersPermission,
            configuredMCPServerNames: Set(PaceMCPServerRegistry.loadConfiguredServers().keys)
        )
    }

    private func appendConfiguredMCPContext(to userPrompt: String) -> String {
        let configuredServerNames = PaceMCPServerRegistry
            .loadConfiguredServers()
            .keys
            .sorted()

        guard !configuredServerNames.isEmpty else {
            return userPrompt
        }

        return """
        \(userPrompt)

        Configured MCP servers:
        \(configuredServerNames.map { "- \($0)" }.joined(separator: "\n"))

        Use MCP only when a task is better handled by one of these configured external servers.
        """
    }

    /// Pace skips the upstream first-run flow entirely — no welcome video,
    /// no email gate, no demo pointing animation. The cursor overlay shows
    /// as soon as all permissions are granted. This constant exists only
    /// so the panel UI's existing conditional branch stays simple.
    let hasCompletedOnboarding: Bool = true

    /// Tap-to-talk entry point from the walking avatar. Folds into the
    /// same pipeline as a keyboard PTT press by simulating the shortcut
    /// transition. First tap → start recording. Tap again while
    /// listening → stop and submit. Taps during processing/responding
    /// are ignored (let the in-flight turn finish; the user can press
    /// the hotkey to cancel if they want).
    func handleAvatarTapped() {
        switch voiceState {
        case .idle:
            // Mark the trigger BEFORE simulating press so the .pressed
            // branch picks the avatar anchor for the response bubble.
            currentDictationTrigger = .avatar
            globalPushToTalkShortcutMonitor.simulateShortcutPressed()
        case .listening:
            // Second click stops recording. Same effect as tapping the
            // in-bubble stop button below.
            globalPushToTalkShortcutMonitor.simulateShortcutReleased()
        case .processing, .responding:
            print("👆 Avatar tap ignored — turn in flight (\(voiceState))")
        }
    }

    /// Called by the stop button in the response bubble. Routes through
    /// the same release path as the keyboard / second-avatar-tap.
    func handleStopButtonTapped() {
        guard voiceState == .listening else { return }
        print("⏹  Stop button tapped")
        globalPushToTalkShortcutMonitor.simulateShortcutReleased()
    }

    /// Entry point for the pace://listen deeplink. Folds into the same
    /// PTT pipeline as an avatar tap, including the transcription-model
    /// readiness rejection and overlay anchoring. Start-only — a deeplink
    /// must never stop or interrupt an in-flight turn.
    func beginListeningFromDeepLink() {
        guard voiceState == .idle else {
            print("🔗 Deeplink listen ignored — turn in flight (\(voiceState))")
            return
        }
        currentDictationTrigger = .keyboard
        globalPushToTalkShortcutMonitor.simulateShortcutPressed()
    }

    /// Entry point for the in-window chat surface. Snapshots the chat
    /// session's mute flag for THIS turn, then forwards to the same
    /// pipeline as the `pace://chat` deeplink so chat and voice share
    /// one planning + execution path. Doing the snapshot here (not
    /// inside the pipeline) keeps the mute decision tied to the moment
    /// of submission — toggling mute mid-stream affects the NEXT turn.
    func submitChatTranscriptFromChatSession(_ transcript: String) {
        isChatModeMutedForCurrentTurn = chatSession.isChatTTSMuted
        if isChatModeMutedForCurrentTurn {
            // Stop any audio that was already in flight from a prior
            // turn so flipping mute on feels instant.
            ttsClient.stopPlayback()
        }
        submitChatTranscriptFromDeepLink(transcript)
    }

    /// Entry point for the pace://chat deeplink. The transcript is treated
    /// exactly like a spoken turn: same intent classification, fast paths,
    /// retrieval injection, and — critically — the same action-approval
    /// policy, so a deeplink can do nothing the user's own voice couldn't.
    func submitChatTranscriptFromDeepLink(_ transcript: String) {
        guard voiceState == .idle else {
            print("🔗 Deeplink chat ignored — turn in flight (\(voiceState))")
            return
        }
        // The notch chat input lives in the same panel as the turn HUD,
        // so as soon as a turn is committed the input collapses and
        // the HUD takes over. Cheap to flip when this code path was
        // entered from the deeplink (the flag is already false).
        isNotchChatInputFocused = false
        print("🔗 Deeplink chat transcript: \(transcript)")

        currentResponseTask?.cancel()
        currentResponseTask = nil
        ttsClient.stopPlayback()
        streamingSentenceTTSPipeline.resetForNewTurn()
        // New turn began — hide the reply-replay button so it doesn't
        // linger past the next push-to-talk press.
        clearLastSpokenReplyState()
        // Apply the chat-mode mute snapshot for this turn AFTER reset
        // (reset clears the pipeline's flag). When the deeplink path
        // is hit directly the snapshot is false, matching voice-turn
        // behaviour. Clear the manager-side flag immediately after so
        // subsequent voice turns can never inherit a stale mute.
        streamingSentenceTTSPipeline.setMutedForCurrentTurn(isChatModeMutedForCurrentTurn)
        isChatModeMutedForCurrentTurn = false
        clearDetectedElementLocation()

        // Transient cursor mode: surface the overlay for the duration of
        // this turn, mirroring the PTT press path.
        if !isPaceCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        lastTranscript = transcript
        _ = PaceAPIAuditLog.shared.beginTurn()
        PaceAnalytics.trackUserMessageSent(transcript: transcript)
        currentTurnHUDState = .understanding("classifying intent")
        responseOverlayManager.setAnchor(.belowRightOfCursor)
        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(transcript)

        // Stamp intent-commit now so TTFSW latency logging stays meaningful
        // for deeplink turns (there is no PTT release to stamp it).
        streamingSentenceTTSPipeline.markIntentCommitted()
        screenContextService.prewarmScreenContext(reason: .deepLinkChat)
        voiceState = .processing
        sendTranscriptToPlannerWithScreenshot(transcript: transcript)
    }

    func start() {
        refreshAllPermissions()
        loadPersistedToolCallDebugRecords()
        print("🔑 Pace start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        // Wire the timer-scheduler speak callback to the active TTS
        // client and rehydrate any persisted timers. Doing this before
        // anything else means a 3-minute egg timer fired while Pace
        // was quit speaks the moment we come back up.
        actionExecutor.setTimerOnFireSpeakCallback { [weak self] spokenReminderText in
            guard let self else { return }
            Task { @MainActor in
                try? await self.ttsClient.speakText(spokenReminderText)
            }
        }
        actionExecutor.rehydratePersistedTimers()
        // Wire the demonstration-flow recorder + replayer through the
        // executor's tool callbacks so the planner's `record_flow` /
        // `run_flow` cases drive the same code paths the voice command
        // parser does. Defaults are no-ops; we set them once here per
        // CompanionManager lifecycle so dry-run/unit-test code stays
        // unaffected.
        actionExecutor.startFlowRecordingCallback = { [weak self] flowName in
            guard let self else {
                return "Ready to record flow \"\(flowName)\"."
            }
            return self.startFlowRecordingFromVoiceCommand(flowName: flowName)
        }
        actionExecutor.runFlowCallback = { [weak self] storedFlow in
            guard let self else { return false }
            return self.runFlowFromExecutorTool(storedFlow)
        }
        startPermissionPolling()
        startLMStudioReachabilityPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindBargeInGateObservation()
        bindWakeWordSpotterObservation()
        // Eagerly touch the planner so the LM Studio cold-load (model
        // swap, first connection) happens before the user's first
        // push-to-talk rather than blocking on it.
        _ = plannerClient
        // Kick off any model load the active provider needs (WhisperKit
        // does ~15s of CoreML compile on first run; Apple Speech is
        // instant and fires onReady synchronously). `onReady` flips the
        // gate so PTT presses while the model is loading get rejected
        // with a clear message instead of hanging the audio engine.
        buddyDictationManager.transcriptionProvider.warmUpModelInBackground { [weak self] in
            self?.isTranscriptionModelReady = true
            print("✅ Transcription model is ready for PTT")
        }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isPaceCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // Foreground app-usage journaling: permission-free NSWorkspace
        // observation that powers "how did I spend my time?" answers.
        // Honors the per-source retrieval toggle like every other source.
        if localRetriever.isSourceEnabled(.appUsageHistory) {
            appUsageTracker?.start()
        }

        // Posture watch resumes across launches when the user left it on.
        if isPostureWatchEnabled {
            latestPostureStatus = "Calibrating — sit how you'd like to sit"
            postureMonitor.start()
        }

        // Screen Time indexes at launch — the read either works (Full Disk
        // Access granted) or reports a skipped status; never a prompt.
        refreshScreenTimeRetrievalDocumentsIfAllowed()

        startThreadMemoryIdleSweepTimer()

        // Daily morning brief — opt-in. The scheduler stays inert
        // (no timer, no fire) until the user enables it in Settings.
        if isMorningTriageEnabled {
            morningTriageScheduler.start()
        }

        // Wave 1a restraint policy: keep the input-activity monitor
        // and the active-call detector running so proactive nudges
        // see live "user is busy" signals. The input-activity monitor
        // is Accessibility-gated and will no-op until that permission
        // is granted; the permission poller calls `start()` again on
        // first grant so we re-attempt seamlessly.
        userInputActivityMonitor.start()
        activeCallDetector.start()

        // Wave 7a: the proactive pipeline owns the 10s drain timer
        // and the orchestrator wiring. Bringing it up here matches
        // the pre-extraction startup order — input/call monitors
        // first, drain timer + orchestrator second.
        proactivityPipeline.start()
    }

    /// 5-minute idle sweep that drops thread-memory state when the
    /// session has gone quiet. Running this off a timer means the
    /// menu-bar surface can show "session ended" without waiting for
    /// the user's next turn to roll the gate.
    private func startThreadMemoryIdleSweepTimer() {
        threadMemoryIdleSweepTimer?.invalidate()
        let lowFrequencySweepIntervalSeconds: TimeInterval = 5 * 60
        threadMemoryIdleSweepTimer = Timer.scheduledTimer(
            withTimeInterval: lowFrequencySweepIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateThreadIdleAndResetIfNeeded(now: Date())
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        appUsageTracker?.stop()
        if isPostureWatchEnabled {
            postureMonitor.stop()
        }
        globalPushToTalkShortcutMonitor.stop()
        globalChatShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        chatShortcutCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        bargeInGatePropertyCancellable?.cancel()
        bargeInGatePropertyCancellable = nil
        detachBargeInAudioLevelSubscription()
        wakeWordToggleCancellable?.cancel()
        wakeWordToggleCancellable = nil
        wakeWordDetectionCancellable?.cancel()
        wakeWordDetectionCancellable = nil
        wakeWordPTTBridgeCancellable?.cancel()
        wakeWordPTTBridgeCancellable = nil
        wakeWordSpotter.stop()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        remindersRetrievalRefreshTask?.cancel()
        remindersRetrievalRefreshTask = nil
        contactsRetrievalRefreshTask?.cancel()
        contactsRetrievalRefreshTask = nil
        fileRetrievalRefreshTask?.cancel()
        fileRetrievalRefreshTask = nil
        threadMemoryIdleSweepTimer?.invalidate()
        threadMemoryIdleSweepTimer = nil
        morningTriageScheduler.stop()

        userInputActivityMonitor.stop()
        activeCallDetector.stop()
        proactivityPipeline.stop()
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadSpeechRecognition = hasSpeechRecognitionPermission
        let previouslyHadAll = allPermissionsGranted

        // PacePermissionService owns the actual probing — including the
        // live SCShareableContent / AXIsProcessTrustedWithOptions checks
        // that defeat macOS's stale-status-cache bugs. Reading from it
        // here means every UI surface and feature gate sees one truth
        // (used to be 20+ direct calls across 8 files, each with its
        // own subtle caching quirks).
        let permissionService = PacePermissionService.shared
        permissionService.refresh()
        let currentlyHasAccessibility = permissionService.isGranted(.accessibility)
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
            globalChatShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
            globalChatShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = permissionService.isGranted(.screenRecording)
        hasMicrophonePermission = permissionService.isGranted(.microphone)
        // SFSpeechRecognizer.authorizationStatus() is a TCC-gated call; even
        // reading it crashes any process without NSSpeechRecognitionUsage-
        // Description in Info.plist. Skip it entirely when the active
        // transcription provider does not use Speech (WhisperKit), so the
        // call site cannot regress past whichever usage-description is in
        // the bundle today.
        if buddyDictationManager.transcriptionProvider.requiresSpeechRecognitionPermission {
            hasSpeechRecognitionPermission = SFSpeechRecognizer.authorizationStatus() == .authorized
        } else {
            hasSpeechRecognitionPermission = true
        }

        let calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        let reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        hasCalendarPermission = permissionService.isGranted(.calendar)
        hasRemindersPermission = permissionService.isGranted(.reminders)
        shouldRequestCalendarPermission = calendarAuthorizationStatus == .notDetermined
        shouldRequestRemindersPermission = reminderAuthorizationStatus == .notDetermined
        refreshCalendarRetrievalDocumentsIfAllowed()
        refreshRemindersRetrievalDocumentsIfAllowed()
        refreshContactsRetrievalDocumentsIfAllowed()

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission
            || previouslyHadSpeechRecognition != hasSpeechRecognitionPermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), speech: \(hasSpeechRecognitionPermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            PaceAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            PaceAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            PaceAnalytics.trackPermissionGranted(permission: "microphone")
        }
        if !previouslyHadSpeechRecognition && hasSpeechRecognitionPermission {
            PaceAnalytics.trackPermissionGranted(permission: "speech_recognition")
        }
        // Screen content permission: we used to trust a sticky UserDefaults
        // cache, which lied when TCC was reset (post-install or tccutil reset).
        // Trust the same flag macOS does — Screen Recording — as the source of
        // truth, since SCShareableContent silently fails the same way when
        // that grant is missing. The persisted "we picked once" bit only
        // gates the onboarding picker prompt, not the permission state.
        let cachedScreenContentPick = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        hasScreenContentPermission = hasScreenRecordingPermission && cachedScreenContentPick

        if !previouslyHadAll && allPermissionsGranted {
            PaceAnalytics.trackAllPermissionsGranted()
        }
    }

    func requestSpeechRecognitionPermission() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            refreshAllPermissions()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                Task { @MainActor in
                    self?.refreshAllPermissions()
                }
            }
        case .denied, .restricted:
            WindowPositionManager.openSpeechRecognitionSettings()
        @unknown default:
            WindowPositionManager.openSpeechRecognitionSettings()
        }
    }

    func requestCalendarPermission() {
        let currentStatus = EKEventStore.authorizationStatus(for: .event)
        guard currentStatus == .notDetermined else {
            WindowPositionManager.openCalendarSettings()
            return
        }

        if #available(macOS 14.0, *) {
            permissionEventStore.requestFullAccessToEvents { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refreshAllPermissions()
                }
            }
        } else {
            permissionEventStore.requestAccess(to: .event) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refreshAllPermissions()
                }
            }
        }
    }

    func requestRemindersPermission() {
        let currentStatus = EKEventStore.authorizationStatus(for: .reminder)
        guard currentStatus == .notDetermined else {
            WindowPositionManager.openRemindersSettings()
            return
        }

        if #available(macOS 14.0, *) {
            permissionEventStore.requestFullAccessToReminders { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refreshAllPermissions()
                }
            }
        } else {
            permissionEventStore.requestAccess(to: .reminder) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refreshAllPermissions()
                }
            }
        }
    }

    private static func isEventKitPermissionGranted(_ authorizationStatus: EKAuthorizationStatus) -> Bool {
        switch authorizationStatus {
        case .authorized, .fullAccess:
            return true
        case .notDetermined, .restricted, .denied, .writeOnly:
            return false
        @unknown default:
            return false
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    PaceAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isPaceCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    /// Polls the configured LM Studio HTTP root every 5 seconds so the
    /// panel can show a live "is the backend up?" indicator. 5s is fast
    /// enough that flipping LM Studio on/off feels responsive while
    /// staying well under one request per second of background traffic.
    private func startLMStudioReachabilityPolling() {
        // Fire once immediately so the panel doesn't sit on a stale
        // "not reachable" before the first 5-second tick.
        Task { [weak self] in await self?.refreshLMStudioReachability() }

        lmStudioReachabilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.refreshLMStudioReachability() }
        }
    }

    /// Sends a HEAD-equivalent GET to LM Studio's /v1/models endpoint
    /// with a 2s timeout. Any 2xx response = reachable. Read the planner
    /// base URL from Info.plist so the check tracks whichever endpoint
    /// the runtime actually uses.
    private func refreshLMStudioReachability() async {
        let baseURLString = AppBundleConfiguration.stringValue(forKey: "LocalPlannerBaseURL")
            ?? "http://localhost:1234/v1"
        let localPlannerBaseURL = PaceLocalEndpointGuard.resolvedLocalOpenAICompatibleBaseURL(
            configuredURLString: baseURLString,
            settingName: "LocalPlannerBaseURL"
        )
        let modelsURL = localPlannerBaseURL.appendingPathComponent("models")

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        let reachable: Bool
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            reachable = (response as? HTTPURLResponse)
                .map { (200...299).contains($0.statusCode) } ?? false
        } catch {
            reachable = false
        }

        await MainActor.run {
            if self.isLMStudioReachable != reachable {
                print("🧠 LM Studio reachability: \(reachable ? "up" : "down")")
            }
            self.isLMStudioReachable = reachable
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    /// Wires the two-condition gate that controls the barge-in
    /// subscription. Either `voiceState` flipping or
    /// `isAlwaysListeningEnabled` flipping reruns the decision; the
    /// VAD audio-level subscription is attached only when BOTH are
    /// satisfied (state is `.responding` AND wake-word/always-listening
    /// is enabled). On any other state combination the subscription
    /// is torn down immediately and the VAD's accumulated speech window
    /// is reset, so background noise during `.idle` cannot accidentally
    /// fire a stale interrupt the next time the gate opens.
    private func bindBargeInGateObservation() {
        bargeInGatePropertyCancellable = $voiceState
            .combineLatest($isAlwaysListeningEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, isEnabled in
                guard let self else { return }
                let shouldAttach = state == .responding && isEnabled
                if shouldAttach {
                    self.attachBargeInAudioLevelSubscriptionIfNeeded()
                } else {
                    self.detachBargeInAudioLevelSubscription()
                }
            }
    }

    /// Attaches the VAD audio-level subscription. Idempotent — if a
    /// subscription is already live, we leave it alone (cancelling and
    /// re-attaching would drop in-flight RMS samples and reset the
    /// sustained-speech window). The publisher emits on the audio
    /// thread; we hop to MainActor inside the sink because the VAD
    /// observation, the TTS drain, the PTT manager call, and the
    /// retrieval journal write are all main-actor work.
    private func attachBargeInAudioLevelSubscriptionIfNeeded() {
        guard bargeInAudioLevelCancellable == nil else { return }
        bargeInVAD.reset()
        bargeInAudioLevelCancellable = buddyDictationManager.audioLevelPublisher
            .sink { [weak self] normalizedLevel in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.observeBargeInAudioLevel(normalizedLevel)
                }
            }
    }

    private func detachBargeInAudioLevelSubscription() {
        bargeInAudioLevelCancellable?.cancel()
        bargeInAudioLevelCancellable = nil
        bargeInVAD.reset()
    }

    /// Forwards a single RMS sample to the VAD. Fires the barge-in
    /// callback chain when the VAD reports sustained speech. The
    /// double-gate check inside the sink guards against an in-flight
    /// sample arriving on the main-actor hop just after voiceState
    /// flipped out of `.responding` — we re-check the conditions here
    /// because the publisher sample raced the state change.
    private func observeBargeInAudioLevel(_ normalizedLevel: Float) {
        guard voiceState == .responding, isAlwaysListeningEnabled else { return }
        let didDetectSustainedSpeech = bargeInVAD.observe(
            normalizedLevel: normalizedLevel,
            at: Date()
        )
        guard didDetectSustainedSpeech else { return }
        // Reset immediately so a continued speech burst doesn't fire
        // the chain twice for the same interrupt.
        bargeInVAD.reset()
        handleBargeInDetected()
    }

    /// Wave 1c barge-in callback chain. Called from
    /// `observeBargeInAudioLevel` once the VAD confirms sustained user
    /// speech during TTS playback. Drains the speech queue, opens a
    /// fresh listening window so the user's interrupting words can
    /// land as the next turn, and journals the interrupt to
    /// paceHistory using the speakable prefix that was already on its
    /// way out the speakers when the user cut in.
    private func handleBargeInDetected() {
        let lastSpokenPrefix = streamingSentenceTTSPipeline.inFlightStreamedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Drain + stop. The pipeline pre-stamps `.userBargeIn` on the
        // TTS client so the next `lastStopReason` read is correct.
        streamingSentenceTTSPipeline.drainQueueAndStopForBargeIn()
        // Belt-and-braces: call stop directly on the client too, since
        // the pipeline already routed it but a second call is a no-op
        // and guarantees state even if the pipeline shape changes.
        ttsClient.stopPlayback()
        // Open a listening window so the wake-word path (Wave 2) or
        // an immediate PTT press resumes capture without re-arming.
        buddyDictationManager.openListeningWindow(
            durationInSeconds: 6,
            trigger: .bargeIn
        )
        // Journal the interrupt locally. `paceHistory` is the existing
        // retrieval source; no new tracking, no new files.
        let prefixForJournalLine = lastSpokenPrefix.isEmpty
            ? "(no prefix captured)"
            : lastSpokenPrefix
        localRetriever.recordPaceHistory(
            userTranscript: "(system) barge-in interrupted assistant turn",
            assistantResponse: "[interrupted-mid-speech] \(prefixForJournalLine)"
        )
        refreshLocalRetrievalPublishedState()
    }

    /// Wave 2b — wires the wake-word spotter lifecycle to the
    /// `isAlwaysListeningEnabled` toggle and forwards detections into
    /// `handleWakeWordDetected(_:)`. Also bridges PTT engagement so
    /// the spotter releases the mic while the user is push-to-talking
    /// and resumes the instant PTT releases. Idempotent: invoking
    /// `start()` again is a no-op on the spotter side.
    private func bindWakeWordSpotterObservation() {
        wakeWordToggleCancellable = $isAlwaysListeningEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                guard let self else { return }
                if isEnabled {
                    self.wakeWordSpotter.start()
                } else {
                    self.wakeWordSpotter.stop()
                }
            }

        wakeWordDetectionCancellable = wakeWordSpotter.wakeWordDetectedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] detection in
                self?.handleWakeWordDetected(detection)
            }

        // PTT-engagement bridge: pause the spotter when PTT starts
        // recording, resume when it stops. The PTT manager publishes
        // `isRecordingFromKeyboardShortcut` and
        // `isPreparingToRecord` — both become "we own the mic" from
        // the spotter's perspective. Microphone-button recording uses
        // the same path through `isRecordingFromMicrophoneButton`,
        // tracked separately so a panel mic-tap also pauses the
        // spotter cleanly.
        wakeWordPTTBridgeCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isPreparingToRecord,
                buddyDictationManager.$isRecordingFromMicrophoneButton
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecordingFromShortcut, isPreparing, isRecordingFromButton in
                guard let self else { return }
                let isPTTOwningMic = isRecordingFromShortcut || isPreparing || isRecordingFromButton
                if isPTTOwningMic {
                    self.wakeWordSpotter.pauseForExternalAudioConsumer()
                } else {
                    self.wakeWordSpotter.resumeIfPausedForExternalAudioConsumer()
                }
            }
    }

    /// Wave 2b — handles a wake-word detection event from the spotter.
    /// Wake-word ONLY opens a listening window; it does NOT route the
    /// matched phrase into the planner. The normal pipeline (transcribe
    /// → intent → planner) handles whatever the user says next. We
    /// drop the detection when a turn is already in flight so the
    /// wake-word can't displace an active PTT session or interrupt
    /// the in-flight response (barge-in handles the responding case
    /// separately).
    private func handleWakeWordDetected(_ detection: PaceWakeWordDetection) {
        guard voiceState == .idle else {
            print("🎙️ Wake-word detected but a turn is in flight (\(voiceState)); ignoring")
            return
        }
        print("🎙️ Wake-word detected: \(detection.phraseMatched) (confidence \(detection.confidence))")
        buddyDictationManager.openListeningWindow(
            durationInSeconds: 6,
            trigger: .wakeWord
        )
        // Lightweight audit trail. paceHistory is the existing
        // retrieval source — no new index, no new tracking.
        localRetriever.recordPaceHistory(
            userTranscript: "(system) wake-word triggered",
            assistantResponse: "[wake-word triggered] \(detection.phraseMatched)"
        )
        refreshLocalRetrievalPublishedState()
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }

        // Notch chat shortcut (default `cmd+shift+P`). The publisher
        // fires once per accepted keystroke; we flip the focus flag
        // and post the existing show-panel notification so the panel
        // surfaces without the manager needing a direct reference to
        // `MenuBarPanelManager`.
        chatShortcutCancellable = globalChatShortcutMonitor
            .chatShortcutPressed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleNotchChatShortcutPressed()
            }
    }

    /// Brings the panel to front and asks the chat input to focus.
    /// Routed through both a notification (panel manager listens) and
    /// the `@Published` flag (CompanionPanelView listens) so neither
    /// side has to know about the other.
    private func handleNotchChatShortcutPressed() {
        // If a turn is already in flight, opening the chat input is
        // confusing — it can't submit anyway. Drop the shortcut.
        guard voiceState == .idle else {
            print("⌨️ Notch chat shortcut ignored — turn in flight (\(voiceState))")
            return
        }
        NotificationCenter.default.post(name: .paceShowPanel, object: nil)
        isNotchChatInputFocused = true
    }

    /// Called by the panel's TextField after a successful submit so
    /// the input collapses back into the existing turn HUD.
    func dismissNotchChatInputAfterSubmit() {
        isNotchChatInputFocused = false
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isPaceCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .paceDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            currentResponseTask = nil
            ttsClient.stopPlayback()
            // Clear the streaming-TTS dispatch state so the new turn
            // starts fresh — without this, the diff tracker would think
            // half of the previous reply had already been queued.
            streamingSentenceTTSPipeline.resetForNewTurn()
            clearLastSpokenReplyState()
            clearDetectedElementLocation()

            // Force voice state back to idle BEFORE the dictation observer
            // sees the new recording flags. The observer at L489 has
            // `guard voiceState != .responding else { return }` which
            // means if the prior turn's task hasn't yet cleaned up to .idle,
            // the new press silently won't transition to .listening — that
            // was the "had to repeat it once" bug. Forcing idle here unblocks
            // the observer's normal state transitions for the new turn.
            voiceState = .idle
            currentTurnHUDState = .listening
    

            PaceAnalytics.trackPushToTalkStarted()

            // Show "listening…" so the user has visible feedback that the
            // press registered. Interim transcripts overwrite this as the
            // STT provider emits partial results, and the planner's
            // streaming text takes over once the response starts.
            responseOverlayManager.showOverlayAndBeginStreaming()
            responseOverlayManager.setListeningForAudio(true)
            responseOverlayManager.updateStreamingText("listening…")

            print("🎙️ PTT pressed — starting dictation (trigger=\(currentDictationTrigger))")
            // Fire the screen-context pre-warm in parallel with dictation.
            // VLM + OCR run during the user's natural speech time (~2-5s)
            // and the result is awaited by the agent loop's first step —
            // perceived VLM latency drops to ~0 in the common case.
            screenContextService.prewarmScreenContext(reason: .pushToTalkPress)
            // Reject the press if the transcription provider's model
            // isn't loaded yet. Apple Speech (default) is always ready
            // on launch; only relevant when the user has switched to
            // WhisperKit and the model is still doing its CoreML compile.
            guard isTranscriptionModelReady else {
                print("⚠️ Speech model still loading — rejecting PTT press")
                responseOverlayManager.setAnchor(.belowRightOfCursor)
                responseOverlayManager.showOverlayAndBeginStreaming()
                responseOverlayManager.updateStreamingText("speech model still loading…")
                responseOverlayManager.finishStreaming()
                voiceState = .idle
                return
            }
            // Set the response bubble's anchor based on what triggered
            // this turn. Keyboard → next to the cursor (rides with the
            // Codex arrow); avatar tap → next to the walking character.
            switch currentDictationTrigger {
            case .keyboard:
                responseOverlayManager.setAnchor(.belowRightOfCursor)
                // The avatar is just visual noise during a keyboard-
                // triggered turn. Hide it; it comes back when we return
                // to idle below.
                if isWalkingAvatarEnabled {
                    avatarOverlayManager?.hide()
                }
            case .avatar:
                let weakAvatarRef = avatarOverlayManager
                responseOverlayManager.setAnchor(.aboveCenterOf(provider: { @MainActor in
                    weakAvatarRef?.currentAvatarAnchorPoint()
                }))
            }
            pendingKeyboardShortcutStartTask?.cancel()
            // Capture self weakly in the outer task so it matches the weak
            // captures in the escaping draft/submit closures below — the task
            // must not extend this manager's lifetime past app teardown.
            pendingKeyboardShortcutStartTask = Task { [weak self] in
                guard let self else { return }
                await self.buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { [weak self] partialTranscript in
                        // The transcription provider may call us off-main;
                        // hop explicitly so we never violate @MainActor on
                        // the overlay (silent isolation errors can show up
                        // as freezes under contention).
                        let trimmedPartial = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedPartial.isEmpty else { return }
                        Task { @MainActor [weak self] in
                            self?.lastPartialTranscriptFromActiveDictation = trimmedPartial
                            self?.liveSpeechDraft = trimmedPartial
                            self?.responseOverlayManager.updateStreamingText(trimmedPartial)
                        }
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            // Mark that a transcript arrived so the release
                            // safety timer skips its cleanup pass.
                            self.transcriptArrivedSinceRelease = true
                            self.lastTranscript = finalTranscript
                            // Keep the live user bubble showing the final
                            // transcript through the turn; recordConversationTurn
                            // clears it when the committed message lands.
                            self.liveSpeechDraft = finalTranscript
                            _ = PaceAPIAuditLog.shared.beginTurn()
                            print("🗣️ Companion received transcript: \(finalTranscript)")
                            PaceAnalytics.trackUserMessageSent(transcript: finalTranscript)
                            self.currentTurnHUDState = .understanding("classifying intent")
                            self.responseOverlayManager.updateStreamingText(finalTranscript)
                            self.sendTranscriptToPlannerWithScreenshot(transcript: finalTranscript)
                        }
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            print("🎙️ PTT released — stopping dictation")
            // Stamp the moment the user committed to a query so the
            // streaming TTS pipeline can log time-to-first-spoken-word
            // (TTFSW), the headline latency metric for this product.
            streamingSentenceTTSPipeline.markIntentCommitted()
            PaceAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            // The stop button only makes sense while we're actually
            // recording — clear it as soon as the release fires.
            responseOverlayManager.setListeningForAudio(false)
            // Safety net: if no transcript materialises within 5s (silent
            // audio, WhisperKit hang, mic permission revoked), clean up so
            // the overlay doesn't sit on "listening…" indefinitely and the
            // state machine returns to idle. The flag is flipped to true
            // inside `submitDraftText` above.
            transcriptArrivedSinceRelease = false
            transcriptSafetyTask?.cancel()
            transcriptSafetyTask = Task { [weak self] in
                // 12s, not 5s — WhisperKit's first finalize after launch
                // takes 5-10s on its own, and the previous timeout dropped
                // the user's words too aggressively. The fallback below
                // also rescues turns that have a partial but no final.
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                await MainActor.run {
                    guard let self else { return }
                    guard !self.transcriptArrivedSinceRelease else { return }
                    // If WhisperKit gave us a partial but never finalized,
                    // use the partial as the transcript — better than
                    // dropping the whole turn as "no audio detected".
                    if let rescuedPartial = self.lastPartialTranscriptFromActiveDictation,
                       !rescuedPartial.isEmpty {
                        print("🗣️ Final transcript timed out — rescuing partial: \(rescuedPartial)")
                        self.transcriptArrivedSinceRelease = true
                        self.lastTranscript = rescuedPartial
                        self.lastPartialTranscriptFromActiveDictation = nil
                        _ = PaceAPIAuditLog.shared.beginTurn()
                        PaceAnalytics.trackUserMessageSent(transcript: rescuedPartial)
                        self.currentTurnHUDState = .understanding("classifying intent")
                        self.responseOverlayManager.updateStreamingText(rescuedPartial)
                        self.sendTranscriptToPlannerWithScreenshot(transcript: rescuedPartial)
                        return
                    }
                    print("⚠️ Transcript didn't arrive within 12s — resetting state")
                    PaceAPIAuditLog.shared.record(
                        subsystem: "dictation",
                        operation: "finalize_timeout",
                        target: self.buddyDictationManager.transcriptionProvider.displayName,
                        durationMilliseconds: 12000,
                        outcome: "no_transcript",
                        detail: "no partial captured"
                    )
                    self.responseOverlayManager.updateStreamingText("no audio detected")
                    self.responseOverlayManager.finishStreaming()
                    self.voiceState = .idle
                    self.currentTurnHUDState = .failed("No audio detected")
                    if self.isWalkingAvatarEnabled {
                        self.avatarOverlayManager?.show()
                    }
                    self.currentDictationTrigger = .keyboard
                }
            }
        case .none:
            break
        }
    }

    // MARK: - AI Response Pipeline (plan-act-observe loop)

    /// Chitchat short-circuit: skips screen capture and the VLM, but lets
    /// the on-device LLM write the actual reply. The classifier still
    /// decides "this is small talk" cheaply; reply generation goes through
    /// the model so the answer fits the turn ("yes, i can hear you" for a
    /// mic check; "morning, what's the plan" for a greeting; etc.) instead
    /// of falling out of a hand-rolled if/contains chain.
    private func handleChitchatFastPath(transcript: String) {
        handleTextOnlyPlannerFastPath(transcript: transcript)
    }

    private func handleClarificationTurn(
        transcript: String,
        clarification: PaceIntentClarification
    ) {
        let optionsText = clarification.options.isEmpty
            ? ""
            : " \(clarification.options.joined(separator: " or "))?"
        let clarificationText = clarification.question.hasSuffix("?")
            ? clarification.question
            : clarification.question + optionsText

        pendingIntentClarification = PacePendingIntentClarification(
            originalTranscript: transcript,
            clarification: clarification
        )
        currentTurnHUDState = .clarification(
            question: clarification.question,
            options: clarification.options
        )
        recordConversationTurn(
            userTranscript: transcript,
            assistantResponse: clarificationText
        )

        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(clarificationText)

        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: clarificationText)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
            if isWalkingAvatarEnabled {
                avatarOverlayManager?.show()
            }
            currentDictationTrigger = .keyboard
            scheduleTransientHideIfNeeded()
        }
    }

    func resolveClarification(option: String) {
        // A pending click-target clarification carries an exact target the
        // user just chose, so it takes precedence over the transcript-rewrite
        // path: resolving it clicks the chosen candidate directly instead of
        // re-running the planner (which could re-rank into a different set).
        if pendingClickTargetClarification != nil {
            resolveClickTargetClarification(selectedOptionLabel: option)
            return
        }

        guard let pendingIntentClarification else {
            currentTurnHUDState = .failed("Clarification expired")
            return
        }

        guard let clarifiedTranscript = PaceIntentClarificationResolver.clarifiedTranscript(
            for: pendingIntentClarification,
            selectedOption: option
        ) else {
            currentTurnHUDState = .failed("Unknown clarification option")
            return
        }

        self.pendingIntentClarification = nil
        currentResponseTask?.cancel()
        currentResponseTask = nil
        ttsClient.stopPlayback()
        streamingSentenceTTSPipeline.resetForNewTurn()
        clearLastSpokenReplyState()
        responseOverlayManager.finishStreaming()
        currentTurnHUDState = .understanding("using \(option.lowercased())")
        sendTranscriptToPlannerWithScreenshot(transcript: clarifiedTranscript)
    }

    /// Visual-target ambiguity raise (PRD
    /// docs/prds/hud-intent-disambiguator.md). When the parsed plan is a
    /// single click whose candidate set has near-tied distinguishable
    /// labels, set the HUD into the same clarification state the
    /// edit/destructive path uses (so the panel renders option chips with
    /// no new view code), store the candidate set + screen captures, and
    /// return true to tell the agent loop to pause. Returns false when
    /// there's a clear winner — the common, zero-friction case.
    ///
    /// Only fires for genuine click-candidate plans. Coordinate-only
    /// `[CLICK:x,y]` planner output never reaches here because it parses
    /// to `.click`, not `.clickCandidates` — when the planner gives exact
    /// coordinates we trust them.
    private func raiseClickTargetClarificationIfAmbiguous(
        actionExecutionPlan: PaceActionExecutionPlan,
        screenCaptures: [CompanionScreenCapture]
    ) -> Bool {
        // Only a single, lone click-candidates action qualifies. A
        // multi-action plan (e.g. click then type) is the planner driving a
        // sequence — interrupting it mid-stream would strand the rest.
        let flattenedActions = actionExecutionPlan.flattenedActions
        guard flattenedActions.count == 1,
              case .clickCandidates(let clickCandidateSet) = flattenedActions[0] else {
            return false
        }

        guard let offeredCandidates = PaceClickCandidateAmbiguity.isAmbiguous(clickCandidateSet),
              let clarification = PaceClickTargetClarificationBuilder.makeClarification(
                  offeredCandidates: offeredCandidates,
                  in: clickCandidateSet
              ) else {
            return false
        }

        let optionLabels = clarification.options.map(\.label)
        pendingClickTargetClarification = PacePendingClickTargetClarification(
            prompt: clarification.prompt,
            options: clarification.options,
            candidateSet: clickCandidateSet,
            screenCaptures: screenCaptures
        )
        currentTurnHUDState = .clarification(
            question: clarification.prompt,
            options: optionLabels
        )
        appendActionResult(PaceActionRunRecord(
            status: .skipped,
            title: "Which target?",
            detail: optionLabels.joined(separator: " / ")
        ))
        print("❔ Click-target clarification: \(optionLabels.joined(separator: " / "))")
        return true
    }

    /// Resolves a pending click-target clarification by clicking the
    /// candidate the user tapped. Executes the chosen target directly via
    /// a one-candidate plan — does NOT re-run the planner. Falls back to
    /// the executor's existing top-candidate auto-click when the option
    /// can't be matched, so a stray tap never strands the turn.
    private func resolveClickTargetClarification(selectedOptionLabel: String) {
        guard let pendingClickTargetClarification else {
            currentTurnHUDState = .failed("Clarification expired")
            return
        }
        self.pendingClickTargetClarification = nil

        let screenCaptures = pendingClickTargetClarification.screenCaptures
        let chosenCandidate = pendingClickTargetClarification
            .candidate(forSelectedOptionLabel: selectedOptionLabel)

        // The chosen candidate becomes the sole candidate of a fresh
        // single-target plan. When the option can't be matched, fall back
        // to the full original set so the executor's top-candidate
        // auto-click still runs — never strand the turn.
        let resolvedCandidateSet: PaceClickCandidateSet
        if let chosenCandidate {
            resolvedCandidateSet = PaceClickCandidateSet(
                candidates: [chosenCandidate],
                clickCount: pendingClickTargetClarification.candidateSet.clickCount
            )
        } else {
            resolvedCandidateSet = pendingClickTargetClarification.candidateSet
        }

        currentTurnHUDState = .acting("clicking \(selectedOptionLabel)")
        let clickPlan = PaceActionExecutionPlan.serial(
            actions: [.clickCandidates(resolvedCandidateSet)]
        )

        currentResponseTask = Task { @MainActor in
            let toolObservations = await actionExecutor.executeActionPlan(
                clickPlan,
                screenCaptures: screenCaptures
            )
            guard !Task.isCancelled else { return }
            if !toolObservations.isEmpty {
                appendActionResult(.completed(observations: toolObservations))
                speakFailureForClickMissedIfApplicable(
                    observations: toolObservations,
                    clickTargetLabel: selectedOptionLabel
                )
            }
            if currentTurnHUDState.status == .acting {
                currentTurnHUDState = .done("clicked \(selectedOptionLabel)")
            }
            currentDictationTrigger = .keyboard
            scheduleTransientHideIfNeeded()
        }
    }

    /// Falls back to the executor's existing top-candidate auto-click when
    /// a pending click-target clarification is dismissed or times out
    /// without a choice, so an unanswered question never strands the turn.
    /// Wired to outside-click dismissal / a new turn beginning.
    func dismissPendingClickTargetClarificationWithAutoClick() {
        guard let pendingClickTargetClarification else { return }
        self.pendingClickTargetClarification = nil

        let screenCaptures = pendingClickTargetClarification.screenCaptures
        let originalCandidateSet = pendingClickTargetClarification.candidateSet
        currentTurnHUDState = .acting("clicking best match")
        let clickPlan = PaceActionExecutionPlan.serial(
            actions: [.clickCandidates(originalCandidateSet)]
        )
        currentResponseTask = Task { @MainActor in
            let toolObservations = await actionExecutor.executeActionPlan(
                clickPlan,
                screenCaptures: screenCaptures
            )
            guard !Task.isCancelled else { return }
            if !toolObservations.isEmpty {
                appendActionResult(.completed(observations: toolObservations))
            }
            if currentTurnHUDState.status == .acting {
                currentTurnHUDState = .done("turn finished")
            }
            currentDictationTrigger = .keyboard
            scheduleTransientHideIfNeeded()
        }
    }

    private func handleUnsupportedTurn(
        transcript: String,
        unsupportedResponse: PaceIntentUnsupportedResponse
    ) {
        currentTurnHUDState = .unsupported(unsupportedResponse.reason)
        recordConversationTurn(
            userTranscript: transcript,
            assistantResponse: unsupportedResponse.spokenText
        )

        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(unsupportedResponse.spokenText)

        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: unsupportedResponse.spokenText)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
            if isWalkingAvatarEnabled {
                avatarOverlayManager?.show()
            }
            currentDictationTrigger = .keyboard
            scheduleTransientHideIfNeeded()
        }
    }

    /// Fast path for pure knowledge questions. Skips screenshot capture,
    /// AX, OCR, VLM, and agent-mode tool docs. Uses the dedicated
    /// text-only planner so short answers can ride Apple Foundation
    /// Models when available while action/screen turns stay on the
    /// larger local planner.
    private func handleTextOnlyPlannerFastPath(transcript: String) {
        currentTurnHUDState = .understanding("answering without screen")
        responseOverlayManager.showOverlayAndBeginStreaming()

        // Capture self weakly so this matches the weak capture in the nested
        // eager-filler task below and never extends the manager's lifetime.
        currentResponseTask = Task { [weak self] in
            guard let self else { return }
            voiceState = .processing

            do {
                let plannerForTextOnlyTurn = textOnlyPlannerClient
                plannerForTextOnlyTurn.resetForNewTurn()
                print("🧠 Text-only planner: using \(plannerForTextOnlyTurn.displayName)")

                let historyForPlanner = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let userPromptForPlanner = await appendLocalRetrievalContext(
                    to: transcript,
                    query: transcript,
                    route: .answerDirectly
                )

                let threadSummaryInjectionForTurn = threadMemory.injectionPrefix()

                // Wave 4: eager-filler debouncer. If the planner doesn't
                // produce its first token within 600ms, dispatch one
                // short "okay" / "let me think" token through TTS so the
                // user hears acknowledgement instead of silence. Only
                // fires on pure-knowledge + chitchat (this path) and is
                // rate-limited across consecutive slow turns.
                let plannerStartedAt = Date()
                let eagerFillerTask: Task<Void, Never> = Task { [weak self] in
                    try? await Task.sleep(
                        nanoseconds: UInt64(StreamingSentenceTTSPipeline
                            .eagerFillerThresholdMillis) * 1_000_000
                    )
                    guard !Task.isCancelled, let self else { return }
                    let elapsedSinceStartMs = Int(
                        Date().timeIntervalSince(plannerStartedAt) * 1000
                    )
                    await self.streamingSentenceTTSPipeline
                        .dispatchEagerFillerIfThresholdExceeded(
                            plannerTTFTMilliseconds: elapsedSinceStartMs
                        )
                }

                let (fullResponseText, _) = try await plannerForTextOnlyTurn.generateResponseStreaming(
                    images: [],
                    systemPrompt: CompanionSystemPrompt.buildTextOnly(
                        threadSummaryInjection: threadSummaryInjectionForTurn
                    ),
                    conversationHistory: historyForPlanner,
                    userPrompt: userPromptForPlanner,
                    onTextChunk: { [weak self] accumulatedPlannerText in
                        // Real text arrived — cancel the filler watcher
                        // so we never speak "okay" right before the real
                        // first sentence lands.
                        eagerFillerTask.cancel()
                        self?.responseOverlayManager.updateStreamingText(accumulatedPlannerText)
                        Task { @MainActor [weak self] in
                            await self?.streamingSentenceTTSPipeline.acceptStreamedText(accumulatedPlannerText)
                        }
                    }
                )
                eagerFillerTask.cancel()
                guard !Task.isCancelled else { return }

                let actionParseResult = PaceActionTagParser.parseActions(from: fullResponseText)
                let (_, textAfterDoneStrip) = PaceTagParsers.parseAndStripDoneSignal(from: actionParseResult.spokenText)
                let pointingParseResult = PaceTagParsers.parsePointingCoordinates(from: textAfterDoneStrip)
                let spokenText = pointingParseResult.spokenText

                // Settings → Debug capture: pure-knowledge turns never run a
                // screenshot/VLM and never execute actions here — surfaced so
                // a misrouted action command (answered instead of acted) is
                // visible as a text-only row.
                recordToolCallDebug(PaceToolCallDebugRecord(
                    transcript: transcript,
                    lane: .textOnly,
                    routingDetail: "pureKnowledge · text-only planner (no screen)",
                    plannerPathDetail: plannerForTextOnlyTurn.displayName,
                    rawPlannerOutput: fullResponseText,
                    spokenText: spokenText,
                    parsedActionsSummary: Self.toolCallDebugSummary(
                        for: actionParseResult.executionPlan
                    ),
                    dispatchSummary: "spoken-only — the text-only path does not execute actions",
                    plannerLatencyMs: Int(Date().timeIntervalSince(plannerStartedAt) * 1000),
                    totalTurnLatencyMs: Int(Date().timeIntervalSince(plannerStartedAt) * 1000),
                    userPrompt: userPromptForPlanner
                ))

                recordConversationTurn(userTranscript: transcript, assistantResponse: spokenText)

                responseOverlayManager.updateStreamingText(spokenText)
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
                    voiceState = .responding
                }

                while ttsClient.isPlaying {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }

                responseOverlayManager.finishStreaming()
                voiceState = .idle
                currentTurnHUDState = .done("answered")
                if isWalkingAvatarEnabled {
                    avatarOverlayManager?.show()
                }
            } catch {
                print("⚠️ Text-only planner fast path failed: \(error.localizedDescription)")
                responseOverlayManager.updateStreamingText("i hit a local planner issue.")
                responseOverlayManager.finishStreaming()
                voiceState = .idle
                currentTurnHUDState = .failed("Local planner issue")
            }
        }
    }

    /// Fast path for deterministic local actions that do not need screen
    /// perception or planner reasoning. This keeps "open Raycast" /
    /// "volume down" in the sub-second local-control lane while preserving
    /// the same approval, preflight, result, and TTS surfaces as planner
    /// generated actions.
    private func handleFastLocalActionPath(
        transcript: String,
        fastActionParseResult: PaceFastActionParseResult
    ) {
        let spokenText = fastActionParseResult.spokenText
        currentTurnHUDState = .acting(fastActionParseResult.executionPlan.approvalSummary)
        recordConversationTurn(userTranscript: transcript, assistantResponse: spokenText)

        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(spokenText)

        currentResponseTask = Task {
            let turnStartedAt = Date()
            voiceState = .responding
            let shouldSpeakInitialFastActionText = !actionExecutor.actionsAreEnabled
                || !PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
                    for: fastActionParseResult.executionPlan
                )

            if shouldSpeakInitialFastActionText,
               !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
            }

            let preflightIssues = PaceToolPreflight.evaluate(
                actionExecutionPlan: fastActionParseResult.executionPlan,
                environment: currentToolPreflightEnvironment()
            )
            appendActionResult(.planned(
                actionExecutionPlan: fastActionParseResult.executionPlan,
                preflightIssues: preflightIssues
            ))

            var fastPathDispatchSummaryForDebug = "executed"
            if actionExecutor.actionsAreEnabled {
                if requestUserApprovalForActionPlan(
                    fastActionParseResult.executionPlan,
                    preflightIssues: preflightIssues
                ) {
                    let toolObservations = await actionExecutor.executeActionPlan(
                        fastActionParseResult.executionPlan,
                        screenCaptures: []
                    )
                    fastPathDispatchSummaryForDebug = toolObservations.isEmpty
                        ? "executed — no observations returned"
                        : PaceActionExecutionObservation.formatForPlanner(toolObservations)
                    if !toolObservations.isEmpty {
                        appendActionResult(.completed(observations: toolObservations))
                        noteReversibleActionExecuted(
                            in: fastActionParseResult.executionPlan
                        )
                        speakFailureForClickMissedIfApplicable(
                            observations: toolObservations,
                            clickTargetLabel: Self.firstClickCandidateLabel(
                                in: fastActionParseResult.executionPlan
                            )
                        )
                    }
                    speakFailureForBlockingPreflightIfApplicable(
                        preflightIssues: preflightIssues
                    )
                    if let userFeedbackText = PaceActionExecutionObservation
                        .formatForUserFeedback(toolObservations) {
                        responseOverlayManager.updateStreamingText(userFeedbackText)
                        await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: userFeedbackText)
                    }
                } else {
                    fastPathDispatchSummaryForDebug = "denied by user"
                    appendActionResult(PaceActionRunRecord(
                        status: .denied,
                        title: "Action denied",
                        detail: fastActionParseResult.executionPlan.approvalSummary
                    ))
                    print("🛑 Fast local action approval denied")
                }
            } else {
                fastPathDispatchSummaryForDebug = "EnableActions=false — not executed"
                appendActionResult(PaceActionRunRecord(
                    status: .skipped,
                    title: "Actions disabled",
                    detail: "Parsed local fast action, but EnableActions is false."
                ))
                print("🤖 Fast local action parsed but EnableActions is false")
            }

            // Settings → Debug capture: the fast path matched before any
            // planner ran, so this row proves a command stayed local and
            // shows exactly what it parsed to.
            recordToolCallDebug(PaceToolCallDebugRecord(
                transcript: transcript,
                lane: .fastPath,
                routingDetail: "fast local parser matched (no screenshot, VLM, or planner)",
                rawPlannerOutput: "",
                spokenText: spokenText,
                parsedActionsSummary: Self.toolCallDebugSummary(
                    for: fastActionParseResult.executionPlan
                ),
                dispatchSummary: fastPathDispatchSummaryForDebug,
                totalTurnLatencyMs: Int(Date().timeIntervalSince(turnStartedAt) * 1000),
                userPrompt: transcript
            ))

            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }

            responseOverlayManager.finishStreaming()
            voiceState = .idle
            if self.currentTurnHUDState.status == .acting {
                self.currentTurnHUDState = .done("local action finished")
            }
            if isWalkingAvatarEnabled {
                avatarOverlayManager?.show()
            }
            currentDictationTrigger = .keyboard
            scheduleTransientHideIfNeeded()
        }
    }

    /// Explicit voice control for the watch loop. This runs before intent
    /// classification because starting/stopping watch mode is a local mode
    /// switch, not a planner task.
    private func handleWatchModeCommand(_ command: PaceWatchModeCommand, transcript: String) {
        let enabled: Bool
        let spokenText: String

        switch command {
        case .start:
            enabled = true
            spokenText = isWatchModeEnabled ? "watch mode is already on" : "watch mode is on"
        case .stop:
            enabled = false
            spokenText = isWatchModeEnabled ? "watch mode is off" : "watch mode is already off"
        }

        setWatchModeEnabled(enabled)
        currentTurnHUDState = .done(spokenText)
        recordConversationTurn(userTranscript: transcript, assistantResponse: spokenText)

        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(spokenText)

        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
            if isWalkingAvatarEnabled {
                avatarOverlayManager?.show()
            }
        }
    }

    /// Multi-step agent loop: capture screens → optional local VLM →
    /// planner → execute actions → re-screenshot → repeat. Each step is
    /// at most one planner round-trip and one action sequence. The loop
    /// exits when the planner emits `[DONE]`, when no action tags are
    /// emitted (it's a pure conversational answer), or when the per-task
    /// step budget is hit.
    ///
    /// The user's spoken transcript becomes the first turn's prompt;
    /// subsequent turns get a fixed "continue the task" prompt so the
    /// planner re-anchors on the conversation history rather than a
    /// repeated user statement.
    private func sendTranscriptToPlannerWithScreenshot(transcript: String) {
        Task { @MainActor in
            await sendTranscriptToPlannerWithScreenshotAsync(transcript: transcript)
        }
    }

    private func sendTranscriptToPlannerWithScreenshotAsync(transcript: String) async {
        currentResponseTask?.cancel()
        ttsClient.stopPlayback()
        pendingIntentClarification = nil
        // A new turn supersedes any unanswered click-target question —
        // drop it silently rather than auto-clicking, because the user
        // chose to keep talking instead of answering.
        pendingClickTargetClarification = nil

        // Idle gate: if the thread sat quiet past the configured
        // threshold, drop the verbatim window + summary and journal
        // a "session ended" line. The next turn starts a fresh
        // session. Runs synchronously here AND from a low-frequency
        // sweep timer so the menu-bar surface drops "session live"
        // indicators without needing a new turn.
        evaluateThreadIdleAndResetIfNeeded(now: Date())

        // Tell the planner this is a fresh user turn. Stateful conformers
        // (Apple Foundation Models) wipe their cross-call session state
        // here so the next turn doesn't drag in 7 prior agent-loop steps
        // and bust the 4K context window. Stateless conformers (LocalPlanner)
        // no-op.
        plannerClient.resetForNewTurn()

        if let watchModeCommand = PaceWatchModeCommandParser.parse(transcript) {
            print("👀 Watch mode voice command: \(watchModeCommand)")
            handleWatchModeCommand(watchModeCommand, transcript: transcript)
            return
        }

        if let alwaysListeningCommand = PaceAlwaysListeningCommandParser.parse(transcript) {
            print("🎙️ Always-listening voice command: \(alwaysListeningCommand)")
            handleAlwaysListeningCommand(alwaysListeningCommand, transcript: transcript)
            return
        }

        if let localMemoryCommand = PaceLocalMemoryCommandParser.parse(transcript) {
            print("🧠 Local memory command: \(localMemoryCommand)")
            handleLocalMemoryCommand(localMemoryCommand)
            return
        }

        if let recipeCommand = PaceRecipeCommandParser.parse(transcript) {
            print("📦 Recipe voice command: \(recipeCommand)")
            handleRecipeCommand(recipeCommand, transcript: transcript)
            return
        }

        if let flowCommand = PaceFlowCommandParser.parse(transcript) {
            print("🔁 Flow voice command: \(flowCommand)")
            handleFlowCommand(flowCommand, transcript: transcript)
            return
        }

        // "remember this as the cloudflare dashboard" — capture the current
        // tab URL under a user-chosen name (Tier 1 × Tier 3).
        if let rememberSiteCommand = PaceRememberSiteCommandParser.parse(transcript: transcript) {
            print("🔖 Remember-site command: \(rememberSiteCommand)")
            handleRememberSiteCommand(rememberSiteCommand, transcript: transcript)
            return
        }

        // "open the cloudflare dashboard" — recall a user-taught destination
        // on the fast path (no VLM, no planner). Only matches names the user
        // actually saved, so non-matching opens fall through below.
        if let destination = PaceNamedDestinationStore.shared.recall(matching: transcript) {
            print("🔖 Opening user-named destination: \(destination.displayName)")
            handleFastLocalActionPath(
                transcript: transcript,
                fastActionParseResult: PaceFastActionParseResult(
                    spokenText: "opening \(destination.displayName).",
                    executionPlan: .serial(actions: [.openURL(destination.url)])
                )
            )
            return
        }

        // Fast-path chitchat ("hi pace", "thanks") with a canned response
        // — skips VLM + planner + agent loop entirely. ~2200ms → ~50ms.
        // Conservative: only fires when the classifier is confident
        // enough to return .chitchat (not .unknown). Anything ambiguous
        // falls through to the full pipeline.
        let intentPrediction = await intentClassifier.classify(transcript)
        lastIntentRouteForEpisodicExtraction = intentPrediction.intent
        currentTurnHUDState = .understanding(routeHUDDetail(for: intentPrediction))
        if let clarification = PaceIntentClarifier.clarification(for: transcript) {
            print("❔ Intent clarification: \(clarification.question)")
            handleClarificationTurn(transcript: transcript, clarification: clarification)
            return
        }
        // When the intent is phoneLargeModel and the user has set up the cloud bridge,
        // route the turn through the bridge instead of refusing it with a local-only message.
        // This is the one intentional break of the no-cloud-LLM principle — consent-gated.
        if intentPrediction.route == .phoneLargeModel {
            let currentBridgeConfiguration = PaceCloudBridgeConsent.loadConfiguration()
            let bridgeIsActiveForThisTurn = currentBridgeConfiguration.hasUserAcceptedConsent
                && (currentBridgeConfiguration.mode == .hybrid
                    || currentBridgeConfiguration.mode == .alwaysBridge)

            if bridgeIsActiveForThisTurn {
                // Signal HybridPlannerClient (or CloudBridgePlannerClient directly in
                // alwaysBridge mode) to use the large-model path for this turn.
                if let hybridPlanner = plannerClient as? HybridPlannerClient {
                    hybridPlanner.routingHintForNextCall = .preferLarge
                }
                // Record first-use so the 24-hour soak timer starts ticking.
                PaceCloudBridgeConsent.markFirstUsedIfUnset(now: Date())
                isCloudBridgeCallActive = true
                isOffDeviceTurnInFlight = true

                let upstreamDisplayName = currentBridgeConfiguration.upstream.displayLabel
                let bridgeRoutingHUDDetail = "thinking with \(upstreamDisplayName.lowercased())…"
                currentTurnHUDState = .understanding(bridgeRoutingHUDDetail)
                print("📡 Routing phoneLargeModel turn to cloud bridge (\(upstreamDisplayName))")
                // Fall through to the normal planner pipeline — the routing hint
                // will cause the planner to call the bridge.
            } else {
                // Bridge is off or consent not given — keep the existing local-only message.
                if let unsupportedResponse = PaceIntentUnsupportedDetector.unsupportedResponse(
                    for: transcript,
                    prediction: intentPrediction
                ) {
                    print("🚫 Unsupported intent: \(unsupportedResponse.reason)")
                    handleUnsupportedTurn(transcript: transcript, unsupportedResponse: unsupportedResponse)
                    return
                }
            }
        } else if let unsupportedResponse = PaceIntentUnsupportedDetector.unsupportedResponse(
            for: transcript,
            prediction: intentPrediction
        ) {
            print("🚫 Unsupported intent: \(unsupportedResponse.reason)")
            handleUnsupportedTurn(transcript: transcript, unsupportedResponse: unsupportedResponse)
            return
        }
        if intentPrediction.intent == .chitchat {
            print("🎯 Intent: chitchat (confidence \(String(format: "%.2f", intentPrediction.confidence))) — fast-path")
            handleChitchatFastPath(transcript: transcript)
            return
        }
        if intentPrediction.route == .answerDirectly {
            print("🎯 Intent: pureKnowledge (confidence \(String(format: "%.2f", intentPrediction.confidence))) — text-only planner")
            handleTextOnlyPlannerFastPath(transcript: transcript)
            return
        }
        if let fastActionParseResult = PaceFastActionCommandParser.parse(transcript: transcript) {
            print("🎯 Intent: fastLocalAction — skipping screenshot, VLM, and planner")
            handleFastLocalActionPath(
                transcript: transcript,
                fastActionParseResult: fastActionParseResult
            )
            return
        }
        print("🎯 Intent: \(intentPrediction.intent.rawValue) (confidence \(String(format: "%.2f", intentPrediction.confidence))) — \(intentPrediction.route.rawValue)")
        currentTurnHUDState = .understanding(routeHUDDetail(for: intentPrediction))

        currentResponseTask = Task {
            voiceState = .processing

            let turnStartedAt = Date()
            let maxAgentStepCount = PaceTagParsers.readMaxAgentStepCount()
            var stepIndex = 0
            var currentTurnUserPrompt = transcript
            var pendingPostActionFeedbackText: String?
            let streamingMailDraftDetector = PaceStreamingMailDraftDetector()

            do {
                agentStepLoop: while stepIndex < maxAgentStepCount {
                    stepIndex += 1
                    streamingMailDraftDetector.reset()
                    let isFirstStep = (stepIndex == 1)
                    guard !Task.isCancelled else { return }

                    // 1. Capture screens for this step. On the first step,
                    // prefer the PTT-press prewarm capture if it finished:
                    // it already contains the cursor screen plus enriched
                    // analysis, so re-capturing before consuming it just
                    // adds latency to the hot path.
                    let screenCaptureStartedAt = Date()
                    var prewarmedContextForStep: PaceScreenContextPrewarmedSnapshot?
                    let screenCaptures: [CompanionScreenCapture]
                    if isFirstStep,
                       screenContextService.hasInFlightPrewarmedTask {
                        print("👁️  Awaiting pre-warm capture for first agent step…")
                        let prewarmedContext = await screenContextService.consumeInFlightPrewarmedSnapshot()
                        if let prewarmedContext,
                           !prewarmedContext.screenCaptures.isEmpty {
                            prewarmedContextForStep = prewarmedContext
                            screenCaptures = prewarmedContext.screenCaptures
                            print("👁️  First step using pre-warmed capture(s): \(screenCaptures.count)")
                        } else {
                            print("⚠️ Pre-warm capture unavailable — capturing screens now")
                            screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                        }
                    } else {
                        screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                    }
                    guard !Task.isCancelled else { return }
                    let screenCaptureElapsedMs = Int(
                        Date().timeIntervalSince(screenCaptureStartedAt) * 1000
                    )
                    // Per-stage timing — combined with TTFT/TTFSW these
                    // explain where each turn's budget actually goes.
                    // Useful when verifying that a perceived slowdown is
                    // (e.g.) screen capture vs. planner inference.
                    print("⏱  Step \(stepIndex) screen capture: \(screenCaptureElapsedMs)ms")

                    // System prompt + thread-memory injection are cheap
                    // (no VLM call) so they're computed BEFORE the planner
                    // branch below. The agent-mode block is omitted when
                    // EnableActions is off — pure prefill savings.
                    let isAgentModeEnabled = AppBundleConfiguration
                        .stringValue(forKey: "EnableActions")?
                        .lowercased() == "true"
                    let threadSummaryInjectionForTurn = threadMemory.injectionPrefix()
                    let systemPromptForTurn = CompanionSystemPrompt.build(
                        includeAgentMode: isAgentModeEnabled,
                        threadSummaryInjection: threadSummaryInjectionForTurn
                    )
                    // Mark this turn as off-device for the amber-tint
                    // capsule when the active planner is anything other
                    // than the on-device tiers (DirectAPI, alwaysBridge).
                    if plannerClient is DirectAPIPlannerClient
                        || plannerClient is CloudBridgePlannerClient {
                        isOffDeviceTurnInFlight = true
                    }

                    // Wave 4 speculative race (FIRST STEP ONLY): when the
                    // gate passes, the in-process Apple FM "lite" planner
                    // (transcript only, NO VLM) runs CONCURRENTLY with the
                    // full VLM-fed planner. Lite produces audio in ~150ms
                    // while a cold VLM (2–3s) is still running; the full
                    // path supersedes within 500ms if it catches up. The
                    // full planner's COMPLETE text always drives action
                    // parsing below — the lite path is spoken-feedback
                    // only and can never emit a real action. When the gate
                    // is false the single-planner else-branch is
                    // byte-identical to pre-race behavior.
                    let appleFoundationModelsIsAvailableForRace =
                        textOnlyPlannerClient is AppleFoundationModelsPlannerClient
                    let useSpeculativeRace = isFirstStep
                        && speculativeRaceShouldFire(
                            intent: intentPrediction.intent,
                            appleFoundationModelsIsAvailable: appleFoundationModelsIsAvailableForRace
                        )

                    // Latency + planner-input capture for the Settings → Debug
                    // trace. plannerSectionStartedAt is measured AFTER screen
                    // capture, so it covers VLM+OCR+planner (single path) or
                    // the race. userPromptForPlannerForDebug records the exact
                    // variable half of the planner input so a failing turn can
                    // be reproduced offline (system prompt is static in source).
                    let plannerSectionStartedAt = Date()
                    var userPromptForPlannerForDebug = ""
                    let fullResponseText: String
                    var raceLiteWonSpokenText: String? = nil
                    if useSpeculativeRace {
                        userPromptForPlannerForDebug = "(speculative race — full-path prompt assembled inside the race; lite path is transcript-only)"
                        let raceWiringResult = await performFirstStepSpeculativePlannerRace(
                            transcript: currentTurnUserPrompt,
                            systemPrompt: systemPromptForTurn,
                            intent: intentPrediction.intent,
                            route: intentPrediction.route,
                            screenCaptures: screenCaptures,
                            prewarmedContext: prewarmedContextForStep
                        )
                        guard !Task.isCancelled else { return }
                        if raceWiringResult.bothPlannersFailed {
                            isCloudBridgeCallActive = false
                            isOffDeviceTurnInFlight = false
                            currentTurnHUDState = .failed("planner offline")
                            speakPlainLanguageFailure(.plannerOffline, context: "speculative-race")
                            break agentStepLoop
                        }
                        fullResponseText = raceWiringResult.fullResponseTextForActionParsing
                        raceLiteWonSpokenText = raceWiringResult.liteWonSpokenText
                    } else {
                        // ---- Single-planner path (byte-identical to pre-race) ----
                        // 2. Build image labels with the actual screenshot pixel
                        //    dimensions so the planner's coordinate space matches
                        //    the image it sees.
                        let labeledImages = screenCaptures.map { capture in
                            let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                            return (data: capture.imageData, label: capture.label + dimensionInfo)
                        }

                        // 3. Optionally enrich the user prompt with the local VLM's
                        //    structured element map — cuts perception cost on the
                        //    planner side and is essential when the planner is text-only.
                        let screenContextStartedAt = Date()
                        let screenContextPrompt = await screenContextService.buildUserPromptWithLocalVLMContextIfEnabled(
                            transcript: currentTurnUserPrompt,
                            screenCaptures: screenCaptures,
                            prewarmedContext: prewarmedContextForStep
                        )
                        let userPromptForPlanner = await appendLocalRetrievalContext(
                            to: appendConfiguredMCPContext(to: screenContextPrompt),
                            query: transcript,
                            route: intentPrediction.route,
                            isFirstPlannerStep: isFirstStep
                        )
                        userPromptForPlannerForDebug = userPromptForPlanner
                        let screenContextElapsedMs = Int(
                            Date().timeIntervalSince(screenContextStartedAt) * 1000
                        )
                        print("⏱  Step \(stepIndex) screen context (VLM + OCR + AX): \(screenContextElapsedMs)ms")

                        // Diagnostic: print the first 5 element lines we're
                        // about to send to the planner.
                        logFirstElementsOfPromptForDiagnostics(
                            userPromptForPlanner: userPromptForPlanner,
                            stepIndex: stepIndex
                        )

                        // 4. Build conversation history (already includes prior steps)
                        let historyForPlanner = conversationHistory.map { entry in
                            (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                        }

                        // 5. Run the planner. Text-only planners get an empty
                        //    images list; the VLM element-map text inside
                        //    userPromptForPlanner is their only view of the screen.
                        let imagesForPlanner: [(data: Data, label: String)] =
                            plannerClient.supportsImageInput ? labeledImages : []

                        let (singlePlannerResponseText, _) = try await plannerClient.generateResponseStreaming(
                            images: imagesForPlanner,
                            systemPrompt: systemPromptForTurn,
                            conversationHistory: historyForPlanner,
                            userPrompt: userPromptForPlanner,
                            onTextChunk: { [weak self] accumulatedPlannerText in
                                // 1. Mirror raw text into the bubble so the user
                                //    sees tags, thinking blocks, everything live.
                                //    The end-of-turn step replaces this with the
                                //    cleaned spoken text once parsing completes.
                                //    EXCEPT a structured (v10 JSON) stream —
                                //    show a thinking ellipsis, not raw JSON.
                                self?.responseOverlayManager.updateStreamingText(
                                    Self.streamedPlannerTextIsStructuredEnvelope(accumulatedPlannerText)
                                        ? "…" : accumulatedPlannerText
                                )
                                // 2. Hand the chunk to the streaming TTS so any
                                //    newly-completed sentences get spoken before
                                //    the planner has finished generating the rest.
                                //    This is the dominant perceived-latency win.
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    let shouldSuppressStreamingNarration = Self.streamedPlannerTextIsStructuredEnvelope(accumulatedPlannerText)
                                        || (self.actionExecutor.actionsAreEnabled
                                            && PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
                                                forPlannerResponseText: accumulatedPlannerText
                                            ))
                                    guard !shouldSuppressStreamingNarration else { return }
                                    await self.streamingSentenceTTSPipeline.acceptStreamedText(accumulatedPlannerText)
                                }
                                if let streamingMailDraftSnapshot = streamingMailDraftDetector
                                    .detectChange(in: accumulatedPlannerText) {
                                    Task { @MainActor [weak self] in
                                        guard let self,
                                              self.actionExecutor.actionsAreEnabled,
                                              !self.requiresActionApproval else {
                                            return
                                        }
                                        _ = await self.actionExecutor.beginOrUpdateStreamingMailDraft(
                                            streamingMailDraftSnapshot
                                        )
                                    }
                                }
                            }
                        )
                        fullResponseText = singlePlannerResponseText
                    }
                    let plannerSectionElapsedMs = Int(
                        Date().timeIntervalSince(plannerSectionStartedAt) * 1000
                    )
                    guard !Task.isCancelled else { return }

                    // Clear the amber bridge indicator now that the stream has finished.
                    // Do this regardless of whether it was a bridge call or a local call —
                    // clearing when already false is a safe no-op. The
                    // unified off-device flag follows the same lifecycle
                    // so Direct-API turns un-tint the capsule too.
                    isCloudBridgeCallActive = false
                    isOffDeviceTurnInFlight = false

                    // 6. Parse: action tags → [DONE] flag → pointing tag.
                    //    Each pass strips its own tag class so the final
                    //    `spokenText` is clean enough to play via TTS.
                    let actionParseResult = PaceActionTagParser.parseActions(from: fullResponseText)
                    let streamedMailDraftForFinalization = PaceStreamingMailDraftDetector
                        .firstMailDraft(in: actionParseResult.executionPlan)
                    if actionExecutor.hasActiveStreamingMailDraft,
                       streamedMailDraftForFinalization == nil {
                        actionExecutor.cancelActiveStreamingMailDraftTracking()
                    }
                    let (plannerSignaledDone, textAfterDoneStrip) =
                        PaceTagParsers.parseAndStripDoneSignal(from: actionParseResult.spokenText)
                    let pointingParseResultRaw = PaceTagParsers.parsePointingCoordinates(from: textAfterDoneStrip)

                    // When the planner emitted action tags but no explicit
                    // [POINT:...], use the first click coordinate as the
                    // cursor-flight target so the buddy lands where it's
                    // about to click.
                    let parseResult: PointingParseResult = {
                        if pointingParseResultRaw.coordinate != nil {
                            return pointingParseResultRaw
                        }
                        if let firstClickLocation = actionParseResult.firstClickVisualisationLocation {
                            return PointingParseResult(
                                spokenText: pointingParseResultRaw.spokenText,
                                coordinate: CGPoint(
                                    x: firstClickLocation.xInScreenshotPixels,
                                    y: firstClickLocation.yInScreenshotPixels
                                ),
                                elementLabel: "action target",
                                screenNumber: firstClickLocation.screenNumber
                            )
                        }
                        return pointingParseResultRaw
                    }()
                    // When the speculative race's LITE path won the audio,
                    // the user already heard the lite answer — so the
                    // spoken/displayed/journaled string is the lite text,
                    // NOT the full planner's text (which only drives the
                    // action parse above). This keeps audio, bubble,
                    // reply-replay, and thread memory consistent with what
                    // was actually spoken, and prevents `flushFinal` from
                    // diffing a different string against the already-spoken
                    // lite prefix. nil in every non-race / full-won case.
                    let spokenText = raceLiteWonSpokenText ?? parseResult.spokenText
                    let plannerProvidedFinalFeedback = actionParseResult.actions.isEmpty
                        && !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if plannerProvidedFinalFeedback {
                        pendingPostActionFeedbackText = nil
                    }
                    // Replace the raw-with-tags streaming view with the
                    // cleaned spoken text now that tags are stripped.
                    responseOverlayManager.updateStreamingText(
                        spokenText.isEmpty ? "…" : spokenText
                    )
                    // Note the spoken text so the notch panel can show
                    // the reply-replay button for the next 30 seconds.
                    // Uses the SAME post-processed string that flows
                    // through TTS (think blocks + action tags already
                    // stripped) — see PRD trust-and-failures.
                    noteLastSpokenReply(spokenText)
                    // Sidecar TTS health check: if Kokoro has been
                    // failing this turn, surface the "switched to
                    // system voice" plain-language failure once per
                    // outage window.
                    if let localServerTTSClient = ttsClient as? LocalServerTTSClient {
                        speakSidecarTTSFallbackMemoIfNeeded(
                            isSidecarUnreachable: localServerTTSClient.hasObservedSidecarOutage
                        )
                    }

                    // 7. Move the cursor to the pointing/click target so the
                    //    flight animation is in flight before the click fires.
                    let hasPointCoordinate = parseResult.coordinate != nil
                    if hasPointCoordinate {
                        voiceState = .idle
                    }

                    let targetScreenCapture: CompanionScreenCapture? = {
                        if let screenNumber = parseResult.screenNumber,
                           screenNumber >= 1 && screenNumber <= screenCaptures.count {
                            return screenCaptures[screenNumber - 1]
                        }
                        return screenCaptures.first(where: { $0.isCursorScreen })
                    }()

                    if let pointCoordinate = parseResult.coordinate,
                       let targetScreenCapture {
                        let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                        let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                        let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                        let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                        let displayFrame = targetScreenCapture.displayFrame

                        let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                        let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                        let appKitY = displayHeight - displayLocalY
                        let globalLocation = CGPoint(
                            x: displayLocalX + displayFrame.origin.x,
                            y: appKitY + displayFrame.origin.y
                        )

                        detectedElementScreenLocation = globalLocation
                        detectedElementDisplayFrame = displayFrame
                        PaceAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                        print("🎯 Step \(stepIndex) pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                    } else {
                        print("🎯 Step \(stepIndex) pointing: \(parseResult.elementLabel ?? "no element")")
                    }

                    // 8. Save this step to conversation history. First step
                    //    gets the real transcript; later steps record the
                    //    continuation placeholder so the planner sees its
                    //    own previous narration via assistant turns.
                    recordConversationTurn(
                        userTranscript: isFirstStep ? transcript : "(agent step \(stepIndex))",
                        assistantResponse: spokenText
                    )
                    print("🧠 Conversation history: \(conversationHistory.count) exchanges")
                    PaceAnalytics.trackAIResponseReceived(response: spokenText)

                    // 9. The bulk of the spoken response has been queued
                    //    sentence-by-sentence inside the onTextChunk
                    //    callback above as the planner was generating.
                    //    Here we just speak whatever tail remains past
                    //    the last sentence boundary the streamer found,
                    //    using the fully-cleaned spokenText as the
                    //    source of truth (the streamer used a coarser
                    //    in-flight strip).
                    let shouldSpeakInitialPlannerText = !actionExecutor.actionsAreEnabled
                        || !PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
                            for: actionParseResult.executionPlan
                        )
                    if shouldSpeakInitialPlannerText,
                       !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
                        voiceState = .responding
                    }

                    // 10. Execute tool calls/action tags if any.
                    var toolObservations: [PaceActionExecutionObservation] = []
                    var userDeniedActionApproval = false
                    if !actionParseResult.actions.isEmpty {
                        let preflightIssues = PaceToolPreflight.evaluate(
                            actionExecutionPlan: actionParseResult.executionPlan,
                            environment: currentToolPreflightEnvironment()
                        )
                        appendActionResult(.planned(
                            actionExecutionPlan: actionParseResult.executionPlan,
                            preflightIssues: preflightIssues
                        ))

                        // Visual-target ambiguity: if the executor's click
                        // candidates have near-tied, distinguishable labels,
                        // ask ONE short HUD question instead of guessing the
                        // top one. Pauses this turn — resolving an option in
                        // the panel executes the chosen candidate directly
                        // (resolveClickTargetClarification), so we break out
                        // of the agent loop here. See PRD
                        // docs/prds/hud-intent-disambiguator.md.
                        if actionExecutor.actionsAreEnabled,
                           raiseClickTargetClarificationIfAmbiguous(
                               actionExecutionPlan: actionParseResult.executionPlan,
                               screenCaptures: screenCaptures
                           ) {
                            break agentStepLoop
                        }

                        if actionExecutor.actionsAreEnabled {
                            if requestUserApprovalForActionPlan(
                                actionParseResult.executionPlan,
                                preflightIssues: preflightIssues
                            ) {
                                // Brief settle so the cursor flight visibly arrives
                                // before the synthetic click fires.
                                try? await Task.sleep(nanoseconds: 350_000_000)
                                guard !Task.isCancelled else { return }
                                if actionExecutor.hasActiveStreamingMailDraft,
                                   let finalMailDraft = streamedMailDraftForFinalization {
                                    if let streamingMailObservation = await actionExecutor
                                        .finishActiveStreamingMailDraft(finalMailDraft: finalMailDraft) {
                                        toolObservations.append(streamingMailObservation)
                                    }

                                    let remainingActionPlan = actionParseResult
                                        .executionPlan
                                        .removingFirstMailDraftAction()
                                    toolObservations += await actionExecutor.executeActionPlan(
                                        remainingActionPlan,
                                        screenCaptures: screenCaptures
                                    )
                                } else {
                                    toolObservations = await actionExecutor.executeActionPlan(
                                        actionParseResult.executionPlan,
                                        screenCaptures: screenCaptures
                                    )
                                }
                                if !toolObservations.isEmpty {
                                    print("🧰 Tool observations:\n\(PaceActionExecutionObservation.formatForPlanner(toolObservations))")
                                    appendActionResult(.completed(observations: toolObservations))
                                    pendingPostActionFeedbackText = PaceActionExecutionObservation
                                        .formatForUserFeedback(toolObservations)
                                    // After every reversible mutation, raise the
                                    // visible undo banner (PRD trust-and-failures).
                                    noteReversibleActionExecuted(
                                        in: actionParseResult.executionPlan
                                    )
                                    // After click-all-fail observations, speak
                                    // the plain-language failure once.
                                    speakFailureForClickMissedIfApplicable(
                                        observations: toolObservations,
                                        clickTargetLabel: Self.firstClickCandidateLabel(
                                            in: actionParseResult.executionPlan
                                        )
                                    )
                                }
                            } else {
                                userDeniedActionApproval = true
                                appendActionResult(PaceActionRunRecord(
                                    status: .denied,
                                    title: "Action denied",
                                    detail: actionParseResult.executionPlan.approvalSummary
                                ))
                                print("🛑 Pace action approval denied — stopping agent loop")
                            }
                        } else {
                            appendActionResult(PaceActionRunRecord(
                                status: .skipped,
                                title: "Actions disabled",
                                detail: "Parsed \(actionParseResult.actions.count) action(s), but EnableActions is false."
                            ))
                            print("🤖 \(actionParseResult.actions.count) action(s) parsed but EnableActions is false — exiting loop after this step")
                        }

                        // Narrate any blocking preflight issue regardless of
                        // approval popup — when the auto-execute path is
                        // silently blocked (no popup, no actions ran), this
                        // keeps the failure audible.
                        speakFailureForBlockingPreflightIfApplicable(
                            preflightIssues: preflightIssues
                        )
                    }

                    // Settings → Debug capture: record this planner step's
                    // raw output, parsed tool calls, and dispatch outcome.
                    // Pure observability sink — never affects the loop.
                    let dispatchSummaryForDebug: String = {
                        if actionParseResult.actions.isEmpty {
                            return "no actions parsed — spoken-only turn"
                        }
                        if userDeniedActionApproval {
                            return "denied by user"
                        }
                        if !actionExecutor.actionsAreEnabled {
                            return "EnableActions=false — not executed"
                        }
                        if toolObservations.isEmpty {
                            return "executed — no observations returned"
                        }
                        return PaceActionExecutionObservation.formatForPlanner(toolObservations)
                    }()
                    recordToolCallDebug(PaceToolCallDebugRecord(
                        transcript: isFirstStep ? transcript : "(agent step \(stepIndex))",
                        lane: .planner,
                        routingDetail: "\(intentPrediction.intent.rawValue) · conf \(String(format: "%.2f", intentPrediction.confidence)) · \(intentPrediction.route.rawValue)",
                        plannerPathDetail: useSpeculativeRace
                            ? (raceLiteWonSpokenText != nil
                                ? "speculative race · lite (Apple FM, no screen) won audio"
                                : "speculative race · full planner won")
                            : "single planner",
                        userHeardScreenlessAnswer: raceLiteWonSpokenText,
                        screenElementCount: lastPlannerElementLineCountForDebug,
                        rawPlannerOutput: fullResponseText,
                        spokenText: spokenText,
                        parsedActionsSummary: Self.toolCallDebugSummary(
                            for: actionParseResult.executionPlan
                        ),
                        dispatchSummary: dispatchSummaryForDebug,
                        plannerLatencyMs: plannerSectionElapsedMs,
                        totalTurnLatencyMs: Int(
                            Date().timeIntervalSince(turnStartedAt) * 1000
                        ),
                        userPrompt: userPromptForPlannerForDebug
                    ))

                    // 11. Exit conditions for the agent loop:
                    //     - planner emitted [DONE]
                    //     - planner emitted no action tags (pure answer turn)
                    //     - actions are disabled (treat every turn as single-shot)
                    // Structured-output turns are SINGLE-SHOT: the v10 JSON
                    // envelope can't carry a [DONE] tag and always contains an
                    // action, so re-looping makes the constrained planner
                    // invent spurious follow-ups (it dictated the user's own
                    // command on an 8-step runaway). Multi-action sequences
                    // ride in one envelope via payload.calls instead.
                    let exitLoop = plannerSignaledDone
                        || actionParseResult.actions.isEmpty
                        || !actionExecutor.actionsAreEnabled
                        || userDeniedActionApproval
                        || plannerClient.usesStructuredActionOutput
                    if exitLoop {
                        if plannerSignaledDone {
                            print("✅ Agent loop: planner signaled [DONE] at step \(stepIndex)")
                        } else if plannerClient.usesStructuredActionOutput {
                            print("✅ Agent loop: structured-output turn is single-shot — stopping after step \(stepIndex)")
                        }
                        break agentStepLoop
                    }

                    // 12. Brief wait so the action's effect lands in the UI
                    //     before we capture the next screenshot. Without this
                    //     the new screen capture may still show pre-click state.
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }

                    // Set up the next iteration.
                    let toolObservationPromptText = PaceActionExecutionObservation.formatForPlanner(toolObservations)
                    if toolObservationPromptText.isEmpty {
                        currentTurnUserPrompt = "continue the task. look at the current screen, then either emit the next step's action tags or emit [DONE] if the task is complete."
                    } else {
                        currentTurnUserPrompt = """
                        tool results:
                        \(toolObservationPromptText)

                        continue the task. use the tool results and current screen, then either emit the next step's tool calls/action tags or emit [DONE] if the task is complete.
                        """
                    }
                    voiceState = .processing
                }

                if stepIndex >= maxAgentStepCount {
                    print("⚠️ Agent loop: hit max steps (\(maxAgentStepCount)) without [DONE] — stopping")
                }

                if let pendingPostActionFeedbackText,
                   !pendingPostActionFeedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !Task.isCancelled {
                    responseOverlayManager.updateStreamingText(pendingPostActionFeedbackText)
                    await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: pendingPostActionFeedbackText)
                    voiceState = .responding
                }
                if currentTurnHUDState.status == .understanding
                    || currentTurnHUDState.status == .acting {
                    currentTurnHUDState = .done("turn finished")
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted. Hide the
                // overlay immediately so it doesn't linger over the next
                // turn's "listening…" state.
                isCloudBridgeCallActive = false
                isOffDeviceTurnInFlight = false
                responseOverlayManager.hideOverlay()
            } catch {
                PaceAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                isCloudBridgeCallActive = false
                isOffDeviceTurnInFlight = false
                responseOverlayManager.updateStreamingText("error: \(error.localizedDescription)")
                responseOverlayManager.finishStreaming()
                currentTurnHUDState = .failed(error.localizedDescription)
                speakCreditsErrorFallback()
                // Plain-language failure narration — see PRD
                // docs/prds/trust-and-failures.md. The cloud bridge
                // gets its own kind so the user knows which CLI to
                // inspect; everything else maps onto plannerOffline.
                if plannerClient is CloudBridgePlannerClient {
                    speakPlainLanguageFailure(
                        .cloudBridgeUpstreamError(
                            provider: cloudBridgeUpstream.displayLabel
                        ),
                        context: "planner-catch"
                    )
                } else {
                    speakPlainLanguageFailure(.plannerOffline, context: "planner-catch")
                }
            }

            if !Task.isCancelled {
                voiceState = .idle
                // Keep the bubble up while TTS is still speaking so the
                // user can read along, then fade ~800ms after audio ends.
                let weakTTSClient = ttsClient
                responseOverlayManager.finishStreaming(keepVisibleUntil: { @MainActor in
                    weakTTSClient.isPlaying
                })
                // Restore the walking avatar (if user has it enabled)
                // and reset the trigger so the next turn defaults to
                // keyboard until something says otherwise.
                if isWalkingAvatarEnabled {
                    avatarOverlayManager?.show()
                }
                currentDictationTrigger = .keyboard
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Result of wiring ONE first agent step through the speculative
    /// planner race. `fullResponseTextForActionParsing` is ALWAYS the
    /// full planner's text when it succeeded (so actions parse from the
    /// accurate, VLM-fed planner no matter who won the audio); it falls
    /// back to the lite text only when the full path threw.
    /// `liteWonSpokenText` is non-nil ONLY when the lite path won the
    /// audio outright — it is the cleaned string the user actually heard,
    /// which the caller uses as the spoken/displayed/journaled text.
    /// `bothPlannersFailed` routes the caller to the failure narrator.
    private struct PaceFirstStepRaceWiringResult {
        let fullResponseTextForActionParsing: String
        let liteWonSpokenText: String?
        let bothPlannersFailed: Bool
    }

    /// Wave 4: wire the first agent step through `PaceSpeculativePlanner
    /// Race`. The lite path (in-process Apple FM, transcript only, no VLM)
    /// races the full VLM-fed planner; the winner's tokens stream to TTS +
    /// the bubble as they arrive, while the full path's COMPLETE text
    /// always comes back for action parsing. Only invoked when
    /// `speculativeRaceShouldFire` is true for a FIRST step — multi-step
    /// agent turns keep the single-planner path.
    private func performFirstStepSpeculativePlannerRace(
        transcript: String,
        systemPrompt: String,
        intent: PaceIntent,
        route: PaceIntentRoute,
        screenCaptures: [CompanionScreenCapture],
        prewarmedContext: PaceScreenContextPrewarmedSnapshot?
    ) async -> PaceFirstStepRaceWiringResult {
        let fullClient = plannerClient
        let liteClient = textOnlyPlannerClient

        // The full path's expensive input prep (VLM + OCR + AX + retrieval)
        // is deferred into this builder so it runs CONCURRENTLY with the
        // lite path instead of blocking it — that overlap is the whole
        // cold-path speed win. Assembly is identical to the single-planner
        // else-branch in the agent loop.
        let fullPlannerInputBuilder: @MainActor () async -> PaceChatTurnPart = { [weak self] in
            guard let self else {
                return PaceChatTurnPart(
                    images: [],
                    systemPrompt: systemPrompt,
                    conversationHistory: [],
                    userPrompt: transcript
                )
            }
            let labeledImages = screenCaptures.map { capture -> (data: Data, label: String) in
                let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                return (data: capture.imageData, label: capture.label + dimensionInfo)
            }
            let screenContextStartedAt = Date()
            let screenContextPrompt = await self.screenContextService.buildUserPromptWithLocalVLMContextIfEnabled(
                transcript: transcript,
                screenCaptures: screenCaptures,
                prewarmedContext: prewarmedContext
            )
            let userPromptForPlanner = await self.appendLocalRetrievalContext(
                to: self.appendConfiguredMCPContext(to: screenContextPrompt),
                query: transcript,
                route: route,
                isFirstPlannerStep: true
            )
            print("⏱  Race full-path screen context (VLM + OCR + AX): \(Int(Date().timeIntervalSince(screenContextStartedAt) * 1000))ms")
            self.logFirstElementsOfPromptForDiagnostics(
                userPromptForPlanner: userPromptForPlanner,
                stepIndex: 1
            )
            let historyForPlanner = self.conversationHistory.map { entry in
                (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
            }
            let imagesForPlanner: [(data: Data, label: String)] =
                fullClient.supportsImageInput ? labeledImages : []
            return PaceChatTurnPart(
                images: imagesForPlanner,
                systemPrompt: systemPrompt,
                conversationHistory: historyForPlanner,
                userPrompt: userPromptForPlanner
            )
        }

        // Winner box: shared by reference between the synchronous onToken
        // callback (winner-flip detection) and the async TTS-dispatch Task
        // (stale-lite-chunk guard after a supersede).
        let winnerBox = PaceSpeculativeRaceWinnerBox()

        let raceResult = await PaceSpeculativePlannerRace.raceSpeculative(
            transcript: transcript,
            systemPrompt: systemPrompt,
            // The system prompt already carries the rolling thread-memory
            // summary via CompanionSystemPrompt.build(threadSummaryInjection:),
            // so the lite user prompt must NOT prepend it again.
            threadMemoryPrefix: "",
            intent: intent,
            liteClient: liteClient,
            fullClient: fullClient,
            fullPlannerInputBuilder: fullPlannerInputBuilder,
            spokenCharacterCountProbe: { [weak self] in
                self?.streamingSentenceTTSPipeline.firstSpokenWordCharacterCount ?? 0
            },
            onToken: { [weak self] accumulatedText, winner in
                guard let self else { return }
                // The first full token while lite has been speaking is a
                // supersede: reset the TTS pipeline so the full stream — a
                // different string than lite — replays cleanly instead of
                // being diffed against the already-spoken lite prefix.
                if winnerBox.winner == .lite, winner == .full {
                    self.streamingSentenceTTSPipeline.prepareForSupersedingStreamWithinTurn()
                }
                winnerBox.winner = winner
                self.responseOverlayManager.updateStreamingText(
                    Self.streamedPlannerTextIsStructuredEnvelope(accumulatedText)
                        ? "…" : accumulatedText
                )
                // The full (main) planner is decode-constrained to the v10
                // JSON envelope, so its stream is raw JSON — never speak it;
                // the parsed spokenText is flushed at turn end instead. The
                // lite path stays free prose and streams normally.
                let shouldSuppressStreamingNarration = Self.streamedPlannerTextIsStructuredEnvelope(accumulatedText)
                    || (self.actionExecutor.actionsAreEnabled
                        && PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
                            forPlannerResponseText: accumulatedText
                        ))
                guard !shouldSuppressStreamingNarration else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // A lite chunk's dispatch Task scheduled BEFORE a
                    // supersede must not re-speak lite over the freshly
                    // reset full stream — drop it if the winner has moved on.
                    guard winner == winnerBox.winner else { return }
                    await self.streamingSentenceTTSPipeline.acceptStreamedText(accumulatedText)
                }
            },
            onCompletion: { _ in }
        )

        switch raceResult.outcome {
        case .bothFailed:
            return PaceFirstStepRaceWiringResult(
                fullResponseTextForActionParsing: "",
                liteWonSpokenText: nil,
                bothPlannersFailed: true
            )
        case .liteWon:
            // Actions (if any) still parse from the full planner's text
            // when it succeeded; the user heard the lite answer, so the
            // spoken/displayed string is the lite text cleaned the same
            // way the full path's spoken text is.
            let liteRawText = raceResult.litePlannerResponseText ?? ""
            return PaceFirstStepRaceWiringResult(
                fullResponseTextForActionParsing: raceResult.fullPlannerResponseText ?? liteRawText,
                liteWonSpokenText: Self.cleanedSpokenTextForRace(from: liteRawText),
                bothPlannersFailed: false
            )
        case .fullWon, .fullSupersededLite:
            return PaceFirstStepRaceWiringResult(
                fullResponseTextForActionParsing: raceResult.fullPlannerResponseText ?? "",
                liteWonSpokenText: nil,
                bothPlannersFailed: false
            )
        }
    }

    /// Strip tags from a planner response the same way the agent loop
    /// derives `spokenText`, so the lite-won spoken string the user hears
    /// matches the cleaning the full path gets. Pure + static — no actor
    /// hops, unit-testable in isolation.
    nonisolated private static func cleanedSpokenTextForRace(from rawText: String) -> String {
        let actionParse = PaceActionTagParser.parseActions(from: rawText)
        let (_, textAfterDoneStrip) = PaceTagParsers.parseAndStripDoneSignal(from: actionParse.spokenText)
        return PaceTagParsers.parsePointingCoordinates(from: textAfterDoneStrip).spokenText
    }

    /// Builds the prompt sent to the cloud planner. When the local VLM is
    /// enabled in Info.plist, runs the cursor screen through it first and
    /// prepends a structured element map. The cloud planner can then refer
    /// to elements by name without re-doing the perception work itself.
    /// One-line diagnostic dump of what the planner is about to see.
    /// Surfaces the FIRST 5 element lines from the prompt so a console
    /// paste makes it obvious whether the target the user named is
    /// actually in the element map — separating "model picked wrong"
    /// from "model never saw the target." Stays terse so it doesn't
    /// drown the rest of the log.
    private func logFirstElementsOfPromptForDiagnostics(
        userPromptForPlanner: String,
        stepIndex: Int
    ) {
        let allElementLines = userPromptForPlanner
            .split(separator: "\n")
            .filter { $0.contains("|") && !$0.hasPrefix("===") }
        // Stash the full count for the Settings → Debug post-execution
        // capture so a "did the planner even see the screen?" question is
        // answerable per turn.
        lastPlannerElementLineCountForDebug = allElementLines.count
        let elementLines = allElementLines.prefix(5)
        guard !elementLines.isEmpty else {
            print("🔬 Step \(stepIndex) planner sees: <no element-list lines in prompt>")
            return
        }
        print("🔬 Step \(stepIndex) planner sees (top 5 of element map):")
        for line in elementLines {
            print("     \(line)")
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Pace" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isPaceCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Surfaces a planner/TTS failure silently — visible in the response
    /// overlay (already updated by the caller) and the audit log, but
    /// never spoken through NSSpeechSynthesizer. The previous Apple-voice
    /// "Something went wrong" line was rated worse than no audio.
    private func speakCreditsErrorFallback() {
        currentTurnHUDState = .failed("response error")
        PaceAPIAuditLog.shared.record(
            subsystem: "pipeline",
            operation: "error",
            target: "companion-manager",
            durationMilliseconds: 0,
            outcome: "error",
            detail: "main planner/TTS path failed"
        )
    }

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
