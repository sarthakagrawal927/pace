//
//  PaceMemoryEntryEnricher.swift
//  leanring-buddy
//
//  Runs Apple's NaturalLanguage entity recognizer + NSDataDetector
//  over a memory entry's text at write time, and returns the extracted
//  structured fields that populate `PaceMemoryEntry.structured`.
//
//  Why at write time rather than recall time:
//
//    Pace's recall path runs on every voice/chat turn. Re-doing the
//    NL/NSDataDetector passes per turn would add latency to a hot
//    path AND would re-tokenise the same string many times across a
//    user's session. Extracting once at write time means recall just
//    reads `structured[...]` and matches deterministically.
//
//  Why both NLTagger + NSDataDetector:
//
//    NLTagger gives us named entities — `personalName` ("Alice"),
//    `placeName` ("Berlin"), `organizationName` ("Anthropic"). These
//    answer "what did Alice and I talk about", "anything about
//    Berlin", "what about my Anthropic contract".
//
//    NSDataDetector gives us typed contact / temporal entities —
//    phone, email, URL, date. These let "the article I sent on
//    march 5th" or "the email I got from hello@example.com" hit
//    the right entries without semantic match luck.
//
//  Pure value-type helper. No actor isolation, no I/O. The NL/NSData
//  passes themselves are documented-thread-safe by Apple, so this
//  enum can be called from background tasks or unit tests directly.
//

import Foundation
import NaturalLanguage

nonisolated enum PaceMemoryEntryEnricher {

    /// Keys in the returned dictionary — kept as constants so the
    /// recall side and the test fixtures both refer to the same
    /// strings.
    nonisolated enum StructuredKey: String {
        case persons        = "persons"
        case places         = "places"
        case organizations  = "organizations"
        case phoneNumbers   = "phones"
        case emails         = "emails"
        case urls           = "urls"
        case dates          = "dates"
    }

    /// Extract structured fields from `entryText`. Returns nil if
    /// nothing meaningful was extracted — caller should leave
    /// `PaceMemoryEntry.structured` at nil rather than store an
    /// empty dictionary (saves a few bytes per entry; an empty
    /// dictionary in JSON is noisier than absence).
    static func extractStructuredFields(fromEntryText entryText: String) -> [String: String]? {
        let trimmedEntryText = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEntryText.isEmpty else { return nil }

        var namedEntitiesByType: [StructuredKey: Set<String>] = [:]
        accumulateNamedEntities(into: &namedEntitiesByType, fromText: trimmedEntryText)
        accumulateTypedContactsAndDates(into: &namedEntitiesByType, fromText: trimmedEntryText)

        guard !namedEntitiesByType.isEmpty else { return nil }

        var result: [String: String] = [:]
        for (key, valuesSet) in namedEntitiesByType {
            // Comma-join with stable ordering so two enrichments of
            // the same text produce identical JSON — keeps diffs
            // small when the memory file is persisted.
            let sortedValues = valuesSet.sorted()
            result[key.rawValue] = sortedValues.joined(separator: ", ")
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Pure sub-passes (unit-testable in isolation)

    /// Run NLTagger with `.nameType` over the text and accumulate
    /// person/place/organization names.
    nonisolated static func accumulateNamedEntities(
        into bucket: inout [StructuredKey: Set<String>],
        fromText sourceText: String
    ) {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = sourceText
        let taggerOptions: NLTagger.Options = [
            .omitWhitespace,
            .omitPunctuation,
            .joinNames,  // "John F. Kennedy" stays one entity
        ]
        tagger.enumerateTags(
            in: sourceText.startIndex..<sourceText.endIndex,
            unit: .word,
            scheme: .nameType,
            options: taggerOptions
        ) { tag, tokenRange in
            guard let tag else { return true }
            let entityText = String(sourceText[tokenRange])
            switch tag {
            case .personalName:
                bucket[.persons, default: []].insert(entityText)
            case .placeName:
                bucket[.places, default: []].insert(entityText)
            case .organizationName:
                bucket[.organizations, default: []].insert(entityText)
            default:
                break
            }
            return true
        }
    }

    /// Run NSDataDetector via the existing `PaceOCRDataDetector` and
    /// fold the results into the same structured bucket. We reuse
    /// the OCR detector because both surfaces want the SAME entity
    /// semantics (mailto split out, ISO 8601 dates) — duplicating
    /// the detector setup would risk silent divergence.
    nonisolated static func accumulateTypedContactsAndDates(
        into bucket: inout [StructuredKey: Set<String>],
        fromText sourceText: String
    ) {
        let detectedEntities = PaceOCRDataDetector.detectEntities(in: sourceText)
        for entity in detectedEntities {
            switch entity.kind {
            case .phoneNumber:
                bucket[.phoneNumbers, default: []].insert(entity.normalizedValue)
            case .emailAddress:
                bucket[.emails, default: []].insert(entity.normalizedValue)
            case .url:
                bucket[.urls, default: []].insert(entity.normalizedValue)
            case .date:
                bucket[.dates, default: []].insert(entity.normalizedValue)
            case .postalAddress, .flightNumber, .trackingNumber:
                // Not in the unified memory schema today; skip
                // rather than invent a new key.
                break
            }
        }
    }
}
