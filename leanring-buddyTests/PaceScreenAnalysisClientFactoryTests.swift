//
//  PaceScreenAnalysisClientFactoryTests.swift
//  leanring-buddyTests
//

import Testing

@testable import Pace

@MainActor
struct PaceScreenAnalysisClientFactoryTests {
    @Test func defaultProviderUsesLMStudioHTTP() async throws {
        let client = PaceScreenAnalysisClientFactory.makeClient(
            configuredProviderName: nil,
            configuredBaseURL: "http://localhost:1234/v1",
            configuredModelIdentifier: "ui-venus-1.5-2b",
            isInProcessRuntimeAvailable: false
        )

        #expect(client.displayName == "LM Studio VLM (ui-venus-1.5-2b)")
    }

    @Test func inProcessProviderFallsBackToHTTPWhenRuntimeUnavailable() async throws {
        let client = PaceScreenAnalysisClientFactory.makeClient(
            configuredProviderName: "in-process",
            configuredBaseURL: "http://localhost:1234/v1",
            configuredModelIdentifier: "ui-venus-1.5-2b",
            isInProcessRuntimeAvailable: false
        )

        #expect(client.displayName == "LM Studio VLM (ui-venus-1.5-2b)")
    }

    @Test func inProcessProviderCanBeSelectedWhenRuntimeAvailable() async throws {
        let client = PaceScreenAnalysisClientFactory.makeClient(
            configuredProviderName: "coreML",
            configuredBaseURL: "http://localhost:1234/v1",
            configuredModelIdentifier: "ui-venus-1.5-2b",
            isInProcessRuntimeAvailable: true
        )

        #expect(client.displayName == "In-process VLM (ui-venus-1.5-2b)")
    }
}
