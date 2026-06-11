//
//  PaceMCPClientIntegrationTests.swift
//  leanring-buddyTests
//
//  End-to-end validation of the stdio MCP bridge against the in-repo
//  fixture server (scripts/mcp-fixture-server.py). These tests prove the
//  full initialize → notifications/initialized → tools/call round trip
//  with a real child process, not a mock.
//

import Foundation
import Testing

@testable import Pace

private enum PaceMCPFixture {
    // Tests run from DerivedData, so #filePath is the only stable anchor
    // back into the repo checkout: …/leanring-buddyTests/<this file>.
    static let fixtureScriptPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts")
        .appendingPathComponent("mcp-fixture-server.py")
        .path

    static let pythonThreeExecutablePath: String? = [
        "/usr/bin/python3",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3"
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    static var isFixtureRunnable: Bool {
        pythonThreeExecutablePath != nil
            && FileManager.default.fileExists(atPath: fixtureScriptPath)
    }

    static func makeFixtureClient(requestTimeoutInSeconds: TimeInterval = 20) -> PaceMCPStdioClient {
        let fixtureServerConfiguration = PaceMCPServerConfiguration(
            command: pythonThreeExecutablePath ?? "python3",
            args: [fixtureScriptPath]
        )
        return PaceMCPStdioClient(
            serverConfigurations: ["fixture": fixtureServerConfiguration],
            requestTimeoutInSeconds: requestTimeoutInSeconds
        )
    }
}

struct PaceMCPClientIntegrationTests {
    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func echoToolCallRoundTripsTextThroughFixtureServer() async throws {
        let fixtureClient = PaceMCPFixture.makeFixtureClient()
        let observationText = try await fixtureClient.callTool(
            PaceMCPToolCall(
                serverName: "fixture",
                toolName: "echo",
                arguments: ["text": .string("hello pace")]
            )
        )
        #expect(observationText == "hello pace")
    }

    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func toolResultWithIsErrorIsSummarizedAsErrorObservation() async throws {
        let fixtureClient = PaceMCPFixture.makeFixtureClient()
        let observationText = try await fixtureClient.callTool(
            PaceMCPToolCall(serverName: "fixture", toolName: "fail", arguments: [:])
        )
        #expect(observationText.hasPrefix("MCP tool reported an error:"))
        #expect(observationText.contains("intentional fixture failure"))
    }

    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func unknownToolNameSurfacesJSONRPCErrorAsRpcError() async {
        let fixtureClient = PaceMCPFixture.makeFixtureClient()
        do {
            _ = try await fixtureClient.callTool(
                PaceMCPToolCall(serverName: "fixture", toolName: "does_not_exist", arguments: [:])
            )
            Issue.record("Expected rpcError for an unknown tool name")
        } catch let mcpError as PaceMCPClientError {
            guard case .rpcError(let errorMessage) = mcpError else {
                Issue.record("Expected rpcError, got \(mcpError)")
                return
            }
            #expect(errorMessage.contains("unknown tool"))
        } catch {
            Issue.record("Expected PaceMCPClientError, got \(error)")
        }
    }

    @Test func starterConfigurationSeedsAppleMCPServer() throws {
        let starterData = try #require(PaceMCPServerRegistry.starterConfigurationJSON.data(using: .utf8))
        let decodedRoot = try JSONDecoder().decode(
            [String: [String: PaceMCPServerConfiguration]].self,
            from: starterData
        )
        let appleServerConfiguration = try #require(decodedRoot["mcpServers"]?["apple"])
        #expect(appleServerConfiguration.command == "npx")
        #expect(appleServerConfiguration.args == ["-y", "apple-mcp"])
    }

    @Test func unconfiguredServerNameThrowsServerNotConfigured() async {
        let clientWithNoServers = PaceMCPStdioClient(serverConfigurations: [:])
        do {
            _ = try await clientWithNoServers.callTool(
                PaceMCPToolCall(serverName: "missing", toolName: "echo", arguments: [:])
            )
            Issue.record("Expected serverNotConfigured")
        } catch let mcpError as PaceMCPClientError {
            guard case .serverNotConfigured(let serverName) = mcpError else {
                Issue.record("Expected serverNotConfigured, got \(mcpError)")
                return
            }
            #expect(serverName == "missing")
        } catch {
            Issue.record("Expected PaceMCPClientError, got \(error)")
        }
    }

    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func slowToolCallTimesOutWithShortTimeout() async {
        let fixtureClient = PaceMCPFixture.makeFixtureClient(requestTimeoutInSeconds: 2)
        do {
            _ = try await fixtureClient.callTool(
                PaceMCPToolCall(
                    serverName: "fixture",
                    toolName: "sleep",
                    arguments: ["seconds": .number(10)]
                )
            )
            Issue.record("Expected requestTimedOut")
        } catch let mcpError as PaceMCPClientError {
            guard case .requestTimedOut = mcpError else {
                Issue.record("Expected requestTimedOut, got \(mcpError)")
                return
            }
        } catch {
            Issue.record("Expected PaceMCPClientError, got \(error)")
        }
    }
}
