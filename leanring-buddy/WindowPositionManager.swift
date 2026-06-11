//
//  WindowPositionManager.swift
//  leanring-buddy
//
//  Manages positioning the app window on the right edge of the screen
//  and shrinking overlapping windows from other apps via the Accessibility API.
//

import AppKit
import ApplicationServices
import ScreenCaptureKit

enum PermissionRequestPresentationDestination: Equatable {
    case alreadyGranted
    case systemPrompt
    case systemSettings
}

@MainActor
class WindowPositionManager {
    /// Persistent across launches — once Pace has triggered the macOS
    /// permission prompt for a TCC entitlement, future Grant taps open
    /// System Settings directly instead of re-firing the prompt. macOS
    /// only ever shows the modal prompt once per bundle identity
    /// anyway, so re-attempts were the "spam" — they did nothing
    /// useful and made the user click around. Persisted so this
    /// survives quit/relaunch (matching macOS's actual behavior).
    private static let promptedKeyPrefix = "PaceHasPromptedSystem."

    private static func hasPromptedSystemFor(_ permissionKey: String) -> Bool {
        UserDefaults.standard.bool(forKey: promptedKeyPrefix + permissionKey)
    }

    private static func markSystemPromptedFor(_ permissionKey: String) {
        UserDefaults.standard.set(true, forKey: promptedKeyPrefix + permissionKey)
    }

    // MARK: - Accessibility Permission

    /// Returns true if the app has Accessibility permission.
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Presents exactly one permission path per tap: the system prompt on the first
    /// attempt, then System Settings on later attempts after macOS has already shown
    /// its one-time alert.
    @discardableResult
    static func requestAccessibilityPermission() -> PermissionRequestPresentationDestination {
        let presentationDestination = permissionRequestPresentationDestination(
            hasPermissionNow: hasAccessibilityPermission(),
            hasAttemptedSystemPrompt: hasPromptedSystemFor("accessibility")
        )

        switch presentationDestination {
        case .alreadyGranted:
            return .alreadyGranted
        case .systemPrompt:
            markSystemPromptedFor("accessibility")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .systemSettings:
            openAccessibilitySettings()
        }

        return presentationDestination
    }

    /// Opens System Settings to the Accessibility pane.
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reveals the running app bundle in Finder so the user can drag it into
    /// the Accessibility list if it doesn't appear automatically.
    static func revealAppInFinder() {
        guard let appURL = Bundle.main.bundleURL as URL? else { return }
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    // MARK: - Screen Recording Permission

    /// Returns true if Screen Recording permission is granted.
    /// Last live result and the timestamp it was captured at. The async
    /// probe is fast (~50ms) but firing it from every 1.5s permissions
    /// poll is wasteful — cache for 5s.
    private static var cachedScreenRecordingLiveResult: Bool?
    private static var cachedScreenRecordingLiveResultAt: Date = .distantPast
    private static let liveScreenRecordingResultStalenessInSeconds: TimeInterval = 5

    /// Returns true if Pace can actually record the screen.
    ///
    /// CGPreflightScreenCaptureAccess has a documented macOS caching
    /// bug: once it returns false for a running process, it keeps
    /// returning false even after the user grants the permission in
    /// System Settings — only a quit/relaunch refreshes it. That made
    /// Pace's permissions panel claim "Grant" even when Settings showed
    /// the toggle ON.
    ///
    /// We now treat CGPreflight as the optimistic fast path AND start
    /// an async SCShareableContent probe to verify. The cached probe
    /// result wins over a false negative from preflight, so a granted
    /// toggle flips the panel state within ~5s of the next poll.
    static func hasScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            cachedScreenRecordingLiveResult = true
            cachedScreenRecordingLiveResultAt = Date()
            return true
        }
        // Preflight said no — kick off (or reuse) the live probe and
        // believe IT instead. Probe success means the grant is real
        // and macOS just hasn't told preflight yet.
        refreshLiveScreenRecordingPermissionIfStale()
        return cachedScreenRecordingLiveResult ?? false
    }

    private static var liveProbeInFlight = false

    private static func refreshLiveScreenRecordingPermissionIfStale() {
        let secondsSinceLastProbe = Date().timeIntervalSince(cachedScreenRecordingLiveResultAt)
        guard secondsSinceLastProbe >= liveScreenRecordingResultStalenessInSeconds,
              !liveProbeInFlight else {
            return
        }
        liveProbeInFlight = true
        Task.detached(priority: .userInitiated) {
            // SCShareableContent.current actually attempts the
            // privileged enumeration; success means TCC granted us
            // access right now, failure (or empty displays) means it
            // didn't. Use the same API that real captures use so the
            // answer reflects reality.
            let canRecord: Bool
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                canRecord = !content.displays.isEmpty
            } catch {
                canRecord = false
            }
            await MainActor.run {
                cachedScreenRecordingLiveResult = canRecord
                cachedScreenRecordingLiveResultAt = Date()
                liveProbeInFlight = false
            }
        }
    }

    /// Prompts the system dialog for Screen Recording permission.
    /// Uses the system prompt once, then opens System Settings on later attempts so
    /// the user never gets the prompt and the Settings pane at the same time.
    @discardableResult
    static func requestScreenRecordingPermission() -> PermissionRequestPresentationDestination {
        let presentationDestination = permissionRequestPresentationDestination(
            hasPermissionNow: hasScreenRecordingPermission(),
            hasAttemptedSystemPrompt: hasPromptedSystemFor("screenRecording")
        )

        switch presentationDestination {
        case .alreadyGranted:
            return .alreadyGranted
        case .systemPrompt:
            markSystemPromptedFor("screenRecording")
            _ = CGRequestScreenCaptureAccess()
        case .systemSettings:
            openScreenRecordingSettings()
        }

        return presentationDestination
    }

    /// Opens System Settings to the Screen Recording pane.
    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    static func openSpeechRecognitionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") else { return }
        NSWorkspace.shared.open(url)
    }

    static func openCalendarSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }

    static func openRemindersSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") else { return }
        NSWorkspace.shared.open(url)
    }

    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    static func permissionRequestPresentationDestination(
        hasPermissionNow: Bool,
        hasAttemptedSystemPrompt: Bool
    ) -> PermissionRequestPresentationDestination {
        if hasPermissionNow {
            return .alreadyGranted
        }

        if hasAttemptedSystemPrompt {
            return .systemSettings
        }

        return .systemPrompt
    }

    // MARK: - Window Positioning

}

// MARK: - NSScreen Extension

extension NSScreen {
    /// The CGDirectDisplayID for this screen.
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? 0
    }
}
