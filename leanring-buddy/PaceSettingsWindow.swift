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
    case mcp = "MCP"
    case permissions = "Permissions"
    case voice = "Voice"
    case cloudBridge = "Cloud bridge"
    case flows = "Flows"
    case activity = "Activity"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .general:
            return "switch.2"
        case .planner:
            return "brain.head.profile"
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
        case .activity:
            return "list.bullet.rectangle"
        }
    }
}

struct PaceSettingsWindowView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var selectedTab: PaceSettingsTab = .general
    @State private var configuredMCPServerNames: [String] = PaceMCPServerRegistry.loadConfiguredServers().keys.sorted()
    /// Reachability result from `GET /health` on the bridge endpoint.
    /// nil = not yet checked, true = reachable, false = unreachable.
    @State private var cloudBridgeIsReachable: Bool? = nil
    @State private var cloudBridgeReachabilityLastCheckedAt: Date? = nil

    // MARK: - Direct API tier state

    /// Buffered API-key text field input. Cleared after Save so the key
    /// is never held in SwiftUI state longer than necessary.
    @State private var directAPIKeyEntryFieldText: String = ""
    /// Outcome of the last "Test" round trip. nil = not yet tested.
    @State private var lastDirectAPITestOutcomeText: String? = nil
    @State private var lastDirectAPITestWasSuccessful: Bool = false
    @State private var isDirectAPITestInFlight: Bool = false
    /// Snapshot of which providers currently have a key stored in
    /// Keychain. Refreshed on view appear and after every save/delete.
    @State private var providersWithStoredDirectAPIKeys: Set<PaceDirectAPIProvider> = []

    // MARK: - Thread memory state
    //
    // These mirror `PaceUserPreferencesStore` values so the picker /
    // toggles can update immediately. The `setX` calls write through
    // to UserDefaults; the new value takes effect on the next
    // `CompanionManager.start()` (which is fine for an end-of-PRD-V1
    // surface — the picker is a setup-time control, not a per-turn
    // control).

    @State private var isThreadMemoryEnabledForSettings: Bool = PaceUserPreferencesStore
        .bool(.isThreadMemoryEnabled, default: true)
    @State private var threadMemoryVerbatimWindowSizeForSettings: Int = PaceUserPreferencesStore
        .clampedInt(.threadMemoryVerbatimWindowSize, default: 4, in: 1...8)
    @State private var threadMemoryIdleMinutesForSettings: Int = PaceUserPreferencesStore
        .clampedInt(.threadMemoryIdleMinutes, default: 20, in: 5...60)
    @State private var isThreadMemoryDebugViewEnabledForSettings: Bool = PaceUserPreferencesStore
        .bool(.isThreadMemoryDebugViewEnabled, default: false)
    @State private var isThreadEndingEpisodicHandoffEnabledForSettings: Bool = PaceUserPreferencesStore
        .bool(.isThreadEndingEpisodicHandoffEnabled, default: false)
    /// Tick value used to force a redraw of the debug summary text
    /// when the user clicks "Reset thread now". The summary itself is
    /// pulled from `companionManager.currentThreadMemorySummarySnapshot()`
    /// on each render.
    @State private var threadMemoryRefreshTick: Int = 0

    // MARK: - Recipe library state
    //
    // The bundled recipes are loaded once on view appear; the
    // installed-set is recomputed from `PaceFlowStore` whenever the
    // refresh tick changes (after install/uninstall) so the row
    // buttons can flip between "Install" and "Installed · Uninstall".

    @State private var bundledRecipesForSettings: [PaceBundledRecipe] = []
    @State private var installedRecipeSlugsForSettings: Set<String> = []
    @State private var recipeLibraryRefreshTick: Int = 0
    @State private var lastRecipeActionMessage: String? = nil

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
                case .planner:
                    plannerContent
                case .mcp:
                    mcpContent
                case .permissions:
                    permissionsContent
                case .voice:
                    voiceContent
                case .cloudBridge:
                    cloudBridgeContent
                case .flows:
                    flowsContent
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
            settingsToggleRow(
                title: "Always listening",
                subtitle: "Opt-in ambient command mode. Push-to-talk remains available.",
                isOn: Binding(
                    get: { companionManager.isAlwaysListeningEnabled },
                    set: { companionManager.setAlwaysListeningEnabled($0) }
                )
            )
            settingsToggleRow(
                title: "Focus nudges",
                subtitle: "Offer a short break prompt after long active foreground sessions.",
                isOn: Binding(
                    get: { companionManager.areFocusFatigueNudgesEnabled },
                    set: { companionManager.setFocusFatigueNudgesEnabled($0) }
                )
            )
            settingsToggleRow(
                title: "Calendar nudges",
                subtitle: "Opt-in five-minute lead-time prompts for meeting-like events.",
                isOn: Binding(
                    get: { companionManager.areCalendarNudgesEnabled },
                    set: { companionManager.setCalendarNudgesEnabled($0) }
                )
            )
            settingsToggleRow(
                title: "Watch observation nudges",
                subtitle: "Opt-in prompts when watch mode sees local error/build-failure cues.",
                isOn: Binding(
                    get: { companionManager.areWatchObservationNudgesEnabled },
                    set: { companionManager.setWatchObservationNudgesEnabled($0) }
                )
            )
            settingsToggleRow(
                title: "Posture watch (camera)",
                subtitle: companionManager.latestPostureStatus
                    ?? "Gentle spoken nudge when you slouch or lean in. One camera frame every ten seconds, analyzed on-device, never stored.",
                isOn: Binding(
                    get: { companionManager.isPostureWatchEnabled },
                    set: { companionManager.setPostureWatchEnabled($0) }
                )
            )
            if companionManager.isPostureWatchEnabled {
                HStack {
                    Spacer()
                    settingsButton("Recalibrate posture", systemName: "figure.seated.side") {
                        companionManager.recalibratePostureWatch()
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    // MARK: - Planner tab

    /// Settings → Planner: the single user-facing tier picker (Local /
    /// CLI bridge / Direct API / Apple FM) plus the Direct-API
    /// configuration sub-panel. See planner-tier-picker.md.
    private var plannerContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            plannerTierPickerSection
            Divider().background(DS.Colors.borderSubtle)
            plannerActiveTierConfigurationSection
        }
        .onAppear {
            refreshProvidersWithStoredDirectAPIKeys()
        }
    }

    private var plannerTierPickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Backend tier")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            VStack(spacing: 0) {
                ForEach(PacePlannerTier.allCases, id: \.rawValue) { plannerTier in
                    plannerTierRow(plannerTier)
                }
            }
        }
    }

    private func plannerTierRow(_ plannerTier: PacePlannerTier) -> some View {
        let (tierTitle, tierSubtitle) = plannerTierLabels(for: plannerTier)
        let isSelected = companionManager.activePlannerTier == plannerTier
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tierTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(tierSubtitle)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(DS.Colors.accent)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            guard companionManager.activePlannerTier != plannerTier else { return }
            handlePlannerTierTap(plannerTier)
        }
        .overlay(alignment: .bottom) {
            Divider().background(DS.Colors.borderSubtle)
        }
    }

    private func plannerTierLabels(for plannerTier: PacePlannerTier) -> (title: String, subtitle: String) {
        switch plannerTier {
        case .local:
            return (
                "Local — LM Studio",
                "On-device reasoner (gemma-3-12b by default). Free. Nothing leaves your Mac."
            )
        case .cliBridge:
            return (
                "CLI bridge",
                "Routes turns through your already-authenticated Claude Code / Codex / Gemini CLI via localhost:3456. Free if you already pay for the CLI."
            )
        case .directAPI:
            return (
                "Direct API (BYO key)",
                "Pace calls Anthropic / OpenAI / OpenRouter directly using a key you paste below. Stored in macOS Keychain only — never in Pace preferences."
            )
        case .appleFoundationModels:
            return (
                "Apple Foundation Models only",
                "Apple's on-device 3B model as the sole planner. Requires Apple Intelligence enabled."
            )
        }
    }

    private func handlePlannerTierTap(_ newPlannerTier: PacePlannerTier) {
        switch newPlannerTier {
        case .local, .appleFoundationModels:
            companionManager.setActivePlannerTier(newPlannerTier)
        case .cliBridge:
            // First-time enablement still goes through the existing
            // NSAlert consent dialog. Rejection reverts to local.
            let consentAccepted = companionManager.requestCloudBridgeConsentIfNeeded()
            guard consentAccepted else {
                companionManager.setActivePlannerTier(.local)
                return
            }
            // If the saved bridge mode is .off (default after first
            // consent), promote it to hybrid so the user immediately
            // benefits from the tier they just picked.
            if companionManager.cloudBridgeMode == .off {
                companionManager.setCloudBridgeMode(.hybrid)
            }
            companionManager.setActivePlannerTier(newPlannerTier)
        case .directAPI:
            // No NSAlert here — the explicit pick is the consent. The
            // sub-panel below requires Save Key + (optionally) Test
            // before turns actually route to the provider.
            companionManager.setActivePlannerTier(newPlannerTier)
        }
    }

    @ViewBuilder
    private var plannerActiveTierConfigurationSection: some View {
        switch companionManager.activePlannerTier {
        case .local:
            plannerLocalDetailPanel
        case .cliBridge:
            plannerCLIBridgeDetailPanel
        case .directAPI:
            plannerDirectAPIDetailPanel
        case .appleFoundationModels:
            plannerAppleFoundationModelsDetailPanel
        }
    }

    private var plannerLocalDetailPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LM Studio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            HStack(spacing: 8) {
                Circle()
                    .fill(companionManager.isLMStudioReachable ? DS.Colors.success : DS.Colors.warning)
                    .frame(width: 8, height: 8)
                Text(companionManager.isLMStudioReachable ? "Reachable" : "Not reachable — open LM Studio and load the configured model.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
            }
            Text("Default model: google/gemma-3-12b. Configure model name via Info.plist key LocalPlannerModelIdentifier.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private var plannerCLIBridgeDetailPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLI bridge")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Configure the upstream CLI, model, and consent in the Cloud bridge tab. This tier reuses that configuration.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
            Text("Active mode: \(companionManager.cloudBridgeMode.rawValue)  •  Upstream: \(companionManager.cloudBridgeUpstream.displayLabel)  •  Model: \(companionManager.cloudBridgeModel)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private var plannerAppleFoundationModelsDetailPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Foundation Models")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Free, on-device. Requires Apple Intelligence to be enabled in System Settings.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
            settingsButton("Open Apple Intelligence settings", systemName: "apple.logo") {
                if let appleIntelligenceURL = URL(string: "x-apple.systempreferences:com.apple.AppleIntelligence-Settings.extension") {
                    NSWorkspace.shared.open(appleIntelligenceURL)
                }
            }
        }
    }

    private var plannerDirectAPIDetailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Provider picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Provider")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Picker("", selection: Binding(
                    get: { companionManager.directAPIProvider },
                    set: { newProvider in
                        companionManager.setDirectAPIProvider(newProvider)
                        // Clear the test outcome — provider switch invalidates it.
                        lastDirectAPITestOutcomeText = nil
                    }
                )) {
                    ForEach(PaceDirectAPIProvider.allCases, id: \.rawValue) { directAPIProvider in
                        let storedKeyIndicator = providersWithStoredDirectAPIKeys.contains(directAPIProvider) ? " ✓" : ""
                        Text(directAPIProvider.displayLabel + storedKeyIndicator).tag(directAPIProvider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            // API key field + Save/Delete buttons
            VStack(alignment: .leading, spacing: 6) {
                Text("API key")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                SecureField("Paste your \(companionManager.directAPIProvider.displayLabel) API key", text: $directAPIKeyEntryFieldText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                HStack(spacing: 10) {
                    let entryFieldTextTrimmed = directAPIKeyEntryFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
                    settingsButton("Save key", systemName: "key.fill") {
                        guard !entryFieldTextTrimmed.isEmpty else { return }
                        let didStore = companionManager.saveDirectAPIKey(
                            entryFieldTextTrimmed,
                            for: companionManager.directAPIProvider
                        )
                        if didStore {
                            directAPIKeyEntryFieldText = ""
                            refreshProvidersWithStoredDirectAPIKeys()
                            lastDirectAPITestOutcomeText = nil
                        }
                    }
                    .disabled(entryFieldTextTrimmed.isEmpty)
                    .opacity(entryFieldTextTrimmed.isEmpty ? 0.45 : 1)

                    settingsButton("Delete key", systemName: "trash") {
                        _ = companionManager.deleteDirectAPIKey(for: companionManager.directAPIProvider)
                        refreshProvidersWithStoredDirectAPIKeys()
                        lastDirectAPITestOutcomeText = nil
                    }
                    .disabled(!providersWithStoredDirectAPIKeys.contains(companionManager.directAPIProvider))
                    .opacity(providersWithStoredDirectAPIKeys.contains(companionManager.directAPIProvider) ? 1 : 0.45)
                }
                Text("Keys are stored in macOS Keychain (service com.pace.app.plannerAPIKeys). They never sync via iCloud and never touch UserDefaults, Info.plist, or any log.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Model identifier text field
            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                TextField(
                    companionManager.directAPIProvider.defaultModelIdentifier,
                    text: Binding(
                        get: { companionManager.directAPIModelIdentifier },
                        set: { companionManager.setDirectAPIModelIdentifier($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            }

            // Custom endpoint URL (only when provider == .custom)
            if companionManager.directAPIProvider == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Endpoint URL")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                    TextField(
                        "https://example.com/v1/chat/completions",
                        text: Binding(
                            get: { companionManager.directAPICustomEndpointURLString },
                            set: { companionManager.setDirectAPICustomEndpointURLString($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    Text("Must be https. http is only accepted for loopback hosts (local OpenAI-compatible proxies).")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            // Fall-back-on-failure toggle (default OFF per PRD)
            settingsToggleRow(
                title: "Fall back to local on cloud failure",
                subtitle: "Off by default. When on, Pace silently retries failed Direct-API turns against LM Studio. When off, errors surface verbatim so you know what happened.",
                isOn: Binding(
                    get: { companionManager.directAPIFallsBackToLocalOnCloudFailure },
                    set: { companionManager.setDirectAPIFallsBackToLocalOnCloudFailure($0) }
                )
            )

            // Test round-trip button + last outcome row
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    settingsButton(isDirectAPITestInFlight ? "Testing…" : "Test", systemName: "bolt.fill") {
                        runDirectAPITest()
                    }
                    .disabled(
                        isDirectAPITestInFlight
                        || !providersWithStoredDirectAPIKeys.contains(companionManager.directAPIProvider)
                    )
                    .opacity(
                        (isDirectAPITestInFlight
                         || !providersWithStoredDirectAPIKeys.contains(companionManager.directAPIProvider))
                        ? 0.45 : 1
                    )

                    if let lastOutcomeText = lastDirectAPITestOutcomeText {
                        HStack(spacing: 6) {
                            Image(systemName: lastDirectAPITestWasSuccessful ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundColor(lastDirectAPITestWasSuccessful ? DS.Colors.success : DS.Colors.warning)
                            Text(lastOutcomeText)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer()
                }
                if !providersWithStoredDirectAPIKeys.contains(companionManager.directAPIProvider) {
                    Text("Save an API key for \(companionManager.directAPIProvider.displayLabel) to enable the round-trip test.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warning)
                }
            }
        }
    }

    private func refreshProvidersWithStoredDirectAPIKeys() {
        providersWithStoredDirectAPIKeys = companionManager.providersWithStoredDirectAPIKeys()
    }

    private func runDirectAPITest() {
        isDirectAPITestInFlight = true
        lastDirectAPITestOutcomeText = nil
        Task { @MainActor in
            let testOutcome = await companionManager.runDirectAPITestRoundTrip()
            switch testOutcome {
            case .success(let echoedModelResponse):
                lastDirectAPITestWasSuccessful = true
                lastDirectAPITestOutcomeText = echoedModelResponse.isEmpty
                    ? "OK (empty response)"
                    : echoedModelResponse
            case .failure(let testError):
                lastDirectAPITestWasSuccessful = false
                lastDirectAPITestOutcomeText = testError.localizedDescription
            }
            isDirectAPITestInFlight = false
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
                    Text("No MCP servers configured yet. Create / Open seeds apple-mcp (Contacts, Notes, Messages, Mail, Reminders, Calendar, Maps); add any other MCP server by editing the same config file.")
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

    private var cloudBridgeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Explanation banner
            VStack(alignment: .leading, spacing: 6) {
                Text("Opt-in only. Default is Off.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("The cloud bridge routes turns through the local-ai Node server at localhost:3456, which spawns your already-authenticated CLI tool and contacts its cloud provider. This is the only intentional break of Pace's on-device-only principle. First enablement shows a consent dialog.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(DS.Colors.borderSubtle)

            // Mode picker
            VStack(spacing: 0) {
                let canEnableAlwaysBridge = PaceCloudBridgeConsent.canEnableAlwaysBridge(now: Date())

                ForEach(PaceCloudBridgeMode.allCases, id: \.rawValue) { mode in
                    let modeDisplayName: String = {
                        switch mode {
                        case .off:          return "Off (local only)"
                        case .hybrid:       return "Hybrid (bridge for complex turns)"
                        case .alwaysBridge: return "Always bridge"
                        }
                    }()
                    let modeSubtitle: String = {
                        switch mode {
                        case .off:
                            return "Default. No bridge code runs."
                        case .hybrid:
                            return "Bridge handles turns your local planner would refuse. Local planner stays for everything else."
                        case .alwaysBridge:
                            return canEnableAlwaysBridge
                                ? "Every planner call routes through the bridge."
                                : "Available after 24 hours of Hybrid usage."
                        }
                    }()
                    let isDisabled = mode == .alwaysBridge && !canEnableAlwaysBridge

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(modeDisplayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(isDisabled ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                            Text(modeSubtitle)
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        Spacer()
                        if companionManager.cloudBridgeMode == mode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(DS.Colors.accent)
                        }
                    }
                    .padding(.vertical, 12)
                    .opacity(isDisabled ? 0.5 : 1.0)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isDisabled else { return }
                        guard mode != companionManager.cloudBridgeMode else { return }

                        if mode != .off {
                            let consentAccepted = companionManager.requestCloudBridgeConsentIfNeeded()
                            guard consentAccepted else {
                                // User rejected consent — revert mode to off.
                                companionManager.setCloudBridgeMode(.off)
                                return
                            }
                        }
                        companionManager.setCloudBridgeMode(mode)
                    }
                    .overlay(alignment: .bottom) {
                        Divider().background(DS.Colors.borderSubtle)
                    }
                }
            }

            Divider().background(DS.Colors.borderSubtle)

            // Upstream picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Upstream CLI")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                Picker("", selection: Binding(
                    get: { companionManager.cloudBridgeUpstream },
                    set: { companionManager.setCloudBridgeUpstream($0) }
                )) {
                    ForEach(PaceCloudBridgeUpstream.allCases, id: \.rawValue) { upstream in
                        Text(upstream.displayLabel).tag(upstream)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            // Model text field
            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                let modelPlaceholder: String = {
                    switch companionManager.cloudBridgeUpstream {
                    case .claude:  return "sonnet"
                    case .codex:   return "gpt-4-1106-preview"
                    case .gemini:  return "gemini-2.0-flash"
                    }
                }()

                TextField(modelPlaceholder, text: Binding(
                    get: { companionManager.cloudBridgeModel },
                    set: { companionManager.setCloudBridgeModel($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            }

            // Bridge URL (read-only)
            let bridgeURLString = PaceCloudBridgeConsent.loadConfiguration().baseURL.absoluteString
            VStack(alignment: .leading, spacing: 4) {
                Text("Bridge URL")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(bridgeURLString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textSelection(.enabled)
                Text("Set via Info.plist key CloudBridgeBaseURL. Must be loopback.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            // Reachability row
            HStack(spacing: 10) {
                Group {
                    if let isReachable = cloudBridgeIsReachable {
                        Circle()
                            .fill(isReachable ? DS.Colors.success : DS.Colors.warning)
                            .frame(width: 8, height: 8)
                        Text(isReachable ? "Bridge reachable" : "Bridge not reachable")
                            .font(.system(size: 12))
                            .foregroundColor(isReachable ? DS.Colors.success : DS.Colors.warning)
                    } else {
                        Circle()
                            .fill(DS.Colors.textTertiary)
                            .frame(width: 8, height: 8)
                        Text("Not checked yet")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }

                if let checkedAt = cloudBridgeReachabilityLastCheckedAt {
                    Text("(\(checkedAt.formatted(date: .omitted, time: .shortened)))")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()
                settingsButton("Check", systemName: "arrow.clockwise") {
                    checkCloudBridgeReachability()
                }
            }

            Divider().background(DS.Colors.borderSubtle)

            // Revoke consent
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Revoke consent")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Clears all bridge state, resets mode to Off.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                settingsButton("Revoke", systemName: "xmark.circle") {
                    PaceCloudBridgeConsent.revokeConsentAndResetAllBridgeState()
                    companionManager.setCloudBridgeMode(.off)
                }
            }
            .padding(.vertical, 8)
        }
        .onAppear {
            checkCloudBridgeReachability()
        }
    }

    private func checkCloudBridgeReachability() {
        let bridgeConfiguration = PaceCloudBridgeConsent.loadConfiguration()
        let healthURL = bridgeConfiguration.baseURL.appendingPathComponent("health")

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(from: healthURL)
                let httpStatusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                cloudBridgeIsReachable = (200...299).contains(httpStatusCode)
            } catch {
                cloudBridgeIsReachable = false
            }
            cloudBridgeReachabilityLastCheckedAt = Date()
        }
    }

    /// Thread summary subsection. Rendered ABOVE the existing
    /// episodic / local memory subsection per PRD. Defaults are ON
    /// for the master switch, OFF for the debug view + the episodic
    /// handoff. The handoff stays default-OFF because the summarizer
    /// is loose; the episodic extractor is precise; coupling them
    /// risks low-confidence facts.
    private var threadSummarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Thread summary")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            Text("Pace keeps the last few turns verbatim and rolls everything older into a one-paragraph summary so it stays coherent across a long conversation. This conversation only — never saved to disk.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $isThreadMemoryEnabledForSettings) {
                Text("Remember this conversation")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .toggleStyle(.switch)
            .onChange(of: isThreadMemoryEnabledForSettings) { _, newValue in
                PaceUserPreferencesStore.setBool(newValue, for: .isThreadMemoryEnabled)
                if !newValue {
                    companionManager.resetThreadMemoryNow()
                    threadMemoryRefreshTick &+= 1
                }
            }

            HStack(spacing: 12) {
                Text("Verbatim window")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                Picker("", selection: $threadMemoryVerbatimWindowSizeForSettings) {
                    ForEach(1...8, id: \.self) { turnPairCount in
                        Text("\(turnPairCount) turn pair\(turnPairCount == 1 ? "" : "s")")
                            .tag(turnPairCount)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .onChange(of: threadMemoryVerbatimWindowSizeForSettings) { _, newValue in
                    PaceUserPreferencesStore.setInt(newValue, for: .threadMemoryVerbatimWindowSize)
                }
            }
            .help("How much exact context the planner sees before falling back to a summary.")

            HStack(spacing: 12) {
                Text("Idle threshold")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                Picker("", selection: $threadMemoryIdleMinutesForSettings) {
                    ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { idleMinutes in
                        Text("\(idleMinutes) minutes").tag(idleMinutes)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .onChange(of: threadMemoryIdleMinutesForSettings) { _, newValue in
                    PaceUserPreferencesStore.setInt(newValue, for: .threadMemoryIdleMinutes)
                }
            }

            settingsButton("Reset thread now", systemName: "arrow.counterclockwise") {
                companionManager.resetThreadMemoryNow()
                threadMemoryRefreshTick &+= 1
            }

            Toggle(isOn: $isThreadMemoryDebugViewEnabledForSettings) {
                Text("Show current summary")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .toggleStyle(.switch)
            .onChange(of: isThreadMemoryDebugViewEnabledForSettings) { _, newValue in
                PaceUserPreferencesStore.setBool(newValue, for: .isThreadMemoryDebugViewEnabled)
            }

            if isThreadMemoryDebugViewEnabledForSettings {
                let snapshot = companionManager.currentThreadMemorySummarySnapshot()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Summary version: \(snapshot.summaryVersion)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(snapshot.summaryText ?? "(no summary yet — verbatim window covers the whole session)")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(threadMemoryRefreshTick)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.borderSubtle.opacity(0.25))
                .cornerRadius(6)
            }

            Toggle(isOn: $isThreadEndingEpisodicHandoffEnabledForSettings) {
                Text("On session end, share summary with episodic memory")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .toggleStyle(.switch)
            .onChange(of: isThreadEndingEpisodicHandoffEnabledForSettings) { _, newValue in
                PaceUserPreferencesStore.setBool(newValue, for: .isThreadEndingEpisodicHandoffEnabled)
            }
            .help("Default off. When on, the final summary is offered to the episodic extractor — the extractor decides whether anything is durable enough to keep.")
        }
    }

    private var flowsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recipe library")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("One-click flows Pace ships out of the box. Install adds them to your saved flows; run them by name.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let lastRecipeActionMessage {
                    Text(lastRecipeActionMessage)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(bundledRecipesForSettings, id: \.slug) { bundledRecipe in
                        recipeLibraryRow(bundledRecipe)
                    }
                }
                .id(recipeLibraryRefreshTick)
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: 8) {
                Text("Saved flows")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Flows you've recorded, plus any recipes installed above. Use \"do <name>\" to run.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                savedFlowsList
            }
        }
        .onAppear {
            reloadRecipeLibrary()
        }
    }

    private func recipeLibraryRow(_ bundledRecipe: PaceBundledRecipe) -> some View {
        let isAlreadyInstalled = installedRecipeSlugsForSettings.contains(bundledRecipe.slug)
        let missingPreferenceKeys = bundledRecipe.requiredPreferences.filter { requiredPreferenceKey in
            guard let resolvedKey = PaceLocalMemoryKey(rawValue: requiredPreferenceKey) else {
                return true
            }
            return PaceLocalMemoryStore.string(for: resolvedKey) == nil
        }
        let canInstallNow = missingPreferenceKeys.isEmpty

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(bundledRecipe.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(bundledRecipe.description)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if !canInstallNow {
                    Text("Set \(missingPreferenceKeys.joined(separator: ", ")) in preferences first.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warning)
                }
            }
            Spacer()
            if isAlreadyInstalled {
                settingsButton("Uninstall", systemName: "minus.circle") {
                    uninstallRecipeFromSettings(bundledRecipe)
                }
            } else {
                settingsButton("Install", systemName: "plus.circle") {
                    installRecipeFromSettings(bundledRecipe)
                }
                .disabled(!canInstallNow)
                .opacity(canInstallNow ? 1 : 0.45)
                .help(canInstallNow
                      ? "Save this recipe into your flows."
                      : "Missing preference: \(missingPreferenceKeys.joined(separator: ", "))")
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
                .background(DS.Colors.borderSubtle)
        }
    }

    private var savedFlowsList: some View {
        let savedFlows = PaceFlowStore().listAll()
        return Group {
            if savedFlows.isEmpty {
                Text("No saved flows yet.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(savedFlows) { savedFlow in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(savedFlow.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(DS.Colors.textPrimary)
                                Text("\(savedFlow.steps.count) steps")
                                    .font(.system(size: 12))
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            Divider()
                                .background(DS.Colors.borderSubtle)
                        }
                    }
                }
            }
        }
        .id(recipeLibraryRefreshTick)
    }

    private func reloadRecipeLibrary() {
        bundledRecipesForSettings = PaceRecipeLibrary.loadBundledRecipes()
        recomputeInstalledRecipeSlugs()
    }

    private func recomputeInstalledRecipeSlugs() {
        let flowStore = PaceFlowStore()
        let installedSlugs = bundledRecipesForSettings
            .filter { PaceRecipeLibrary.isInstalled($0, in: flowStore) }
            .map { $0.slug }
        installedRecipeSlugsForSettings = Set(installedSlugs)
    }

    private func installRecipeFromSettings(_ bundledRecipe: PaceBundledRecipe) {
        do {
            try PaceRecipeLibrary.install(bundledRecipe, into: PaceFlowStore())
            lastRecipeActionMessage = "Installed \(bundledRecipe.name)."
        } catch PaceRecipeInstallError.missingRequiredPreference(let requiredPreferenceKey) {
            lastRecipeActionMessage = "Set \(requiredPreferenceKey) in preferences before installing."
        } catch PaceRecipeInstallError.alreadyInstalled {
            lastRecipeActionMessage = "\(bundledRecipe.name) is already installed."
        } catch {
            lastRecipeActionMessage = "Couldn't install \(bundledRecipe.name)."
        }
        recomputeInstalledRecipeSlugs()
        recipeLibraryRefreshTick &+= 1
    }

    private func uninstallRecipeFromSettings(_ bundledRecipe: PaceBundledRecipe) {
        PaceRecipeLibrary.uninstall(slug: bundledRecipe.slug, from: PaceFlowStore())
        lastRecipeActionMessage = "Removed \(bundledRecipe.name)."
        recomputeInstalledRecipeSlugs()
        recipeLibraryRefreshTick &+= 1
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            threadSummarySection

            Divider()
                .background(DS.Colors.borderSubtle)

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

    private static let defaultMCPConfigText = PaceMCPServerRegistry.starterConfigurationJSON
}
