//
//  PaceFMTurnResponse.swift
//  leanring-buddy
//
//  Typed output schema for Apple Foundation Models' planner path.
//
//  Why typed
//  ---------
//  The string-tag protocol ([CLICK:x,y], [POINT:x,y:label]) let the
//  3B model hallucinate coordinates — the most reliable failure mode
//  was "user asked to click X, X not in element list, model emits
//  [CLICK:1728,NNN] at the screen edge anyway." No amount of prompt
//  threatening fixed it because the model could ALWAYS write two
//  integers.
//
//  Here we replace the freeform integer fields with element IDs. The
//  prompt lists elements as `[N] role|x,y|label|text`. The model
//  picks integer IDs from that list (or -1 for "none"). The planner
//  looks the ID up in its own copy of the element list and resolves
//  to real coordinates. Coordinates can no longer be hallucinated
//  because the model never writes coordinates — only indices.
//
//  Multi-step tool-calling (from Agent!/macOS26)
//  ----------------------------------------------
//  The original schema only supported a single point + single click.
//  Agent! showed that Apple FM can do multi-step tool-calling where
//  the model emits a sequence of tool calls that the agent loop
//  executes one by one. We extend the schema with an optional
//  `toolCalls` array — each entry is a tool name + JSON arguments.
//  The agent loop serializes these into the same `<tool_calls>` JSON
//  format that PaceActionTagParser already understands, so the
//  existing execution path works unchanged.
//
//  Streaming caveat
//  ----------------
//  We were using `streamResponse(to: ..., generating: String.self)`
//  to get incremental Snapshot.content for the TTS pipeline. Typed
//  Generable streaming exposes `PartiallyGenerated` which is much
//  harder to feed into our existing sentence-streaming pipeline.
//  For this first cut we use non-streaming `respond(to:generating:)`
//  and TTS the whole `spokenText` at once. TTFSW gets a bit worse
//  but correctness gets dramatically better — and we re-introduce
//  streaming as a follow-up once we know the schema is right.
//

import Foundation
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct PaceFMToolCall {
    @Guide(description: "Tool name from the available tools list. Must be one of: click, type, key, scroll, open_app, open_url, music, volume, brightness, calendar, reminder, create_note, append_note, compose_mail, create_reminder, create_calendar_event, clipboard_read, clipboard_write, download_file, run_flow, record_flow, mcp, draw_annotation, clear_annotations, undo.")
    let tool: String

    @Guide(description: "JSON object with the tool's arguments. Example: {\"x\":400,\"y\":300} for click, {\"text\":\"hello\"} for type, {\"app\":\"Safari\"} for open_app.")
    let arguments: String
}

@available(macOS 26.0, *)
@Generable
struct PaceFMTurnResponse {
    @Guide(description: "What to say to the user, read aloud by text-to-speech. One or two short casual sentences. Lowercase, no markdown.")
    let spokenText: String

    @Guide(description: "ID of an element from the on-screen list to point the cursor at. Use the integer in brackets from the element list. Use -1 if no element should be pointed at (pure knowledge questions, or target not in list).")
    let pointAtElementId: Int

    @Guide(description: "ID of an element to click. Use the integer in brackets from the element list. Use -1 if no click is requested or if the target is not in the element list. Only emit a non-negative value when the user explicitly asked to click, tap, or press something.")
    let clickElementId: Int

    @Guide(description: "Optional list of tool calls for multi-step actions. Each call has a tool name and JSON arguments. Leave empty for simple point/click actions. The agent loop executes these in order after speaking.")
    var toolCalls: [PaceFMToolCall]?
}

// MARK: - Tool call serialization

@available(macOS 26.0, *)
extension PaceFMTurnResponse {
    /// Serialize the tool calls into the `<tool_calls>` JSON format
    /// that PaceActionTagParser expects. Returns nil if no tool calls
    /// are present.
    func serializedToolCallsJSON() -> String? {
        guard let calls = toolCalls, !calls.isEmpty else { return nil }

        var jsonArray: [[String: Any]] = []
        for call in calls {
            // Parse the arguments string as JSON; if it fails, wrap
            // it as a plain string value.
            var args: [String: Any] = [:]
            if let argsData = call.arguments.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                args = parsed
            } else if !call.arguments.isEmpty {
                args["value"] = call.arguments
            }

            var entry: [String: Any] = ["tool": call.tool]
            for (key, value) in args {
                entry[key] = value
            }
            jsonArray.append(entry)
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: [jsonArray],
            options: [.fragmentsAllowed]
        ),
        let jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }

        return "<tool_calls>\n\(jsonString)\n</tool_calls>"
    }
}
