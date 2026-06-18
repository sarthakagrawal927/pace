//
//  PaceSettingsWindow.swift
//  leanring-buddy
//
//  A normal macOS settings window for configuration that has outgrown the
//  notch panel. The notch remains the quick surface; this owns management.
//

import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class PaceSettingsWindowManager {
    static let shared = PaceSettingsWindowManager()

    private var window: NSWindow?

    func show(companionManager: CompanionManager) {
        if window == nil {
            createWindow(companionManager: companionManager)
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow(companionManager: CompanionManager) {
        let settingsView = PaceSettingsWindowView(companionManager: companionManager)
        let hostingView = NSHostingView(rootView: settingsView)

        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "Pace Settings"
        settingsWindow.contentMinSize = NSSize(width: 680, height: 460)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.contentView = hostingView
        window = settingsWindow
    }
}

private enum PaceSettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case planner = "Planner"
    case models = "Models"
    case research = "Research"
    case proactive = "Proactive"
    case mcp = "MCP"
    case permissions = "Permissions"
    case voice = "Voice"
    case cloudBridge = "Cloud bridge"
    case flows = "Flows"
    case memory = "Memory"
    case activity = "Activity"
    case debug = "Debug"
    case doctor = "Diagnostics"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .general:
            return "switch.2"
        case .planner:
            return "brain.head.profile"
        case .models:
            return "shippingbox"
        case .research:
            return "magnifyingglass.circle"
        case .proactive:
            return "bell.badge"
        case .mcp:
            return "point.3.connected.trianglepath.dotted"
        case .permissions:
            return "lock.shield"
        case .voice:
            return "waveform"
        case .cloudBridge:
            return "antenna.radiowaves.left.and.right"
        case .flows:
            return "play.square.stack"
        case .memory:
            return "brain"
        case .activity:
            return "list.bullet.rectangle"
        case .debug:
            return "ladybug"
        case .doctor:
            return "stethoscope"
        }
    }
}

struct PaceSettingsWindowView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var selectedTab: PaceSettingsTab = .general
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
                .background(DS.Colors.borderSubtle)
            content
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(DS.Colors.background)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pace")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 10)

            ForEach(PaceSettingsTab.allCases) { tab in
                Button(action: {
                    selectedTab = tab
                }) {
                    HStack(spacing: 9) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(selectedTab == tab ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selectedTab == tab ? Color.white.opacity(0.08) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .frame(width: 180)
        .background(Color.black.opacity(0.16))
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(title: selectedTab.rawValue)

                switch selectedTab {
                case .general:
                    PaceGeneralSettingsTab(companionManager: companionManager)
                case .planner:
                    PacePlannerSettingsTab(companionManager: companionManager)
                case .models:
                    PaceBundledModelsSettingsTab(companionManager: companionManager)
                case .research:
                    PaceResearchSettingsTab(companionManager: companionManager)
                case .proactive:
                    PaceProactiveSettingsTab(companionManager: companionManager)
                case .mcp:
                    PaceMCPSettingsTab(companionManager: companionManager)
                case .permissions:
                    PacePermissionsSettingsTab(companionManager: companionManager)
                case .voice:
                    PaceVoiceSettingsTab(companionManager: companionManager)
                case .cloudBridge:
                    PaceCloudBridgeSettingsTab(companionManager: companionManager)
                case .flows:
                    PaceFlowsSettingsTab(companionManager: companionManager)
                case .memory:
                    PaceMemorySettingsTab(companionManager: companionManager)
                case .activity:
                    PaceActivitySettingsTab(companionManager: companionManager)
                case .debug:
                    PaceDebugSettingsTab(companionManager: companionManager)
                case .doctor:
                    PaceDoctorSettingsTab(companionManager: companionManager)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Manage the full app configuration here; keep the notch panel for quick status.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }









}
