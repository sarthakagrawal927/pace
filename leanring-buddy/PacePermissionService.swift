//
//  PacePermissionService.swift
//  leanring-buddy
//
//  Single owner of every TCC-gated permission Pace cares about. Replaces
//  the previous pattern where 20+ call sites across 8 files each polled
//  the OS directly with subtly different caching behavior — the source
//  of "Settings shows granted, panel shows Grant" bugs.
//
//  Two design rules:
//
//  1. Live probes wherever macOS's status API is known to lie.
//     CGPreflightScreenCaptureAccess and AXIsProcessTrusted both cache
//     'false' for the running process's lifetime once they've returned
//     false — even after the user grants the permission, both keep
//     returning false until the app is quit and relaunched. Pace can't
//     ask the user to relaunch every time they touch System Settings,
//     so the live probes (SCShareableContent for screen, an actual AX
//     query for Accessibility) override the stale answers.
//
//  2. Active-application refresh. When the user switches back from
//     System Settings to Pace, the service refreshes immediately
//     instead of waiting for the next 1.5s poll tick. That collapses
//     the "I just granted it but Pace doesn't see it" gap to roughly
//     the time it takes to switch windows.
//

import AppKit
import AVFoundation
import ApplicationServices
import Combine
import Contacts
import EventKit
import Foundation
import ScreenCaptureKit

nonisolated enum PacePermissionKind: String, CaseIterable {
    case accessibility
    case screenRecording
    case microphone
    case camera
    case calendar
    case reminders
    case contacts
}

@MainActor
final class PacePermissionService: ObservableObject {
    static let shared = PacePermissionService()

    @Published private(set) var grants: [PacePermissionKind: Bool] = [:]

    private let pollIntervalInSeconds: TimeInterval = 1.5
    private let liveProbeStalenessInSeconds: TimeInterval = 5
    private var pollTimer: Timer?
    private var lifecycleObservers: [NSObjectProtocol] = []

    // No SCShareableContent live probe: it triggers the macOS Screen
    // Recording modal whenever the running process's cdhash hasn't been
    // explicitly authorized — even when the toggle in System Settings is
    // already ON for a previous Pace cdhash. That made the "detect granted
    // toggle" feature actively cause the prompt spam it was trying to
    // sidestep. We rely on CGPreflightScreenCaptureAccess (which never
    // prompts) and accept that a fresh Pace process may show the toggle
    // as not-granted-yet until next relaunch.

    private init() {
        refresh()
        startPollingTimer()
        subscribeToActiveApplicationChanges()
    }

    deinit {
        // Observers are removed when the service is deallocated, but
        // since this is a singleton that never deallocates the
        // notification subscription holds for the app lifetime. The
        // teardown lives here for completeness — if a test allocates
        // its own instance it'll still clean up.
        for observer in lifecycleObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        pollTimer?.invalidate()
    }

    /// Synchronous answer for callers that need an immediate `Bool` —
    /// matches `grants[kind]` but defaults to `false` so unknown
    /// permissions are treated as denied (safe failure mode).
    func isGranted(_ kind: PacePermissionKind) -> Bool {
        grants[kind] ?? false
    }

    /// Manual refresh hook for places that just performed an action
    /// likely to change the grant state (e.g. user closed System
    /// Settings, the calendar request callback fired).
    func refresh() {
        var next = grants

        // Screen Recording: CGPreflight only. It does NOT trigger any
        // system prompt. The downside is the documented staleness — a
        // fresh process whose cdhash wasn't pre-authorized will keep
        // returning false until relaunch. The onboarding flow tells the
        // user to relaunch when that happens; spam-prompt is worse than
        // a relaunch.
        next[.screenRecording] = CGPreflightScreenCaptureAccess()

        // Accessibility: AXIsProcessTrusted is the canonical check, but
        // it caches false the same way as CGPreflight. The 'live probe'
        // here is cheap — we call it every poll because the AX API has
        // no async cost worth caching.
        next[.accessibility] = liveAccessibilityCheck()

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        next[.microphone] = micStatus == .authorized

        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        next[.camera] = cameraStatus == .authorized

        next[.calendar] = isEventKitGranted(for: .event)
        next[.reminders] = isEventKitGranted(for: .reminder)

        let contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
        next[.contacts] = contactsStatus == .authorized

        if next != grants {
            grants = next
        }
    }

    // MARK: - Live probes

    /// AXIsProcessTrusted lies the same way CGPreflight does once the
    /// user has revoked + re-granted. The reliable live test is to
    /// actually exercise an AX API and check whether the answer is
    /// permission-blocked. This call is cheap (no IPC) so we run it on
    /// every poll instead of caching.
    private func liveAccessibilityCheck() -> Bool {
        // AXIsProcessTrustedWithOptions with NO prompt option: never
        // pops a dialog from a polling path, just reports the current
        // authoritative answer.
        let optionsDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(optionsDictionary)
    }

    // MARK: - EventKit version drift

    /// EKAuthorizationStatus added .fullAccess on macOS 14 (Sonoma) and
    /// retired the legacy .authorized case. The app targets macOS 26+, so
    /// .fullAccess is the only status that means "read + write granted".
    private func isEventKitGranted(for entityType: EKEntityType) -> Bool {
        let status = EKEventStore.authorizationStatus(for: entityType)
        return status == .fullAccess
    }

    // MARK: - Polling + lifecycle

    private func startPollingTimer() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: pollIntervalInSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Refresh the moment the user returns to Pace from System Settings.
    /// Far snappier than waiting for the next 1.5s poll tick.
    private func subscribeToActiveApplicationChanges() {
        let activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let activatedApp = notification
                .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  activatedApp.bundleIdentifier == Bundle.main.bundleIdentifier else {
                return
            }
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        lifecycleObservers.append(activationObserver)
    }
}
