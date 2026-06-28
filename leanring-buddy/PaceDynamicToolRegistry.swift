//
//  PaceDynamicToolRegistry.swift
//  leanring-buddy
//
//  Dynamic tool registry + self-modifying plugin system. Inspired by
//  Samuel's self-modifying plugins with auto-repair.
//
//  Unlike the static PaceToolRegistry (which ships 26 built-in tools
//  validated at compile time), this registry allows tools to be
//  loaded at runtime from JSON files in
//  ~/Library/Application Support/Pace/plugins/.
//
//  Each plugin defines:
//    - A tool name and schema
//    - A shell command or AppleScript to execute
//    - A risk level and approval policy
//    - A description for the planner prompt
//
//  Auto-repair: when a plugin fails (e.g. its command returns an
//  error), the system can ask the planner to generate a fix for the
//  plugin's command. The fix is applied and the plugin is retried
//  (up to 2 attempts, matching Samuel's approach).
//

import Combine
import Foundation

/// A dynamically-loaded tool plugin.
struct PaceDynamicToolPlugin: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    /// Shell command to execute. Supports {arg} substitution.
    /// Mutable so auto-repair can update it.
    var command: String
    /// JSON schema example for the planner prompt.
    let schemaExample: String
    /// Risk level: "safe" | "requires_approval" | "destructive"
    let riskLevel: String
    /// Whether this plugin should be included in the planner prompt.
    var isEnabled: Bool
    /// Number of times this plugin has failed (for auto-repair).
    var failureCount: Int
    /// Whether auto-repair is enabled for this plugin.
    let autoRepairEnabled: Bool

    static func == (lhs: PaceDynamicToolPlugin, rhs: PaceDynamicToolPlugin) -> Bool {
        lhs.id == rhs.id
    }
}

/// Manages dynamic tool plugins. Loads from disk, validates, and
/// provides hooks for the planner to use dynamic tools.
@MainActor
final class PaceDynamicToolRegistry: ObservableObject {
    static let shared = PaceDynamicToolRegistry()

    @Published private(set) var plugins: [PaceDynamicToolPlugin] = []

    /// Plugins directory: ~/Library/Application Support/Pace/plugins/
    private static var pluginsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            ?? URL(fileURLWithPath: "/dev/null")
    }

    /// Callback to ask the planner to generate a fix for a failed
    /// plugin command. Set by CompanionManager.
    var generatePluginFix: ((PaceDynamicToolPlugin, String) async -> String?)?

    private init() {
        loadPlugins()
    }

    // MARK: - Loading

    /// Load all plugins from the plugins directory.
    func loadPlugins() {
        let dir = Self.pluginsDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }

        var loaded: [PaceDynamicToolPlugin] = []
        for entry in entries where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry),
                  let plugin = try? JSONDecoder().decode(PaceDynamicToolPlugin.self, from: data) else {
                continue
            }
            loaded.append(plugin)
        }
        plugins = loaded
    }

    /// Save a plugin to disk.
    func savePlugin(_ plugin: PaceDynamicToolPlugin) throws {
        let dir = Self.pluginsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(plugin.id).json")
        let data = try JSONEncoder().encode(plugin)
        try data.write(to: url, options: [.atomic])
        if !plugins.contains(where: { $0.id == plugin.id }) {
            plugins.append(plugin)
        }
    }

    /// Delete a plugin.
    func deletePlugin(id: String) {
        let url = Self.pluginsDirectory.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
        plugins.removeAll(where: { $0.id == id })
    }

    // MARK: - Execution

    /// Execute a dynamic tool plugin with the given arguments.
    /// Returns the command output as a string. On failure, attempts
    /// auto-repair if enabled.
    func executePlugin(id: String, arguments: [String: String]) async -> Result<String, Error> {
        guard let pluginIndex = plugins.firstIndex(where: { $0.id == id }) else {
            return .failure(NSError(domain: "PaceDynamicToolRegistry", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Plugin not found: \(id)"
            ]))
        }

        let plugin = plugins[pluginIndex]
        guard plugin.isEnabled else {
            return .failure(NSError(domain: "PaceDynamicToolRegistry", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Plugin is disabled: \(plugin.name)"
            ]))
        }

        let result = await runCommand(plugin: plugin, arguments: arguments)

        switch result {
        case .success(let output):
            return .success(output)

        case .failure(let error):
            // Auto-repair: ask the planner to generate a fix.
            if plugin.autoRepairEnabled, plugin.failureCount < 2 {
                return await attemptAutoRepair(
                    pluginIndex: pluginIndex,
                    error: error.localizedDescription,
                    arguments: arguments
                )
            } else {
                plugins[pluginIndex].failureCount += 1
                return .failure(error)
            }
        }
    }

    // MARK: - Private

    private func runCommand(
        plugin: PaceDynamicToolPlugin,
        arguments: [String: String]
    ) async -> Result<String, Error> {
        var command = plugin.command
        for (key, value) in arguments {
            command = command.replacingOccurrences(of: "{\(key)}", with: value)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                return .success(output.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                return .failure(NSError(domain: "PaceDynamicToolRegistry", code: Int(process.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: "Plugin command failed (exit \(process.terminationStatus)): \(output.prefix(200))"
                ]))
            }
        } catch {
            return .failure(error)
        }
    }

    /// Attempt to auto-repair a failed plugin by asking the planner
    /// to generate a fixed command. Samuel's approach: up to 2
    /// attempts, then give up.
    private func attemptAutoRepair(
        pluginIndex: Int,
        error: String,
        arguments: [String: String]
    ) async -> Result<String, Error> {
        guard let generatePluginFix else {
            return .failure(NSError(domain: "PaceDynamicToolRegistry", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Auto-repair callback not set"
            ]))
        }

        plugins[pluginIndex].failureCount += 1
        let failedPlugin = plugins[pluginIndex]

        // Ask the planner for a fix.
        let fixPrompt = """
        The plugin "\(failedPlugin.name)" failed with error: \(error)
        Original command: \(failedPlugin.command)
        Arguments: \(arguments)
        Generate a fixed shell command that accomplishes the same goal.
        Respond with ONLY the command, no explanation.
        """

        guard let fixedCommand = await generatePluginFix(failedPlugin, fixPrompt) else {
            return .failure(NSError(domain: "PaceDynamicToolRegistry", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Auto-repair: planner did not generate a fix"
            ]))
        }

        // Apply the fix and retry.
        var repairedPlugin = failedPlugin
        repairedPlugin.command = fixedCommand.trimmingCharacters(in: .whitespacesAndNewlines)

        let retryResult = await runCommand(plugin: repairedPlugin, arguments: arguments)
        if case .success = retryResult {
            // Save the repaired command.
            plugins[pluginIndex].command = repairedPlugin.command
            plugins[pluginIndex].failureCount = 0
            try? savePlugin(plugins[pluginIndex])
        }
        return retryResult
    }

    // MARK: - Planner prompt

    /// Generate the planner prompt lines for all enabled plugins.
    /// These are appended to the existing tool documentation in the
    /// system prompt.
    func plannerPromptLines() -> String {
        let enabledPlugins = plugins.filter { $0.isEnabled }
        guard !enabledPlugins.isEmpty else { return "" }

        var lines: [String] = []
        for plugin in enabledPlugins {
            lines.append("- \(plugin.name): \(plugin.description) Schema: \(plugin.schemaExample)")
        }
        return lines.joined(separator: "\n")
    }
}
