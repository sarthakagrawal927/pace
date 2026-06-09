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
    case mcp = "MCP"
    case permissions = "Permissions"
    case voice = "Voice"
    case activity = "Activity"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .general:
            return "switch.2"
        case .mcp:
            return "point.3.connected.trianglepath.dotted"
        case .permissions:
            return "lock.shield"
        case .voice:
            return "waveform"
        case .activity:
            return "list.bullet.rectangle"
        }
    }
}

struct PaceSettingsWindowView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var selectedTab: PaceSettingsTab = .general
    @State private var configuredMCPServerNames: [String] = PaceMCPServerRegistry.loadConfiguredServers().keys.sorted()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
                .background(DS.Colors.borderSubtle)
            content
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(DS.Colors.background)
        .onAppear {
            refreshMCPServerNames()
        }
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
                    generalContent
                case .mcp:
                    mcpContent
                case .permissions:
                    permissionsContent
                case .voice:
                    voiceContent
                case .activity:
                    activityContent
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

    private var generalContent: some View {
        VStack(spacing: 0) {
            settingsToggleRow(
                title: "Read my screen",
                subtitle: "Use local screen context when a turn needs it.",
                isOn: Binding(
                    get: { companionManager.useLocalVLMForScreenContext },
                    set: { companionManager.setUseLocalVLMForScreenContext($0) }
                )
            )
            settingsToggleRow(
                title: "Approve risky actions",
                subtitle: "Ask before non-undoable local changes, message drafts, shortcuts, and MCP calls.",
                isOn: Binding(
                    get: { companionManager.requiresActionApproval },
                    set: { companionManager.setRequiresActionApproval($0) }
                )
            )
            settingsToggleRow(
                title: "Cursor annotations",
                subtitle: "Show transcript, response, and pointer labels near the cursor.",
                isOn: Binding(
                    get: { companionManager.areCursorAnnotationsEnabled },
                    set: { companionManager.setCursorAnnotationsEnabled($0) }
                )
            )
            settingsToggleRow(
                title: "Watch mode",
                subtitle: companionManager.latestWatchModeSummary ?? "Watch for meaningful screen changes.",
                isOn: Binding(
                    get: { companionManager.isWatchModeEnabled },
                    set: { companionManager.setWatchModeEnabled($0) }
                )
            )
        }
    }

    private var mcpContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Config file")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(PaceMCPServerRegistry.configurationPaths[0].path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                settingsButton("Create / Open", systemName: "doc.badge.gearshape") {
                    createMCPConfigIfNeeded()
                    openPrimaryMCPConfig()
                    refreshMCPServerNames()
                }
                settingsButton("Reveal", systemName: "folder") {
                    createMCPConfigIfNeeded()
                    NSWorkspace.shared.activateFileViewerSelecting([PaceMCPServerRegistry.configurationPaths[0]])
                    refreshMCPServerNames()
                }
                settingsButton("Refresh", systemName: "arrow.clockwise") {
                    refreshMCPServerNames()
                }
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: 8) {
                Text("Configured servers")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                if configuredMCPServerNames.isEmpty {
                    Text("No MCP servers configured yet. Start with Altic MCP or AirMCP, then add its command to the config file.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(configuredMCPServerNames, id: \.self) { serverName in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(DS.Colors.success)
                                .frame(width: 7, height: 7)
                            Text(serverName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var permissionsContent: some View {
        VStack(spacing: 0) {
            permissionRow(
                title: "Accessibility",
                subtitle: "Needed for clicks, keys, and AX targeting.",
                isGranted: companionManager.hasAccessibilityPermission,
                actionTitle: "Grant",
                action: { _ = WindowPositionManager.requestAccessibilityPermission() }
            )
            permissionRow(
                title: "Screen Recording",
                subtitle: "Needed for screenshots and watch mode.",
                isGranted: companionManager.hasScreenRecordingPermission,
                actionTitle: "Grant",
                action: { _ = WindowPositionManager.requestScreenRecordingPermission() }
            )
            permissionRow(
                title: "Screen Content",
                subtitle: "Needed to enumerate displays before screenshots.",
                isGranted: companionManager.hasScreenContentPermission,
                actionTitle: "Grant",
                action: companionManager.requestScreenContentPermission
            )
            permissionRow(
                title: "Microphone",
                subtitle: "Needed for push-to-talk.",
                isGranted: companionManager.hasMicrophonePermission,
                actionTitle: "Open",
                action: openMicrophoneSettings
            )
            permissionRow(
                title: "Speech Recognition",
                subtitle: "On-device transcription.",
                isGranted: companionManager.hasSpeechRecognitionPermission,
                actionTitle: "Grant",
                action: companionManager.requestSpeechRecognitionPermission
            )
            permissionRow(
                title: "Calendar",
                subtitle: "Needed only for calendar tools.",
                isGranted: companionManager.hasCalendarPermission,
                actionTitle: "Grant",
                action: companionManager.requestCalendarPermission
            )
            permissionRow(
                title: "Reminders",
                subtitle: "Needed only for reminder tools.",
                isGranted: companionManager.hasRemindersPermission,
                actionTitle: "Grant",
                action: companionManager.requestRemindersPermission
            )
            permissionRow(
                title: "Automation",
                subtitle: "Per-app prompts for Notes, Music, Mail, Things, Shortcuts, and MCP servers.",
                isGranted: false,
                actionTitle: "Open",
                action: WindowPositionManager.openAutomationSettings
            )
        }
    }

    private var voiceContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            infoRow(title: "Transcription", value: companionManager.buddyDictationManager.transcriptionProviderDisplayName)
            infoRow(title: "Transcription model", value: companionManager.isTranscriptionModelReady ? "Ready" : "Loading")
            infoRow(title: "Active voice", value: companionManager.activeTTSVoiceSummary.displayText)
            if companionManager.activeTTSVoiceSummary.needsUpgrade {
                Text(companionManager.activeTTSVoiceSummary.recommendationText)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            settingsButton("Open Spoken Content", systemName: "speaker.wave.2") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Local memory")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(companionManager.localMemorySummary)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(companionManager.localRetrievalSummary)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                settingsButton("Reset Retrieval", systemName: "arrow.counterclockwise") {
                    companionManager.resetLocalRetrievalIndex()
                }

                localRetrievalFileRootsSection

                VStack(alignment: .leading, spacing: 0) {
                    Text("Retrieval sources")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.top, 8)

                    ForEach(PaceRetrievalSource.allCases, id: \.rawValue) { source in
                        retrievalSourceToggleRow(source)
                    }
                }
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent actions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                if companionManager.recentActionResults.isEmpty {
                    Text("No approved actions yet.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                } else {
                    ForEach(companionManager.recentActionResults.prefix(8)) { actionResult in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(actionResult.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text(actionResult.detail)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                                .lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    }
                }
            }
        }
    }

    private var localRetrievalFileRootsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("File folders")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                settingsButton("Add Folder", systemName: "folder.badge.plus") {
                    chooseLocalRetrievalFileRoots()
                }
                settingsButton("Clear", systemName: "xmark.circle") {
                    companionManager.clearLocalRetrievalFileRootPaths()
                }
                .disabled(companionManager.localRetrievalFileRootPaths.isEmpty)
                .opacity(companionManager.localRetrievalFileRootPaths.isEmpty ? 0.45 : 1)
            }

            if companionManager.localRetrievalFileRootPaths.isEmpty {
                Text("No folders selected. File retrieval will stay skipped unless roots are set in the app bundle.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(companionManager.localRetrievalFileRootPaths, id: \.self) { rootPath in
                        localRetrievalFileRootRow(rootPath)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func localRetrievalFileRootRow(_ rootPath: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.accent)
                .frame(width: 18)

            Text(rootPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer()

            Button {
                companionManager.removeLocalRetrievalFileRootPath(rootPath)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Remove folder")
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Divider()
                .background(DS.Colors.borderSubtle)
        }
    }

    private func settingsToggleRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Divider()
                .background(DS.Colors.borderSubtle)
        }
    }

    private func retrievalSourceToggleRow(_ source: PaceRetrievalSource) -> some View {
        let sourceStatus = companionManager.localRetrievalSourceStatuses.first { $0.source == source }
        let indexedDocumentCount = sourceStatus?.documentCount ?? 0
        let subtitle: String
        if let sourceStatus {
            if let lastError = sourceStatus.lastError {
                if sourceStatus.documentCount > 0 {
                    subtitle = "\(lastError) \(sourceStatus.documentCount) indexed locally."
                } else {
                    subtitle = lastError
                }
            } else {
                subtitle = "\(sourceStatus.documentCount) indexed"
            }
        } else {
            subtitle = "No local documents indexed"
        }

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(source.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                companionManager.clearLocalRetrievalSource(source)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(indexedDocumentCount > 0 ? DS.Colors.warning : DS.Colors.textTertiary)
                    .frame(width: 26, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(indexedDocumentCount > 0 ? 0.07 : 0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.7)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Clear indexed \(source.displayName.lowercased()) documents")
            .disabled(indexedDocumentCount == 0)
            .opacity(indexedDocumentCount == 0 ? 0.45 : 1)

            Toggle("", isOn: Binding(
                get: { companionManager.isLocalRetrievalSourceEnabled(source) },
                set: { companionManager.setLocalRetrievalSourceEnabled($0, for: source) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Divider()
                .background(DS.Colors.borderSubtle)
        }
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        isGranted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(isGranted ? DS.Colors.success : DS.Colors.warning)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            if isGranted {
                Text("Granted")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.success)
            } else {
                settingsButton(actionTitle, systemName: "arrow.up.right.square", action: action)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Divider()
                .background(DS.Colors.borderSubtle)
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
                .background(DS.Colors.borderSubtle)
        }
    }

    private func settingsButton(
        _ title: String,
        systemName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func refreshMCPServerNames() {
        configuredMCPServerNames = PaceMCPServerRegistry.loadConfiguredServers().keys.sorted()
    }

    private func createMCPConfigIfNeeded() {
        let configURL = PaceMCPServerRegistry.configurationPaths[0]
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }

        do {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.defaultMCPConfigText.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            print("⚠️ Pace Settings: could not create MCP config: \(error)")
        }
    }

    private func openPrimaryMCPConfig() {
        NSWorkspace.shared.open(PaceMCPServerRegistry.configurationPaths[0])
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func chooseLocalRetrievalFileRoots() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Add File Retrieval Folders"
        openPanel.prompt = "Add"
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = true
        openPanel.canCreateDirectories = false

        guard openPanel.runModal() == .OK else { return }
        companionManager.addLocalRetrievalFileRootURLs(openPanel.urls)
    }

    private static let defaultMCPConfigText = """
    {
      "mcpServers": {}
    }
    """
}
