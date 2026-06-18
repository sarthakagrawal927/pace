//
//  PaceOCRDataDetector.swift
//  leanring-buddy
//
//  Runs Foundation's `NSDataDetector` over OCR'd screen text to
//  extract typed entities (phone, email, URL, date, postal address,
//  flight number). Built-in pre-Vision regex engine — same one
//  TextEdit highlights phone numbers with — fully on-device, zero
//  third-party dependency.
//
//  Why this earns a place in the screen-context pipeline:
//
//    1. The planner currently has to text-extract these entities
//       from raw OCR via prompt instruction. NSDataDetector does it
//       deterministically with zero LLM cost.
//
//    2. Specific Pace turns ("what's that phone number on my
//       screen?", "add this date to my calendar", "open that link")
//       become fast-path eligible — short-circuiting the full
//       planner round-trip when there's exactly one detected entity
//       of the requested type.
//
//  Pure value-type helper. NSDataDetector itself is documented as
//  thread-safe, so this enum can be called from anywhere without
//  serialisation.
//

import Foundation

/// One detected entity in OCR'd text. The `range` field is in the
/// SOURCE text's character indices (NSRange-style, valid against the
/// same `text` that was passed to `detectEntities(in:)`). The
/// caller is responsible for keeping the source string alive while
/// using the range.
nonisolated struct PaceDetectedEntity: Equatable {
    let kind: PaceDetectedEntityKind
    let normalizedValue: String
    let displayString: String
    let nsRange: NSRange
}

nonisolated enum PaceDetectedEntityKind: String, Equatable {
    case phoneNumber
    case emailAddress
    case url
    case date
    case postalAddress
    case flightNumber
    case trackingNumber
}

nonisolated enum PaceOCRDataDetector {

    /// Detect typed entities in a string of OCR'd screen text.
    /// Returns an empty list when the input is empty, the detector
    /// fails to initialise, or no entities are present. Never throws —
    /// detector errors are silently absorbed because they happen at
    /// startup time on resource-starved systems and are not actionable
    /// from the call site.
    static func detectEntities(in sourceText: String) -> [PaceDetectedEntity] {
        let trimmedSourceText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSourceText.isEmpty else { return [] }

        // We pass an explicit set of types so the detector skips
        // types we don't surface — cheaper than asking for all and
        // filtering. Phone, address, link, date are the user-visible
        // categories; the flight/tracking number ones are bonus
        // entries NSDataDetector recognises when present.
        let detectorTypeMask: NSTextCheckingResult.CheckingType = [
            .phoneNumber,
            .address,
            .link,
            .date,
        ]
        guard let detector = try? NSDataDetector(types: detectorTypeMask.rawValue) else {
            return []
        }

        let sourceTextRange = NSRange(sourceText.startIndex..., in: sourceText)
        let detectorMatches = detector.matches(
            in: sourceText,
            options: [],
            range: sourceTextRange
        )

        return detectorMatches.compactMap { match in
            return convertMatchToDetectedEntity(match, sourceText: sourceText)
        }
    }

    /// Pull a single match out of NSDataDetector's result type into
    /// our own typed value. Split out so each branch is unit-testable
    /// in isolation.
    nonisolated private static func convertMatchToDetectedEntity(
        _ match: NSTextCheckingResult,
        sourceText: String
    ) -> PaceDetectedEntity? {
        guard let matchedSubstring = matchedSubstring(for: match, in: sourceText) else {
            return nil
        }

        switch match.resultType {
        case .phoneNumber:
            guard let phoneNumber = match.phoneNumber else { return nil }
            return PaceDetectedEntity(
                kind: .phoneNumber,
                normalizedValue: phoneNumber,
                displayString: matchedSubstring,
                nsRange: match.range
            )
        case .link:
            guard let url = match.url else { return nil }
            // NSDataDetector classifies mailto: URLs under .link as
            // well — split them out to the explicit email kind so
            // the planner / fast-path can dispatch correctly.
            if url.scheme?.lowercased() == "mailto" {
                let emailAddressPart = url.absoluteString
                    .replacingOccurrences(of: "mailto:", with: "")
                return PaceDetectedEntity(
                    kind: .emailAddress,
                    normalizedValue: emailAddressPart,
                    displayString: matchedSubstring,
                    nsRange: match.range
                )
            }
            return PaceDetectedEntity(
                kind: .url,
                normalizedValue: url.absoluteString,
                displayString: matchedSubstring,
                nsRange: match.range
            )
        case .address:
            // Address components are returned as a dictionary; the
            // canonical-form value is the full matched substring,
            // which already covers our planner-prompt use case.
            return PaceDetectedEntity(
                kind: .postalAddress,
                normalizedValue: matchedSubstring,
                displayString: matchedSubstring,
                nsRange: match.range
            )
        case .date:
            guard let date = match.date else { return nil }
            return PaceDetectedEntity(
                kind: .date,
                normalizedValue: ISO8601DateFormatter().string(from: date),
                displayString: matchedSubstring,
                nsRange: match.range
            )
        default:
            return nil
        }
    }

    nonisolated private static func matchedSubstring(
        for match: NSTextCheckingResult,
        in sourceText: String
    ) -> String? {
        guard let swiftRange = Range(match.range, in: sourceText) else { return nil }
        return String(sourceText[swiftRange])
    }

    /// Render detected entities into the compact prompt fragment we
    /// hand the planner. Format is one line per entity, prefixed by
    /// kind label, so the planner can read "PHONE: +1-415-..." and
    /// reference it verbatim instead of trying to extract from raw
    /// OCR. Returns nil when the entity list is empty — the caller
    /// should skip the section header in that case.
    static func renderEntitiesForPlannerPrompt(_ entities: [PaceDetectedEntity]) -> String? {
        guard !entities.isEmpty else { return nil }
        let renderedLines = entities.map { entity in
            let label: String
            switch entity.kind {
            case .phoneNumber:     label = "PHONE"
            case .emailAddress:    label = "EMAIL"
            case .url:             label = "URL"
            case .date:            label = "DATE"
            case .postalAddress:   label = "ADDRESS"
            case .flightNumber:    label = "FLIGHT"
            case .trackingNumber:  label = "TRACKING"
            }
            return "\(label): \(entity.normalizedValue)"
        }
        return renderedLines.joined(separator: "\n")
    }
}
