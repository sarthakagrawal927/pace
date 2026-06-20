//
//  PaceTagParsers.swift
//  leanring-buddy
//
//  Pure, isolation-free parsers for the inline tag dialect the local
//  planner emits — `[POINT:x,y]`, `[DONE]`, `[CLICK:…]`, etc. — plus the
//  cheap keyword heuristic that decides whether a transcript needs the
//  VLM at all.
//
//  Extracted from `CompanionManager` so each parser can be unit-tested
//  in isolation, and so the central state machine doesn't carry 150
//  lines of regex helpers.
//
//  All functions are `static`; no instance state. `nonisolated` where
//  the original code marked them so, so tests can call them off the
//  main actor.
//

import CoreGraphics
import Foundation

/// Result of parsing the trailing `[POINT:x,y:label:screenN]` tag from
/// the planner's response. The tag is removed from `spokenText` so the
/// TTS layer never speaks the literal coordinates.
struct PointingParseResult: Equatable {
    /// The response text with the `[POINT:…]` tag removed — this is what
    /// gets spoken aloud.
    let spokenText: String
    /// The parsed pixel coordinate, or `nil` if the planner said
    /// `[POINT:none]` or no tag was found.
    let coordinate: CGPoint?
    /// Short label describing the element (e.g. "run button"), or
    /// `"none"` when the planner explicitly opted out of pointing.
    let elementLabel: String?
    /// Which screen the coordinate refers to (1-based), or `nil` to
    /// default to the cursor screen.
    let screenNumber: Int?
}

enum PaceTagParsers {
    // MARK: - Agent-loop tags

    /// Max agent-loop iterations before the loop bails. 8 steps × ~5-8s
    /// per step keeps wall-clock under ~70s even on a slow local stack.
    /// Configurable via Info.plist `AgentMaxSteps`; clamped to [1, 30].
    nonisolated static func readMaxAgentStepCount() -> Int {
        guard let rawValue = AppBundleConfiguration.stringValue(forKey: "AgentMaxSteps"),
              let parsedValue = Int(rawValue),
              parsedValue >= 1 else {
            return 8
        }
        return min(parsedValue, 30)
    }

    /// Looks for a `[DONE]` (case-insensitive) anywhere in the planner
    /// response. Returns the strip-and-detect result so the agent loop
    /// knows when to exit and the TTS layer never speaks the literal tag.
    nonisolated static func parseAndStripDoneSignal(
        from rawAssistantText: String
    ) -> (didSignalDone: Bool, strippedText: String) {
        let donePattern = #"\[DONE\]"#
        guard let doneRegex = try? NSRegularExpression(pattern: donePattern, options: [.caseInsensitive]) else {
            return (false, rawAssistantText)
        }
        let entireRange = NSRange(rawAssistantText.startIndex..., in: rawAssistantText)
        let matchCount = doneRegex.numberOfMatches(in: rawAssistantText, options: [], range: entireRange)
        guard matchCount > 0 else {
            return (false, rawAssistantText)
        }
        let strippedText = doneRegex.stringByReplacingMatches(
            in: rawAssistantText,
            options: [],
            range: entireRange,
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return (true, strippedText)
    }

    // MARK: - VLM-skip heuristic

    /// Lower-cased tokens that suggest the user is referring to
    /// something on screen or asking for an action. Substring matching
    /// so plurals / tense variants ("clicking", "scrolled") catch.
    nonisolated private static let screenReferentialKeywords: Set<String> = [
        // Screen-MANIPULATION verbs — they act on something currently
        // visible, so the planner needs the element map.
        "click", "tap", "press", "save", "delete",
        "type", "write", "enter", "fill", "paste", "copy",
        "scroll", "select", "choose", "drag",
        // Visual deictic / pointer terms
        "where", "find", "show", "point", "highlight", "see", "look",
        "this", "that", "here", "there",
        // Names of screen artifacts
        "screen", "window", "page", "menu", "button", "field", "tab",
        "panel", "icon", "toolbar", "sidebar", "dialog", "form", "file"
        // NOTE: launch/navigate verbs — open, close, go to, navigate — are
        // deliberately NOT here. "open chrome" / "open hacker news" / "go to
        // github" are app/site launches that need NO screen context, so
        // forcing the 2-3s VLM on them was pure wasted latency. When an open
        // DOES target an on-screen element ("open the file menu"), the
        // artifact word above ("menu") still trips the VLM.
    ]

    /// Cheap heuristic: should we bother spinning up the local VLM for
    /// this turn? Pure-Q&A queries ("what is HTML?", "explain async")
    /// return false here and skip the perception call. Errs toward
    /// false positives — when in doubt, run the VLM.
    nonisolated static func transcriptIsLikelyScreenReferential(_ transcript: String) -> Bool {
        let normalizedTranscript = transcript.lowercased()
        for keyword in screenReferentialKeywords {
            if normalizedTranscript.contains(keyword) {
                return true
            }
        }
        return false
    }

    // MARK: - Point Tag Parsing

    /// Parses a `[POINT:x,y:label:screenN]` or `[POINT:none]` tag from
    /// the end of the planner's response. Returns the spoken text (tag
    /// removed) plus the optional coordinate / label / screen number.
    nonisolated static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(
                in: responseText,
                range: NSRange(responseText.startIndex..., in: responseText)
              ) else {
            // No tag found at all
            return PointingParseResult(
                spokenText: responseText,
                coordinate: nil,
                elementLabel: nil,
                screenNumber: nil
            )
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(
                spokenText: spokenText,
                coordinate: nil,
                elementLabel: "none",
                screenNumber: nil
            )
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4,
           let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange])
                .trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5,
           let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }
}
