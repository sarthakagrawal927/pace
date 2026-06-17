//
//  PaceMCPServerCatalog.swift
//  leanring-buddy
//
//  Bundled, one-tap MCP server installs surfaced from Settings → MCP.
//
//  The catalog is intentionally a fixed list shipped inside the app
//  binary: there is no remote fetch path, no auto-update of catalog
//  entries beyond a Pace release, and no telemetry on which servers
//  the user picks. Each catalog entry knows the JSON shape it would
//  add to `~/.config/pace/mcp-servers.json`; `install(_:into:)` does
//  an atomic JSON merge that preserves every other server the user
//  may have added by hand or installed from a different catalog row.
//
//  Pure module: no SwiftUI, no AppKit. Tests exercise install/uninstall
//  end-to-end against temp files.
//

import Foundation

/// Single row in the catalog. Each row knows how to install itself
/// into the user's MCP config file under the keyed `slug`.
struct PaceMCPServerCatalogEntry: Equatable, Identifiable {
    /// Stable identifier used both as the JSON key in `mcpServers`
    /// and as the dictionary key inside the catalog. Lowercase.
    let slug: String
    /// Human-readable name shown in the Settings card.
    let displayName: String
    /// One-line description rendered under the name.
    let description: String
    /// Optional setup note — e.g. "needs a GitHub personal access
    /// token". Surfaced inline on the card. `nil` when the server
    /// works without any user setup.
    let setupNote: String?
    /// Optional documentation URL for setup instructions. When
    /// present, the card renders a "Setup docs" button.
    let setupDocsURL: URL?
    /// The command Pace will execute when the server is launched.
    let command: String
    /// Arguments passed to the command. Captures the canonical
    /// install invocation (`npx -y <pkg>`, `uvx <pkg>`, etc.).
    let arguments: [String]
    /// Environment variables required by the server. Values are the
    /// catalog default — usually a placeholder the user must edit
    /// (e.g. `ghp_replace_me` for GitHub). We still write the
    /// placeholder so the JSON structure is correct and the user
    /// only has to change the value, not invent the key.
    let environment: [String: String]

    var id: String { slug }
}

/// Reasonable starter catalog. Six servers, matches the PRD list.
/// Keep this in sync with `mcp-servers.example.json` so users editing
/// the file by hand see the same canonical commands.
enum PaceMCPServerCatalog {
    static let bundledCatalog: [PaceMCPServerCatalogEntry] = [
        PaceMCPServerCatalogEntry(
            slug: "filesystem",
            displayName: "Filesystem",
            description: "Read and write files inside a folder you pick.",
            setupNote: "Edit the path arg to point at the folder you want Pace to read.",
            setupDocsURL: URL(string: "https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem"),
            command: "npx",
            arguments: [
                "-y",
                "@modelcontextprotocol/server-filesystem",
                NSString(string: "~/Documents").expandingTildeInPath
            ],
            environment: [:]
        ),
        PaceMCPServerCatalogEntry(
            slug: "fetch",
            displayName: "Fetch",
            description: "Generic web fetch. Unblocks 'go look up X' asks.",
            setupNote: nil,
            setupDocsURL: URL(string: "https://github.com/modelcontextprotocol/servers/tree/main/src/fetch"),
            command: "uvx",
            arguments: ["mcp-server-fetch"],
            environment: [:]
        ),
        PaceMCPServerCatalogEntry(
            slug: "applescript",
            displayName: "AppleScript",
            description: "Bridge to apps Pace doesn't integrate natively.",
            setupNote: nil,
            setupDocsURL: URL(string: "https://github.com/peakmojo/applescript-mcp"),
            command: "npx",
            arguments: ["-y", "@peakmojo/applescript-mcp"],
            environment: [:]
        ),
        PaceMCPServerCatalogEntry(
            slug: "composio",
            displayName: "Composio",
            description: "OAuth + 700 SaaS tools (Gmail, Slack, GitHub, Linear, Notion, Calendar, web search). Off-device — routes through Composio's cloud.",
            setupNote: "Set your COMPOSIO_API_KEY in Settings → MCP → Composio Key. First call to each tool opens an OAuth flow in your browser.",
            setupDocsURL: URL(string: "https://docs.composio.dev/mcp"),
            command: "npx",
            // The empty COMPOSIO_API_KEY sentinel is the marker
            // `PaceMCPServerRegistry`/`PaceMCPClient` will substitute
            // from `PaceMCPSecretStore` at spawn time. The user never
            // needs to edit the JSON file — the Settings card paste
            // flow writes the key directly to Keychain.
            arguments: ["-y", "@composio/mcp@latest"],
            environment: ["COMPOSIO_API_KEY": ""]
        )
    ]

    /// Catalog slugs whose entries were retired (superseded by Composio)
    /// but may still be present in user-installed mcp-servers.json files.
    /// The Settings → MCP tab surfaces a one-time "Composio replaces
    /// this" hint when one of these slugs is still installed.
    ///
    /// We do NOT auto-remove these — silent removal of a working
    /// integration would be hostile to the user's setup. They migrate
    /// when they're ready by clicking Remove on the legacy server card
    /// and Install on the Composio entry.
    static let supersededBySlug: [String: String] = [
        "github": "composio",
        "slack": "composio",
        "linear": "composio"
    ]

    /// Convenience lookup used by the Settings cards to map slug → entry.
    static func entry(forSlug slug: String) -> PaceMCPServerCatalogEntry? {
        bundledCatalog.first { $0.slug == slug }
    }
}

/// Errors surfaced from the installer to the Settings UI. Each case
/// carries enough detail for the card to show an inline status string.
enum PaceMCPCatalogInstallError: Error, CustomStringConvertible {
    case unreadableExistingConfig(String)
    case writeFailed(String)

    var description: String {
        switch self {
        case .unreadableExistingConfig(let message):
            return "Existing MCP config is not valid JSON: \(message)"
        case .writeFailed(let message):
            return "Failed to write MCP config: \(message)"
        }
    }
}

/// The atomic JSON-merge installer. Pure file I/O — no XPC, no
/// AppKit, no async. Tests pass a temp file URL.
enum PaceMCPCatalogInstaller {
    /// Inserts (or overwrites) a single catalog entry into the given
    /// `mcp-servers.json` file. The merge:
    ///   1. Reads the existing JSON if present.
    ///   2. Preserves every other server entry — user-added or from
    ///      a different catalog row.
    ///   3. Writes the new JSON to a sibling temp file.
    ///   4. Atomically renames the temp file over the real config.
    /// Returns the full updated `mcpServers` dictionary so callers
    /// can refresh their UI without a second disk read.
    @discardableResult
    static func install(
        _ entry: PaceMCPServerCatalogEntry,
        into configFileURL: URL
    ) throws -> [String: [String: Any]] {
        let existingServers = try loadExistingMCPServerEntries(at: configFileURL)
        var mergedServers = existingServers
        mergedServers[entry.slug] = installPayload(for: entry)
        try atomicallyWriteMCPServers(mergedServers, to: configFileURL)
        return mergedServers
    }

    /// Removes a catalog entry by slug. If the slug isn't present in
    /// the file (or the file doesn't exist), the operation is a no-op
    /// and returns whatever was on disk. Mirrors `install`'s atomic
    /// write semantics.
    @discardableResult
    static func uninstall(
        slug: String,
        from configFileURL: URL
    ) throws -> [String: [String: Any]] {
        let existingServers = try loadExistingMCPServerEntries(at: configFileURL)
        guard existingServers[slug] != nil else { return existingServers }
        var mergedServers = existingServers
        mergedServers.removeValue(forKey: slug)
        try atomicallyWriteMCPServers(mergedServers, to: configFileURL)
        return mergedServers
    }

    /// Reports whether a given slug is currently in the config file.
    /// Used by the Settings cards to render "Installed ✓" state.
    static func isInstalled(
        slug: String,
        in configFileURL: URL
    ) -> Bool {
        guard let servers = try? loadExistingMCPServerEntries(at: configFileURL) else {
            return false
        }
        return servers[slug] != nil
    }

    // MARK: - Internals

    /// Serializes a catalog entry into the JSON shape expected inside
    /// `mcpServers`. Kept as `[String: Any]` so we can write it back
    /// through `JSONSerialization` alongside whatever shape the user's
    /// hand-edited entries happen to use.
    static func installPayload(for entry: PaceMCPServerCatalogEntry) -> [String: Any] {
        var payload: [String: Any] = [
            "command": entry.command,
            "args": entry.arguments
        ]
        if !entry.environment.isEmpty {
            payload["env"] = entry.environment
        }
        return payload
    }

    private static func loadExistingMCPServerEntries(
        at configFileURL: URL
    ) throws -> [String: [String: Any]] {
        guard FileManager.default.fileExists(atPath: configFileURL.path) else {
            return [:]
        }
        let data: Data
        do {
            data = try Data(contentsOf: configFileURL)
        } catch {
            // An unreadable file (perms, disk error) — treat as fatal
            // so we don't silently nuke the user's config.
            throw PaceMCPCatalogInstallError.unreadableExistingConfig(error.localizedDescription)
        }
        if data.isEmpty {
            return [:]
        }
        let rawDecoded: Any
        do {
            rawDecoded = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PaceMCPCatalogInstallError.unreadableExistingConfig(error.localizedDescription)
        }
        guard let rootObject = rawDecoded as? [String: Any] else {
            return [:]
        }
        // The legacy registry accepted both `mcpServers` and `servers`.
        // Prefer `mcpServers` when both exist; we only write that key.
        if let mcpServers = rootObject["mcpServers"] as? [String: [String: Any]] {
            return mcpServers
        }
        if let legacyServers = rootObject["servers"] as? [String: [String: Any]] {
            return legacyServers
        }
        return [:]
    }

    private static func atomicallyWriteMCPServers(
        _ servers: [String: [String: Any]],
        to configFileURL: URL
    ) throws {
        let parentDirectory = configFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parentDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw PaceMCPCatalogInstallError.writeFailed(
                "could not create directory \(parentDirectory.path): \(error.localizedDescription)"
            )
        }

        // We always rewrite the top-level shape as `{ "mcpServers": ... }`
        // so the file is unambiguous. Hand-edited `servers` keys are
        // migrated forward into `mcpServers` on first install — the
        // existing reader accepts both shapes, so this stays compatible.
        let rootObject: [String: Any] = ["mcpServers": servers]
        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(
                withJSONObject: rootObject,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw PaceMCPCatalogInstallError.writeFailed(error.localizedDescription)
        }

        // Atomic write: temp file in the same directory + rename. This
        // guarantees readers never see a half-written config and any
        // crash mid-write leaves the previous version intact.
        let tempFileURL = parentDirectory.appendingPathComponent(
            ".\(configFileURL.lastPathComponent).pace.tmp.\(UUID().uuidString)"
        )
        do {
            try jsonData.write(to: tempFileURL, options: [.atomic])
        } catch {
            throw PaceMCPCatalogInstallError.writeFailed(
                "could not write temp file: \(error.localizedDescription)"
            )
        }
        do {
            if FileManager.default.fileExists(atPath: configFileURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    configFileURL,
                    withItemAt: tempFileURL
                )
            } else {
                try FileManager.default.moveItem(at: tempFileURL, to: configFileURL)
            }
        } catch {
            // Best-effort cleanup of the temp file if the rename fails.
            try? FileManager.default.removeItem(at: tempFileURL)
            throw PaceMCPCatalogInstallError.writeFailed(
                "could not rename temp file into place: \(error.localizedDescription)"
            )
        }
    }
}
