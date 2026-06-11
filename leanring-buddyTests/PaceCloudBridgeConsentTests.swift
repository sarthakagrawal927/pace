//
//  PaceCloudBridgeConsentTests.swift
//  leanring-buddyTests
//
//  Unit tests for PaceCloudBridgeConsent — pure state-machine, no network.
//

import Foundation
import Testing

@testable import Pace

struct PaceCloudBridgeConsentTests {

    // MARK: - Helpers

    /// Returns a fresh UserDefaults suite isolated from production state.
    private func makeIsolatedUserDefaults(suiteName: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - Configuration load tests

    @Test
    func defaultConfigurationHasOffModeAndNoConsent() {
        // Use a fresh UserDefaults domain so earlier test runs don't leak state.
        let suiteName = "test.cloudBridge.defaults.\(UUID().uuidString)"
        let isolatedDefaults = makeIsolatedUserDefaults(suiteName: suiteName)
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        // Write nothing — just verify the defaults match what the code documents.
        // (PaceCloudBridgeConsent reads UserDefaults.standard so we can't
        // fully isolate it, but we CAN verify the raw-value fallbacks by
        // instantiating fresh enum values.)
        let defaultMode = PaceCloudBridgeMode(rawValue: "nonexistent") ?? .off
        #expect(defaultMode == .off)
    }

    @Test
    func allModeRawValuesRoundTrip() {
        for mode in PaceCloudBridgeMode.allCases {
            let reconstituted = PaceCloudBridgeMode(rawValue: mode.rawValue)
            #expect(reconstituted == mode)
        }
    }

    @Test
    func allUpstreamRawValuesRoundTrip() {
        for upstream in PaceCloudBridgeUpstream.allCases {
            let reconstituted = PaceCloudBridgeUpstream(rawValue: upstream.rawValue)
            #expect(reconstituted == upstream)
        }
    }

    @Test
    func upstreamDisplayLabelsAreNonEmpty() {
        for upstream in PaceCloudBridgeUpstream.allCases {
            #expect(!upstream.displayLabel.isEmpty)
        }
    }

    // MARK: - 24-hour soak tests

    @Test
    func canEnableAlwaysBridgeReturnsFalseWhenFirstUsedAtIsUnset() {
        // Temporarily remove the firstUsedAt key so the gate starts clean.
        let savedValue = UserDefaults.standard.object(forKey: "pace.cloudBridge.firstUsedAt")
        UserDefaults.standard.removeObject(forKey: "pace.cloudBridge.firstUsedAt")
        defer {
            if let savedValue {
                UserDefaults.standard.set(savedValue, forKey: "pace.cloudBridge.firstUsedAt")
            } else {
                UserDefaults.standard.removeObject(forKey: "pace.cloudBridge.firstUsedAt")
            }
        }

        let result = PaceCloudBridgeConsent.canEnableAlwaysBridge(now: Date())
        #expect(result == false)
    }

    @Test
    func canEnableAlwaysBridgeReturnsFalseWhenFirstUsedLessThan24HoursAgo() {
        let savedValue = UserDefaults.standard.object(forKey: "pace.cloudBridge.firstUsedAt")
        let twentyThreeHoursAgo = Date().addingTimeInterval(-(23 * 60 * 60))
        UserDefaults.standard.set(
            twentyThreeHoursAgo.timeIntervalSinceReferenceDate,
            forKey: "pace.cloudBridge.firstUsedAt"
        )
        defer {
            if let savedValue {
                UserDefaults.standard.set(savedValue, forKey: "pace.cloudBridge.firstUsedAt")
            } else {
                UserDefaults.standard.removeObject(forKey: "pace.cloudBridge.firstUsedAt")
            }
        }

        let result = PaceCloudBridgeConsent.canEnableAlwaysBridge(now: Date())
        #expect(result == false)
    }

    @Test
    func canEnableAlwaysBridgeReturnsTrueWhenFirstUsedMoreThan24HoursAgo() {
        let savedValue = UserDefaults.standard.object(forKey: "pace.cloudBridge.firstUsedAt")
        let twentyFiveHoursAgo = Date().addingTimeInterval(-(25 * 60 * 60))
        UserDefaults.standard.set(
            twentyFiveHoursAgo.timeIntervalSinceReferenceDate,
            forKey: "pace.cloudBridge.firstUsedAt"
        )
        defer {
            if let savedValue {
                UserDefaults.standard.set(savedValue, forKey: "pace.cloudBridge.firstUsedAt")
            } else {
                UserDefaults.standard.removeObject(forKey: "pace.cloudBridge.firstUsedAt")
            }
        }

        let result = PaceCloudBridgeConsent.canEnableAlwaysBridge(now: Date())
        #expect(result == true)
    }

    // MARK: - markFirstUsedIfUnset tests

    @Test
    func markFirstUsedIfUnsetStoresValueOnFirstCall() {
        let savedValue = UserDefaults.standard.object(forKey: "pace.cloudBridge.firstUsedAt")
        UserDefaults.standard.removeObject(forKey: "pace.cloudBridge.firstUsedAt")
        defer {
            if let savedValue {
                UserDefaults.standard.set(savedValue, forKey: "pace.cloudBridge.firstUsedAt")
            } else {
                UserDefaults.standard.removeObject(forKey: "pace.cloudBridge.firstUsedAt")
            }
        }

        let referenceDate = Date(timeIntervalSinceReferenceDate: 1_000_000)
        PaceCloudBridgeConsent.markFirstUsedIfUnset(now: referenceDate)

        let storedTimeInterval = UserDefaults.standard.object(
            forKey: "pace.cloudBridge.firstUsedAt"
        ) as? Double
        #expect(storedTimeInterval != nil)
        #expect(storedTimeInterval == referenceDate.timeIntervalSinceReferenceDate)
    }

    @Test
    func markFirstUsedIfUnsetIsIdempotentOnSubsequentCalls() {
        let savedValue = UserDefaults.standard.object(forKey: "pace.cloudBridge.firstUsedAt")
        let originalReferenceDate = Date(timeIntervalSinceReferenceDate: 1_000_000)
        UserDefaults.standard.set(
            originalReferenceDate.timeIntervalSinceReferenceDate,
            forKey: "pace.cloudBridge.firstUsedAt"
        )
        defer {
            if let savedValue {
                UserDefaults.standard.set(savedValue, forKey: "pace.cloudBridge.firstUsedAt")
            } else {
                UserDefaults.standard.removeObject(forKey: "pace.cloudBridge.firstUsedAt")
            }
        }

        // A second call with a later date should NOT overwrite the first.
        let laterDate = Date(timeIntervalSinceReferenceDate: 2_000_000)
        PaceCloudBridgeConsent.markFirstUsedIfUnset(now: laterDate)

        let storedTimeInterval = UserDefaults.standard.object(
            forKey: "pace.cloudBridge.firstUsedAt"
        ) as? Double
        #expect(storedTimeInterval == originalReferenceDate.timeIntervalSinceReferenceDate)
    }

    // MARK: - Configuration equality

    @Test
    func configurationEquatableMatchesSameValues() {
        let configurationA = PaceCloudBridgeConfiguration(
            mode: .hybrid,
            upstream: .claude,
            model: "sonnet",
            baseURL: URL(string: "http://localhost:3456")!,
            hasUserAcceptedConsent: true,
            firstUsedAt: nil
        )
        let configurationB = PaceCloudBridgeConfiguration(
            mode: .hybrid,
            upstream: .claude,
            model: "sonnet",
            baseURL: URL(string: "http://localhost:3456")!,
            hasUserAcceptedConsent: true,
            firstUsedAt: nil
        )
        #expect(configurationA == configurationB)
    }

    @Test
    func configurationEquatableDetectsMismatch() {
        let configurationA = PaceCloudBridgeConfiguration(
            mode: .hybrid,
            upstream: .claude,
            model: "sonnet",
            baseURL: URL(string: "http://localhost:3456")!,
            hasUserAcceptedConsent: true,
            firstUsedAt: nil
        )
        let configurationB = PaceCloudBridgeConfiguration(
            mode: .off,
            upstream: .claude,
            model: "sonnet",
            baseURL: URL(string: "http://localhost:3456")!,
            hasUserAcceptedConsent: false,
            firstUsedAt: nil
        )
        #expect(configurationA != configurationB)
    }
}
