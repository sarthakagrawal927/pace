//
//  PaceRuntimeSmokeTestHooks.swift
//  leanring-buddy
//
//  Runtime smoke-test hooks for app-level verification that is otherwise
//  fragile to drive through SwiftUI Accessibility. Disabled unless the app is
//  launched with PACE_ENABLE_SMOKE_HOOKS=1.
//

import Foundation

extension Notification.Name {
    static let paceSmokeShowPanel = Notification.Name("com.pace.smoke.showPanel")
    static let paceSmokeHidePanel = Notification.Name("com.pace.smoke.hidePanel")
    static let paceSmokeShowSettings = Notification.Name("com.pace.smoke.showSettings")
    static let paceSmokeCursorAnnotationsOn = Notification.Name("com.pace.smoke.cursorAnnotationsOn")
    static let paceSmokeCursorAnnotationsOff = Notification.Name("com.pace.smoke.cursorAnnotationsOff")
    static let paceSmokeRequestApproval = Notification.Name("com.pace.smoke.requestApproval")
    static let paceSmokeShowClarification = Notification.Name("com.pace.smoke.showClarification")
    static let paceSmokeResolveClarification = Notification.Name("com.pace.smoke.resolveClarification")
}

@MainActor
final class PaceRuntimeSmokeTestHooks {
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["PACE_ENABLE_SMOKE_HOOKS"] == "1"
    }()

    private enum DefaultsKey {
        static let ready = "PaceSmoke.ready"
        static let lastPanelCommand = "PaceSmoke.lastPanelCommand"
        static let lastSettingsCommand = "PaceSmoke.lastSettingsCommand"
        static let lastCursorAnnotationsEnabled = "PaceSmoke.lastCursorAnnotationsEnabled"
        static let lastApprovalAllowed = "PaceSmoke.lastApprovalAllowed"
        static let lastClarificationState = "PaceSmoke.lastClarificationState"
        static let lastClarifiedTranscript = "PaceSmoke.lastClarifiedTranscript"
    }

    private let menuBarPanelManager: MenuBarPanelManager
    private let companionManager: CompanionManager
    private var observers: [NSObjectProtocol] = []

    init(menuBarPanelManager: MenuBarPanelManager, companionManager: CompanionManager) {
        self.menuBarPanelManager = menuBarPanelManager
        self.companionManager = companionManager
        installObservers()
        UserDefaults.standard.set(true, forKey: DefaultsKey.ready)
    }

    deinit {
        let distributedNotificationCenter = DistributedNotificationCenter.default()
        for observer in observers {
            distributedNotificationCenter.removeObserver(observer)
        }
    }

    private func installObservers() {
        observe(.paceSmokeShowPanel) { [weak self] in
            self?.menuBarPanelManager.showPanelForSmokeTest()
            UserDefaults.standard.set("show", forKey: DefaultsKey.lastPanelCommand)
        }

        observe(.paceSmokeHidePanel) { [weak self] in
            self?.menuBarPanelManager.hidePanelForSmokeTest()
            UserDefaults.standard.set("hide", forKey: DefaultsKey.lastPanelCommand)
        }

        observe(.paceSmokeShowSettings) { [weak self] in
            guard let self else { return }
            menuBarPanelManager.hidePanelForSmokeTest()
            PaceSettingsWindowManager.shared.show(companionManager: companionManager)
            UserDefaults.standard.set("show", forKey: DefaultsKey.lastSettingsCommand)
        }

        observe(.paceSmokeCursorAnnotationsOn) { [weak self] in
            guard let self else { return }
            let isEnabled = companionManager.smokeSetCursorAnnotationsEnabled(true)
            UserDefaults.standard.set(isEnabled, forKey: DefaultsKey.lastCursorAnnotationsEnabled)
        }

        observe(.paceSmokeCursorAnnotationsOff) { [weak self] in
            guard let self else { return }
            let isEnabled = companionManager.smokeSetCursorAnnotationsEnabled(false)
            UserDefaults.standard.set(isEnabled, forKey: DefaultsKey.lastCursorAnnotationsEnabled)
        }

        observe(.paceSmokeRequestApproval) { [weak self] in
            guard let self else { return }
            let didApprove = companionManager.smokeRequestApprovalForSyntheticActionPlan()
            UserDefaults.standard.set(didApprove, forKey: DefaultsKey.lastApprovalAllowed)
        }

        observe(.paceSmokeShowClarification) { [weak self] in
            guard let self else { return }
            let didShowClarification = companionManager.smokeShowSyntheticClarification()
            UserDefaults.standard.set(
                didShowClarification ? "shown" : "failed",
                forKey: DefaultsKey.lastClarificationState
            )
        }

        observe(.paceSmokeResolveClarification) { [weak self] in
            guard let self else { return }
            let clarifiedTranscript = companionManager.smokeResolveSyntheticClarification()
            UserDefaults.standard.set(
                clarifiedTranscript ?? "<failed>",
                forKey: DefaultsKey.lastClarifiedTranscript
            )
        }
    }

    private func observe(_ name: Notification.Name, handler: @escaping @MainActor () -> Void) {
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                handler()
            }
        }
        observers.append(observer)
    }
}
