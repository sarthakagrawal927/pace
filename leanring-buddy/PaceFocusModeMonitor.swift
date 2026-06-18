//
//  PaceFocusModeMonitor.swift
//  leanring-buddy
//
//  Bridges Apple's `INFocusStatusCenter` into Pace's restraint pipeline.
//  When the user has a system Focus active (Do Not Disturb, Work,
//  Sleep, Personal, Driving, etc.), the morning brief, fatigue nudges,
//  posture nudges, and any other proactive surface defer until the
//  Focus ends.
//
//  Why this is its own monitor rather than ad-hoc reads:
//    - INFocusStatusCenter.requestAuthorization is a one-time prompt;
//      it must be called exactly once on first activation, not on
//      every gate evaluation. Centralising the lifecycle avoids
//      double-prompts.
//    - The framework publishes via `focusStatusDidChange` notifications.
//      A single observer lets `isCurrentlyInUserFocus` stay accurate
//      without polling.
//
//  Best-effort: a denied-permission user sees no behavior change at
//  all (we never observe a focus → never defer). We do NOT degrade
//  the gate when permission is missing — silent overcaution would
//  feel like Pace forgetting how to talk.
//
//  Privacy: Apple's framework returns only the boolean "is the user
//  in a Focus mode" — never the Focus name, never the schedule, never
//  the allowed-apps list. The boolean stays in process memory.
//

import Combine
import Foundation
import Intents

@MainActor
final class PaceFocusModeMonitor: ObservableObject {

    /// True when macOS reports a Focus is currently active. Defaults
    /// to false on launch (and stays false if permission is denied)
    /// so the restraint gate's default behaviour matches the pre-
    /// Focus-integration era.
    @Published private(set) var isCurrentlyInUserFocus: Bool = false

    /// Read-only flag tracking whether we've asked the user for
    /// `INFocusStatus` permission yet. Exposed so the Settings view
    /// can render a "Pace can see your Focus state" status row
    /// without re-asking on every render.
    @Published private(set) var hasRequestedAuthorization: Bool = false

    private var focusStatusObserver: NSObjectProtocol?

    deinit {
        if let focusStatusObserver {
            NotificationCenter.default.removeObserver(focusStatusObserver)
        }
    }

    /// Begin observing. Idempotent. Asks for `INFocusStatus`
    /// permission exactly once per process, ignores the result, and
    /// observes the focus-status notification thereafter. Safe to
    /// call before the user has granted permission — the read will
    /// just always return `.unknown` until they do.
    func start() {
        guard focusStatusObserver == nil else { return }

        if !hasRequestedAuthorization {
            hasRequestedAuthorization = true
            INFocusStatusCenter.default.requestAuthorization { _ in
                // Drop the result on the floor. Authorized vs denied
                // is a UX concern for the Settings status row, not a
                // signal we act on here. We always RE-read the focus
                // status below — denied permission means
                // `focusStatus.isFocused == nil` → leaves
                // `isCurrentlyInUserFocus = false`.
                Task { @MainActor [weak self] in
                    self?.refreshCurrentFocusState()
                }
            }
        }
        refreshCurrentFocusState()
        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("INFocusStatusCenterFocusStatusDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCurrentFocusState()
            }
        }
        focusStatusObserver = observer
    }

    func stop() {
        if let focusStatusObserver {
            NotificationCenter.default.removeObserver(focusStatusObserver)
            self.focusStatusObserver = nil
        }
    }

    // MARK: - Pure helpers (unit-testable)

    /// Apply the read result to the published state. Pulled out so
    /// unit tests can drive the same path with a synthetic
    /// `Bool?` reading without instantiating `INFocusStatusCenter`.
    nonisolated static func resolveIsFocusedFromFrameworkReading(_ reading: Bool?) -> Bool {
        // `INFocusStatus.isFocused` is `Bool?` — nil means "we have
        // no permission to read", which Pace treats as "no focus"
        // (don't silently defer; the user probably hasn't even
        // granted permission yet).
        return reading ?? false
    }

    private func refreshCurrentFocusState() {
        let frameworkReading = INFocusStatusCenter.default.focusStatus.isFocused
        isCurrentlyInUserFocus = Self.resolveIsFocusedFromFrameworkReading(frameworkReading)
    }
}
