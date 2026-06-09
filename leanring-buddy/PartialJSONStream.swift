import Foundation

/// Streaming partial-JSON parser — Swift port of the Python prototype
/// in tinygpt/scripts/partial_json_stream.py.
///
/// Pace's planner emits JSON of the shape:
///   {"spokenText": "...", "pointAtLabel": "...", "clickLabel": "..."}
///
/// To hit JARVIS-class perceived latency, Pace should start TTS on
/// the `spokenText` field's characters AS THEY GENERATE, not after
/// the closing brace arrives. The Python prototype measured a
/// ~200-400ms latency win on a typical planner call.
///
/// Usage:
///   let parser = PartialJSONStream()
///   parser.onChunk = { field, text in
///       if field == "spokenText" {
///           tts.speak(partial: text)   // stream into TTS pipeline
///       }
///   }
///   parser.onComplete = { field, value in
///       if field == "clickLabel" {
///           executor.click(elementWithLabel: value)
///       }
///   }
///   // Feed SSE delta chunks as they arrive from /v1/chat/completions:
///   for chunk in sseStream {
///       parser.feed(chunk)
///   }
///
/// Scope: flat `{"key": "string-value", ...}` JSON. Does NOT support
/// nested objects, arrays, numbers, booleans, or nulls in values —
/// Pace's schema is all strings.
public final class PartialJSONStream {
    private enum State {
        case beforeObject
        case inObject
        case readingKey
        case afterKey
        case afterColon
        case readingValue
        case afterValue
    }

    public var onStart: (String) -> Void = { _ in }
    public var onChunk: (String, String) -> Void = { _, _ in }
    public var onComplete: (String, String) -> Void = { _, _ in }

    private var state: State = .beforeObject
    private var keyBuf = ""
    private var valueBuf = ""
    private var currentField: String?
    private var escapeNext = false
    private(set) public var completeFields: [String: String] = [:]

    public init() {}

    public func reset() {
        state = .beforeObject
        keyBuf = ""
        valueBuf = ""
        currentField = nil
        escapeNext = false
        completeFields = [:]
    }

    /// Feed a chunk of UTF-8 text. May trigger any of the callbacks
    /// zero or more times.
    public func feed(_ chunk: String) {
        for ch in chunk {
            step(ch)
        }
    }

    private func step(_ ch: Character) {
        switch state {
        case .beforeObject:
            if ch == "{" { state = .inObject }
        case .inObject:
            if ch == "\"" {
                keyBuf = ""
                state = .readingKey
            } else if ch == "}" {
                state = .beforeObject
            }
        case .readingKey:
            if escapeNext {
                keyBuf.append(ch)
                escapeNext = false
            } else if ch == "\\" {
                escapeNext = true
            } else if ch == "\"" {
                state = .afterKey
            } else {
                keyBuf.append(ch)
            }
        case .afterKey:
            if ch == ":" { state = .afterColon }
        case .afterColon:
            if ch == "\"" {
                currentField = keyBuf
                valueBuf = ""
                if let f = currentField { onStart(f) }
                state = .readingValue
            }
            // Whitespace ignored; non-string values not supported.
        case .readingValue:
            guard let f = currentField else { return }
            if escapeNext {
                let decoded: Character
                switch ch {
                case "n":  decoded = "\n"
                case "t":  decoded = "\t"
                case "r":  decoded = "\r"
                case "\"": decoded = "\""
                case "\\": decoded = "\\"
                case "/":  decoded = "/"
                default:   decoded = ch
                }
                valueBuf.append(decoded)
                onChunk(f, String(decoded))
                escapeNext = false
            } else if ch == "\\" {
                escapeNext = true
            } else if ch == "\"" {
                let val = valueBuf
                completeFields[f] = val
                onComplete(f, val)
                currentField = nil
                valueBuf = ""
                state = .afterValue
            } else {
                valueBuf.append(ch)
                onChunk(f, String(ch))
            }
        case .afterValue:
            if ch == "," { state = .inObject }
            else if ch == "}" { state = .beforeObject }
        }
    }
}
