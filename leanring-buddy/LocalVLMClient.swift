//
//  LocalVLMClient.swift
//  leanring-buddy
//
//  Talks to a local vision-language model served by LM Studio (or any
//  other OpenAI-compatible runtime) over HTTP. Sends a screenshot plus
//  a structured prompt and returns a parsed element map describing the
//  interactive UI elements and key text on screen.
//
//  The output is designed to be passed as a *text* block alongside the
//  user's transcript to the cloud reasoning model (Claude). That way:
//    - The cloud model never sees raw screen pixels (privacy + cost).
//    - The local VLM specialises in perception (hot path, every turn).
//    - The cloud model specialises in planning (cold path, once per turn).
//
//  This file is intentionally self-contained and not yet wired into
//  CompanionManager — that wiring is the next phase of the build.
//

import Foundation

/// Describes one interactive element or block of text the local VLM
/// found on screen. Coordinates and sizes are in screen pixels.
struct LocalVLMScreenElement: Codable, Hashable {
    /// Short human-readable label, e.g. "Send" or "Email field".
    let label: String
    /// Role taxonomy borrowed from the macOS accessibility tree:
    /// "button", "text_field", "static_text", "link", "image", etc.
    ///
    /// Why this is sanitized at decode time: ui-venus-1.5-2b sometimes
    /// emits multi-role values like `"window|text_area|image"` for
    /// composite elements. CompanionManager later formats element lines
    /// as `[N] role|x,y|label|text` for the planner — an unsanitized
    /// pipe-role would split that line incorrectly. We collapse to the
    /// first non-empty token so the role stays a single taxonomy value.
    let role: String
    /// `[x, y, width, height]` of the element's bounding box, in pixels
    /// from the top-left of the screenshot.
    let bbox: [Int]
    /// Verbatim text content if the element contains readable text.
    let text: String?

    init(label: String, role: String, bbox: [Int], text: String?) {
        self.label = label
        self.role = role
        self.bbox = bbox
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.label = try container.decode(String.self, forKey: .label)
        let rawRole = try container.decode(String.self, forKey: .role)
        self.role = LocalVLMScreenElement.sanitizeRoleValue(rawRole)
        self.bbox = try container.decode([Int].self, forKey: .bbox)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
    }

    /// Returns the first non-empty pipe-separated token, trimmed.
    /// `"window|text_area|image"` → `"window"`. Single roles pass
    /// through unchanged.
    static func sanitizeRoleValue(_ raw: String) -> String {
        let firstToken = raw
            .split(separator: "|", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return firstToken?.isEmpty == false ? firstToken! : raw.trimmingCharacters(in: .whitespaces)
    }

    private enum CodingKeys: String, CodingKey {
        case label, role, bbox, text
    }
}

struct LocalVLMScreenAnalysis: Codable {
    let elements: [LocalVLMScreenElement]
    /// One-paragraph natural-language description of what's on screen.
    /// Useful as conversational context for the downstream planner LLM.
    ///
    /// Why this defaults to empty rather than being required: ui-venus
    /// (and likely other 2B-class VLMs) sometimes drops the description
    /// field entirely on dense screens like Xcode, returning just
    /// `{"elements":[…]}`. Hard-failing the whole analysis in that case
    /// forced Pace to fall back to OCR-only, even though the element
    /// list itself was useful. Treat the absence as a soft loss.
    let description: String

    init(elements: [LocalVLMScreenElement], description: String) {
        self.elements = elements
        self.description = description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.elements = try container.decode([LocalVLMScreenElement].self, forKey: .elements)
        // If description is missing/null, default to empty rather than
        // throwing — see field doc-comment above.
        self.description = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case elements
        case description
    }
}

struct LocalVLMClientError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// Talks to a local OpenAI-compatible chat-completions endpoint (LM Studio
/// by default) to extract a structured element map from a screenshot.
final class LocalVLMClient {
    private let baseURL: URL
    private let modelIdentifier: String
    private let urlSession: URLSession

    /// `baseURL` should point at the OpenAI-compatible root (e.g.
    /// `http://localhost:1234/v1`). `modelIdentifier` is the model name
    /// as shown in LM Studio (e.g. `qwen3-vl-8b-instruct`).
    init(
        baseURL: URL = URL(string: "http://localhost:1234/v1")!,
        modelIdentifier: String = "qwen3-vl-8b-instruct"
    ) {
        self.baseURL = baseURL
        self.modelIdentifier = modelIdentifier

        let urlSessionConfiguration = URLSessionConfiguration.default
        // Local inference can be slow on cold load (model swap, first prompt).
        // 120s gives headroom; subsequent calls are typically <5s on 7B VLMs.
        urlSessionConfiguration.timeoutIntervalForRequest = 120
        urlSessionConfiguration.timeoutIntervalForResource = 180
        urlSessionConfiguration.waitsForConnectivity = false
        urlSessionConfiguration.urlCache = nil
        urlSessionConfiguration.httpCookieStorage = nil
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
    }

    /// Sends `screenshotImageData` (JPEG or PNG) to the local VLM and
    /// returns the parsed element map. `userIntent` is the user's spoken
    /// transcript — passed to the VLM so it can prioritise elements the
    /// user is likely about to interact with (improves recall on busy
    /// screens).
    func analyzeScreenshot(
        screenshotImageData: Data,
        userIntent: String
    ) async throws -> LocalVLMScreenAnalysis {
        let chatCompletionsURL = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // LM Studio ignores Authorization by default but downstream
        // OpenAI-compatible proxies might require it. Sending a dummy token
        // is harmless and makes routing through tools like LiteLLM work.
        request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")

        let mediaType = Self.detectImageMediaType(for: screenshotImageData)
        let base64EncodedImage = screenshotImageData.base64EncodedString()
        let imageDataURL = "data:\(mediaType);base64,\(base64EncodedImage)"

        let systemInstruction = """
        You are a UI vision model. Output STRICT JSON only — no prose, no \
        markdown fences, no commentary outside the JSON object.

        Schema. `elements` FIRST, `description` LAST and SHORT:
        {"elements":[{"label":"<≤4 words>","role":"<button|text_field|static_text|link|image|menu_item|checkbox|tab|other>","bbox":[<x>,<y>,<w>,<h>],"text":"<verbatim or null>"}],"description":"<≤20 words, app + main view>"}

        HARD FORMATTING RULES — failure to follow these causes truncation:
        - Compact JSON only. NO indentation, NO newlines inside the object. \
          One element per line is fine; multi-line per element is NOT.
        - No trailing commas. Strings double-quoted. `text:null` (not \
          `text:"null"`) for non-text elements.
        - Coordinates are screen pixels, top-left origin.

        CONTENT RULES:
        - `description` is one terse sentence, not a paragraph.
        - Prefer high recall on interactive elements (buttons, fields, \
          links, tabs). Skip purely decorative chrome.
        - If the user intent below names a target, list that element first.
        """

        let userMessage: [[String: Any]] = [
            [
                "type": "text",
                "text": "User intent: \(userIntent)\n\nAnalyse the screenshot and return the JSON element map."
            ],
            [
                "type": "image_url",
                "image_url": [
                    "url": imageDataURL
                ]
            ]
        ]

        // No `response_format` field — LM Studio's MLX engine returns
        // HTTP 400 when given `"type": "json_object"` (it only accepts
        // `"json_schema"` with a real schema, or `"text"`). We rely on
        // the regex-extract fallback further down to pluck JSON out of
        // unstructured responses, which is what we did before anyway
        // when the model decided to wrap its JSON in prose.
        // max_tokens bumped 2048 → 4096. The 2B VLM pretty-printed each
        // element across multiple lines despite the prompt asking for
        // compact output (we just tightened the prompt above); 4096
        // gives headroom while the model still learns to be terse.
        // Real screens regularly need 30-50 elements; at ~30 tokens
        // per compact JSON element + 200 for the schema scaffold, 4096
        // comfortably fits.
        let requestBody: [String: Any] = [
            "model": modelIdentifier,
            "messages": [
                ["role": "system", "content": systemInstruction],
                ["role": "user", "content": userMessage]
            ],
            "temperature": 0.1,
            "max_tokens": 4096
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (responseData, urlResponse) = try await urlSession.data(for: request)

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw LocalVLMClientError(message: "Local VLM returned a non-HTTP response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "<binary>"
            throw LocalVLMClientError(
                message: "Local VLM error (\(httpResponse.statusCode)): \(errorBody)"
            )
        }

        return try Self.parseChatCompletionResponse(responseData)
    }

    /// True when an LM Studio (or compatible) server responds at `baseURL`.
    /// Use from the UI to surface "VLM not running" hints to the user
    /// without making them speak first.
    func isLocalVLMReachable() async -> Bool {
        let modelsURL = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - Response parsing

    private static func parseChatCompletionResponse(_ responseData: Data) throws -> LocalVLMScreenAnalysis {
        let topLevelJSON = try JSONSerialization.jsonObject(with: responseData)
        guard let topLevelDictionary = topLevelJSON as? [String: Any],
              let choices = topLevelDictionary["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let messageDictionary = firstChoice["message"] as? [String: Any],
              let messageContent = messageDictionary["content"] as? String else {
            throw LocalVLMClientError(message: "Local VLM response missing message content.")
        }

        let jsonStringToDecode = extractJSONObjectString(from: messageContent)

        guard let jsonData = jsonStringToDecode.data(using: .utf8) else {
            throw LocalVLMClientError(message: "Local VLM response was not valid UTF-8.")
        }

        do {
            return try JSONDecoder().decode(LocalVLMScreenAnalysis.self, from: jsonData)
        } catch {
            throw LocalVLMClientError(
                message: "Local VLM returned malformed JSON: \(error.localizedDescription). Raw content: \(messageContent.prefix(400))"
            )
        }
    }

    /// Some VLMs wrap their JSON in a ```json ... ``` fence or precede it
    /// with a sentence even when asked for strict JSON. This pulls the
    /// first {...} block out of the string so decoding can succeed.
    private static func extractJSONObjectString(from rawContent: String) -> String {
        let trimmedContent = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedContent.hasPrefix("{") && trimmedContent.hasSuffix("}") {
            return trimmedContent
        }

        // Strip ```json … ``` fence if present.
        if let codeFenceStartRange = trimmedContent.range(of: "```"),
           let codeFenceEndRange = trimmedContent.range(
               of: "```",
               range: codeFenceStartRange.upperBound..<trimmedContent.endIndex
           ) {
            var bodyInsideFence = String(trimmedContent[codeFenceStartRange.upperBound..<codeFenceEndRange.lowerBound])
            // The line right after the opening fence may say "json".
            if let firstNewlineIndex = bodyInsideFence.firstIndex(of: "\n") {
                let firstLine = bodyInsideFence[bodyInsideFence.startIndex..<firstNewlineIndex]
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if firstLine == "json" {
                    bodyInsideFence = String(bodyInsideFence[bodyInsideFence.index(after: firstNewlineIndex)...])
                }
            }
            return bodyInsideFence.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Greedy match the first {...} block, balancing braces.
        if let firstOpeningBraceIndex = trimmedContent.firstIndex(of: "{") {
            var braceDepth = 0
            var currentIndex = firstOpeningBraceIndex
            while currentIndex < trimmedContent.endIndex {
                let currentCharacter = trimmedContent[currentIndex]
                if currentCharacter == "{" { braceDepth += 1 }
                if currentCharacter == "}" {
                    braceDepth -= 1
                    if braceDepth == 0 {
                        return String(trimmedContent[firstOpeningBraceIndex...currentIndex])
                    }
                }
                currentIndex = trimmedContent.index(after: currentIndex)
            }
        }

        return trimmedContent
    }

    private static func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignaturePrefix: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignaturePrefix {
                return "image/png"
            }
        }
        return "image/jpeg"
    }
}
