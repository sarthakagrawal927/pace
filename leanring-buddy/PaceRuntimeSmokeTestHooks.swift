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
    static let paceSmokeShowClickTargetClarification = Notification.Name("com.pace.smoke.showClickTargetClarification")
    static let paceSmokeResolveClickTargetClarification = Notification.Name("com.pace.smoke.resolveClickTargetClarification")
    static let paceSmokeSimulateClickAllFailObservation = Notification.Name("com.pace.smoke.simulateClickAllFailObservation")
}

@MainActor
final class PaceRuntimeSmokeTestHooks {
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["PACE_ENABLE_SMOKE_HOOKS"] == "1"
    }()

    private let menuBarPanelManager: MenuBarPanelManager
    private let companionManager: CompanionManager
    private var observers: [NSObjectProtocol] = []

    init(menuBarPanelManager: MenuBarPanelManager, companionManager: CompanionManager) {
        self.menuBarPanelManager = menuBarPanelManager
        self.companionManager = companionManager
        installObservers()
        PaceSmokeTestStateStore.markSmokeHooksReady()
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
            PaceSmokeTestStateStore.recordLastPanelCommand("show")
        }

        observe(.paceSmokeHidePanel) { [weak self] in
            self?.menuBarPanelManager.hidePanelForSmokeTest()
            PaceSmokeTestStateStore.recordLastPanelCommand("hide")
        }

        observe(.paceSmokeShowSettings) { [weak self] in
            guard let self else { return }
            menuBarPanelManager.hidePanelForSmokeTest()
            PaceSettingsWindowManager.shared.show(companionManager: companionManager)
            PaceSmokeTestStateStore.recordLastSettingsCommand("show")
        }

        observe(.paceSmokeCursorAnnotationsOn) { [weak self] in
            guard let self else { return }
            let isEnabled = companionManager.smokeSetCursorAnnotationsEnabled(true)
            PaceSmokeTestStateStore.recordLastCursorAnnotationsEnabled(isEnabled)
        }

        observe(.paceSmokeCursorAnnotationsOff) { [weak self] in
            guard let self else { return }
            let isEnabled = companionManager.smokeSetCursorAnnotationsEnabled(false)
            PaceSmokeTestStateStore.recordLastCursorAnnotationsEnabled(isEnabled)
        }

        observe(.paceSmokeRequestApproval) { [weak self] in
            guard let self else { return }
            let didApprove = companionManager.smokeRequestApprovalForSyntheticActionPlan()
            PaceSmokeTestStateStore.recordLastApprovalAllowed(didApprove)
        }

        observe(.paceSmokeShowClarification) { [weak self] in
            guard let self else { return }
            let didShowClarification = companionManager.smokeShowSyntheticClarification()
            PaceSmokeTestStateStore.recordLastClarificationState(
                didShowClarification ? "shown" : "failed"
            )
        }

        observe(.paceSmokeResolveClarification) { [weak self] in
            guard let self else { return }
            let clarifiedTranscript = companionManager.smokeResolveSyntheticClarification()
            PaceSmokeTestStateStore.recordLastClarifiedTranscript(
                clarifiedTranscript ?? "<failed>"
            )
        }

        observe(.paceSmokeShowClickTargetClarification) { [weak self] in
            guard let self else { return }
            let didShow = companionManager.smokeShowClickTargetClarification()
            PaceSmokeTestStateStore.recordLastClickTargetClarificationState(
                didShow ? "shown" : "failed"
            )
        }

        observe(.paceSmokeResolveClickTargetClarification) { [weak self] in
            guard let self else { return }
            let resolvedLabel = companionManager.smokeResolveClickTargetClarification()
            PaceSmokeTestStateStore.recordLastClickTargetResolution(
                resolvedLabel ?? "<failed>"
            )
        }

        observe(.paceSmokeSimulateClickAllFailObservation) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let summary = await self.companionManager.smokeSimulateClickAllFailObservation()
                PaceSmokeTestStateStore.recordLastClickAllFailSummary(summary ?? "<failed>")
            }
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
