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
    /// Strong owner of the top-right mascot perch (CompanionManager holds a
    /// weak ref). nil when running the legacy notch-capsule surface.
    private var avatarOverlayManager: PaceAvatarOverlayManager?
    private var runtimeSmokeTestHooks: PaceRuntimeSmokeTestHooks?
    private let companionManager = CompanionManager()

    // A cold launch via URL delivers application(_:open:) before
    // applicationDidFinishLaunching has built the managers — buffer the
    // commands and drain them once launch completes.
    private var pendingDeepLinkCommands: [PaceDeepLinkCommand] = []
    private var hasFinishedLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Pace: Starting...")
        print("🎯 Pace: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        Task {
            await PaceRemoteModelManifest.refreshIfNeeded()
        }

        // Single-instance enforcement is fundamentally hostile to macOS's
        // own "restart the app to apply the new permission" flow for
        // Screen Recording / Accessibility: macOS launches a fresh process
        // post-grant, and us killing the older one (or the older killing
        // us first) churns through ANOTHER permission re-prompt. Only run
        // duplicate cleanup in RELEASE builds where the user is unlikely
        // to be cycling permissions.
        #if !DEBUG
        terminateOtherRunningPaceInstances()
        #endif

        PaceToolRegistry.validateForAppStartup()
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])
        // One-shot migration of the prototype-era UserDefaults flow
        // snapshot into the on-disk JSON store. No-op on a fresh
        // install or after the migration has already run.
        PaceFlowStore().migrateLegacyUserDefaultsFlowsIfNeeded()

        // Wave 4: warm Apple Foundation Models at launch so the lite
        // path in the speculative-planner race + every Apple FM turn
        // pays for the system model load BEFORE the user pushes to
        // talk. Detached + fire-and-forget; bails silently when Apple
        // Intelligence is unavailable. No new model RAM — FM is
        // in-process and bundled with macOS.
        if #available(macOS 26.0, *) {
            Task.detached(priority: .utility) {
                await AppleFoundationModelsPlannerClient.warmUp()
            }
        }

        PaceAnalytics.configure()
        PaceAnalytics.trackAppOpened()

        // Auto-load the configured planner + VLM into LM Studio so the
        // user's first push-to-talk doesn't pay the cold-load tax.
        // Fire-and-forget — app launch is not blocked. Companion
        // unload happens in `applicationWillTerminate`.
        // Auto-update: Sparkle starts its background check immediately
        // against the GitHub-hosted appcast. Manual checks live behind
        // PaceAutoUpdateController.shared.checkForUpdatesManually().
        _ = PaceAutoUpdateController.shared

        PaceLMStudioModelLoader.warmUpConfiguredModelsAsync()
        // Auto-start the Kokoro TTS sidecar so the user never has to
        // remember scripts/start-tts-server.sh. Idempotent — does
        // nothing if the sidecar is already reachable on the configured
        // port. Detached so it survives Pace quit/restart and stays
        // warm for the next launch.
        PaceTTSSidecarLauncher.startIfNotRunning()
        prewarmMailForFastDraftsIfNeeded()

        let menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        self.menuBarPanelManager = menuBarPanelManager

        // Primary surface: the top-right mascot perch. The notch capsule
        // (PaceMenuBarOverlayManager) is created + preserved but not shown —
        // flip useRightCornerMascot to false to restore the notch.
        let useRightCornerMascot = true
        menuBarOverlayManager = PaceMenuBarOverlayManager(
            companionManager: companionManager,
            onTap: { [weak self] anchorFrame in
                self?.menuBarPanelManager?.togglePanel(anchoredTo: anchorFrame)
            }
        )
        if useRightCornerMascot {
            let mascot = PaceAvatarOverlayManager()
            mascot.attach(to: companionManager)
            mascot.onTap = { [weak self] anchorFrame in
                self?.menuBarPanelManager?.togglePanel(anchoredTo: anchorFrame)
            }
            mascot.onConversationStart = { [weak self] anchorFrame in
                self?.menuBarPanelManager?.showPanel(anchoredTo: anchorFrame)
            }
            companionManager.avatarOverlayManager = mascot
            avatarOverlayManager = mascot
            mascot.show()
        } else {
            menuBarOverlayManager?.show()
        }
        companionManager.start()
        if useRightCornerMascot {
            // Mascot is the only surface — silence the cursor-level overlays
            // so nothing renders near the mouse pointer.
            companionManager.suppressCursorOverlaysForMascotMode()
        }
        if PaceRuntimeSmokeTestHooks.isEnabled {
            runtimeSmokeTestHooks = PaceRuntimeSmokeTestHooks(
                menuBarPanelManager: menuBarPanelManager,
                companionManager: companionManager
            )
            print("🧪 Pace: runtime smoke-test hooks enabled")
        }
        // First-launch onboarding: dedicated welcome window walking through
        // the required permissions, replacing the old "shove the notch
        // panel in their face" pattern. Future launches go straight to the
        // menu bar — the user opens the panel themselves.
        PaceOnboardingWindowManager.shared.showOnboardingIfNeeded()
        registerAsLoginItemIfNeeded()

        hasFinishedLaunching = true
        let bufferedDeepLinkCommands = pendingDeepLinkCommands
        pendingDeepLinkCommands = []
        for deepLinkCommand in bufferedDeepLinkCommands {
            executeDeepLinkCommand(deepLinkCommand)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let deepLinkCommand = PaceDeepLinkParser.parse(url) else {
                print("🔗 Pace: ignoring unrecognized deeplink \(url.absoluteString)")
                continue
            }
            print("🔗 Pace: deeplink \(url.absoluteString)")
            if hasFinishedLaunching {
                executeDeepLinkCommand(deepLinkCommand)
            } else {
                pendingDeepLinkCommands.append(deepLinkCommand)
            }
        }
    }

    /// Public entry point shared between the `pace://` deeplink handler
    /// and App Intents (Siri / Shortcuts / Spotlight). Buffering and
    /// dispatch behavior is identical to the deeplink path — App Intents
    /// hitting this method before `applicationDidFinishLaunching`
    /// completes will be queued and drained the same way a cold-launch
    /// deeplink is.
    func executePaceExternalCommand(_ command: PaceDeepLinkCommand) {
        if hasFinishedLaunching {
            executeDeepLinkCommand(command)
        } else {
            pendingDeepLinkCommands.append(command)
        }
    }

    private func executeDeepLinkCommand(_ command: PaceDeepLinkCommand) {
        switch command {
        case .showPanel:
            menuBarPanelManager?.showPanelFromDeepLink()
        case .setWatchMode(let enabled):
            companionManager.setWatchModeEnabled(enabled)
        case .startListening:
            companionManager.beginListeningFromDeepLink()
        case .sendChatMessage(let text):
            companionManager.submitChatTranscriptFromDeepLink(text)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tear down every visible surface FIRST: the LM Studio model unload
        // below is synchronous (100ms–seconds via the lms CLI), and any
        // panel or settings window still on screen would visibly linger for
        // that whole time after the user hit quit.
        for window in NSApp.windows {
            window.orderOut(nil)
        }
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
    ///
    /// Skipped for DEBUG builds: an unsigned dev bundle's path can change
    /// each Xcode rebuild, leaving stale launch-services records that
    /// resurrect old copies (and re-trigger TCC permission prompts) after
    /// every grant. Release builds keep the convenience.
    private func registerAsLoginItemIfNeeded() {
        #if DEBUG
        return
        #else
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Pace: Registered as login item")
            } catch {
                print("⚠️ Pace: Failed to register as login item: \(error)")
            }
        }
        #endif
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
