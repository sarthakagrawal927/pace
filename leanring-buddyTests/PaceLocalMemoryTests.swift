//
//  PaceLocalMemoryTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Pace

struct PaceLocalMemoryTests {
    @Test func parserSetsAndForgetsPreferredBrowser() async throws {
        #expect(PaceLocalMemoryCommandParser.parse("remember my preferred browser is Safari") == .set(.preferredBrowser, "Safari"))
        #expect(PaceLocalMemoryCommandParser.parse("forget my preferred browser") == .forget(.preferredBrowser))
        #expect(PaceLocalMemoryCommandParser.parse("use the screen tool") == nil)
    }

    @Test func storePersistsAndClearsPreference() async throws {
        PaceLocalMemoryStore.setString(nil, for: .preferredBrowser)
        #expect(PaceLocalMemoryStore.string(for: .preferredBrowser) == nil)

        PaceLocalMemoryStore.setString("Safari", for: .preferredBrowser)
        #expect(PaceLocalMemoryStore.string(for: .preferredBrowser) == "Safari")
        #expect(PaceLocalMemoryStore.summaryText.contains("Browser: Safari"))

        PaceLocalMemoryStore.setString(nil, for: .preferredBrowser)
        #expect(PaceLocalMemoryStore.string(for: .preferredBrowser) == nil)
    }
}
