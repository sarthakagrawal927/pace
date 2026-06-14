//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the custom borderless NSPanel that drops down from the Pace
//  notch/menu-bar overlay. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let paceDismissPanel = Notification.Name("paceDismissPanel")
    /// Posted by `CompanionManager` when the notch chat shortcut fires,
    /// so the panel manager can bring the panel forward without the
    /// manager needing a direct reference to it. Mirrors the existing
    /// `paceDismissPanel` pattern.
    static let paceShowPanel = Notification.Name("paceShowPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var panel: NSPanel?
    private var panelAnchorFrameOverride: NSRect?
    private var clickOutsideMonitor: Any?
    private var localClickOutsideMonitor: Any?
    /// When the panel was last shown. Outside-click dismissal is ignored for
    /// a brief grace window after this so the very click/gesture that opened
    /// the panel (e.g. tapping the mascot, which is outside the panel frame)
    /// can't immediately close it.
    private var panelShownAt: Date?
    private var dismissPanelObserver: NSObjectProtocol?
    private var showPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .paceDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let manager = self else { return }
            Task { @MainActor in
                manager.hidePanel()
            }
        }

        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .paceShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let manager = self else { return }
            Task { @MainActor in
                manager.showPanel()
            }
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localClickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the notch overlay has time to appear in the menu bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    func togglePanel() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func togglePanel(anchoredTo anchorFrame: NSRect) {
        panelAnchorFrameOverride = anchorFrame
        togglePanel()
    }

    /// Non-toggling show anchored to a frame — used when a conversation
    /// starts so the panel reliably appears at the mascot (never closes an
    /// already-open panel mid-turn).
    func showPanel(anchoredTo anchorFrame: NSRect) {
        panelAnchorFrameOverride = anchorFrame
        if panel?.isVisible != true {
            showPanel()
        } else {
            positionPanelBelowAnchor()
        }
    }

    func showPanelForSmokeTest() {
        showPanel()
    }

    /// Entry point for the pace://panel deeplink (Raycast/Shortcuts).
    func showPanelFromDeepLink() {
        showPanel()
    }

    func hidePanelForSmokeTest() {
        hidePanel()
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowAnchor()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        panelShownAt = Date()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        // Premium chat surface (PacePanelChatView). The prior dashboard
        // (CompanionPanelView) is kept in the tree, not deleted — swap this
        // line back to revert.
        let companionPanelView = PacePanelChatView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowAnchor() {
        guard let panel else { return }
        let anchorFrame: NSRect
        if let panelAnchorFrameOverride {
            anchorFrame = panelAnchorFrameOverride
        } else if let defaultAnchorFrame = defaultMenuBarAnchorFrame() {
            anchorFrame = defaultAnchorFrame
        } else {
            return
        }
        let gapBelowMenuBar: CGFloat = 4

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        var panelOriginX = anchorFrame.midX - (panelWidth / 2)
        let panelOriginY = anchorFrame.minY - actualPanelHeight - gapBelowMenuBar

        // Keep the panel fully on-screen. A right-corner anchor (the mascot
        // perch) would otherwise center the panel under the mascot and push
        // its right half off the screen edge; clamp so it drops down-left.
        if let anchorScreen = NSScreen.screens.first(where: { $0.frame.intersects(anchorFrame) }) ?? NSScreen.main {
            let horizontalMargin: CGFloat = 8
            let maxOriginX = anchorScreen.frame.maxX - panelWidth - horizontalMargin
            let minOriginX = anchorScreen.frame.minX + horizontalMargin
            panelOriginX = min(max(panelOriginX, minOriginX), maxOriginX)
        }

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    private func defaultMenuBarAnchorFrame() -> NSRect? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }

        let fallbackAnchorWidth: CGFloat = 292
        let fallbackAnchorHeight: CGFloat = 34
        return NSRect(
            x: screen.frame.midX - (fallbackAnchorWidth / 2),
            y: screen.frame.maxY - fallbackAnchorHeight,
            width: fallbackAnchorWidth,
            height: fallbackAnchorHeight
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        // Global monitor: clicks that land in OTHER apps.
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.dismissPanelIfClickIsOutside()
        }

        // Local monitor: clicks that land in OUR OWN other windows — most
        // importantly the Settings window. A global monitor never sees these
        // (they're same-process events), so without this the panel stays open
        // when you click the Settings window. Returns the event unchanged so
        // the clicked control still works.
        localClickOutsideMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.dismissPanelIfClickIsOutside()
            return event
        }
    }

    /// Hides the panel when a click lands outside its frame. Shared by the
    /// global (other-app) and local (own-window, e.g. Settings) monitors.
    private func dismissPanelIfClickIsOutside() {
        guard let panel else { return }
        // Grace window: ignore the click/gesture that just opened the panel
        // (tapping the mascot is outside the panel frame, so without this it
        // would immediately re-close — the open/close flicker).
        if let panelShownAt, Date().timeIntervalSince(panelShownAt) < 0.45 {
            return
        }
        let clickLocation = NSEvent.mouseLocation
        if panel.frame.contains(clickLocation) {
            return
        }
        // Small delay so a Grant button inside the panel that spawns a system
        // permission dialog doesn't race the dismissal. Clicks inside the
        // panel already returned above; anything here is genuinely outside,
        // so dismiss like NSPopover.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, panel.isVisible else { return }
            self.hidePanel()
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = localClickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            localClickOutsideMonitor = nil
        }
    }
}
