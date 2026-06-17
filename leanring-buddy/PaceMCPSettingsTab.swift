//
//  PaceMCPSettingsTab.swift
//  leanring-buddy
//
//  Settings → MCP tab content. Three sub-sections:
//   - Config file (path + Create/Open/Reveal/Refresh buttons)
//   - Curated catalog of bundled MCP servers (one-tap install/remove)
//   - List of currently-configured servers
//
//  Catalog install/uninstall performs an atomic JSON merge into
//  `mcp-servers.json` via `PaceMCPCatalogInstaller`, preserving every
//  hand-edited server entry the user already has.
//

import AppKit
import SwiftUI

struct PaceMCPSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var configuredMCPServerNames: [String] = PaceMCPServerRegistry.loadConfiguredServers().keys.sorted()
    /// Last per-catalog-slug operation feedback so the install card can
    /// show "Installed ✓" / "Removed" / "Failed: …" after each tap.
    /// Resets to nil on a fresh refresh so stale outcomes don't linger.
    @State private var lastCatalogActionBySlug: [String: String] = [:]
    /// In-memory editing state for the Composio API key SecureField.
    /// Never persisted in @State — Save commits it to Keychain via
    /// `PaceMCPSecretStore`; the field clears after save so the SwiftUI
    /// tree never holds the secret across re-renders.
    @State private var composioAPIKeyEditingDraft: String = ""
    /// Mirror of `PaceMCPSecretStore.hasSecret(...)` re-evaluated on
    /// appear / save / remove so the "Key in Keychain: yes/no"
    /// indicator stays in sync without polling.
    @State private var composioKeyIsStoredInKeychain: Bool = false
    /// Save/Remove feedback for the Composio key row.
    @State private var composioKeyStatusFeedback: String?

    var body: some View {
        ScrollView {
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
                    paceSettingsButton("Create / Open", systemName: "doc.badge.gearshape") {
                        createMCPConfigIfNeeded()
                        openPrimaryMCPConfig()
                        refreshMCPServerNames()
                    }
                    paceSettingsButton("Reveal", systemName: "folder") {
                        createMCPConfigIfNeeded()
                        NSWorkspace.shared.activateFileViewerSelecting([PaceMCPServerRegistry.configurationPaths[0]])
                        refreshMCPServerNames()
                    }
                    paceSettingsButton("Refresh", systemName: "arrow.clockwise") {
                        refreshMCPServerNames()
                    }
                }

                Divider()
                    .background(DS.Colors.borderSubtle)

                mcpCatalogSection

                Divider()
                    .background(DS.Colors.borderSubtle)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Configured servers")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)

                    if configuredMCPServerNames.isEmpty {
                        Text("No MCP servers configured yet. Install one from the catalog above, or use Create / Open to seed the file.")
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
        .onAppear {
            refreshMCPServerNames()
            refreshComposioKeyState()
        }
    }

    /// Curated MCP server catalog rendered as one-tap install cards.
    /// Each card writes/removes a single server entry in
    /// `mcp-servers.json` via `PaceMCPCatalogInstaller`, which performs
    /// an atomic JSON merge that preserves every other server the user
    /// has already configured by hand.
    private var mcpCatalogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Install a popular server")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("One-tap installs for the curated MCP servers Pace ships with. Adds the entry to your local config — never fetches a remote catalog. Composio handles the bulk of external SaaS (Gmail, Slack, GitHub, Linear, Notion, web search) via one OAuth.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // One-time hint: when the user still has a superseded
            // server installed (github / slack / linear), point them
            // at Composio. We don't auto-remove their existing setup
            // — silent removal of a working integration would be
            // hostile. They migrate when they're ready.
            if !installedSupersededServerSlugs.isEmpty {
                supersededByComposioHintBanner
            }

            VStack(spacing: 6) {
                ForEach(PaceMCPServerCatalog.bundledCatalog) { catalogEntry in
                    mcpCatalogCardRow(entry: catalogEntry)
                    if catalogEntry.slug == "composio"
                        && configuredMCPServerNames.contains(catalogEntry.slug) {
                        composioKeyEditorRow
                    }
                }
            }
        }
    }

    /// Slugs still configured in the user's mcp-servers.json that
    /// have been superseded by Composio.
    private var installedSupersededServerSlugs: [String] {
        configuredMCPServerNames.filter { slug in
            PaceMCPServerCatalog.supersededBySlug[slug] != nil
        }
    }

    private var supersededByComposioHintBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Composio now handles \(installedSupersededServerSlugs.map { $0.capitalized }.sorted().joined(separator: ", ")) through a single OAuth.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can remove the server-specific entries below when you've installed Composio and confirmed it works for you.")
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

    private var composioKeyEditorRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("Composio API key")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text("Key in Keychain: \(composioKeyIsStoredInKeychain ? "yes" : "no")")
                    .font(.system(size: 11))
                    .foregroundColor(composioKeyIsStoredInKeychain ? DS.Colors.success : DS.Colors.textTertiary)
            }
            HStack(spacing: 8) {
                SecureField("paste composio API key", text: $composioAPIKeyEditingDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                paceSettingsButton("Save", systemName: "checkmark.circle") {
                    saveComposioAPIKey()
                }
                if composioKeyIsStoredInKeychain {
                    paceSettingsButton("Remove", systemName: "xmark.circle") {
                        removeComposioAPIKey()
                    }
                }
            }
            if let statusFeedback = composioKeyStatusFeedback {
                Text(statusFeedback)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Stored in macOS Keychain; auto-injected into the Composio subprocess at launch. Never written to the mcp-servers.json file or to any log.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.025))
        )
    }

    private func saveComposioAPIKey() {
        let trimmedKey = composioAPIKeyEditingDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            composioKeyStatusFeedback = "Paste a key before tapping Save."
            return
        }
        let didStore = PaceMCPSecretStore.storeSecret(
            trimmedKey,
            server: "composio",
            key: "COMPOSIO_API_KEY"
        )
        if didStore {
            composioAPIKeyEditingDraft = ""
            composioKeyIsStoredInKeychain = true
            composioKeyStatusFeedback = "Saved to Keychain."
        } else {
            composioKeyStatusFeedback = "Save failed — see Console for the Keychain status code."
        }
    }

    private func removeComposioAPIKey() {
        let didDelete = PaceMCPSecretStore.deleteSecret(
            server: "composio",
            key: "COMPOSIO_API_KEY"
        )
        if didDelete {
            composioKeyIsStoredInKeychain = false
            composioKeyStatusFeedback = "Removed from Keychain."
        } else {
            composioKeyStatusFeedback = "Remove failed — see Console for the Keychain status code."
        }
    }

    private func refreshComposioKeyState() {
        composioKeyIsStoredInKeychain = PaceMCPSecretStore.hasSecret(
            server: "composio",
            key: "COMPOSIO_API_KEY"
        )
    }

    private func mcpCatalogCardRow(entry: PaceMCPServerCatalogEntry) -> some View {
        let isInstalled = configuredMCPServerNames.contains(entry.slug)
        let statusFeedback = lastCatalogActionBySlug[entry.slug]
        return HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isInstalled ? DS.Colors.success : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    if isInstalled {
                        Text("Installed")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.success)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(DS.Colors.success.opacity(0.12))
                            )
                    }
                }
                Text(entry.description)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let setupNote = entry.setupNote {
                    Text(setupNote)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let statusFeedback {
                    Text(statusFeedback)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 6) {
                if isInstalled {
                    paceSettingsButton("Remove", systemName: "trash") {
                        uninstallCatalogEntry(entry)
                    }
                } else {
                    paceSettingsButton("Install", systemName: "arrow.down.circle") {
                        installCatalogEntry(entry)
                    }
                }
                if let docsURL = entry.setupDocsURL {
                    paceSettingsButton("Setup docs", systemName: "book") {
                        NSWorkspace.shared.open(docsURL)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func installCatalogEntry(_ entry: PaceMCPServerCatalogEntry) {
        let configURL = PaceMCPServerRegistry.configurationPaths[0]
        do {
            try PaceMCPCatalogInstaller.install(entry, into: configURL)
            // Composio's key lives in Keychain (sentinel "" env value
            // in the catalog entry), so the user doesn't have to edit
            // the JSON. Other servers still use the legacy placeholder
            // flow.
            if entry.slug == "composio" {
                lastCatalogActionBySlug[entry.slug] = "Installed. Paste your COMPOSIO_API_KEY in the key field below; it'll be auto-injected at launch."
            } else {
                lastCatalogActionBySlug[entry.slug] = "Installed. Edit \(configURL.lastPathComponent) to fill in any required values."
            }
            refreshMCPServerNames()
            refreshComposioKeyState()
        } catch {
            lastCatalogActionBySlug[entry.slug] = "Install failed: \(error.localizedDescription)"
        }
    }

    private func uninstallCatalogEntry(_ entry: PaceMCPServerCatalogEntry) {
        let configURL = PaceMCPServerRegistry.configurationPaths[0]
        do {
            try PaceMCPCatalogInstaller.uninstall(slug: entry.slug, from: configURL)
            lastCatalogActionBySlug[entry.slug] = "Removed from \(configURL.lastPathComponent)."
            refreshMCPServerNames()
            refreshComposioKeyState()
        } catch {
            lastCatalogActionBySlug[entry.slug] = "Remove failed: \(error.localizedDescription)"
        }
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

    private static let defaultMCPConfigText = PaceMCPServerRegistry.starterConfigurationJSON
}
