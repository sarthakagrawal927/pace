//
//  PaceOnboardingWindow.swift
//  leanring-buddy
//
//  Hosts PaceOnboardingView in a borderless centered panel on the
//  first-ever launch — replaces the old "auto-open the notch panel"
//  pattern, which was cramped and shoved a bunch of UI at the user
//  before they'd seen anything about what Pace was.
//

import AppKit
import SwiftUI

@MainActor
final class PaceOnboardingWindowManager {
    static let shared = PaceOnboardingWindowManager()

    private var window: NSWindow?

    private init() {}

    /// True if the user has completed onboarding before. Stored as a
    /// UserDefaults bool so the welcome window only shows once. The
    /// onboarding view writes this when the user clicks Finish.
    static var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }

    func showOnboardingIfNeeded() {
        guard !Self.hasCompletedOnboarding else { return }
        show()
    }

    func show() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = PaceOnboardingView(onComplete: { [weak self] in
            self?.close()
        })
        let hostingController = NSHostingController(rootView: rootView)
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Welcome to Pace"
        newWindow.titlebarAppearsTransparent = true
        newWindow.contentViewController = hostingController
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = newWindow
    }

    private func close() {
        window?.close()
        window = nil
    }
}
