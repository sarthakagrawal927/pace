//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import Combine
import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private let avatarOverlayManager = PaceAvatarOverlayManager()
    private var avatarVisibilityCancellable: AnyCancellable?
    private var avatarTapNotificationObserver: NSObjectProtocol?
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Pace: Starting...")
        print("🎯 Pace: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        // Single-instance enforcement. If another Pace is already
        // running (e.g. login-item launched at boot and now Xcode is
        // Cmd+R'ing a dev build on top), the newer launch wins —
        // terminate the older instance so the user doesn't see two
        // walking avatars, two cursors, and two menu-bar icons. Bug
        // confirmed by `ps -ax | grep Pace` showing duplicate PIDs.
        terminateOtherRunningPaceInstances()

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        PaceAnalytics.configure()
        PaceAnalytics.trackAppOpened()

        // Auto-load the configured planner + VLM into LM Studio so the
        // user's first push-to-talk doesn't pay the cold-load tax.
        // Fire-and-forget — app launch is not blocked. Companion
        // unload happens in `applicationWillTerminate`.
        PaceLMStudioModelLoader.warmUpConfiguredModelsAsync()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()

        avatarOverlayManager.attach(to: companionManager)
        // CompanionManager needs a weak handle to ask for the avatar's
        // current screen position when anchoring the response bubble.
        companionManager.avatarOverlayManager = avatarOverlayManager
        avatarVisibilityCancellable = companionManager.$isWalkingAvatarEnabled.sink { [weak self] isVisible in
            if isVisible {
                self?.avatarOverlayManager.show()
            } else {
                self?.avatarOverlayManager.hide()
            }
        }
        // Clicking the avatar starts / stops a voice turn — the same
        // pipeline as the keyboard push-to-talk shortcut. Routed through
        // CompanionManager so all the dictation/overlay/state plumbing
        // stays in one place.
        avatarTapNotificationObserver = NotificationCenter.default.addObserver(
            forName: .paceAvatarTapped,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.companionManager.handleAvatarTapped()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let avatarTapNotificationObserver {
            NotificationCenter.default.removeObserver(avatarTapNotificationObserver)
        }
        avatarOverlayManager.hide()
        companionManager.stop()
        // Stop the keepalive heartbeat so it doesn't race with the
        // unload below and immediately re-trigger a load.
        PaceLMStudioModelLoader.stopKeepaliveLoop()
        // Free the planner + VLM weights so Pace doesn't leave 5-20 GB
        // of model RAM resident after the user quits. Synchronous via
        // `lms` CLI; ~100-300ms on the way out.
        PaceLMStudioModelLoader.unloadConfiguredModelsSynchronously()
    }

    /// Kill any other Pace processes that are already running. Called
    /// at launch so a duplicate launch (Xcode Cmd+R landing on top of
    /// a login-item Pace, or a Finder double-launch) doesn't end up
    /// with two of every visual — two avatars, two cursor overlays,
    /// two menu-bar icons. Each prior instance is asked to terminate
    /// cooperatively first; force-killed if it doesn't respond.
    private func terminateOtherRunningPaceInstances() {
        guard let myBundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let myProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let otherPaceInstances = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == myBundleIdentifier && $0.processIdentifier != myProcessIdentifier
        }
        guard !otherPaceInstances.isEmpty else { return }

        for otherInstance in otherPaceInstances {
            print("🧹 Pace: terminating duplicate instance pid=\(otherInstance.processIdentifier)")
            // Try the polite path first — gives the other instance a
            // chance to run its applicationWillTerminate (which unloads
            // its LM Studio models). 1.5s grace then force-kill.
            otherInstance.terminate()
        }
        // Give cooperative terminate a moment, then forceTerminate any
        // stragglers. Synchronous wait is acceptable here — we're at
        // launch and the user is staring at a stale duplicate.
        let pollDeadline = Date(timeIntervalSinceNow: 1.5)
        while Date() < pollDeadline {
            let stillAlive = otherPaceInstances.contains { !$0.isTerminated }
            if !stillAlive { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        for stragglerInstance in otherPaceInstances where !stragglerInstance.isTerminated {
            print("🧹 Pace: force-killing stuck instance pid=\(stragglerInstance.processIdentifier)")
            stragglerInstance.forceTerminate()
        }
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Pace: Registered as login item")
            } catch {
                print("⚠️ Pace: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Pace: Sparkle updater failed to start: \(error)")
        }
    }
}
