//
//  CompanionManager+CloudBridge.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition Phase A5):
//  cloud bridge mode/upstream/model setters and one-time consent alert.
//

import AppKit
import Foundation

@MainActor
extension CompanionManager {

    // MARK: - Cloud bridge published state

    func setCloudBridgeMode(_ mode: PaceCloudBridgeMode) {
        cloudBridgeMode = mode
        PaceCloudBridgeConsent.saveMode(mode)
        // Rebuild the planner so the new mode takes effect on the next turn
        // without requiring an app restart.
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    func setCloudBridgeUpstream(_ upstream: PaceCloudBridgeUpstream) {
        cloudBridgeUpstream = upstream
        PaceCloudBridgeConsent.saveUpstream(upstream)
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    func setCloudBridgeModel(_ model: String) {
        cloudBridgeModel = model
        PaceCloudBridgeConsent.saveModel(model)
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    /// Shows the one-time cloud-bridge consent NSAlert.
    /// Returns true if the user tapped "Use the bridge", false if they cancelled.
    /// Persists acceptance via `PaceCloudBridgeConsent.acceptConsent()` on approval.
    func requestCloudBridgeConsentIfNeeded() -> Bool {
        let currentConfiguration = PaceCloudBridgeConsent.loadConfiguration()
        guard !currentConfiguration.hasUserAcceptedConsent else {
            // Already accepted — no dialog needed.
            return true
        }

        let consentAlert = NSAlert()
        consentAlert.alertStyle = .warning
        consentAlert.messageText = "Send data outside Pace?"
        consentAlert.informativeText = """
The cloud bridge sends your transcript and the planner system \
prompt to the upstream CLI you choose (Claude Code, Codex, or \
Gemini CLI), which in turn calls Anthropic, OpenAI, or Google \
servers respectively. Their data-handling policies apply.

Pace will show an indicator in the menu-bar capsule whenever a \
bridge call is in flight. Push-to-talk text-only turns still \
default to your local planner; the bridge is used only for \
turns Pace would otherwise refuse as "too hard locally."

You can turn this off at any time in Settings → Cloud bridge.
"""
        consentAlert.addButton(withTitle: "Use the bridge")
        consentAlert.addButton(withTitle: "Keep local only")

        NSApp.activate(ignoringOtherApps: true)
        let userResponse = consentAlert.runModal()
        let userAccepted = userResponse == .alertFirstButtonReturn

        if userAccepted {
            PaceCloudBridgeConsent.acceptConsent()
        }
        return userAccepted
    }
}
