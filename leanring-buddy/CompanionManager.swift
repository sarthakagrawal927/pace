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
import CryptoKit
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

/// Per-screen VLM analysis cached by the pixel hash of the screenshot.
/// As long as the screen hasn't changed visually, repeat questions reuse
/// the cached element map — zero VLM cost, instant response.
private struct CachedScreenAnalysis {
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
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

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
    private lazy var streamingSentenceTTSPipeline: StreamingSentenceTTSPipeline = {
        return StreamingSentenceTTSPipeline(ttsClient: ttsClient)
    }()

    /// Classifies the user's transcript into pureKnowledge /
    /// screenDescription / screenAction / chitchat so the pipeline
    /// can skip work the turn doesn't need. Today only the chitchat
    /// fast-path is wired (canned response, no VLM, no planner call) —
    /// other intents still flow through the full pipeline. The
    /// rule-based backend ships now; the Core ML backend takes over
    /// once the .mlmodel is bundled (see #113 follow-up).
    private lazy var intentClassifier: PaceIntentClassifier = {
        return PaceIntentClassifier()
    }()

    // The reasoning/planning model. Today this is always a
    // LocalPlannerClient pointing at LM Studio; the protocol shape stays
    // so an alternate local runtime (Ollama, raw llama.cpp, MLX-server)
    // can plug in by writing a new conformer.
    private lazy var plannerClient: any BuddyPlannerClient = {
        return BuddyPlannerClientFactory.makeDefault()
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

    /// Native macOS OCR. Runs in parallel with the VLM, both pre-warmed
    /// at PTT-press so neither shows up in perceived latency. The VLM
    /// identifies elements; OCR delivers verbatim text — merged by
    /// bbox overlap. Cheap (~50-200ms), no model load.
    private let visionOCRClient = PaceVisionOCRClient()
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

    // Local vision-language model (LM Studio by default) that extracts a
    // structured element map from screenshots. Only invoked when the
    // `UseLocalVLMForScreenContext` Info.plist key is set to true.
    // Always allocated so toggling the key doesn't require a restart logic
    // change, but the LM Studio server only sees traffic when enabled.
    private lazy var localVLMClient: LocalVLMClient = {
        let configuredBaseURL = AppBundleConfiguration.stringValue(forKey: "LocalVLMBaseURL")
            ?? "http://localhost:1234/v1"
        let configuredModelIdentifier = AppBundleConfiguration.stringValue(forKey: "LocalVLMModelIdentifier")
            ?? "qwen3-vl-8b-instruct"
        let resolvedBaseURL = URL(string: configuredBaseURL) ?? URL(string: "http://localhost:1234/v1")!
        return LocalVLMClient(baseURL: resolvedBaseURL, modelIdentifier: configuredModelIdentifier)
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
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

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

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
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

    /// User preference for whether Pace asks before executing local tools.
    /// Defaults on because action mode can click, type, open apps/URLs,
    /// and modify local system state.
    @Published var requiresActionApproval: Bool = PaceUserPreferencesStore
        .bool(.requiresActionApproval, default: true)

    func setRequiresActionApproval(_ enabled: Bool) {
        requiresActionApproval = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .requiresActionApproval)
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

    private func handleWatchModeEvent(_ event: PaceScreenWatchEvent) async {
        let summary = "Screen changed: \(event.screenLabel)"
        latestWatchModeSummary = summary
        print("👀 Watch mode: \(summary) meanDelta=\(String(format: "%.2f", event.diff.meanPixelDelta)) changedRatio=\(String(format: "%.3f", event.diff.changedPixelRatio))")

        guard voiceState == .idle else { return }

        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText("i noticed the screen changed.")
        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: "i noticed the screen changed.")
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
        }
    }

    private func requestUserApprovalForActionPlan(_ actionExecutionPlan: PaceActionExecutionPlan) -> Bool {
        guard requiresActionApproval else { return true }

        let approvalSummary = actionExecutionPlan.approvalSummary
        guard !approvalSummary.isEmpty else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Approve Pace actions?"
        alert.informativeText = """
        Pace wants to control your Mac:

        \(approvalSummary)

        Only approve this if it matches what you asked for.
        """
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
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

    func start() {
        refreshAllPermissions()
        print("🔑 Pace start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
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
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
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
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
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
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            PaceAnalytics.trackAllPermissionsGranted()
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
        guard let modelsURL = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines))?.appendingPathComponent("models") else {
            await MainActor.run { self.isLMStudioReachable = false }
            return
        }

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
                            print("🗣️ Companion received transcript: \(finalTranscript)")
                            PaceAnalytics.trackUserMessageSent(transcript: finalTranscript)
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
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run {
                    guard let self else { return }
                    guard !self.transcriptArrivedSinceRelease else { return }
                    print("⚠️ Transcript didn't arrive within 5s — resetting state")
                    self.responseOverlayManager.updateStreamingText("no audio detected")
                    self.responseOverlayManager.finishStreaming()
                    self.voiceState = .idle
                    // Mirror the normal turn-end cleanup: bring back the
                    // walking avatar if the user has it on, and reset the
                    // trigger so the next press defaults to keyboard.
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

    /// Picks a canned reply for chitchat turns the intent classifier
    /// confidently identified. Hardcoded responses are intentionally
    /// short and varied so back-to-back greetings don't feel scripted.
    /// Returns a single utterance string ready for TTS — no further
    /// processing needed.
    private func cannedChitchatResponse(for transcript: String) -> String {
        let lowercased = transcript.lowercased()
        if lowercased.contains("thank") || lowercased.contains("appreciate") {
            return ["you got it", "anytime", "happy to help", "no problem"].randomElement() ?? "you got it"
        }
        if lowercased.contains("bye") || lowercased.contains("later") || lowercased.contains("see you") {
            return ["catch you later", "see you", "talk soon"].randomElement() ?? "see you"
        }
        if lowercased.contains("how are you") || lowercased.contains("how's it going") || lowercased.contains("what's up") {
            return ["doing great, what's up?", "all good — what can I do?", "i'm good, you?"].randomElement() ?? "doing great"
        }
        if lowercased.contains("good morning") {
            return "morning! what's the plan?"
        }
        if lowercased.contains("good evening") {
            return "evening! what's up?"
        }
        if lowercased.contains("hi") || lowercased.contains("hello") || lowercased.contains("hey") {
            return ["hey", "hey there", "hi! what's on your mind?"].randomElement() ?? "hey"
        }
        // Generic acknowledgement for "ok cool", "got it", "perfect", "nice", etc.
        return ["got it", "okay", "sounds good"].randomElement() ?? "okay"
    }

    /// Short-circuit turn handler for the chitchat intent. Skips VLM,
    /// planner, and the agent loop entirely. Dispatches a canned
    /// response straight to TTS and the overlay bubble. Used by the
    /// intent-classifier fast-path in `sendTranscriptToPlannerWithScreenshot`.
    private func handleChitchatFastPath(transcript: String) {
        let cannedReply = cannedChitchatResponse(for: transcript)

        // Append to conversation history so multi-turn context still sees
        // the exchange — important so a follow-up question after a
        // greeting still reads naturally to the planner.
        conversationHistory.append(
            (userTranscript: transcript, assistantResponse: cannedReply)
        )

        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(cannedReply)

        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: cannedReply)
            // Wait for TTS to drain before returning to idle so the
            // walking avatar's mouth animation matches.
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

    /// Fast path for pure knowledge questions. Skips screenshot capture,
    /// AX, OCR, and VLM. The local planner still answers, but it gets a
    /// text-only prompt and no agent-mode tool docs.
    private func handleTextOnlyPlannerFastPath(transcript: String) {
        responseOverlayManager.showOverlayAndBeginStreaming()

        currentResponseTask = Task {
            voiceState = .processing

            do {
                let historyForPlanner = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await plannerClient.generateResponseStreaming(
                    images: [],
                    systemPrompt: CompanionSystemPrompt.build(includeAgentMode: false),
                    conversationHistory: historyForPlanner,
                    userPrompt: transcript,
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

                conversationHistory.append((userTranscript: transcript, assistantResponse: spokenText))
                if conversationHistory.count > 1 {
                    conversationHistory.removeFirst(conversationHistory.count - 1)
                }

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
                if isWalkingAvatarEnabled {
                    avatarOverlayManager?.show()
                }
            } catch {
                print("⚠️ Text-only planner fast path failed: \(error.localizedDescription)")
                responseOverlayManager.updateStreamingText("i hit a local planner issue.")
                responseOverlayManager.finishStreaming()
                voiceState = .idle
            }
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
        conversationHistory.append((userTranscript: transcript, assistantResponse: spokenText))
        if conversationHistory.count > 1 {
            conversationHistory.removeFirst(conversationHistory.count - 1)
        }

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
        currentResponseTask?.cancel()
        ttsClient.stopPlayback()

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

        // Fast-path chitchat ("hi pace", "thanks") with a canned response
        // — skips VLM + planner + agent loop entirely. ~2200ms → ~50ms.
        // Conservative: only fires when the classifier is confident
        // enough to return .chitchat (not .unknown). Anything ambiguous
        // falls through to the full pipeline.
        let intentPrediction = intentClassifier.classify(transcript)
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
        if intentPrediction.route == .phoneLargeModel {
            print("🎯 Intent: phoneLargeModel requested — local-only fallback pipeline")
        }
        print("🎯 Intent: \(intentPrediction.intent.rawValue) (confidence \(String(format: "%.2f", intentPrediction.confidence))) — \(intentPrediction.route.rawValue)")

        currentResponseTask = Task {
            voiceState = .processing

            let maxAgentStepCount = PaceTagParsers.readMaxAgentStepCount()
            var stepIndex = 0
            var currentTurnUserPrompt = transcript

            do {
                agentStepLoop: while stepIndex < maxAgentStepCount {
                    stepIndex += 1
                    let isFirstStep = (stepIndex == 1)
                    guard !Task.isCancelled else { return }

                    // 1. Capture all connected screens
                    let screenCaptureStartedAt = Date()
                    let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
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
                    let userPromptForPlanner = await buildUserPromptWithLocalVLMContextIfEnabled(
                        transcript: currentTurnUserPrompt,
                        screenCaptures: screenCaptures
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
                    let (fullResponseText, _) = try await plannerClient.generateResponseStreaming(
                        images: imagesForPlanner,
                        systemPrompt: CompanionSystemPrompt.build(includeAgentMode: isAgentModeEnabled),
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
                                await self?.streamingSentenceTTSPipeline.acceptStreamedText(accumulatedPlannerText)
                            }
                        }
                    )
                    guard !Task.isCancelled else { return }

                    // 6. Parse: action tags → [DONE] flag → pointing tag.
                    //    Each pass strips its own tag class so the final
                    //    `spokenText` is clean enough to play via TTS.
                    let actionParseResult = PaceActionTagParser.parseActions(from: fullResponseText)
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
                    conversationHistory.append((
                        userTranscript: isFirstStep ? transcript : "(agent step \(stepIndex))",
                        assistantResponse: spokenText
                    ))
                    // Keep history very short — Apple Foundation Models'
                    // 4K context window is the hard constraint, and we
                    // saw it bust at exactly the 3-exchange mark in the
                    // last test run. 1 exchange is enough for "remember
                    // what we just discussed" without eating the budget
                    // that should go to the current screen's element map.
                    if conversationHistory.count > 1 {
                        conversationHistory.removeFirst(conversationHistory.count - 1)
                    }
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
                    if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
                        voiceState = .responding
                    }

                    // 10. Execute tool calls/action tags if any.
                    var toolObservations: [PaceActionExecutionObservation] = []
                    var userDeniedActionApproval = false
                    if !actionParseResult.actions.isEmpty {
                        if actionExecutor.actionsAreEnabled {
                            if requestUserApprovalForActionPlan(actionParseResult.executionPlan) {
                                // Brief settle so the cursor flight visibly arrives
                                // before the synthetic click fires.
                                try? await Task.sleep(nanoseconds: 350_000_000)
                                guard !Task.isCancelled else { return }
                                toolObservations = await actionExecutor.executeActionPlan(
                                    actionParseResult.executionPlan,
                                    screenCaptures: screenCaptures
                                )
                                if !toolObservations.isEmpty {
                                    print("🧰 Tool observations:\n\(PaceActionExecutionObservation.formatForPlanner(toolObservations))")
                                }
                            } else {
                                userDeniedActionApproval = true
                                print("🛑 Pace action approval denied — stopping agent loop")
                            }
                        } else {
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
            } catch is CancellationError {
                // User spoke again — response was interrupted. Hide the
                // overlay immediately so it doesn't linger over the next
                // turn's "listening…" state.
                responseOverlayManager.hideOverlay()
            } catch {
                PaceAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                responseOverlayManager.updateStreamingText("error: \(error.localizedDescription)")
                responseOverlayManager.finishStreaming()
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
        screenCaptures: [CompanionScreenCapture]
    ) async -> String {
        guard useLocalVLMForScreenContext else {
            print("👁️  VLM skipped — 'Read My Screen' toggle is off")
            return transcript
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
            if let cached = perScreenAnalysisCache[capture.label] {
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
                    taskGroup.addTask { [localVLMClient, visionOCRClient] in
                        // VLM + OCR concurrent. OCR finishes much faster
                        // (~100-200ms); we wait on the VLM and then merge.
                        async let vlmAnalysisFuture = localVLMClient.analyzeScreenshot(
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
        return """
        === \(screenLabel) (\(elementCountSummary) elements) ===
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
        let vlmClient = localVLMClient
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
                let cachedAnalysis = await MainActor.run { () -> LocalVLMScreenAnalysis? in
                    guard let self else { return nil }
                    guard let cached = self.perScreenAnalysisCache[cursorScreenCapture.label] else {
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

    /// Speaks a hardcoded error message via the system NSSpeechSynthesizer
    /// when the main planner/TTS path fails — independent of LM Studio and
    /// the main TTS pipeline so the user always hears something.
    private func speakCreditsErrorFallback() {
        let utterance = "Something went wrong on my end. Check the console for details."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

}
