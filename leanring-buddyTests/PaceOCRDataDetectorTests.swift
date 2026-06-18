//
//  PaceOCRDataDetectorTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Pace

struct PaceOCRDataDetectorTests {

    @Test func detectsPhoneNumberInOCRBoxText() async throws {
        let entities = PaceOCRDataDetector.detectEntities(in: "call +1 (415) 555-1234 tomorrow")
        let phoneEntities = entities.filter { $0.kind == .phoneNumber }
        #expect(!phoneEntities.isEmpty)
        // NSDataDetector normalizes phone numbers to digits-only or
        // includes punctuation depending on locale — assert the
        // display string contains the literal subsequence the user
        // sees, not a precise format.
        #expect(phoneEntities.first?.displayString.contains("415") == true)
    }

    @Test func detectsURLInOCRBoxText() async throws {
        let entities = PaceOCRDataDetector.detectEntities(
            in: "more info at https://example.com/docs?ref=pace"
        )
        let urlEntities = entities.filter { $0.kind == .url }
        #expect(urlEntities.first?.normalizedValue.contains("example.com") == true)
    }

    @Test func detectsEmailAsSeparateKindFromGenericURL() async throws {
        // NSDataDetector classifies email addresses as mailto: links
        // under the .link checking type. Our wrapper splits them
        // back out to the explicit .emailAddress kind so callers
        // can dispatch on kind directly.
        let entities = PaceOCRDataDetector.detectEntities(in: "email me at hello@example.com")
        let emailEntities = entities.filter { $0.kind == .emailAddress }
        #expect(emailEntities.first?.normalizedValue == "hello@example.com")
        // And it should NOT also leak through as a .url entity.
        let urlEntities = entities.filter { $0.kind == .url }
        #expect(urlEntities.isEmpty)
    }

    @Test func detectsDateInOCRBoxText() async throws {
        let entities = PaceOCRDataDetector.detectEntities(in: "meeting on March 5, 2026 at 3pm")
        let dateEntities = entities.filter { $0.kind == .date }
        #expect(!dateEntities.isEmpty)
        // Normalized to ISO 8601 so the planner can ingest it cleanly.
        #expect(dateEntities.first?.normalizedValue.contains("2026") == true)
    }

    @Test func returnsEmptyListForTextWithNoEntities() async throws {
        let entities = PaceOCRDataDetector.detectEntities(
            in: "this sentence contains no detectable entities"
        )
        #expect(entities.isEmpty)
    }

    @Test func returnsEmptyListForEmptyOrWhitespaceInput() async throws {
        #expect(PaceOCRDataDetector.detectEntities(in: "").isEmpty)
        #expect(PaceOCRDataDetector.detectEntities(in: "   \n\t  ").isEmpty)
    }

    @Test func rendersPromptFragmentWithLabelledLines() async throws {
        let entities: [PaceDetectedEntity] = [
            PaceDetectedEntity(
                kind: .phoneNumber,
                normalizedValue: "+14155551234",
                displayString: "(415) 555-1234",
                nsRange: NSRange(location: 0, length: 0)
            ),
            PaceDetectedEntity(
                kind: .emailAddress,
                normalizedValue: "hello@example.com",
                displayString: "hello@example.com",
                nsRange: NSRange(location: 0, length: 0)
            ),
        ]
        let prompt = PaceOCRDataDetector.renderEntitiesForPlannerPrompt(entities)
        #expect(prompt == "PHONE: +14155551234\nEMAIL: hello@example.com")
    }

    @Test func rendersNilWhenEntityListIsEmpty() async throws {
        let prompt = PaceOCRDataDetector.renderEntitiesForPlannerPrompt([])
        #expect(prompt == nil)
    }
}
