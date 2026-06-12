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

/// Per-screen VLM analysis cached by the analyzer identity plus pixel hash.
/// As long as the model/runtime/display and screen pixels haven't changed,
/// repeat questions reuse the cached element map — zero VLM cost.
private struct ScreenAnalysisCacheIdentity: Equatable {
    let analyzerDisplayName: String
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect

    init(
        analyzerDisplayName: String,
        capture: CompanionScreenCapture
    ) {
        self.analyzerDisplayName = analyzerDisplayName
        self.screenshotWidthInPixels = capture.screenshotWidthInPixels
        self.screenshotHeightInPixels = capture.screenshotHeightInPixels
        self.displayWidthInPoints = capture.displayWidthInPoints
        self.displayHeightInPoints = capture.displayHeightInPoints
        self.displayFrame = capture.displayFrame
    }
}

private struct CachedScreenAnalysis {
    let identity: ScreenAnalysisCacheIdentity
    let pixelHash: String
    let visualFingerprint: PaceScreenVisualFingerprint?
    let analysis: LocalVLMScreenAnalysis
    let capturedAt: Date
}

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
    @Published private(set) var localMemorySummary: String = PaceLocalMemoryStore.summaryText
    @Published private(set) var localRetrievalSummary: String = "Retrieval: local preferences and Pace history"
    @Published private(set) var localRetrievalSourceStatuses: [PaceRetrievalSourceStatus] = []
    @Published private(set) var localRetrievalFileRootPaths: [String] = PaceLocalRetrievalFileRootPreferences
        .rootPaths(for: PaceLocalRetrievalFileRootPreferences.userSelectedRootURLs())
    @Published private(set) var currentTurnHUDState: PaceTurnHUDState = .idle

    private var pendingIntentClarification: PacePendingIntentClarification?
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
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
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
    private let episodicFactExtractor = PaceEpisodicFactExtractor()

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

    /// Task started at PTT press that captures the screen and runs the
    /// VLM + OCR in parallel. By the time the user finishes speaking
    /// (~2-5s typical), the result is usually ready. The agent loop
    /// awaits this instead of doing the work serially after the
    /// transcript arrives. nil when not started or when pre-warm is
    /// disabled (e.g. "Read My Screen" toggle off).
    private var prewarmedScreenContextTask: Task<PrewarmedScreenContext?, Never>?

    /// Snapshot returned by the pre-warm task. Held briefly between
    /// PTT press and transcript arrival; consumed once by the agent
    /// loop's first step then cleared.
    private struct PrewarmedScreenContext {
        let screenCaptures: [CompanionScreenCapture]
        let enrichedAnalysesByScreenLabel: [String: LocalVLMScreenAnalysis]
    }

    // Screen-analysis provider (LM Studio HTTP by default) that extracts a
    // structured element map from screenshots. Only invoked when the
    // `UseLocalVLMForScreenContext` Info.plist key is set to true.
    // Always allocated so toggling the key doesn't require restart logic.
    private lazy var screenAnalysisClient: any PaceScreenAnalysisClient = {
        PaceScreenAnalysisClientFactory.makeDefaultClient()
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

    /// Per-screen VLM analysis cache keyed by screen label (e.g.
    /// "primary focus", "screen 2"). Hash of the screenshot's JPEG
    /// bytes is checked on each turn: hash match → reuse cached
    /// analysis for free; hash mismatch → re-run VLM only on the
    /// changed screens, in parallel with the rest. This is the
    /// performance lever for "always-looking" — most turns hit the
    /// cache for at least some screens.
    private var perScreenAnalysisCache: [String: CachedScreenAnalysis] = [:]

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
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
    }

    @Published var areCalendarNudgesEnabled: Bool = PaceUserPreferencesStore
        .bool(.areCalendarNudgesEnabled, default: false)

    func setCalendarNudgesEnabled(_ enabled: Bool) {
        areCalendarNudgesEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .areCalendarNudgesEnabled)
    }

    @Published var areWatchObservationNudgesEnabled: Bool = PaceUserPreferencesStore
        .bool(.areWatchObservationNudgesEnabled, default: false)

    func setWatchObservationNudgesEnabled(_ enabled: Bool) {
        areWatchObservationNudgesEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .areWatchObservationNudgesEnabled)
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
        var freshCachedScreenDescription: String?
        if let cachedScreenAnalysis = perScreenAnalysisCache[event.screenLabel],
           event.detectedAt.timeIntervalSince(cachedScreenAnalysis.capturedAt) <= 120 {
            let cachedDescription = cachedScreenAnalysis.analysis.description
            if !cachedDescription.isEmpty {
                freshCachedScreenDescription = cachedDescription
            }
        }
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
        let extractedFacts = episodicFactExtractor.extractFacts(
            from: userTranscript,
            assistantText: assistantResponse,
            frontmostApplicationName: NSWorkspace.shared.frontmostApplication?.localizedName,
            sourceTurnId: stableTurnId
        )
        localRetriever.recordEpisodicFacts(extractedFacts)
        refreshLocalRetrievalPublishedState()

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
                await MainActor.run {
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
        let spokenText: String
        switch command {
        case .startRecording(let name):
            spokenText = "ready to record \(name). flow recording is queued for the AX recorder."
        case .stopRecording:
            spokenText = "recording stopped."
        case .run(let name):
            spokenText = PaceFlowStore().load(named: name) == nil
                ? "i couldn't find a flow named \(name)."
                : "that flow is ready for approval before replay."
        case .delete(let name):
            do {
                try PaceFlowStore().delete(named: name)
                spokenText = "deleted \(name)."
            } catch {
                spokenText = "i couldn't delete \(name)."
            }
        }
        handleImmediateLocalModeResponse(transcript: transcript, spokenText: spokenText)
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
        print("🔗 Deeplink chat transcript: \(transcript)")

        currentResponseTask?.cancel()
        currentResponseTask = nil
        ttsClient.stopPlayback()
        streamingSentenceTTSPipeline.resetForNewTurn()
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
        startScreenContextPrewarmIfEnabled()
        voiceState = .processing
        sendTranscriptToPlannerWithScreenshot(transcript: transcript)
    }

    func start() {
        refreshAllPermissions()
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
        startPermissionPolling()
        startLMStudioReachabilityPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
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
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
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
        } else {
            globalPushToTalkShortcutMonitor.stop()
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
                Task { @MainActor in
                    self?.refreshAllPermissions()
                }
            }
        } else {
            permissionEventStore.requestAccess(to: .event) { [weak self] _, _ in
                Task { @MainActor in
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
                Task { @MainActor in
                    self?.refreshAllPermissions()
                }
            }
        } else {
            permissionEventStore.requestAccess(to: .reminder) { [weak self] _, _ in
                Task { @MainActor in
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
            startScreenContextPrewarmIfEnabled()
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
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
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
        responseOverlayManager.finishStreaming()
        currentTurnHUDState = .understanding("using \(option.lowercased())")
        sendTranscriptToPlannerWithScreenshot(transcript: clarifiedTranscript)
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

        currentResponseTask = Task {
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
                let (fullResponseText, _) = try await plannerForTextOnlyTurn.generateResponseStreaming(
                    images: [],
                    systemPrompt: CompanionSystemPrompt.buildTextOnly(
                        threadSummaryInjection: threadSummaryInjectionForTurn
                    ),
                    conversationHistory: historyForPlanner,
                    userPrompt: userPromptForPlanner,
                    onTextChunk: { [weak self] accumulatedPlannerText in
                        self?.responseOverlayManager.updateStreamingText(accumulatedPlannerText)
                        Task { @MainActor [weak self] in
                            await self?.streamingSentenceTTSPipeline.acceptStreamedText(accumulatedPlannerText)
                        }
                    }
                )
                guard !Task.isCancelled else { return }

                let actionParseResult = PaceActionTagParser.parseActions(from: fullResponseText)
                let (_, textAfterDoneStrip) = PaceTagParsers.parseAndStripDoneSignal(from: actionParseResult.spokenText)
                let pointingParseResult = PaceTagParsers.parsePointingCoordinates(from: textAfterDoneStrip)
                let spokenText = pointingParseResult.spokenText

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

            if actionExecutor.actionsAreEnabled {
                if requestUserApprovalForActionPlan(
                    fastActionParseResult.executionPlan,
                    preflightIssues: preflightIssues
                ) {
                    let toolObservations = await actionExecutor.executeActionPlan(
                        fastActionParseResult.executionPlan,
                        screenCaptures: []
                    )
                    if !toolObservations.isEmpty {
                        appendActionResult(.completed(observations: toolObservations))
                    }
                    if let userFeedbackText = PaceActionExecutionObservation
                        .formatForUserFeedback(toolObservations) {
                        responseOverlayManager.updateStreamingText(userFeedbackText)
                        await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: userFeedbackText)
                    }
                } else {
                    appendActionResult(PaceActionRunRecord(
                        status: .denied,
                        title: "Action denied",
                        detail: fastActionParseResult.executionPlan.approvalSummary
                    ))
                    print("🛑 Fast local action approval denied")
                }
            } else {
                appendActionResult(PaceActionRunRecord(
                    status: .skipped,
                    title: "Actions disabled",
                    detail: "Parsed local fast action, but EnableActions is false."
                ))
                print("🤖 Fast local action parsed but EnableActions is false")
            }

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

        // Fast-path chitchat ("hi pace", "thanks") with a canned response
        // — skips VLM + planner + agent loop entirely. ~2200ms → ~50ms.
        // Conservative: only fires when the classifier is confident
        // enough to return .chitchat (not .unknown). Anything ambiguous
        // falls through to the full pipeline.
        let intentPrediction = await intentClassifier.classify(transcript)
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
                    var prewarmedContextForStep: PrewarmedScreenContext?
                    let screenCaptures: [CompanionScreenCapture]
                    if isFirstStep,
                       let prewarmedTask = prewarmedScreenContextTask {
                        print("👁️  Awaiting pre-warm capture for first agent step…")
                        let prewarmedContext = await prewarmedTask.value
                        prewarmedScreenContextTask = nil
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
                    let screenContextPrompt = await buildUserPromptWithLocalVLMContextIfEnabled(
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
                    let screenContextElapsedMs = Int(
                        Date().timeIntervalSince(screenContextStartedAt) * 1000
                    )
                    print("⏱  Step \(stepIndex) screen context (VLM + OCR + AX): \(screenContextElapsedMs)ms")

                    // Diagnostic: print the first 5 element lines we're
                    // about to send to the planner. The single most
                    // useful thing when a click misses is comparing
                    // "what coordinates the planner saw" against "what
                    // coordinates the planner emitted."
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

                    // System prompt is built per-turn from blocks so we
                    // can omit the ~700-token agent-mode block when
                    // EnableActions is off. That's pure
                    // prefill savings every turn.
                    let isAgentModeEnabled = AppBundleConfiguration
                        .stringValue(forKey: "EnableActions")?
                        .lowercased() == "true"
                    // Mark this turn as off-device for the amber-tint
                    // capsule when the active planner is anything other
                    // than the on-device tiers. The Hybrid wrapper sets
                    // its own bridge-specific flag right before its bridge
                    // branch fires; this catches every non-Local call
                    // shape (DirectAPI, alwaysBridge, hybrid-large-routing
                    // already handled above).
                    if plannerClient is DirectAPIPlannerClient
                        || plannerClient is CloudBridgePlannerClient {
                        isOffDeviceTurnInFlight = true
                    }
                    let threadSummaryInjectionForTurn = threadMemory.injectionPrefix()
                    let (fullResponseText, _) = try await plannerClient.generateResponseStreaming(
                        images: imagesForPlanner,
                        systemPrompt: CompanionSystemPrompt.build(
                            includeAgentMode: isAgentModeEnabled,
                            threadSummaryInjection: threadSummaryInjectionForTurn
                        ),
                        conversationHistory: historyForPlanner,
                        userPrompt: userPromptForPlanner,
                        onTextChunk: { [weak self] accumulatedPlannerText in
                            // 1. Mirror raw text into the bubble so the user
                            //    sees tags, thinking blocks, everything live.
                            //    The end-of-turn step replaces this with the
                            //    cleaned spoken text once parsing completes.
                            self?.responseOverlayManager.updateStreamingText(accumulatedPlannerText)
                            // 2. Hand the chunk to the streaming TTS so any
                            //    newly-completed sentences get spoken before
                            //    the planner has finished generating the rest.
                            //    This is the dominant perceived-latency win.
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                let shouldSuppressStreamingNarration = self.actionExecutor.actionsAreEnabled
                                    && PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
                                        forPlannerResponseText: accumulatedPlannerText
                                    )
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
                    let spokenText = parseResult.spokenText
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
                    }

                    // 11. Exit conditions for the agent loop:
                    //     - planner emitted [DONE]
                    //     - planner emitted no action tags (pure answer turn)
                    //     - actions are disabled (treat every turn as single-shot)
                    let exitLoop = plannerSignaledDone
                        || actionParseResult.actions.isEmpty
                        || !actionExecutor.actionsAreEnabled
                        || userDeniedActionApproval
                    if exitLoop {
                        if plannerSignaledDone {
                            print("✅ Agent loop: planner signaled [DONE] at step \(stepIndex)")
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
        let elementLines = userPromptForPlanner
            .split(separator: "\n")
            .filter { $0.contains("|") && !$0.hasPrefix("===") }
            .prefix(5)
        guard !elementLines.isEmpty else {
            print("🔬 Step \(stepIndex) planner sees: <no element-list lines in prompt>")
            return
        }
        print("🔬 Step \(stepIndex) planner sees (top 5 of element map):")
        for line in elementLines {
            print("     \(line)")
        }
    }

    ///
    /// If the VLM is unreachable or errors, returns the raw transcript
    /// unchanged so the cloud-only path keeps working. Errors are logged
    /// for debugging but never surfaced to the user.
    private func buildUserPromptWithLocalVLMContextIfEnabled(
        transcript: String,
        screenCaptures: [CompanionScreenCapture],
        prewarmedContext: PrewarmedScreenContext? = nil
    ) async -> String {
        guard useLocalVLMForScreenContext else {
            print("👁️  VLM skipped — 'Read My Screen' toggle is off")
            return transcript
        }

        if let prewarmedContext,
           !prewarmedContext.screenCaptures.isEmpty {
            print("👁️  Pre-warm context supplied by first-step capture path")
            return buildPromptFromEnrichedAnalyses(
                transcript: transcript,
                captures: prewarmedContext.screenCaptures,
                enrichedAnalysesByLabel: prewarmedContext.enrichedAnalysesByScreenLabel
            )
        }

        // First try: did the PTT-press pre-warm finish? If yes, we
        // consume its result and skip the synchronous VLM + OCR work
        // entirely — perceived VLM latency drops to ~0.
        if let prewarmedTask = prewarmedScreenContextTask {
            print("👁️  Awaiting pre-warm result…")
            let awaitStartedAt = Date()
            let prewarmed = await prewarmedTask.value
            prewarmedScreenContextTask = nil
            let awaitedDuration = Date().timeIntervalSince(awaitStartedAt)
            if let prewarmed, !prewarmed.screenCaptures.isEmpty {
                print(String(format: "👁️  Pre-warm consumed in %.2fs", awaitedDuration))
                return buildPromptFromEnrichedAnalyses(
                    transcript: transcript,
                    captures: prewarmed.screenCaptures,
                    enrichedAnalysesByLabel: prewarmed.enrichedAnalysesByScreenLabel
                )
            }
            print("⚠️ Pre-warm returned nothing — falling back to synchronous VLM")
        }

        guard !screenCaptures.isEmpty else {
            print("⚠️ VLM skipped — no screen captures available")
            return transcript
        }

        // Synchronous fallback: pre-warm wasn't started or failed.
        // Cursor-screen-only by design — user is almost always asking
        // about the screen they're looking at.
        let orderedCaptures: [CompanionScreenCapture] = {
            if let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) {
                return [cursorScreenCapture]
            }
            if let firstCapture = screenCaptures.first {
                return [firstCapture]
            }
            return []
        }()

        // Bucket captures into cache hits (free, reuse stored analysis)
        // and misses (need a fresh VLM call). Hash is SHA256 of the JPEG
        // bytes — stable across runs, cheap (~5ms for 1MB).
        var perCaptureCachedAnalysis: [Int: LocalVLMScreenAnalysis] = [:]
        var capturesToAnalyze: [(captureIndex: Int, capture: CompanionScreenCapture, pixelHash: String, visualFingerprint: PaceScreenVisualFingerprint?)] = []

        for (captureIndex, capture) in orderedCaptures.enumerated() {
            let pixelHash = Self.computePixelHash(for: capture.imageData)
            let visualFingerprint = PaceScreenImageDiffer.fingerprint(for: capture.imageData)
            let cacheIdentity = ScreenAnalysisCacheIdentity(
                analyzerDisplayName: screenAnalysisClient.displayName,
                capture: capture
            )
            if let cached = perScreenAnalysisCache[capture.label] {
                guard cached.identity == cacheIdentity else {
                    print("👁️  Cache MISS for \(capture.label) — analyzer or display changed")
                    capturesToAnalyze.append((captureIndex, capture, pixelHash, visualFingerprint))
                    continue
                }
                if cached.pixelHash == pixelHash {
                    perCaptureCachedAnalysis[captureIndex] = cached.analysis
                    print("👁️  Cache HIT for \(capture.label) — reusing \(cached.analysis.elements.count) elements")
                    continue
                }

                if let cachedVisualFingerprint = cached.visualFingerprint,
                   let visualFingerprint,
                   let visualDiff = PaceScreenImageDiffer.diff(
                    from: cachedVisualFingerprint,
                    to: visualFingerprint
                   ),
                   !visualDiff.isMeaningful {
                    perCaptureCachedAnalysis[captureIndex] = cached.analysis
                    perScreenAnalysisCache[capture.label] = CachedScreenAnalysis(
                        identity: cacheIdentity,
                        pixelHash: pixelHash,
                        visualFingerprint: visualFingerprint,
                        analysis: cached.analysis,
                        capturedAt: Date()
                    )
                    print(String(format: "👁️  Visual diff cache HIT for %@ — %.3f changed, %.1f mean delta", capture.label, visualDiff.changedPixelRatio, visualDiff.meanPixelDelta))
                    continue
                }
            }

            capturesToAnalyze.append((captureIndex, capture, pixelHash, visualFingerprint))
        }

        // Try the AX-tree first on the cursor screen (cheap, ~50ms);
        // if it returns elements we skip the VLM for this in-loop
        // re-analysis the same way the PTT-press pre-warm does. The
        // 2B VLM was failing on every in-loop call last test run,
        // leaving the planner with no screen context and looping on
        // useless scrolls — AX fixes that.
        var capturesStillNeedingVLM: [(captureIndex: Int, capture: CompanionScreenCapture, pixelHash: String, visualFingerprint: PaceScreenVisualFingerprint?)] = []
        var freshAnalysesByCaptureIndex: [Int: LocalVLMScreenAnalysis] = [:]
        if !capturesToAnalyze.isEmpty {
            let axScreenReaderForLoopBody = self.axScreenReader
            for (captureIndex, capture, pixelHash, visualFingerprint) in capturesToAnalyze {
                let axElements = axScreenReaderForLoopBody.readFocusedWindow(
                    scalingToScreenshot: capture
                )
                if !axElements.isEmpty {
                    let ocrBoxes = (try? await visionOCRClient.recognizeText(
                        in: capture.imageData,
                        screenshotWidthInPixels: capture.screenshotWidthInPixels,
                        screenshotHeightInPixels: capture.screenshotHeightInPixels
                    )) ?? []
                    let axBackedAnalysis = PaceScreenContextMerger.enrich(
                        vlmAnalysis: LocalVLMScreenAnalysis(elements: axElements, description: ""),
                        with: ocrBoxes
                    )
                    print("👁️  In-loop AX HIT for \(capture.label): \(axElements.count) elements + \(ocrBoxes.count) OCR boxes — skipping VLM")
                    freshAnalysesByCaptureIndex[captureIndex] = axBackedAnalysis
                    perScreenAnalysisCache[capture.label] = CachedScreenAnalysis(
                        identity: ScreenAnalysisCacheIdentity(
                            analyzerDisplayName: screenAnalysisClient.displayName,
                            capture: capture
                        ),
                        pixelHash: pixelHash,
                        visualFingerprint: visualFingerprint,
                        analysis: axBackedAnalysis,
                        capturedAt: Date()
                    )
                } else {
                    capturesStillNeedingVLM.append((captureIndex, capture, pixelHash, visualFingerprint))
                }
            }
        }

        // Anything AX couldn't see falls back to the VLM. With the
        // FM planner this is rarely hit; the LM Studio VLM path
        // stays around for Electron / games / broken-AX apps.
        if !capturesStillNeedingVLM.isEmpty {
            print("👁️  Running VLM + OCR on \(capturesStillNeedingVLM.count) screen(s) (AX missed)…")
            let analyses = await withTaskGroup(
                of: (Int, String, LocalVLMScreenAnalysis?, String, PaceScreenVisualFingerprint?).self
            ) { taskGroup in
                for (captureIndex, capture, pixelHash, visualFingerprint) in capturesStillNeedingVLM {
                    taskGroup.addTask { [screenAnalysisClient, visionOCRClient] in
                        // VLM + OCR concurrent. OCR finishes much faster
                        // (~100-200ms); we wait on the VLM and then merge.
                        async let vlmAnalysisFuture = screenAnalysisClient.analyzeScreenshot(
                            screenshotImageData: capture.imageData,
                            userIntent: transcript
                        )
                        async let ocrBoxesFuture = visionOCRClient.recognizeText(
                            in: capture.imageData,
                            screenshotWidthInPixels: capture.screenshotWidthInPixels,
                            screenshotHeightInPixels: capture.screenshotHeightInPixels
                        )
                        do {
                            let vlmAnalysis = try await vlmAnalysisFuture
                            let ocrBoxes = (try? await ocrBoxesFuture) ?? []
                            let enriched = PaceScreenContextMerger.enrich(
                                vlmAnalysis: vlmAnalysis,
                                with: ocrBoxes
                            )
                            return (captureIndex, capture.label, enriched, pixelHash, visualFingerprint)
                        } catch {
                            print("⚠️ VLM failed for \(capture.label): \(error.localizedDescription)")
                            return (captureIndex, capture.label, nil, pixelHash, visualFingerprint)
                        }
                    }
                }
                var collected: [(Int, String, LocalVLMScreenAnalysis?, String, PaceScreenVisualFingerprint?)] = []
                for await result in taskGroup {
                    collected.append(result)
                }
                return collected
            }
            for (captureIndex, label, maybeAnalysis, pixelHash, visualFingerprint) in analyses {
                guard let analysis = maybeAnalysis else { continue }
                freshAnalysesByCaptureIndex[captureIndex] = analysis
                perScreenAnalysisCache[label] = CachedScreenAnalysis(
                    identity: ScreenAnalysisCacheIdentity(
                        analyzerDisplayName: screenAnalysisClient.displayName,
                        capture: orderedCaptures[captureIndex]
                    ),
                    pixelHash: pixelHash,
                    visualFingerprint: visualFingerprint,
                    analysis: analysis,
                    capturedAt: Date()
                )
                print("👁️  VLM analysed \(label): \(analysis.elements.count) elements")
            }
        }

        // Merge cached + fresh analyses back into the original capture order.
        var perScreenPromptSections: [String] = []
        for (captureIndex, capture) in orderedCaptures.enumerated() {
            let analysis = perCaptureCachedAnalysis[captureIndex]
                ?? freshAnalysesByCaptureIndex[captureIndex]
            guard let analysis else { continue }
            perScreenPromptSections.append(Self.formatScreenAnalysisForPrompt(
                screenLabel: capture.label,
                analysis: analysis
            ))
        }

        if perScreenPromptSections.isEmpty {
            print("⚠️ All VLM calls failed — falling back to raw transcript")
            return transcript
        }

        let joinedScreenSections = perScreenPromptSections.joined(separator: "\n\n")
        return """
        On-device screen analysis (auto-extracted by a local vision model on each connected display):

        \(joinedScreenSections)

        User said: \(transcript)
        """
    }

    /// Build the planner prompt from already-enriched analyses (the
    /// pre-warm path). Same formatting as the synchronous path so the
    /// planner can't tell whether it's reading a pre-warmed or fresh
    /// analysis — keeps prompt-engineering work consistent.
    private func buildPromptFromEnrichedAnalyses(
        transcript: String,
        captures: [CompanionScreenCapture],
        enrichedAnalysesByLabel: [String: LocalVLMScreenAnalysis]
    ) -> String {
        let perScreenPromptSections: [String] = captures.compactMap { capture in
            guard let analysis = enrichedAnalysesByLabel[capture.label] else { return nil }
            return Self.formatScreenAnalysisForPrompt(
                screenLabel: capture.label,
                analysis: analysis
            )
        }
        guard !perScreenPromptSections.isEmpty else { return transcript }
        return """
        On-device screen analysis (auto-extracted by a local vision model + native OCR):

        \(perScreenPromptSections.joined(separator: "\n\n"))

        User said: \(transcript)
        """
    }

    /// Render one screen's element map into the planner-prompt block.
    /// Compact format: one element per line as `role|x,y|label|text`.
    /// Cap reduced to 15 (down from 25) because Apple Foundation
    /// Models' 4K context window busts on bigger element lists once
    /// the system prompt + agent rules + history are added. 30-char
    /// text cap (down from 60) keeps headings and button labels
    /// intact while shedding the bulk of verbose OCR runs.
    private static func formatScreenAnalysisForPrompt(
        screenLabel: String,
        analysis: LocalVLMScreenAnalysis
    ) -> String {
        let maxElementsRendered = 15
        let maxTextCharsPerElement = 30
        let elementSummaryLines = analysis.elements
            .prefix(maxElementsRendered)
            .enumerated()
            .map { elementIndex, element -> String in
                // Bbox CENTER, not top-left — Click landed half-element
                // off when we sent corners.
                let coordinateText = element.bbox.count == 4
                    ? "\(element.bbox[0] + element.bbox[2] / 2),\(element.bbox[1] + element.bbox[3] / 2)"
                    : "?,?"
                let textSuffix = element.text.flatMap { text -> String? in
                    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedText.isEmpty else { return nil }
                    let truncatedText = trimmedText.count > maxTextCharsPerElement
                        ? String(trimmedText.prefix(maxTextCharsPerElement)) + "…"
                        : trimmedText
                    return "|\(truncatedText)"
                } ?? ""
                // Numeric ID prefix lets the FM @Generable planner
                // emit element IDs instead of free-text coords. The
                // ID space is local to this turn; the planner client
                // re-parses these lines to map ID → (x, y) on output.
                return "[\(elementIndex)] \(element.role)|\(coordinateText)|\(element.label)\(textSuffix)"
            }
        let elementSummaryText = elementSummaryLines.joined(separator: "\n")
        let elementCountSummary = analysis.elements.count > maxElementsRendered
            ? "top \(maxElementsRendered) of \(analysis.elements.count)"
            : "\(analysis.elements.count)"
        let trimmedDescription = analysis.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionLine = trimmedDescription.isEmpty
            ? ""
            : "\nsummary: \(trimmedDescription)"
        return """
        === \(screenLabel) (\(elementCountSummary) elements) ===\(descriptionLine)
        \(elementSummaryText)
        """
    }

    /// SHA256 of the JPEG byte stream. Stable across runs, ~5ms for a
    /// 1 MB capture on Apple Silicon. Used as the cache key for the
    /// per-screen VLM analysis — if the pixels didn't change, the
    /// element map didn't either.
    nonisolated private static func computePixelHash(for jpegData: Data) -> String {
        let digest = SHA256.hash(data: jpegData)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Kicks off the screen-context pre-warm at PTT press. By the time
    /// the user releases (~2-5s of speech), the VLM + OCR have usually
    /// finished — so the planner can start immediately without waiting.
    /// Cancellable: a quick press-release replaces the task with a new
    /// one or nil.
    private func startScreenContextPrewarmIfEnabled() {
        prewarmedScreenContextTask?.cancel()
        guard useLocalVLMForScreenContext else {
            prewarmedScreenContextTask = nil
            print("👁️  Skipping prewarm — Read My Screen is off")
            return
        }
        // Snapshot the dependencies so the detached task doesn't have
        // to hop back to MainActor for them.
        let vlmClient = screenAnalysisClient
        let ocrClient = visionOCRClient
        prewarmedScreenContextTask = Task { [weak self] in
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen })
                    ?? screenCaptures.first else {
                    return nil
                }

                // Hash check — reuse cached analysis if the screen
                // hasn't changed since last turn. Cache lookups are
                // MainActor-bound so we hop briefly.
                let pixelHash = Self.computePixelHash(for: cursorScreenCapture.imageData)
                let visualFingerprint = PaceScreenImageDiffer.fingerprint(for: cursorScreenCapture.imageData)
                let cacheIdentity = ScreenAnalysisCacheIdentity(
                    analyzerDisplayName: vlmClient.displayName,
                    capture: cursorScreenCapture
                )
                let cachedAnalysis = await MainActor.run { () -> LocalVLMScreenAnalysis? in
                    guard let self else { return nil }
                    guard let cached = self.perScreenAnalysisCache[cursorScreenCapture.label] else {
                        return nil
                    }
                    guard cached.identity == cacheIdentity else {
                        print("👁️  Prewarm cache MISS for \(cursorScreenCapture.label) — analyzer or display changed")
                        return nil
                    }
                    if cached.pixelHash == pixelHash {
                        print("👁️  Prewarm cache HIT for \(cursorScreenCapture.label)")
                        return cached.analysis
                    }
                    if let cachedVisualFingerprint = cached.visualFingerprint,
                       let visualFingerprint,
                       let visualDiff = PaceScreenImageDiffer.diff(
                        from: cachedVisualFingerprint,
                        to: visualFingerprint
                       ),
                       !visualDiff.isMeaningful {
                        self.perScreenAnalysisCache[cursorScreenCapture.label] = CachedScreenAnalysis(
                            identity: cacheIdentity,
                            pixelHash: pixelHash,
                            visualFingerprint: visualFingerprint,
                            analysis: cached.analysis,
                            capturedAt: Date()
                        )
                        print(String(format: "👁️  Prewarm visual diff cache HIT for %@ — %.3f changed, %.1f mean delta", cursorScreenCapture.label, visualDiff.changedPixelRatio, visualDiff.meanPixelDelta))
                        return cached.analysis
                    }
                    return nil
                }

                if let cachedAnalysis {
                    return PrewarmedScreenContext(
                        screenCaptures: [cursorScreenCapture],
                        enrichedAnalysesByScreenLabel: [cursorScreenCapture.label: cachedAnalysis]
                    )
                }

                // Fast tier: try the AX tree of the focused window
                // before standing up the VLM. AX is 10-100x faster
                // than the VLM and covers most AppKit / SwiftUI /
                // Catalyst apps cleanly. Fires in parallel with OCR
                // so we still get verbatim text enrichment.
                // Scaled to the cursor screen's actual screenshot
                // dimensions so the planner sees coordinates in the
                // same pixel space the executor uses for clicks
                // (downsampled to maxDimension=1280, not Retina-native).
                async let axElementsFuture: [LocalVLMScreenElement] = MainActor.run { [weak self] in
                    self?.axScreenReader.readFocusedWindow(scalingToScreenshot: cursorScreenCapture) ?? []
                }
                async let earlyOCRBoxesFuture = ocrClient.recognizeText(
                    in: cursorScreenCapture.imageData,
                    screenshotWidthInPixels: cursorScreenCapture.screenshotWidthInPixels,
                    screenshotHeightInPixels: cursorScreenCapture.screenshotHeightInPixels
                )
                let axElements = await axElementsFuture
                if !axElements.isEmpty {
                    let earlyOCRBoxes = (try? await earlyOCRBoxesFuture) ?? []
                    let synthesizedAnalysisFromAX = LocalVLMScreenAnalysis(
                        elements: axElements,
                        description: ""
                    )
                    let enrichedFromAX = PaceScreenContextMerger.enrich(
                        vlmAnalysis: synthesizedAnalysisFromAX,
                        with: earlyOCRBoxes
                    )
                    print("👁️  Prewarm AX HIT: \(axElements.count) elements + \(earlyOCRBoxes.count) OCR boxes — skipping VLM")
                    await MainActor.run { [weak self] in
                        self?.perScreenAnalysisCache[cursorScreenCapture.label] = CachedScreenAnalysis(
                            identity: cacheIdentity,
                            pixelHash: pixelHash,
                            visualFingerprint: visualFingerprint,
                            analysis: enrichedFromAX,
                            capturedAt: Date()
                        )
                    }
                    return PrewarmedScreenContext(
                        screenCaptures: [cursorScreenCapture],
                        enrichedAnalysesByScreenLabel: [cursorScreenCapture.label: enrichedFromAX]
                    )
                }

                print("👁️  Prewarm AX returned nothing — falling back to VLM + OCR…")
                // Reuse the OCR future from the AX attempt above —
                // it's been running concurrently and we don't want to
                // double-spend on the same screenshot.
                async let vlmAnalysisFuture = vlmClient.analyzeScreenshot(
                    screenshotImageData: cursorScreenCapture.imageData,
                    userIntent: "general screen analysis"
                )

                let vlmAnalysis: LocalVLMScreenAnalysis
                do {
                    vlmAnalysis = try await vlmAnalysisFuture
                } catch {
                    print("⚠️ Prewarm VLM failed: \(error.localizedDescription)")
                    // Fall back to OCR-only context
                    let ocrBoxesFallback = (try? await earlyOCRBoxesFuture) ?? []
                    let descriptionFromOCR = ocrBoxesFallback.prefix(8)
                        .map { $0.text }
                        .joined(separator: " · ")
                    let ocrOnlyAnalysis = LocalVLMScreenAnalysis(
                        elements: PaceScreenContextMerger.enrich(
                            vlmAnalysis: LocalVLMScreenAnalysis(elements: [], description: ""),
                            with: ocrBoxesFallback
                        ).elements,
                        description: descriptionFromOCR.isEmpty
                            ? "VLM failed; OCR text only."
                            : "VLM failed. OCR text snippets: \(descriptionFromOCR)"
                    )
                    return PrewarmedScreenContext(
                        screenCaptures: [cursorScreenCapture],
                        enrichedAnalysesByScreenLabel: [cursorScreenCapture.label: ocrOnlyAnalysis]
                    )
                }

                let ocrBoxes = (try? await earlyOCRBoxesFuture) ?? []
                let enriched = PaceScreenContextMerger.enrich(
                    vlmAnalysis: vlmAnalysis,
                    with: ocrBoxes
                )

                // Update cache for next turn.
                await MainActor.run { [weak self] in
                    self?.perScreenAnalysisCache[cursorScreenCapture.label] = CachedScreenAnalysis(
                        identity: cacheIdentity,
                        pixelHash: pixelHash,
                        visualFingerprint: visualFingerprint,
                        analysis: enriched,
                        capturedAt: Date()
                    )
                }
                print("👁️  Prewarm complete: \(enriched.elements.count) elements (\(ocrBoxes.count) OCR boxes merged)")

                return PrewarmedScreenContext(
                    screenCaptures: [cursorScreenCapture],
                    enrichedAnalysesByScreenLabel: [cursorScreenCapture.label: enriched]
                )
            } catch {
                print("⚠️ Prewarm failed: \(error.localizedDescription)")
                return nil
            }
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
