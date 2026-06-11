//
//  PaceMainWindow.swift
//  leanring-buddy
//
//  Proper resizable main window for everything that doesn't fit (and
//  shouldn't fit) in the menu-bar notch panel: past conversations,
//  usage analytics, extended settings, onboarding. The notch panel
//  stays minimal — voice state, latest reply, "Open Pace…" — and the
//  product gets a real Mac UI for the longer-form surfaces.
//
//  Lifecycle owned by CompanionAppDelegate; the window is created lazily
//  the first time the user opens it. Multiple "Open Pace…" taps reuse
//  the same window.
//

import AppKit
import SwiftUI

@MainActor
final class PaceMainWindowManager {
    static let shared = PaceMainWindowManager()

    private var window: NSWindow?
    private weak var companionManager: CompanionManager?

    private init() {}

    func show(companionManager: CompanionManager) {
        self.companionManager = companionManager
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = PaceMainView(companionManager: companionManager)
        let hostingController = NSHostingController(rootView: rootView)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Pace"
        newWindow.titlebarAppearsTransparent = true
        newWindow.isMovableByWindowBackground = true
        newWindow.contentViewController = hostingController
        newWindow.minSize = NSSize(width: 720, height: 480)
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = newWindow
    }
}
