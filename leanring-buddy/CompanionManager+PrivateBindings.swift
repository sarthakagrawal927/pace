//
//  CompanionManager+PrivateBindings.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition):
//  permission polling, LM Studio reachability, barge-in VAD, wake-word, and shortcut bindings.
//

import AppKit
import Combine
import Foundation

@MainActor
extension CompanionManager {

    // MARK: - Private bindings

    func startPermissionPolling() {
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
    func startLMStudioReachabilityPolling() {
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
    func refreshLMStudioReachability() async {
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

    func bindAudioPowerLevel() {
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
    func bindBargeInGateObservation() {
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
    func attachBargeInAudioLevelSubscriptionIfNeeded() {
        guard bargeInAudioLevelCancellable == nil else { return }
        bargeInVAD.reset()
        // Notify the VAD that TTS playback is active so the echo
        // rejection window and raised threshold take effect.
        bargeInVAD.setTTSPlaybackActive(true)
        bargeInAudioLevelCancellable = buddyDictationManager.audioLevelPublisher
            .sink { [weak self] normalizedLevel in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.observeBargeInAudioLevel(normalizedLevel)
                }
            }
    }

    func detachBargeInAudioLevelSubscription() {
        bargeInAudioLevelCancellable?.cancel()
        bargeInAudioLevelCancellable = nil
        bargeInVAD.setTTSPlaybackActive(false)
        bargeInVAD.reset()
    }

    /// Forwards a single RMS sample to the VAD. Fires the barge-in
    /// callback chain when the VAD reports sustained speech. The
    /// double-gate check inside the sink guards against an in-flight
    /// sample arriving on the main-actor hop just after voiceState
    /// flipped out of `.responding` — we re-check the conditions here
    /// because the publisher sample raced the state change.
    func observeBargeInAudioLevel(_ normalizedLevel: Float) {
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
    func handleBargeInDetected() {
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
    func bindWakeWordSpotterObservation() {
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
    func handleWakeWordDetected(_ detection: PaceWakeWordDetection) {
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

    func bindVoiceStateObservation() {
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

    func bindShortcutTransitions() {
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
    func handleNotchChatShortcutPressed() {
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

    func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
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

            // Dismiss the menu bar panel so it doesn't cover the screen.
            // NOT in mascot mode — there the panel IS the conversation
            // surface, so dismissing it on push-to-talk is the open/close
            // flicker. presentConversationPanel keeps it up instead.
            if !mascotModeActive {
                NotificationCenter.default.post(name: .paceDismissPanel, object: nil)
            }

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
            // Stamp PTT press for STT latency measurement.
            pttPressedAt = Date()
            // Fire the screen-context pre-warm in parallel with dictation.
            // VLM + OCR run during the user's natural speech time (~2-5s)
            // and the result is awaited by the agent loop's first step —
            // perceived VLM latency drops to ~0 in the common case.
            screenContextService.prewarmScreenContext(reason: .pushToTalkPress)
            // Warm the Kokoro TTS sidecar in the same PTT-press dead-time
            // window. The single-space prewarm synthesis runs while the user
            // is still speaking, so the first real sentence after the planner
            // responds hits a hot MLX cache instead of paying the cold-load
            // tax — and, finishing before any real utterance is enqueued, it
            // never competes with one for the sidecar. Idempotent: a no-op
            // after the first PTT press of the process.
            if let localServerTTSClient = ttsClient as? LocalServerTTSClient {
                localServerTTSClient.prewarmSidecarForUpcomingTurnIfNeeded()
            }
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
            // Surface the conversation at the mascot perch (top-right) the
            // moment a turn starts, so the live transcript + reply appear
            // THERE rather than only near the cursor. No-op in legacy mode
            // (onConversationStart unset).
            avatarOverlayManager?.presentConversationPanel()

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
                            // Record STT latency: PTT press → final transcript.
                            if let pressedAt = self.pttPressedAt {
                                let sttMs = Int(Date().timeIntervalSince(pressedAt) * 1000)
                                let wordCount = finalTranscript.split(separator: " ").count
                                PaceTelemetryLog.recordSTTLatency(
                                    milliseconds: sttMs,
                                    transcriptWordCount: wordCount
                                )
                                self.pttPressedAt = nil
                            }
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
}
