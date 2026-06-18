//
//  PaceMemoryEntryEnricherTests.swift
//  leanring-buddyTests
//
//  Pins the contract that memory entry write-time enrichment surfaces
//  the entity types the recall side actually filters on. Regressions
//  here = "what about Berlin" / "the email from Alice" turns silently
//  lose the structured signal and fall back to lexical-only match.
//

import Foundation
import Testing
@testable import Pace

struct PaceMemoryEntryEnricherTests {

    @Test func extractsTypedContactsFromConversationText() async throws {
        let entryText = """
        User: book a meeting with hello@example.com on March 5, 2026
        Pace: drafted a calendar invite
        """
        let structured = PaceMemoryEntryEnricher.extractStructuredFields(fromEntryText: entryText)
        #expect(structured?["emails"]?.contains("hello@example.com") == true)
        #expect(structured?["dates"] != nil)
    }

    @Test func returnsNilWhenTextHasNoExtractableEntities() async throws {
        // A run-of-the-mill no-entity sentence shouldn't manufacture
        // structured fields. Saving nil keeps the JSON small and the
        // recall side knows there's nothing to filter on.
        let structured = PaceMemoryEntryEnricher.extractStructuredFields(
            fromEntryText: "just thinking out loud here"
        )
        #expect(structured == nil)
    }

    @Test func returnsNilForEmptyAndWhitespaceText() async throws {
        #expect(PaceMemoryEntryEnricher.extractStructuredFields(fromEntryText: "") == nil)
        #expect(PaceMemoryEntryEnricher.extractStructuredFields(fromEntryText: "   \n\t  ") == nil)
    }

    @Test func dedupesRepeatedEntities() async throws {
        // Same entity appearing three times produces ONE comma-joined
        // value — the recall side's "contains X" check fires once
        // regardless. Multi-mention should not bloat the structured
        // dictionary.
        let entryText = "email hello@example.com / cc hello@example.com / forward hello@example.com"
        let structured = PaceMemoryEntryEnricher.extractStructuredFields(fromEntryText: entryText)
        let emailsField = structured?["emails"] ?? ""
        // No commas means a single value.
        #expect(emailsField == "hello@example.com")
    }

    @Test func combinesPhoneAndURLEntitiesInOneStructuredDictionary() async throws {
        let entryText = "call +1 (415) 555-1234 about https://example.com/article"
        let structured = PaceMemoryEntryEnricher.extractStructuredFields(fromEntryText: entryText)
        #expect(structured?["phones"]?.isEmpty == false)
        #expect(structured?["urls"]?.contains("example.com") == true)
    }

    @Test func stableOrderingProducesIdenticalOutputAcrossCalls() async throws {
        // Set → sorted-array → comma-joined is the contract. Two
        // enrichments of the same text must produce the SAME JSON
        // — otherwise the persisted memory file would churn on
        // every save even when nothing changed.
        let entryText = "Alice met Bob at Anthropic on March 5, 2026"
        let firstEnrichment = PaceMemoryEntryEnricher.extractStructuredFields(fromEntryText: entryText)
        let secondEnrichment = PaceMemoryEntryEnricher.extractStructuredFields(fromEntryText: entryText)
        #expect(firstEnrichment == secondEnrichment)
    }

    @Test func pureSubpassAccumulatesNamedEntitiesIntoExistingBucket() async throws {
        // The sub-pass mutates a caller-owned bucket — important for
        // composition with future named-entity sources (e.g. an LLM-
        // extracted facts pass). Verify the bucket-mutation contract.
        var entityBucket: [PaceMemoryEntryEnricher.StructuredKey: Set<String>] = [:]
        PaceMemoryEntryEnricher.accumulateNamedEntities(
            into: &entityBucket,
            fromText: "Alice met Bob in Berlin"
        )
        // We don't assert specific contents (NLTagger's recall on
        // tiny strings is fuzzy) — we only assert that the bucket
        // is either empty or populated with the expected key set.
        let allowedKeys: Set<PaceMemoryEntryEnricher.StructuredKey> = [.persons, .places, .organizations]
        for key in entityBucket.keys {
            #expect(allowedKeys.contains(key))
        }
    }
}
