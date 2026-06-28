//
//  CompanionManager+Lifecycle.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition):
//  app start/stop, permission requests/refreshes, and UI entry points (avatar, deeplink, chat submit).
//

import AppKit
import AVFoundation
import Combine
import Contacts
import EventKit
import Foundation
import ScreenCaptureKit
import Speech

@MainActor
extension CompanionManager {

    // MARK: - Lifecycle & permissions

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
        // Begin observing macOS Focus state. Idempotent — only the
        // first call triggers the one-shot INFocusStatus permission
        // ask; the rest are no-ops. Denied permission means the
        // monitor always reports "not focused," matching the pre-
        // Focus-integration behaviour.
        focusModeMonitor.start()
        // Subscribe to thermal-state changes. Gates the speculative
        // race, watch mode cadence, and prewarm task so we don't
        // pour fuel on a hot machine.
        thermalStateAdvisor.start()
        // Resume the prior conversation across quit/relaunch. "Always,
        // until reset" — no staleness expiry; the file is only cleared on
        // an explicit thread reset or when the feature is disabled.
        restorePersistedThreadMemoryIfEnabled()
        // Rehydrate the unified memory index (Phase 2 dual-write; ships dark).
        restoreUnifiedMemory()
        // Phase 5 step 2: pull any already-indexed connector docs (preferences,
        // competitive research, rehydrated journals) into the unified index.
        // Sources that populate later in the session get synced via the
        // debounced hook in refreshLocalRetrievalPublishedState().
        syncConnectorsIntoUnifiedMemoryIfDue()
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
        // Hosted-MCP gateways (Composio etc.) flip the existing
        // off-device tint while their call is in flight, so the
        // menu-bar capsule shows amber the same way it does for
        // Direct API and Cloud Bridge planner turns.
        actionExecutor.setOffDeviceTurnInFlightCallback = { [weak self] isOffDeviceCallInFlight in
            Task { @MainActor [weak self] in
                self?.isOffDeviceTurnInFlight = isOffDeviceCallInFlight
            }
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

        // Glow border: show on all screens once onboarded. The border
        // is click-through and sits below the cursor overlay, so it
        // doesn't interfere with interaction. Gated by the
        // `isGlowBorderEnabled` preference (default ON).
        if hasCompletedOnboarding {
            glowBorderManager.show(onScreens: NSScreen.screens, companionManager: self)
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

        // — Automation module wiring —
        // Each module is a standalone singleton that needs a callback
        // to actually DO things in the app. We wire them here so the
        // modules can execute planner turns, speak results, and react
        // to preference changes without each needing its own Companion
        // reference.

        // 1. Background agent runner: when a background task fires, it
        //    runs a headless planner turn and speaks the result when done.
        PaceBackgroundAgentRunner.shared.executePlannerTurn = { [weak self] prompt in
            guard let self else { return "Background agent: CompanionManager unavailable." }
            return await withCheckedContinuation { continuation in
                Task { @MainActor [weak self] in
                    guard let self else {
                        continuation.resume(returning: "Background agent: CompanionManager unavailable.")
                        return
                    }
                    // Run a text-only planner turn (no screen capture).
                    let systemPrompt = CompanionSystemPrompt.build(
                        includeAgentMode: false,
                        threadSummaryInjection: nil
                    )
                    do {
                        let (text, _) = try await self.plannerClient.generateResponseStreaming(
                            images: [],
                            systemPrompt: systemPrompt,
                            conversationHistory: [],
                            userPrompt: prompt,
                            onTextChunk: { _ in }
                        )
                        continuation.resume(returning: text)
                    } catch {
                        continuation.resume(returning: "Background agent error: \(error.localizedDescription)")
                    }
                }
            }
        }
        PaceBackgroundAgentRunner.shared.speakResult = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let summary = String(result.prefix(200))
                try? await self.ttsClient.speakText(summary)
            }
        }

        // 2. Cron scheduler: each fire runs a planner turn and speaks
        //    the result. Enabled by the isCronSchedulerEnabled pref.
        PaceCronScheduler.shared.executeTaskCallback = { [weak self] task in
            guard let self else { return }
            let systemPrompt = CompanionSystemPrompt.build(
                includeAgentMode: false,
                threadSummaryInjection: nil
            )
            do {
                let (text, _) = try await self.plannerClient.generateResponseStreaming(
                    images: [],
                    systemPrompt: systemPrompt,
                    conversationHistory: [],
                    userPrompt: task.taskPrompt,
                    onTextChunk: { _ in }
                )
                let summary = String(text.prefix(200))
                try? await self.ttsClient.speakText(summary)
            } catch {
                try? await self.ttsClient.speakText("Scheduled task failed: \(error.localizedDescription)")
            }
        }
        if PaceUserPreferencesStore.bool(for: .isCronSchedulerEnabled) {
            PaceCronScheduler.shared.setEnabled(true)
        }

        // 3. Dynamic tool registry: auto-repair callback generates a
        //    fixed command via the planner when a plugin's shell
        //    command fails.
        PaceDynamicToolRegistry.shared.generatePluginFix = { [weak self] plugin, errorMessage in
            guard let self else { return nil }
            let prompt = "The plugin '\(plugin.name)' failed with error: \(errorMessage). The plugin command template is: \(plugin.command). Generate a corrected shell command that achieves the same goal. Reply with ONLY the command, no explanation."
            let systemPrompt = CompanionSystemPrompt.build(
                includeAgentMode: false,
                threadSummaryInjection: nil
            )
            do {
                let (text, _) = try await self.plannerClient.generateResponseStreaming(
                    images: [],
                    systemPrompt: systemPrompt,
                    conversationHistory: [],
                    userPrompt: prompt,
                    onTextChunk: { _ in }
                )
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "```", with: "")
                    .replacingOccurrences(of: "bash", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? nil : cleaned
            } catch {
                return nil
            }
        }

        // 4. Meeting mode: resume across launches when the user left it on.
        if PaceUserPreferencesStore.bool(for: .isMeetingModeEnabled) {
            PaceMeetingModeController.shared.isEnabled = true
            Task { @MainActor in
                await PaceMeetingModeController.shared.start()
            }
        }


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
    func startThreadMemoryIdleSweepTimer() {
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

    static func isEventKitPermissionGranted(_ authorizationStatus: EKAuthorizationStatus) -> Bool {
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
}
