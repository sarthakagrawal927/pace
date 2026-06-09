//
//  LocalVLMScreenAnalysisDecoderTests.swift
//  leanring-buddyTests
//
//  Pace's Local VLM (ui-venus-1.5-2b) is documented as returning STRICT
//  JSON with both `elements` and `description` fields. In practice the
//  2B model occasionally drops the `description` field on dense screens
//  like Xcode, returning just `{"elements":[…]}`. Before, that hard-
//  failed the whole turn's screen analysis. We now decode the missing
//  description from the element list so useful screen context still
//  flows through to the planner.
//
//  These tests pin that behaviour down so a future "tighten the
//  decoder" PR doesn't silently regress the Xcode-screen case.
//

import Testing
import Foundation
@testable import Pace

struct LocalVLMScreenAnalysisDecoderTests {

    @Test func wellFormedJSONStillDecodes() throws {
        let wellFormedJSON = """
        {
          "elements": [
            {"label": "search", "role": "button", "bbox": [10, 20, 100, 30], "text": "Search"}
          ],
          "description": "a search bar at the top of the screen"
        }
        """.data(using: .utf8)!

        let analysis = try JSONDecoder().decode(LocalVLMScreenAnalysis.self, from: wellFormedJSON)

        #expect(analysis.elements.count == 1)
        #expect(analysis.elements.first?.label == "search")
        #expect(analysis.description == "a search bar at the top of the screen")
    }

    @Test func missingDescriptionSynthesizesFromElements() throws {
        // Exact shape ui-venus-1.5-2b returns on dense Xcode screens.
        // Reproduced from user's PTT log on 2026-05-29.
        let elementsOnlyJSON = """
        {
          "elements": [
            {"label": "Xcode application window", "role": "window", "bbox": [107, 39, 865, 942]}
          ]
        }
        """.data(using: .utf8)!

        let analysis = try JSONDecoder().decode(LocalVLMScreenAnalysis.self, from: elementsOnlyJSON)

        #expect(analysis.elements.count == 1)
        #expect(analysis.description == "Screen contains: Xcode application window.")
    }

    @Test func nullDescriptionWithNoElementsDecodesAsEmptyString() throws {
        let nullDescriptionJSON = """
        {
          "elements": [],
          "description": null
        }
        """.data(using: .utf8)!

        let analysis = try JSONDecoder().decode(LocalVLMScreenAnalysis.self, from: nullDescriptionJSON)

        #expect(analysis.description == "")
    }

    @Test func emptyDescriptionSynthesizesFromElementTextAndLabels() throws {
        let emptyDescriptionJSON = """
        {
          "elements": [
            {"label": "send button", "role": "button", "bbox": [10, 20, 100, 30], "text": "Send"},
            {"label": "subject field", "role": "text_field", "bbox": [10, 60, 200, 30], "text": null},
            {"label": "send button duplicate", "role": "button", "bbox": [220, 20, 100, 30], "text": "Send"}
          ],
          "description": ""
        }
        """.data(using: .utf8)!

        let analysis = try JSONDecoder().decode(LocalVLMScreenAnalysis.self, from: emptyDescriptionJSON)

        #expect(analysis.description == "Screen contains: Send, subject field.")
    }

    @Test func missingElementsStillThrows() throws {
        // Elements are load-bearing — without them the analysis is
        // genuinely useless and the caller should fall back to OCR-only.
        // Only `description` is soft-optional.
        let noElementsJSON = """
        {
          "description": "just a description, no elements at all"
        }
        """.data(using: .utf8)!

        #expect(throws: Error.self) {
            _ = try JSONDecoder().decode(LocalVLMScreenAnalysis.self, from: noElementsJSON)
        }
    }

    // MARK: - Role sanitization
    //
    // ui-venus emits pipe-separated multi-role strings for composite
    // elements ("window|text_area|image"). The element list later gets
    // formatted as `[N] role|x,y|label|text` for the planner — leaving
    // pipes in the role corrupts that line. Collapse to first token.

    @Test func singleRoleIsUnchanged() throws {
        #expect(LocalVLMScreenElement.sanitizeRoleValue("button") == "button")
        #expect(LocalVLMScreenElement.sanitizeRoleValue("text_field") == "text_field")
    }

    @Test func pipeSeparatedRoleCollapsesToFirstToken() throws {
        #expect(LocalVLMScreenElement.sanitizeRoleValue("window|text_area|image") == "window")
        #expect(LocalVLMScreenElement.sanitizeRoleValue("button|link") == "button")
    }

    @Test func roleWithLeadingPipeFallsThroughToFirstNonEmpty() throws {
        // Defensive — VLM probably won't do this but the function shouldn't crash.
        #expect(LocalVLMScreenElement.sanitizeRoleValue("|button|link") == "button")
    }

    @Test func decodingElementWithPipeRoleSanitizesIt() throws {
        let elementWithPipeRoleJSON = """
        {
          "elements": [
            {"label": "Xcode window", "role": "window|text_area|image", "bbox": [107, 39, 865, 942]}
          ],
          "description": ""
        }
        """.data(using: .utf8)!

        let analysis = try JSONDecoder().decode(LocalVLMScreenAnalysis.self, from: elementWithPipeRoleJSON)

        #expect(analysis.elements.first?.role == "window", "pipe-roles must be collapsed at decode time")
        #expect(analysis.description == "Screen contains: Xcode window.")
    }
}
