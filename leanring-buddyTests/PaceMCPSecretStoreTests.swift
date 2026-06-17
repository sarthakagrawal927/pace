//
//  PaceMCPSecretStoreTests.swift
//  leanring-buddyTests
//
//  Pure tests for the MCP env-secret Keychain wrapper.
//
//  Why only pure tests: under `xcodebuild test`, the test runner runs
//  without the host app's signed identity, so live Keychain calls fail
//  with errSecMissingEntitlement and the in-process Swift Testing
//  runner crashes when our generic-password lookups return that error
//  from inside an `#expect`. Round-tripping the actual Keychain is
//  verified manually in Xcode Cmd+R smoke flow per the plan's
//  verification section.
//

import Foundation
import Testing
@testable import Pace

struct PaceMCPSecretStoreTests {

    @Test func keychainAccountNameIsComposable() async throws {
        let accountName = PaceMCPSecretStore.keychainAccountName(
            server: "Composio",
            key: "COMPOSIO_API_KEY"
        )
        // Server slug is lowercased; env key is preserved (env keys
        // are case-sensitive in shells).
        #expect(accountName == "mcp.composio.COMPOSIO_API_KEY")
    }

    @Test func keychainAccountNameTrimsWhitespace() async throws {
        let accountName = PaceMCPSecretStore.keychainAccountName(
            server: "  Composio  ",
            key: "  COMPOSIO_API_KEY  "
        )
        #expect(accountName == "mcp.composio.COMPOSIO_API_KEY")
    }

    @Test func keychainAccountNameDifferentiatesEnvKeysPerServer() async throws {
        let slackBotToken = PaceMCPSecretStore.keychainAccountName(
            server: "slack",
            key: "SLACK_BOT_TOKEN"
        )
        let slackAppToken = PaceMCPSecretStore.keychainAccountName(
            server: "slack",
            key: "SLACK_APP_TOKEN"
        )
        // Same server, different env keys → distinct Keychain accounts.
        #expect(slackBotToken != slackAppToken)
    }

    @Test func serviceIdentifierIsScopedAwayFromPlannerKeychain() async throws {
        // Sanity guard: planner API keys and MCP server secrets are
        // different threat surfaces, so the two stores MUST use
        // different service identifiers — otherwise a wipe of one would
        // nuke the other.
        #expect(PaceMCPSecretStore.serviceIdentifier != PaceKeychainStore.serviceIdentifier)
    }
}
