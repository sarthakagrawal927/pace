//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available notch/menu-bar overlay. Clicking the overlay opens
//  a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI

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
    private var menuBarOverlayManager: PaceMenuBarOverlayManager?
    private var runtimeSmokeTestHooks: PaceRuntimeSmokeTestHooks?
    private let companionManager = CompanionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Pace: Starting...")
        print("🎯 Pace: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        // Single-instance enforcement. If another Pace is already
        // running (e.g. login-item launched at boot and now Xcode is
        // Cmd+R'ing a dev build on top), the newer launch wins —
        // terminate the older instance so the user doesn't see two
        // walking avatars, two cursors, and two notch overlays. Bug
        // confirmed by `ps -ax | grep Pace` showing duplicate PIDs.
        terminateOtherRunningPaceInstances()

        PaceToolRegistry.validateForAppStartup()
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        PaceAnalytics.configure()
        PaceAnalytics.trackAppOpened()

        // Auto-load the configured planner + VLM into LM Studio so the
        // user's first push-to-talk doesn't pay the cold-load tax.
        // Fire-and-forget — app launch is not blocked. Companion
        // unload happens in `applicationWillTerminate`.
        PaceLMStudioModelLoader.warmUpConfiguredModelsAsync()
        prewarmMailForFastDraftsIfNeeded()

        let menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        self.menuBarPanelManager = menuBarPanelManager
        menuBarOverlayManager = PaceMenuBarOverlayManager(
            companionManager: companionManager,
            onTap: { [weak self] anchorFrame in
                self?.menuBarPanelManager?.togglePanel(anchoredTo: anchorFrame)
            }
        )
        menuBarOverlayManager?.show()
        companionManager.start()
        if PaceRuntimeSmokeTestHooks.isEnabled {
            runtimeSmokeTestHooks = PaceRuntimeSmokeTestHooks(
                menuBarPanelManager: menuBarPanelManager,
                companionManager: companionManager
            )
            print("🧪 Pace: runtime smoke-test hooks enabled")
        }
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarOverlayManager?.hide()
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
    /// two notch overlays. Each prior instance is asked to terminate
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

    /// Eats Mail's cold-launch cost before the first compose command. This is
    /// launch-only and non-activating so the user does not lose focus.
    private func prewarmMailForFastDraftsIfNeeded() {
        let rawFlag = AppBundleConfiguration
            .stringValue(forKey: "PrewarmMailForDrafts")?
            .lowercased()
        guard rawFlag != "false", rawFlag != "0", rawFlag != "no" else {
            print("📬 Pace: Mail draft prewarm disabled")
            return
        }

        let mailBundleIdentifier = "com.apple.mail"
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == mailBundleIdentifier
        }) {
            print("📬 Pace: Mail already running for fast drafts")
            return
        }

        guard let mailApplicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: mailBundleIdentifier
        ) else {
            print("⚠️ Pace: Mail app not found for draft prewarm")
            return
        }

        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = false
        openConfiguration.addsToRecentItems = false
        openConfiguration.createsNewApplicationInstance = false

        NSWorkspace.shared.openApplication(
            at: mailApplicationURL,
            configuration: openConfiguration
        ) { runningApplication, error in
            if let error {
                print("⚠️ Pace: Mail draft prewarm failed: \(error.localizedDescription)")
            } else if let runningApplication {
                print("📬 Pace: Mail prewarmed for drafts pid=\(runningApplication.processIdentifier)")
            } else {
                print("📬 Pace: Mail draft prewarm requested")
            }
        }
    }

}
