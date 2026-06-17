//
//  PaceResearchSettingsTab.swift
//  leanring-buddy
//
//  Settings → Research tab content. Sibling to Settings → Planner but
//  scoped to research-class turns ("research X", "look into Y", "compare
//  A vs B"). The user picks an escalation tier — Off (default), CLI
//  bridge to Claude Code / Codex / Gemini, or Direct API to Anthropic
//  Opus — plus a step ceiling and a per-turn token-budget cap so a
//  runaway loop can't blow the bill.
//
//  When the tier is `.off`, research turns fall back to the existing
//  `.phoneLargeModel` route via PaceCloudBridgeConsent — zero behavior
//  change for users who haven't opted in.
//
//  Direct-API keys reuse `PaceKeychainStore` — the same Keychain entry
//  the main Direct API tier writes to — so a user with Opus configured
//  for their normal planner doesn't double-paste the key.
//

import AppKit
import SwiftUI

struct PaceResearchSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var researchConfiguration: PaceResearchTierConfiguration = PaceResearchTierStore.loadConfiguration()
    /// In-memory editing buffer for the Direct API key SecureField.
    /// Cleared after Save so the key is never held in SwiftUI state
    /// longer than necessary.
    @State private var directAPIKeyEntryFieldText: String = ""
    @State private var lastSaveFeedback: String?
    @State private var providersWithStoredDirectAPIKeys: Set<PaceDirectAPIProvider> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            researchTierIntroBanner
            tierPickerSection

            switch researchConfiguration.tier {
            case .off:
                EmptyView()
            case .cliBridge:
                cliBridgeConfigurationSection
            case .directAPI:
                directAPIConfigurationSection
            }

            if researchConfiguration.tier != .off {
                stepAndBudgetSection
                billingDisclosure
            }
        }
        .onAppear {
            refreshResearchConfiguration()
            refreshProvidersWithStoredDirectAPIKeys()
        }
    }

    private var researchTierIntroBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Research escalation")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("When you say \"research X\" / \"look into Y\" / \"compare A vs B\", Pace routes that one turn to the heavyweight model you pick here. Other turns continue to use whatever your main Planner tier is set to.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("On the CLI tier, Claude Code / Codex use their own built-in WebSearch and WebFetch tools — no separate MCP server, no Composio key. The CLI does the research; Pace speaks the answer.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Cancel an in-flight research turn by saying \"stop researching\".")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tierPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Tier", selection: Binding(
                get: { researchConfiguration.tier },
                set: { newTier in
                    PaceResearchTierStore.saveTier(newTier)
                    refreshResearchConfiguration()
                }
            )) {
                Text("Off — fall back to Cloud Bridge").tag(PaceResearchTier.off)
                Text("CLI bridge (Claude Code / Codex / Gemini)").tag(PaceResearchTier.cliBridge)
                Text("Direct API (BYO key)").tag(PaceResearchTier.directAPI)
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var cliBridgeConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLI bridge upstream")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Picker("Upstream", selection: Binding(
                get: { researchConfiguration.cliBridgeUpstream },
                set: { newUpstream in
                    PaceResearchTierStore.saveCLIBridgeUpstream(newUpstream)
                    refreshResearchConfiguration()
                }
            )) {
                ForEach(PaceCloudBridgeUpstream.allCases, id: \.rawValue) { upstream in
                    Text(upstream.displayLabel).tag(upstream)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            HStack(spacing: 8) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                TextField("model identifier", text: Binding(
                    get: { researchConfiguration.cliBridgeModel },
                    set: { newModel in
                        PaceResearchTierStore.saveCLIBridgeModel(newModel)
                        refreshResearchConfiguration()
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            }

            Text("Spawns the local `\(researchConfiguration.cliBridgeUpstream.rawValue)` CLI directly — no Node bridge needed. Free if you've already authenticated. (Pace falls back to the local-ai bridge only for the legacy `gemini` upstream.)")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var directAPIConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Direct API provider")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Picker("Provider", selection: Binding(
                get: { researchConfiguration.directAPIProvider },
                set: { newProvider in
                    PaceResearchTierStore.saveDirectAPIProvider(newProvider)
                    refreshResearchConfiguration()
                }
            )) {
                ForEach(PaceDirectAPIProvider.allCases, id: \.rawValue) { provider in
                    Text(provider.displayLabel).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            HStack(spacing: 8) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                TextField("e.g. claude-opus-4-7", text: Binding(
                    get: { researchConfiguration.directAPIModelIdentifier },
                    set: { newModel in
                        PaceResearchTierStore.saveDirectAPIModelIdentifier(newModel)
                        refreshResearchConfiguration()
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            }

            if researchConfiguration.directAPIProvider == .custom {
                HStack(spacing: 8) {
                    Text("Endpoint URL")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    TextField("https://your-endpoint/v1/chat/completions", text: Binding(
                        get: { researchConfiguration.directAPICustomEndpointURLString },
                        set: { newURLString in
                            PaceResearchTierStore.saveDirectAPICustomEndpointURL(newURLString)
                            refreshResearchConfiguration()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                }
            }

            directAPIKeyEditorRow
        }
    }

    private var directAPIKeyEditorRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("API key")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text("Key in Keychain: \(keyIsStoredForCurrentProvider ? "yes" : "no")")
                    .font(.system(size: 11))
                    .foregroundColor(keyIsStoredForCurrentProvider ? DS.Colors.success : DS.Colors.textTertiary)
            }
            HStack(spacing: 8) {
                SecureField("paste \(researchConfiguration.directAPIProvider.displayLabel) API key", text: $directAPIKeyEntryFieldText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                paceSettingsButton("Save", systemName: "checkmark.circle") {
                    saveDirectAPIKey()
                }
                if keyIsStoredForCurrentProvider {
                    paceSettingsButton("Remove", systemName: "xmark.circle") {
                        removeDirectAPIKey()
                    }
                }
            }
            if let lastSaveFeedback {
                Text(lastSaveFeedback)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Shared with Settings → Planner Direct API key for the same provider. Stored in macOS Keychain; never written to disk or logs.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepAndBudgetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().background(DS.Colors.borderSubtle)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Max steps per turn")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("Clamped \(PaceResearchTierStore.maximumAgentStepsRange.lowerBound)–\(PaceResearchTierStore.maximumAgentStepsRange.upperBound). Default \(PaceResearchTierStore.defaultMaximumAgentSteps).")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Stepper(value: Binding(
                    get: { researchConfiguration.maximumAgentSteps },
                    set: { newValue in
                        PaceResearchTierStore.saveMaximumAgentSteps(newValue)
                        refreshResearchConfiguration()
                    }
                ), in: PaceResearchTierStore.maximumAgentStepsRange) {
                    Text("\(researchConfiguration.maximumAgentSteps)")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 30)
                }
                .labelsHidden()
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Token budget cap")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("Bails the research loop once cumulative output ≈ this. Clamped \(PaceResearchTierStore.perTurnTokenBudgetCapRange.lowerBound) – \(PaceResearchTierStore.perTurnTokenBudgetCapRange.upperBound). Default \(PaceResearchTierStore.defaultPerTurnTokenBudgetCap).")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Stepper(value: Binding(
                    get: { researchConfiguration.perTurnTokenBudgetCap },
                    set: { newValue in
                        PaceResearchTierStore.savePerTurnTokenBudgetCap(newValue)
                        refreshResearchConfiguration()
                    }
                ), in: PaceResearchTierStore.perTurnTokenBudgetCapRange, step: 10_000) {
                    Text("\(researchConfiguration.perTurnTokenBudgetCap)")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 70)
                }
                .labelsHidden()
            }
        }
    }

    private var billingDisclosure: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Research turns cost real money on the Direct API tier.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Pace shows the per-turn cost in the Privacy dashboard, and the token-budget cap above is a hard backstop. Cancel with \"stop researching\".")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DS.Colors.warning.opacity(0.35), lineWidth: 0.5)
        )
    }

    // MARK: - State refresh

    private func refreshResearchConfiguration() {
        researchConfiguration = PaceResearchTierStore.loadConfiguration()
    }

    private func refreshProvidersWithStoredDirectAPIKeys() {
        providersWithStoredDirectAPIKeys = PaceKeychainStore.providersWithStoredKeys()
    }

    private var keyIsStoredForCurrentProvider: Bool {
        providersWithStoredDirectAPIKeys.contains(researchConfiguration.directAPIProvider)
    }

    private func saveDirectAPIKey() {
        let trimmedKey = directAPIKeyEntryFieldText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            lastSaveFeedback = "Paste a key before tapping Save."
            return
        }
        let didStore = PaceKeychainStore.storeAPIKey(trimmedKey, for: researchConfiguration.directAPIProvider)
        if didStore {
            directAPIKeyEntryFieldText = ""
            lastSaveFeedback = "Saved to Keychain."
            refreshProvidersWithStoredDirectAPIKeys()
        } else {
            lastSaveFeedback = "Save failed — see Console for the Keychain status code."
        }
    }

    private func removeDirectAPIKey() {
        let didDelete = PaceKeychainStore.deleteAPIKey(for: researchConfiguration.directAPIProvider)
        if didDelete {
            lastSaveFeedback = "Removed from Keychain."
            refreshProvidersWithStoredDirectAPIKeys()
        } else {
            lastSaveFeedback = "Remove failed — see Console for the Keychain status code."
        }
    }
}
