//
//  PacePrivacyDashboardComposioClassificationTests.swift
//  leanring-buddyTests
//
//  Pins the off-device tier classifier for the new .mcpHosted case so
//  Composio tool calls reliably show up under "MCP (hosted)" in the
//  Privacy Dashboard while local stdio MCP calls (filesystem, fetch,
//  applescript) stay on-device.
//

import Foundation
import Testing
@testable import Pace

struct PacePrivacyDashboardComposioClassificationTests {

    @Test func composioTargetClassifiesAsMcpHosted() async throws {
        let resolvedTier = PacePrivacyDashboardAggregator.tier(
            forSubsystem: "mcp",
            target: "composio.gmail.send_email"
        )
        #expect(resolvedTier == .mcpHosted)
    }

    @Test func localStdioMCPTargetStaysOnDevice() async throws {
        let resolvedTier = PacePrivacyDashboardAggregator.tier(
            forSubsystem: "mcp",
            target: "filesystem.read_file"
        )
        #expect(resolvedTier == nil)
    }

    @Test func applescriptStdioMCPTargetStaysOnDevice() async throws {
        let resolvedTier = PacePrivacyDashboardAggregator.tier(
            forSubsystem: "mcp",
            target: "applescript.run_script"
        )
        #expect(resolvedTier == nil)
    }

    @Test func directAPISubsystemClassificationUnchanged() async throws {
        let resolvedTier = PacePrivacyDashboardAggregator.tier(
            forSubsystem: "planner.directAPI",
            target: "anthropic/claude-opus-4-7"
        )
        #expect(resolvedTier == .directAPI)
    }

    @Test func cloudBridgeSubsystemClassificationUnchanged() async throws {
        let resolvedTier = PacePrivacyDashboardAggregator.tier(
            forSubsystem: "planner.cloudBridge",
            target: "claude"
        )
        #expect(resolvedTier == .cloudBridge)
    }

    @Test func unknownSubsystemReturnsNil() async throws {
        let resolvedTier = PacePrivacyDashboardAggregator.tier(
            forSubsystem: "tts",
            target: "kokoro"
        )
        #expect(resolvedTier == nil)
    }

    @Test func mcpEntryWithoutTargetReturnsNilNotCrash() async throws {
        let resolvedTier = PacePrivacyDashboardAggregator.tier(
            forSubsystem: "mcp",
            target: nil
        )
        #expect(resolvedTier == nil)
    }

    @Test func composioTargetCaseInsensitive() async throws {
        let resolvedTier = PacePrivacyDashboardAggregator.tier(
            forSubsystem: "mcp",
            target: "Composio.gmail.send_email"
        )
        #expect(resolvedTier == .mcpHosted)
    }
}
