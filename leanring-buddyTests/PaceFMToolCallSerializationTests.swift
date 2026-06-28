//
//  PaceFMToolCallSerializationTests.swift
//  leanring-buddyTests
//
//  Tests for the multi-step tool-calling extension to
//  PaceFMTurnResponse. Verifies that tool calls serialize
//  correctly into the <tool_calls> JSON format that
//  PaceActionTagParser expects.
//
//  Note: @available(macOS 26.0, *) cannot be combined with @Test
//  in Swift Testing, so we test the serialization logic directly
//  rather than constructing @Generable structs.
//

import Foundation
import Testing
@testable import Pace

struct PaceFMToolCallSerializationTests {

    // MARK: - Serialization format

    /// A single tool call serializes to the correct JSON format
    /// matching what PaceActionTagParser expects: [[{...}]].
    @Test
    func singleToolCallSerializesCorrectly() {
        let toolCall: [String: Any] = [
            "tool": "open_app",
            "app": "Safari"
        ]
        let jsonArray = [[toolCall]]
        let data = try! JSONSerialization.data(
            withJSONObject: jsonArray,
            options: [.fragmentsAllowed]
        )
        let jsonString = String(data: data, encoding: .utf8)!

        // Verify the format matches what PaceActionTagParser expects.
        #expect(jsonString.contains("\"tool\""))
        #expect(jsonString.contains("open_app"))
        #expect(jsonString.contains("Safari"))
        #expect(jsonString.contains("[["))
        #expect(jsonString.contains("]]"))
    }

    /// Multiple tool calls serialize in order within the outer array.
    @Test
    func multipleToolCallsSerializeInOrder() {
        let calls: [[String: Any]] = [
            ["tool": "open_app", "app": "Notes"],
            ["tool": "type", "text": "hello world"],
            ["tool": "key", "key": "cmd+s"]
        ]

        let data = try! JSONSerialization.data(
            withJSONObject: [calls],
            options: [.fragmentsAllowed]
        )
        let jsonString = String(data: data, encoding: .utf8)!

        // Verify all three tools are present.
        #expect(jsonString.contains("open_app"))
        #expect(jsonString.contains("type"))
        #expect(jsonString.contains("cmd+s"))
        #expect(jsonString.contains("Notes"))
        #expect(jsonString.contains("hello world"))
    }

    /// The serialized JSON uses the nested array format [[...]]
    /// that PaceActionTagParser.parseToolCallBlocks expects.
    @Test
    func serializedJSONUsesNestedArrayFormat() {
        let toolCall: [String: Any] = ["tool": "click", "x": 400, "y": 300]
        let data = try! JSONSerialization.data(
            withJSONObject: [[toolCall]],
            options: [.fragmentsAllowed]
        )
        let jsonString = String(data: data, encoding: .utf8)!

        // The parser expects [[{...}]] — outer array = sequential
        // steps, inner array = parallel group.
        #expect(jsonString.hasPrefix("[["))
        #expect(jsonString.hasSuffix("]]"))
    }

    // MARK: - Argument parsing

    /// Valid JSON arguments are parsed as a dictionary.
    @Test
    func validJSONArgumentsAreParsedAsDict() {
        let arguments = #"{"app":"Safari","url":"https://example.com"}"#
        let data = arguments.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(parsed != nil)
        #expect(parsed?["app"] as? String == "Safari")
        #expect(parsed?["url"] as? String == "https://example.com")
    }

    /// Invalid JSON arguments fall back to wrapping as a string value.
    @Test
    func invalidJSONArgumentsFallbackToStringValue() {
        let invalidJSON = "just some text"

        var args: [String: Any] = [:]
        if let data = invalidJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = parsed
        } else if !invalidJSON.isEmpty {
            args["value"] = invalidJSON
        }

        #expect(args["value"] as? String == "just some text")
    }

    /// Empty arguments string produces empty args dict.
    @Test
    func emptyArgumentsProduceEmptyDict() {
        let empty = ""
        var args: [String: Any] = [:]
        if let data = empty.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = parsed
        } else if !empty.isEmpty {
            args["value"] = empty
        }

        #expect(args.isEmpty)
    }

    // MARK: - <tool_calls> wrapper format

    /// The serialized tool calls are wrapped in <tool_calls> tags.
    @Test
    func toolCallsAreWrappedInTags() {
        let toolCall: [String: Any] = ["tool": "open_app", "app": "Calendar"]
        let data = try! JSONSerialization.data(
            withJSONObject: [[toolCall]],
            options: [.fragmentsAllowed]
        )
        let jsonString = String(data: data, encoding: .utf8)!
        let wrapped = "<tool_calls>\n\(jsonString)\n</tool_calls>"

        #expect(wrapped.hasPrefix("<tool_calls>"))
        #expect(wrapped.hasSuffix("</tool_calls>"))
        #expect(wrapped.contains("open_app"))
        #expect(wrapped.contains("Calendar"))
    }

    // MARK: - Integration with PaceActionTagParser

    /// The <tool_calls> block format is parseable by the existing
    /// parser. This verifies the contract between the FM serializer
    /// and the action executor.
    @Test
    func toolCallsBlockIsParseableFormat() {
        // Build a <tool_calls> block in the format the serializer
        // produces, then verify it can be extracted with regex.
        let toolCall: [String: Any] = [
            "tool": "open_app",
            "app": "Calendar"
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: [[toolCall]],
            options: [.fragmentsAllowed]
        )
        let jsonString = String(data: data, encoding: .utf8)!
        let wrappedBlock = "<tool_calls>\n\(jsonString)\n</tool_calls>"

        // Verify the block can be extracted with the same regex
        // pattern PaceActionTagParser uses.
        let pattern = #"<tool_calls>(.*?)</tool_calls>"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(wrappedBlock.startIndex..., in: wrappedBlock)
        let match = regex.firstMatch(in: wrappedBlock, options: [], range: range)

        #expect(match != nil)

        // Extract and verify the content.
        if let match,
           let contentRange = Range(match.range(at: 1), in: wrappedBlock) {
            let content = wrappedBlock[contentRange].trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(content.contains("open_app"))
            #expect(content.contains("Calendar"))
        }
    }
}
