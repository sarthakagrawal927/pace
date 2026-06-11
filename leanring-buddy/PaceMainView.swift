//
//  PaceMainView.swift
//  leanring-buddy
//
//  Sidebar-driven root view for PaceMainWindow. Each sidebar item maps
//  to one focused screen — Conversations / Usage / Permissions / About —
//  so each lives in its own file with no cross-talk.
//

import SwiftUI

enum PaceMainSection: String, CaseIterable, Identifiable {
    case conversations = "Conversations"
    case usage = "Usage"
    case permissions = "Permissions"
    case about = "About"

    var id: String { rawValue }

    var iconSystemName: String {
        switch self {
        case .conversations: return "bubble.left.and.bubble.right"
        case .usage: return "chart.bar"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

struct PaceMainView: View {
    let companionManager: CompanionManager
    @State private var selectedSection: PaceMainSection? = .conversations

    var body: some View {
        NavigationSplitView {
            List(PaceMainSection.allCases, selection: $selectedSection) { section in
                NavigationLink(value: section) {
                    Label(section.rawValue, systemImage: section.iconSystemName)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            switch selectedSection ?? .conversations {
            case .conversations:
                PaceConversationsView()
            case .usage:
                PaceUsageAnalyticsView()
            case .permissions:
                PacePermissionsView(companionManager: companionManager)
            case .about:
                PaceAboutView()
            }
        }
    }
}

// MARK: - Permissions (live grant state, no system prompts)

struct PacePermissionsView: View {
    let companionManager: CompanionManager
    @ObservedObject private var permissionService = PacePermissionService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.system(size: 22, weight: .semibold))
            Text("Pace's permission state reflects live macOS values. If a row shows Granted, you're set — no relaunch needed.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                ForEach(PacePermissionKind.allCases, id: \.rawValue) { kind in
                    permissionRow(kind: kind)
                    Divider().opacity(0.25)
                }
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func permissionRow(kind: PacePermissionKind) -> some View {
        let isGranted = permissionService.isGranted(kind)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(humanName(kind))
                    .font(.system(size: 14, weight: .medium))
                Text(humanDescription(kind))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .semibold))
            } else {
                Button("Open Settings") {
                    openSettings(for: kind)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 10)
    }

    private func humanName(_ kind: PacePermissionKind) -> String {
        switch kind {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        }
    }

    private func humanDescription(_ kind: PacePermissionKind) -> String {
        switch kind {
        case .accessibility: return "Needed for clicks, key presses, and reading focused UI."
        case .screenRecording: return "Needed to see the screen when you ask questions about it."
        case .microphone: return "Needed for push-to-talk voice input."
        case .camera: return "Optional. Only used when posture watch is enabled."
        case .calendar: return "Optional. Only used when you ask Pace to read or create events."
        case .reminders: return "Optional. Only used when you ask Pace to create reminders."
        case .contacts: return "Optional. Only used to resolve names into email addresses for drafts."
        }
    }

    private func openSettings(for kind: PacePermissionKind) {
        let urlString: String
        switch kind {
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .camera:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case .calendar:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        case .reminders:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        case .contacts:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - About

struct PaceAboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Pace")
                .font(.system(size: 32, weight: .semibold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text("Local-only macOS voice companion.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
