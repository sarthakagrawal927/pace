//
//  PaceActiveCallDetector.swift
//  leanring-buddy
//
//  Polls every five seconds for evidence the user is on a call. The
//  restraint policy reads `isOnActiveCall` so proactive nudges stay
//  silent (and get queued) during Zoom, Teams, FaceTime, Slack
//  huddles, etc.
//
//  v1 ships only the running-applications signal: if a known call
//  bundle identifier is present in `NSWorkspace.shared
//  .runningApplications`, the user is treated as "on a call". This is
//  a deliberate v1 simplification:
//
//    - it covers the launches users care about (Zoom, Teams, FaceTime,
//      Slack) with zero permission cost,
//    - it can over-fire when a call app is open but idle (Slack
//      running ≠ huddle, Teams running ≠ active meeting), which is the
//      restraint-safe direction — we'd rather stay quiet than barge in,
//    - it has zero CoreAudio surface area, so the detector cannot fail
//      to a noisier state due to a missing API or a denied input device.
//
//  TODO (v1.1): cross-reference with `CoreAudio` input-device-is-running
//  on the default built-in input. With both signals AND'd, an open-but-
//  idle Slack stops counting as a call while an active huddle still
//  does. The current design intentionally errs toward "stay quiet"
//  until the audio signal lands. The bundle-ID list is otherwise the
//  same set `PaceRestraintGate.activeCallBundleIdentifiers` already
//  pattern-matches against.
//

import AppKit
import Combine
import Foundation

@MainActor
final class PaceActiveCallDetector: ObservableObject {
    /// True when at least one running application matches a known
    /// call-app bundle identifier. Polled — not reactive — so callers
    /// can read a stable snapshot without subscribing to AppKit
    /// notifications.
    @Published private(set) var isOnActiveCall: Bool = false

    /// Bundle identifiers Pace treats as "the user might be on a call".
    /// Match is case-insensitive. Keep this list intentionally narrow:
    /// the cost of a false positive is silenced proactive speech.
    ///
    /// Google Meet is intentionally absent — it runs as a Chrome PWA
    /// without a distinguishing bundle ID. The v1.1 CoreAudio path
    /// will catch it.
    static let callBundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.apple.facetime",
        "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap",
    ]

    private static let pollIntervalSeconds: TimeInterval = 5

    private let runningApplicationBundleIdentifiersProvider: () -> Set<String>
    private var pollTimer: Timer?

    /// Designated initializer. The bundle-identifier provider is
    /// injected so XCTests can simulate "Zoom running" or
    /// "FaceTime running" without launching a real call app.
    init(
        runningApplicationBundleIdentifiersProvider: @escaping () -> Set<String> = PaceActiveCallDetector.liveRunningApplicationBundleIdentifiers
    ) {
        self.runningApplicationBundleIdentifiersProvider = runningApplicationBundleIdentifiersProvider
    }

    func start() {
        // Run one synchronous poll immediately so `isOnActiveCall` is
        // accurate the first time anyone reads it — without waiting
        // five seconds for the timer to tick.
        recomputeForTesting()

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pollIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recomputeForTesting()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Public for tests. Runs one classification pass synchronously
    /// using whatever the injected provider returns. Production code
    /// can also call this manually after a known event (e.g., the
    /// menu-bar panel opening) to refresh without waiting for the
    /// next timer tick.
    func recomputeForTesting() {
        let currentlyRunningBundleIdentifiers = runningApplicationBundleIdentifiersProvider()
        isOnActiveCall = Self.anyCallBundleIdentifierIsRunning(
            among: currentlyRunningBundleIdentifiers
        )
    }

    /// Pure classifier — case-insensitive membership check. Exposed
    /// at the type level so unit tests can verify the matching logic
    /// directly without constructing a detector instance.
    static func anyCallBundleIdentifierIsRunning(among runningBundleIdentifiers: Set<String>) -> Bool {
        let normalizedRunningBundleIdentifiers = Set(
            runningBundleIdentifiers.map { $0.lowercased() }
        )
        let normalizedCallBundleIdentifiers = Set(
            callBundleIdentifiers.map { $0.lowercased() }
        )
        return !normalizedRunningBundleIdentifiers.isDisjoint(with: normalizedCallBundleIdentifiers)
    }

    /// Default live provider. Snapshots `NSWorkspace.runningApplications`
    /// into a `Set<String>` of bundle identifiers; nil identifiers (rare
    /// — typically agents without an Info.plist) are skipped.
    nonisolated static func liveRunningApplicationBundleIdentifiers() -> Set<String> {
        var collectedBundleIdentifiers: Set<String> = []
        for runningApplication in NSWorkspace.shared.runningApplications {
            if let bundleIdentifier = runningApplication.bundleIdentifier {
                collectedBundleIdentifiers.insert(bundleIdentifier)
            }
        }
        return collectedBundleIdentifiers
    }
}
