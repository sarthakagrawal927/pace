//
//  PaceAutoUpdateController.swift
//  leanring-buddy
//
//  Wires Sparkle into Pace so the app silently checks for updates
//  against the GitHub-hosted appcast and downloads / installs them on
//  user approval. No Apple Developer Program / notarization needed —
//  Sparkle verifies update authenticity with its own EdDSA signature
//  (private key kept in the Mac's keychain on the release machine;
//  public key embedded in Info.plist as SUPublicEDKey).
//
//  Lifecycle: created lazily by CompanionAppDelegate at launch. The
//  user can also trigger a manual check from the Settings window via
//  `checkForUpdatesManually()`.
//

import Foundation
import Sparkle

@MainActor
final class PaceAutoUpdateController: NSObject {
    static let shared = PaceAutoUpdateController()

    private let updaterController: SPUStandardUpdaterController

    override init() {
        // startingUpdater: true → automatic background check kicks off
        // as soon as the controller is constructed, with the cadence
        // Sparkle's defaults / Info.plist drive (SUEnableAutomaticChecks,
        // SUScheduledCheckInterval). Manual checks still work either way.
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        print("🔄 PaceAutoUpdateController: started (feed=\(self.updaterController.updater.feedURL?.absoluteString ?? "unset"))")
    }

    /// Hook for a Settings-window "Check for updates…" button. Sparkle
    /// shows its own UI (no update / found update / installing) so this
    /// is a single call.
    func checkForUpdatesManually() {
        updaterController.checkForUpdates(nil)
    }
}
