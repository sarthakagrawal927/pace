//
//  LocalVLMClient.swift
//  leanring-buddy
//
//  Talks to a local vision-language model served by LM Studio (or any
//  other OpenAI-compatible runtime) over loopback HTTP. Sends a screenshot plus
//  a structured prompt and returns a parsed element map describing the
//  interactive UI elements and key text on screen.
//
//  The output is designed to be passed as a *text* block alongside the
//  user's transcript to the local planner. That way the VLM specializes
//  in perception and the planner specializes in action/answer selection,
//  while raw screen pixels never leave the Mac.
//

import Foundation

/// Describes one interactive element or block of text the local VLM
/// found on screen. Coordinates and sizes are in screen pixels.
nonisolated struct LocalVLMScreenElement: Codable, Hashable {
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

nonisolated struct LocalVLMScreenAnalysis: Codable {
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
        self.description = Self.normalizedDescription(description, elements: elements)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.elements = try container.decode([LocalVLMScreenElement].self, forKey: .elements)
        // If description is missing/null, synthesize one from the element
        // list rather than throwing — see field doc-comment above.
        let decodedDescription = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? ""
        self.description = Self.normalizedDescription(decodedDescription, elements: elements)
    }

    private enum CodingKeys: String, CodingKey {
        case elements
        case description
    }

    static func synthesizedDescription(from elements: [LocalVLMScreenElement]) -> String {
        let candidateTexts = elements
            .prefix(6)
            .compactMap { element -> String? in
                let text = element.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let bestText = text?.isEmpty == false ? text! : label
                let compactText = bestText
                    .replacingOccurrences(of: "\n", with: " ")
                    .split(separator: " ")
                    .prefix(4)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !compactText.isEmpty else { return nil }
                return compactText
            }

        guard !candidateTexts.isEmpty else { return "" }

        let uniqueCandidateTexts = candidateTexts.reduce(into: [String]()) { partialResult, candidateText in
            guard !partialResult.contains(where: { $0.caseInsensitiveCompare(candidateText) == .orderedSame }) else {
                return
            }
            partialResult.append(candidateText)
        }

        return "Screen contains: \(uniqueCandidateTexts.prefix(4).joined(separator: ", "))."
    }

    private static func normalizedDescription(
        _ rawDescription: String,
        elements: [LocalVLMScreenElement]
    ) -> String {
        let trimmedDescription = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedDescription.isEmpty else { return trimmedDescription }
        return synthesizedDescription(from: elements)
    }
}

struct LocalVLMClientError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

protocol PaceScreenAnalysisClient: AnyObject, Sendable {
    var displayName: String { get }

    func analyzeScreenshot(
        screenshotImageData: Data,
        userIntent: String
    ) async throws -> LocalVLMScreenAnalysis
}

enum PaceScreenAnalysisClientFactory {
    static func makeDefaultClient() -> any PaceScreenAnalysisClient {
        makeClient(
            configuredProviderName: AppBundleConfiguration.stringValue(forKey: "ScreenAnalysisProvider"),
            configuredBaseURL: AppBundleConfiguration.stringValue(forKey: "LocalVLMBaseURL"),
            configuredModelIdentifier: AppBundleConfiguration.stringValue(forKey: "LocalVLMModelIdentifier"),
            isInProcessRuntimeAvailable: InProcessVLMClient.isRuntimeAvailable
        )
    }

    static func makeClient(
        configuredProviderName: String?,
        configuredBaseURL: String?,
        configuredModelIdentifier: String?,
        isInProcessRuntimeAvailable: Bool
    ) -> any PaceScreenAnalysisClient {
        let normalizedProviderName = configuredProviderName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")

        let modelIdentifier = configuredModelIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
            ? configuredModelIdentifier!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "qwen3-vl-8b-instruct"

        switch normalizedProviderName {
        case "inprocess", "coreml", "mlx", "ane":
            if isInProcessRuntimeAvailable {
                let client = InProcessVLMClient(modelIdentifier: modelIdentifier)
                print("👁️ Screen analysis: using \(client.displayName)")
                return client
            }
            print("⚠️ Screen analysis: in-process VLM requested but runtime is unavailable; falling back to LM Studio HTTP")
            fallthrough
        case "lmstudio", "http", "openai", .none:
            let baseURLString = configuredBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedBaseURL = PaceLocalEndpointGuard.resolvedLocalOpenAICompatibleBaseURL(
                configuredURLString: baseURLString,
                settingName: "LocalVLMBaseURL"
            )
            let client = LocalVLMClient(baseURL: resolvedBaseURL, modelIdentifier: modelIdentifier)
            print("👁️ Screen analysis: using \(client.displayName)")
            return client
        default:
            print("⚠️ Screen analysis: unknown provider '\(configuredProviderName ?? "nil")'; falling back to LM Studio HTTP")
            let baseURLString = configuredBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedBaseURL = PaceLocalEndpointGuard.resolvedLocalOpenAICompatibleBaseURL(
                configuredURLString: baseURLString,
                settingName: "LocalVLMBaseURL"
            )
            let client = LocalVLMClient(baseURL: resolvedBaseURL, modelIdentifier: modelIdentifier)
            print("👁️ Screen analysis: using \(client.displayName)")
            return client
        }
    }
}

final class InProcessVLMClient: PaceScreenAnalysisClient, @unchecked Sendable {
    static let isRuntimeAvailable = false

    let modelIdentifier: String

    var displayName: String {
        "In-process VLM (\(modelIdentifier))"
    }

    init(modelIdentifier: String) {
        self.modelIdentifier = modelIdentifier
    }

    func analyzeScreenshot(
        screenshotImageData: Data,
        userIntent: String
    ) async throws -> LocalVLMScreenAnalysis {
        throw LocalVLMClientError(
            message: "In-process VLM is configured but the CoreML/MLX runtime bridge is not installed in Pace yet."
        )
    }
}

/// Talks to a local OpenAI-compatible chat-completions endpoint (LM Studio
/// by default) to extract a structured element map from a screenshot.
final class LocalVLMClient: PaceScreenAnalysisClient, @unchecked Sendable {
    private let baseURL: URL
    private let modelIdentifier: String
    private let urlSession: URLSession

    var displayName: String {
        "LM Studio VLM (\(modelIdentifier))"
    }

    /// `baseURL` should point at the OpenAI-compatible root (e.g.
    /// `http://localhost:1234/v1`). `modelIdentifier` is the model name
    /// as shown in LM Studio (e.g. `qwen3-vl-8b-instruct`).
    init(
        baseURL: URL = URL(string: "http://localhost:1234/v1")!,
        modelIdentifier: String = "qwen3-vl-8b-instruct"
    ) {
        self.baseURL = PaceLocalEndpointGuard.resolvedLocalOpenAICompatibleBaseURL(
            configuredURL: baseURL,
            settingName: "LocalVLMBaseURL"
        )
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

        let requestStartedAt = Date()
        func auditVLMCall(outcome: String, outputCharacterCount: Int? = nil, detail: String? = nil) {
            PaceAPIAuditLog.shared.record(
                subsystem: "vlm",
                operation: "chat.completions.image",
                target: modelIdentifier,
                durationMilliseconds: Int(Date().timeIntervalSince(requestStartedAt) * 1000),
                outcome: outcome,
                outputCharacterCount: outputCharacterCount,
                detail: detail
            )
        }

        let responseData: Data
        let urlResponse: URLResponse
        do {
            (responseData, urlResponse) = try await urlSession.data(for: request)
        } catch {
            auditVLMCall(outcome: "transport_error", detail: String(error.localizedDescription.prefix(160)))
            throw error
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            auditVLMCall(outcome: "non_http_response")
            throw LocalVLMClientError(message: "Local VLM returned a non-HTTP response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "<binary>"
            auditVLMCall(outcome: "http_\(httpResponse.statusCode)", detail: String(errorBody.prefix(160)))
            throw LocalVLMClientError(
                message: "Local VLM error (\(httpResponse.statusCode)): \(errorBody)"
            )
        }

        do {
            let analysis = try Self.parseChatCompletionResponse(responseData)
            auditVLMCall(outcome: "ok", outputCharacterCount: responseData.count, detail: "\(analysis.elements.count) elements")
            return analysis
        } catch {
            auditVLMCall(outcome: "decode_error", detail: String(error.localizedDescription.prefix(160)))
            throw error
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
