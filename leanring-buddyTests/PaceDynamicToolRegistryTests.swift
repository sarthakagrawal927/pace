//
//  PaceDynamicToolRegistryTests.swift
//  leanring-buddyTests
//
//  Tests for the dynamic tool plugin registry. Verifies plugin
//  loading, execution, and auto-repair logic.
//

import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceDynamicToolRegistryTests {

    // MARK: - Plugin structure

    /// A plugin can be encoded and decoded.
    @Test
    func pluginIsCodable() throws {
        let plugin = PaceDynamicToolPlugin(
            id: "test-plugin",
            name: "Test Plugin",
            description: "A test plugin",
            command: "echo {message}",
            schemaExample: #"{"message":"hello"}"#,
            riskLevel: "safe",
            isEnabled: true,
            failureCount: 0,
            autoRepairEnabled: true
        )

        let data = try JSONEncoder().encode(plugin)
        let decoded = try JSONDecoder().decode(PaceDynamicToolPlugin.self, from: data)

        #expect(decoded.id == plugin.id)
        #expect(decoded.name == plugin.name)
        #expect(decoded.command == plugin.command)
        #expect(decoded.isEnabled == plugin.isEnabled)
        #expect(decoded.autoRepairEnabled == plugin.autoRepairEnabled)
    }

    // MARK: - Execution

    /// A simple echo plugin executes successfully.
    @Test
    func echoPluginExecutesSuccessfully() async {
        let registry = PaceDynamicToolRegistry.shared

        let plugin = PaceDynamicToolPlugin(
            id: "echo-test-\(UUID().uuidString.prefix(8))",
            name: "Echo Test",
            description: "Echoes a message",
            command: "echo hello world",
            schemaExample: "{}",
            riskLevel: "safe",
            isEnabled: true,
            failureCount: 0,
            autoRepairEnabled: false
        )

        try? registry.savePlugin(plugin)
        defer { registry.deletePlugin(id: plugin.id) }

        let result = await registry.executePlugin(id: plugin.id, arguments: [:])

        switch result {
        case .success(let output):
            #expect(output.contains("hello world"))
        case .failure(let error):
            #expect(Bool(false), "Plugin should succeed: \(error.localizedDescription)")
        }
    }

    /// A plugin with argument substitution works.
    @Test
    func pluginWithArgumentSubstitution() async {
        let registry = PaceDynamicToolRegistry.shared

        let plugin = PaceDynamicToolPlugin(
            id: "arg-test-\(UUID().uuidString.prefix(8))",
            name: "Arg Test",
            description: "Echoes with args",
            command: "echo {message}",
            schemaExample: #"{"message":"test"}"#,
            riskLevel: "safe",
            isEnabled: true,
            failureCount: 0,
            autoRepairEnabled: false
        )

        try? registry.savePlugin(plugin)
        defer { registry.deletePlugin(id: plugin.id) }

        let result = await registry.executePlugin(
            id: plugin.id,
            arguments: ["message": "custom_value"]
        )

        switch result {
        case .success(let output):
            #expect(output.contains("custom_value"))
        case .failure(let error):
            #expect(Bool(false), "Plugin should succeed: \(error.localizedDescription)")
        }
    }

    /// A failing plugin (non-zero exit) returns failure.
    @Test
    func failingPluginReturnsFailure() async {
        let registry = PaceDynamicToolRegistry.shared

        let plugin = PaceDynamicToolPlugin(
            id: "fail-test-\(UUID().uuidString.prefix(8))",
            name: "Fail Test",
            description: "Always fails",
            command: "exit 1",
            schemaExample: "{}",
            riskLevel: "safe",
            isEnabled: true,
            failureCount: 0,
            autoRepairEnabled: false // Disable auto-repair for this test.
        )

        try? registry.savePlugin(plugin)
        defer { registry.deletePlugin(id: plugin.id) }

        let result = await registry.executePlugin(id: plugin.id, arguments: [:])

        if case .failure = result {
            // Expected.
        } else {
            #expect(Bool(false), "Plugin should fail")
        }
    }

    /// A disabled plugin returns failure.
    @Test
    func disabledPluginReturnsFailure() async {
        let registry = PaceDynamicToolRegistry.shared

        let plugin = PaceDynamicToolPlugin(
            id: "disabled-test-\(UUID().uuidString.prefix(8))",
            name: "Disabled Test",
            description: "Disabled plugin",
            command: "echo hello",
            schemaExample: "{}",
            riskLevel: "safe",
            isEnabled: false,
            failureCount: 0,
            autoRepairEnabled: false
        )

        try? registry.savePlugin(plugin)
        defer { registry.deletePlugin(id: plugin.id) }

        let result = await registry.executePlugin(id: plugin.id, arguments: [:])

        if case .failure = result {
            // Expected.
        } else {
            #expect(Bool(false), "Disabled plugin should fail")
        }
    }

    /// Non-existent plugin returns failure.
    @Test
    func nonExistentPluginReturnsFailure() async {
        let registry = PaceDynamicToolRegistry.shared

        let result = await registry.executePlugin(id: "does-not-exist", arguments: [:])

        if case .failure = result {
            // Expected.
        } else {
            #expect(Bool(false), "Non-existent plugin should fail")
        }
    }

    // MARK: - Auto-repair

    /// A failing plugin with auto-repair enabled triggers the
    /// repair callback.
    @Test
    func autoRepairTriggersOnFailure() async {
        let registry = PaceDynamicToolRegistry.shared

        let plugin = PaceDynamicToolPlugin(
            id: "autorepair-test-\(UUID().uuidString.prefix(8))",
            name: "AutoRepair Test",
            description: "Fails then gets repaired",
            command: "exit 1",
            schemaExample: "{}",
            riskLevel: "safe",
            isEnabled: true,
            failureCount: 0,
            autoRepairEnabled: true
        )

        try? registry.savePlugin(plugin)
        defer { registry.deletePlugin(id: plugin.id) }

        // Set up the repair callback to provide a fixed command.
        registry.generatePluginFix = { _, _ in
            return "echo repaired"
        }
        defer { registry.generatePluginFix = nil }

        let result = await registry.executePlugin(id: plugin.id, arguments: [:])

        switch result {
        case .success(let output):
            #expect(output.contains("repaired"))
        case .failure(let error):
            #expect(Bool(false), "Auto-repair should fix the plugin: \(error.localizedDescription)")
        }
    }

    /// Auto-repair gives up after 2 failures (failureCount check).
    @Test
    func autoRepairGivesUpAfterMaxFailures() async {
        let registry = PaceDynamicToolRegistry.shared

        let plugin = PaceDynamicToolPlugin(
            id: "maxfail-test-\(UUID().uuidString.prefix(8))",
            name: "MaxFail Test",
            description: "Always fails",
            command: "exit 1",
            schemaExample: "{}",
            riskLevel: "safe",
            isEnabled: true,
            failureCount: 2, // Already at max.
            autoRepairEnabled: true
        )

        try? registry.savePlugin(plugin)
        defer { registry.deletePlugin(id: plugin.id) }

        registry.generatePluginFix = { _, _ in
            return "echo should_not_reach"
        }
        defer { registry.generatePluginFix = nil }

        let result = await registry.executePlugin(id: plugin.id, arguments: [:])

        // Should fail without attempting repair.
        if case .failure = result {
            // Expected.
        } else {
            #expect(Bool(false), "Should fail without repair at max failure count")
        }
    }

    // MARK: - Planner prompt

    /// The planner prompt lines include enabled plugins.
    @Test
    func plannerPromptIncludesEnabledPlugins() async {
        let registry = PaceDynamicToolRegistry.shared

        let plugin = PaceDynamicToolPlugin(
            id: "prompt-test-\(UUID().uuidString.prefix(8))",
            name: "PromptTestPlugin",
            description: "Test description",
            command: "echo test",
            schemaExample: #"{"key":"value"}"#,
            riskLevel: "safe",
            isEnabled: true,
            failureCount: 0,
            autoRepairEnabled: false
        )

        try? registry.savePlugin(plugin)
        defer { registry.deletePlugin(id: plugin.id) }

        let promptLines = registry.plannerPromptLines()

        #expect(promptLines.contains("PromptTestPlugin"))
        #expect(promptLines.contains("Test description"))
    }

    /// The planner prompt is empty when no plugins are enabled.
    @Test
    func plannerPromptEmptyWhenNoPlugins() async {
        let registry = PaceDynamicToolRegistry.shared

        // Save a disabled plugin.
        let plugin = PaceDynamicToolPlugin(
            id: "disabled-prompt-test-\(UUID().uuidString.prefix(8))",
            name: "DisabledPromptTest",
            description: "Disabled",
            command: "echo test",
            schemaExample: "{}",
            riskLevel: "safe",
            isEnabled: false,
            failureCount: 0,
            autoRepairEnabled: false
        )

        try? registry.savePlugin(plugin)
        defer { registry.deletePlugin(id: plugin.id) }

        // The prompt should not contain this disabled plugin.
        let promptLines = registry.plannerPromptLines()
        #expect(!promptLines.contains("DisabledPromptTest"))
    }
}
