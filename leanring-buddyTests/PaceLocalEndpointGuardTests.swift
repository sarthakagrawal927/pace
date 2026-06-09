//
//  PaceLocalEndpointGuardTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing

@testable import Pace

struct PaceLocalEndpointGuardTests {
    @Test func acceptsLoopbackHTTPHosts() throws {
        let allowedURLs = [
            "http://localhost:1234/v1",
            "https://localhost:1234/v1",
            "http://127.0.0.1:1234/v1",
            "http://127.12.34.56:1234/v1",
            "http://[::1]:1234/v1"
        ]

        for allowedURLString in allowedURLs {
            let allowedURL = try #require(URL(string: allowedURLString))
            #expect(throws: Never.self) {
                try PaceLocalEndpointGuard.validateLocalHTTPURL(
                    allowedURL,
                    settingName: "LocalPlannerBaseURL"
                )
            }
        }
    }

    @Test func rejectsRemoteAndLanHosts() throws {
        let rejectedURLs = [
            "https://api.openai.com/v1",
            "http://192.168.1.20:1234/v1",
            "http://10.0.0.5:1234/v1",
            "http://pace-runtime.local:1234/v1",
            "http://example.com/v1",
            "file:///tmp/local-runtime.sock"
        ]

        for rejectedURLString in rejectedURLs {
            let rejectedURL = try #require(URL(string: rejectedURLString))
            #expect(throws: PaceLocalEndpointGuardError.self) {
                try PaceLocalEndpointGuard.validateLocalHTTPURL(
                    rejectedURL,
                    settingName: "LocalPlannerBaseURL"
                )
            }
        }
    }

    @Test func rejectsMalformedIPv4LoopbackLookalikes() {
        #expect(!PaceLocalEndpointGuard.isLoopbackHost("127.0.0"))
        #expect(!PaceLocalEndpointGuard.isLoopbackHost("127.0.0.999"))
        #expect(!PaceLocalEndpointGuard.isLoopbackHost("127.localhost"))
        #expect(!PaceLocalEndpointGuard.isLoopbackHost("localhost.localdomain"))
    }

    @Test func explicitRemoteConfigurationFallsBackToDefaultLocalhost() {
        let resolvedURL = PaceLocalEndpointGuard.resolvedLocalOpenAICompatibleBaseURL(
            configuredURLString: "https://api.openai.com/v1",
            settingName: "LocalPlannerBaseURL"
        )

        #expect(resolvedURL == PaceLocalEndpointGuard.defaultOpenAICompatibleBaseURL)
    }
}
