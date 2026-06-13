//
//  PaceProactivityPipeline.swift
//  leanring-buddy
//
//  Wave 7a extraction. Owns the proactive utterance ring buffer, the
//  10-second idle drain timer, the proactive nudge orchestrator
//  wiring, the three nudge generators (focus fatigue, calendar
//  pre-meeting, watch-mode observation), and the live restraint-
//  context construction the generators consume on every gate
//  decision.
//
//  CompanionManager OWNS this pipeline. It feeds in references to
//  the input/call monitors plus a small set of closures so the
//  pipeline can talk back for TTS playback, paceHistory journaling,
//  and the per-turn voice-state read. Behavior is identical to the
//  pre-extraction code: same ≤3 ring buffer, same 10s drain cadence,
//  same per-source generator toggles, same restraint-context shape.
//

import AppKit
import Combine
import Foundation

@MainActor
final class PaceProactivityPipeline {
    // MARK: - Dependencies wired in by CompanionManager

    /// Stamps the timestamp of the most recent user mouse / keyboard /
    /// scroll event. Read by `buildProactiveRestraintContext` and the
    /// idle-drain loop so a queued nudge waits until the user pauses.
    private let userInputActivityMonitor: PaceUserInputActivityMonitor

    /// Polls running applications for known call-app bundle identifiers
    /// (Zoom, Teams, FaceTime, Slack). Combined with the input-activity
    /// monitor this gives the restraint gate a permission-free "user is
    /// busy" signal.
    private let activeCallDetector: PaceActiveCallDetector

    /// Reads the user-tunable assertiveness profile on every gate
    /// decision so a flip in Settings → Proactive affects the next
    /// decision without restarting the pipeline.
    private let proactivityProfileProvider: () -> PaceProactivityProfile

    /// Returns the live `voiceState` so the drain loop stays quiet
    /// while a voice turn is mid-flight.
    private let currentVoiceStateProvider: () -> CompanionVoiceState

    /// Speaks a proactive utterance through the manager's TTS client.
    /// Kept as a closure (vs holding the BuddyTTSClient directly) so
    /// the pipeline doesn't widen its dependency footprint and so the
    /// existing print-on-failure shape stays identical.
    private let speakUtterance: (PaceProactiveUtterance) -> Void

    /// Writes a paceHistory breadcrumb for nudges. CompanionManager
    /// retains the journal/refresh logic so this pipeline never
    /// touches the local retriever directly.
    private let journalProactiveNudge: (PaceProactiveUtterance) -> Void

    /// Provides the most-recent per-screen VLM/OCR description for
    /// the watch-mode observation generator. Lives on CompanionManager
    /// because the per-screen cache is on the manager.
    private let cachedScreenDescriptionProvider: (String) -> String?

    /// Streams watch-mode events into the watch-mode observation
    /// generator. Passed in as an erased publisher so the pipeline
    /// doesn't import the watch controller directly.
    private let watchModeEventPublisher: AnyPublisher<PaceScreenWatchEvent, Never>

    /// Live calendar connector for the pre-meeting generator.
    private let calendarRetrievalConnector: PaceCalendarRetrievalConnector

    // MARK: - Owned state

    /// Capped FIFO of nudges waiting for the user to pause. Cap is 3
    /// — the oldest entry gets dropped on overflow. Mutations only
    /// happen on the main actor; no separate lock needed.
    private(set) var proactiveUtteranceQueue: [PaceProactiveUtterance] = []

    /// Maximum entries kept in the queue. Above this the oldest is
    /// dropped so a busy hour doesn't produce a five-utterance burst.
    private static let proactiveUtteranceQueueMaximumCapacity: Int = 3

    /// Backs the 10-second drain loop. Started in `start()`, torn
    /// down in `stop()`. Each tick attempts at most one utterance —
    /// the next tick handles the rest so we never speak two nudges
    /// back-to-back in a single drain pass.
    private var proactiveQueueDrainTimer: Timer?

    private static let proactiveQueueDrainIntervalSeconds: TimeInterval = 10

    /// Updated whenever a proactive nudge speaks. Feeds the gate's
    /// cooldown check so back-to-back nudges respect the user's
    /// profile (talkative / balanced / reserved).
    private(set) var lastProactiveUtteranceAt: Date?

    // MARK: - Per-generator preference snapshots

    /// Mirrors CompanionManager's `areFocusFatigueNudgesEnabled` etc.
    /// at the moment `start()` runs so the initial fan-out matches the
    /// user's saved preferences. Subsequent toggles flow through
    /// `setGeneratorEnabled(identifier:enabled:)`.
    private let initiallyEnabledGeneratorIdentifiers: Set<String>

    // MARK: - Generators + orchestrator (lazy)

    /// Built lazily so the restraint-context capture closure can refer
    /// back to `self`. The init wires nothing — `start()` flips the
    /// switches and arms the timer.
    private lazy var focusFatigueNudgeGenerator: PaceFocusFatigueNudgeGenerator = {
        return PaceFocusFatigueNudgeGenerator(
            restraintContextProvider: { [weak self] in
                self?.buildProactiveRestraintContext() ?? PaceProactivityPipeline
                    .defaultRestraintContext(proactiveSource: .watchNudge)
            }
        )
    }()

    private lazy var calendarPreMeetingNudgeGenerator: PaceCalendarPreMeetingNudgeGenerator = {
        return PaceCalendarPreMeetingNudgeGenerator(
            restraintContextProvider: { [weak self] in
                self?.buildProactiveRestraintContext(proactiveSource: .backgroundReminder) ?? PaceProactivityPipeline
                    .defaultRestraintContext(proactiveSource: .backgroundReminder)
            },
            calendarConnector: calendarRetrievalConnector
        )
    }()

    private lazy var watchModeObservationNudgeGenerator: PaceWatchModeObservationNudgeGenerator = {
        return PaceWatchModeObservationNudgeGenerator(
            restraintContextProvider: { [weak self] in
                self?.buildProactiveRestraintContext(intent: .screenDescription) ?? PaceProactivityPipeline
                    .defaultRestraintContext(proactiveSource: .watchNudge, intent: .screenDescription)
            },
            watchEventPublisher: watchModeEventPublisher,
            screenDescriptionProvider: { [weak self] screenLabel in
                self?.cachedScreenDescriptionProvider(screenLabel)
            }
        )
    }()

    private lazy var proactiveNudgeOrchestrator: PaceProactiveNudgeOrchestrator = {
        return PaceProactiveNudgeOrchestrator(
            restraintContextProvider: { [weak self] in
                self?.buildProactiveRestraintContext() ?? PaceProactivityPipeline
                    .defaultRestraintContext(proactiveSource: .watchNudge)
            },
            generators: [
                focusFatigueNudgeGenerator,
                calendarPreMeetingNudgeGenerator,
                watchModeObservationNudgeGenerator,
            ]
        )
    }()

    // MARK: - Init

    init(
        userInputActivityMonitor: PaceUserInputActivityMonitor,
        activeCallDetector: PaceActiveCallDetector,
        proactivityProfileProvider: @escaping () -> PaceProactivityProfile,
        currentVoiceStateProvider: @escaping () -> CompanionVoiceState,
        speakUtterance: @escaping (PaceProactiveUtterance) -> Void,
        journalProactiveNudge: @escaping (PaceProactiveUtterance) -> Void,
        cachedScreenDescriptionProvider: @escaping (String) -> String?,
        watchModeEventPublisher: AnyPublisher<PaceScreenWatchEvent, Never>,
        calendarRetrievalConnector: PaceCalendarRetrievalConnector,
        initiallyEnabledGeneratorIdentifiers: Set<String>
    ) {
        self.userInputActivityMonitor = userInputActivityMonitor
        self.activeCallDetector = activeCallDetector
        self.proactivityProfileProvider = proactivityProfileProvider
        self.currentVoiceStateProvider = currentVoiceStateProvider
        self.speakUtterance = speakUtterance
        self.journalProactiveNudge = journalProactiveNudge
        self.cachedScreenDescriptionProvider = cachedScreenDescriptionProvider
        self.watchModeEventPublisher = watchModeEventPublisher
        self.calendarRetrievalConnector = calendarRetrievalConnector
        self.initiallyEnabledGeneratorIdentifiers = initiallyEnabledGeneratorIdentifiers
    }

    // MARK: - Lifecycle

    /// Brings up the drain timer and the orchestrator. Mirrors the
    /// pre-extraction sequence in `CompanionManager.start()`.
    func start() {
        startProactiveQueueDrainTimer()
        startProactiveNudgeOrchestrator()
    }

    /// Tears down the drain timer + orchestrator. Mirrors the
    /// pre-extraction sequence in `CompanionManager.stop()`.
    func stop() {
        proactiveQueueDrainTimer?.invalidate()
        proactiveQueueDrainTimer = nil
        proactiveNudgeOrchestrator.stop()
    }

    // MARK: - Public surface used by CompanionManager forwarders

    /// Adds an utterance to the proactive queue, dropping the oldest
    /// entry once the cap is exceeded. Exposed for nudge generators
    /// and the morning-triage scheduler — both should call this when
    /// the gate returns `.queueUntilIdle` instead of speaking
    /// directly.
    func enqueueProactiveUtterance(_ utterance: PaceProactiveUtterance) {
        proactiveUtteranceQueue.append(utterance)
        if proactiveUtteranceQueue.count > Self.proactiveUtteranceQueueMaximumCapacity {
            proactiveUtteranceQueue.removeFirst(
                proactiveUtteranceQueue.count - Self.proactiveUtteranceQueueMaximumCapacity
            )
        }
    }

    /// Test seam: read the queue contents without depending on
    /// internal ordering invariants.
    func proactiveUtteranceQueueSnapshot() -> [PaceProactiveUtterance] {
        return proactiveUtteranceQueue
    }

    /// Speaks the oldest queued nudge if all three idle signals say
    /// "now is a good time": no recent input, not on a call, voice
    /// turn idle. Otherwise leaves the queue untouched for the next
    /// tick. Called by the drain timer; safe to call manually.
    func drainProactiveQueueIfIdle(now: Date = Date()) {
        guard proactiveUtteranceQueue.isEmpty == false else { return }

        if let lastUserInputAt = userInputActivityMonitor.lastUserInputAt,
           now.timeIntervalSince(lastUserInputAt) < PaceRestraintGate.activeInputWindowSeconds {
            return
        }
        if activeCallDetector.isOnActiveCall {
            return
        }
        guard currentVoiceStateProvider() == .idle else { return }

        let nextUtterance = proactiveUtteranceQueue.removeFirst()
        // Use the same speakUtterance closure path so a future TTS
        // routing change stays in one place.
        speakUtterance(nextUtterance)
    }

    /// Routes a per-generator enable/disable through the orchestrator
    /// without tearing down the rest. Closures match what `start()`
    /// passes to `proactiveNudgeOrchestrator.start(...)` so a Settings
    /// flip after launch behaves exactly like the initial fan-out.
    func setGeneratorEnabled(identifier: String, enabled: Bool) {
        proactiveNudgeOrchestrator.setGeneratorEnabled(
            identifier: identifier,
            enabled: enabled,
            emit: { [weak self] utterance in
                self?.emitProactiveUtterance(utterance)
            },
            queueForLater: { [weak self] utterance in
                self?.enqueueProactiveUtterance(utterance)
            }
        )
    }

    /// Stable identifiers exposed so CompanionManager's per-source
    /// toggles can call `setGeneratorEnabled(identifier:enabled:)`
    /// without reaching into the generator instances directly.
    var focusFatigueNudgeGeneratorIdentifier: String {
        return focusFatigueNudgeGenerator.identifier
    }

    var calendarPreMeetingNudgeGeneratorIdentifier: String {
        return calendarPreMeetingNudgeGenerator.identifier
    }

    var watchModeObservationNudgeGeneratorIdentifier: String {
        return watchModeObservationNudgeGenerator.identifier
    }

    /// Stamps the proactive cooldown clock from CompanionManager's
    /// own emit path (the `speakProactiveNudge` callback). Keeps the
    /// timestamp owned by the pipeline so the gate-context builder
    /// stays self-contained.
    func markProactiveUtteranceSpoken(at now: Date = Date()) {
        lastProactiveUtteranceAt = now
    }

    // MARK: - Internal helpers

    /// Built by every nudge generator on every gate decision. Reads
    /// the live `userInputActivityMonitor` / `activeCallDetector` /
    /// `proactivityProfileProvider` so a profile change or a Zoom
    /// launch affects the next decision instantly.
    private func buildProactiveRestraintContext(
        proactiveSource: PaceProactiveSource = .watchNudge,
        intent: PaceIntent = .pureKnowledge
    ) -> PaceRestraintContext {
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return PaceRestraintContext(
            now: Date(),
            lastProactiveUtteranceAt: lastProactiveUtteranceAt,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: userInputActivityMonitor.lastUserInputAt,
            frontmostAppBundleIdentifier: frontmostBundleIdentifier,
            isOnActiveCall: activeCallDetector.isOnActiveCall,
            wakeWordConfidence: nil,
            intent: intent,
            proactiveSource: proactiveSource,
            profile: proactivityProfileProvider()
        )
    }

    /// Conservative-default restraint context used as the `?? fallback`
    /// when `self` has already been deinited and a generator's
    /// captured closure still fires. Mirrors the pre-extraction
    /// fallback values one-for-one.
    private static func defaultRestraintContext(
        proactiveSource: PaceProactiveSource,
        intent: PaceIntent = .pureKnowledge
    ) -> PaceRestraintContext {
        return PaceRestraintContext(
            now: Date(),
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: intent,
            proactiveSource: proactiveSource,
            profile: .balanced
        )
    }

    private func startProactiveQueueDrainTimer() {
        proactiveQueueDrainTimer?.invalidate()
        proactiveQueueDrainTimer = Timer.scheduledTimer(
            withTimeInterval: Self.proactiveQueueDrainIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drainProactiveQueueIfIdle()
            }
        }
    }

    /// Routes the orchestrator's `emit` callback into the manager-
    /// supplied TTS path AND stamps the proactive cooldown clock.
    /// Matches the pre-extraction `speakProactiveNudge` shape exactly.
    private func emitProactiveUtterance(_ utterance: PaceProactiveUtterance) {
        lastProactiveUtteranceAt = Date()
        journalProactiveNudge(utterance)
        speakUtterance(utterance)
    }

    /// Starts whichever subset of generators the user has enabled.
    /// Called from `start()` after the input/call monitors come up.
    private func startProactiveNudgeOrchestrator() {
        let emitClosure: (PaceProactiveUtterance) -> Void = { [weak self] utterance in
            self?.emitProactiveUtterance(utterance)
        }
        let queueClosure: (PaceProactiveUtterance) -> Void = { [weak self] utterance in
            self?.enqueueProactiveUtterance(utterance)
        }

        proactiveNudgeOrchestrator.start(emit: emitClosure, queueForLater: queueClosure)
        // Initial fan-out: stop generators whose preference is off.
        // `start()` on the orchestrator brought ALL generators up;
        // honoring the per-source toggles here keeps the default
        // behavior (all off) intact.
        let allGeneratorIdentifiers: [String] = [
            focusFatigueNudgeGenerator.identifier,
            calendarPreMeetingNudgeGenerator.identifier,
            watchModeObservationNudgeGenerator.identifier,
        ]
        for generatorIdentifier in allGeneratorIdentifiers {
            if !initiallyEnabledGeneratorIdentifiers.contains(generatorIdentifier) {
                proactiveNudgeOrchestrator.setGeneratorEnabled(
                    identifier: generatorIdentifier,
                    enabled: false,
                    emit: emitClosure,
                    queueForLater: queueClosure
                )
            }
        }
    }
}
