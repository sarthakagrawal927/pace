//
//  CloudBridgePlannerClient.swift
//  leanring-buddy
//
//  BuddyPlannerClient conformer that routes turns through the sibling
//  local-ai Node bridge at http://localhost:3456. The bridge spawns the
//  user's already-authenticated Claude Code, Codex, or Gemini CLI and
//  streams the response back as SSE.
//
//  This is the ONLY intentional break of Pace's no-cloud-LLM principle.
//  It is consent-gated (PaceCloudBridgeConsent) and visually indicated
//  (isCloudBridgeCallActive → amber capsule tint). See PRD:
//  docs/prds/cloud-bridge-toggle.md
//
//  SSE shape from ../local-ai/index.mjs (source-verified):
//    data: {"text":"..."}\n\n  — token chunk
//    data: [DONE]\n\n          — stream complete
//    data: {"error":"..."}\n\n — upstream error (bridge surfaces these
//                               when the CLI itself errors; NOT used for
//                               network-level errors which throw instead)
//

import Foundation

// MARK: - Error type

enum PaceCloudBridgeError: LocalizedError {
    /// The upstream CLI (Claude Code / Codex / Gemini CLI) returned an error
    /// message. No retry — if the model itself failed, retrying burns more
    /// of the user's quota for the same outcome.
    case upstream(message: String)
    /// The bridge returned a non-HTTP response (should not happen against
    /// localhost, but fail-closed anyway).
    case unexpectedNonHTTPResponse
    /// The bridge returned an HTTP error (e.g. 400 unknown provider, 500
    /// internal error). The raw body is attached for the log.
    case httpError(statusCode: Int, body: String)
    /// The bridge response event contained JSON we could not parse.
    case malformedEventPayload(rawLine: String)

    var errorDescription: String? {
        switch self {
        case .upstream(let message):
            return "Cloud bridge upstream error: \(message)"
        case .unexpectedNonHTTPResponse:
            return "Cloud bridge returned a non-HTTP response."
        case .httpError(let statusCode, let body):
            return "Cloud bridge HTTP \(statusCode): \(body)"
        case .malformedEventPayload(let rawLine):
            return "Cloud bridge malformed SSE event: \(rawLine)"
        }
    }
}

// MARK: - CloudBridgePlannerClient

@MainActor
final class CloudBridgePlannerClient: BuddyPlannerClient {
    let displayName: String

    /// The bridge has no vision support — it accepts only text.
    /// CompanionManager will not attach screenshots when this is false.
    let supportsImageInput = false

    private let bridgeChatURL: URL
    private let upstreamProvider: PaceCloudBridgeUpstream
    private let modelIdentifier: String
    private let urlSession: URLSession

    init(
        bridgeBaseURL: URL,
        upstreamProvider: PaceCloudBridgeUpstream,
        modelIdentifier: String
    ) {
        let validatedBridgeBaseURL = PaceLocalEndpointGuard.validatedCloudBridgeURL(
            from: bridgeBaseURL.absoluteString
        )
        self.bridgeChatURL = validatedBridgeBaseURL.appendingPathComponent("chat")
        self.upstreamProvider = upstreamProvider
        self.modelIdentifier = modelIdentifier
        self.displayName = "\(upstreamProvider.displayLabel) (\(modelIdentifier))"

        let urlSessionConfiguration = URLSessionConfiguration.default
        // Cloud CLI calls can be slow, especially Gemini on first token.
        // 300s covers even very long model calls without hanging forever.
        urlSessionConfiguration.timeoutIntervalForRequest = 300
        urlSessionConfiguration.timeoutIntervalForResource = 360
        urlSessionConfiguration.waitsForConnectivity = false
        urlSessionConfiguration.urlCache = nil
        urlSessionConfiguration.httpCookieStorage = nil
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
    }

    /// Convenience constructor from the loaded configuration snapshot.
    convenience init(configuration: PaceCloudBridgeConfiguration) {
        self.init(
            bridgeBaseURL: configuration.baseURL,
            upstreamProvider: configuration.upstream,
            modelIdentifier: configuration.model
        )
    }

    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        // The bridge has no vision — discard images and log so the user
        // notices if their config somehow sends images here.
        // (routingHint is ignored by the bridge: it is always "large model")
        if !images.isEmpty {
            print("ℹ️ CloudBridgePlannerClient: received \(images.count) image(s) but bridge is text-only — ignoring")
        }

        // Build the messages array the bridge expects.
        // Conversation history turns are flattened into role-tagged messages.
        var messages: [[String: String]] = []
        for (userPlaceholderText, assistantResponseText) in conversationHistory {
            messages.append(["role": "user",      "content": userPlaceholderText])
            messages.append(["role": "assistant", "content": assistantResponseText])
        }
        messages.append(["role": "user", "content": userPrompt])

        // The bridge body: systemPrompt lives in a dedicated field, not in
        // the messages array, so providers that accept a --system-prompt flag
        // (Claude Code) can use it natively.
        var requestBodyDictionary: [String: Any] = [
            "provider": upstreamProvider.rawValue,
            "messages": messages
        ]
        if !systemPrompt.isEmpty {
            requestBodyDictionary["systemPrompt"] = systemPrompt
        }
        if !modelIdentifier.isEmpty {
            requestBodyDictionary["model"] = modelIdentifier
        }

        let requestBodyData = try JSONSerialization.data(withJSONObject: requestBodyDictionary)

        var urlRequest = URLRequest(url: bridgeChatURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = requestBodyData

        print("📡 Pace planner via cloud bridge — provider=\(upstreamProvider.rawValue) model=\(modelIdentifier)")

        let startTime = Date()

        let (byteStream, response) = try await urlSession.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PaceCloudBridgeError.unexpectedNonHTTPResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyLines: [String] = []
            for try await line in byteStream.lines {
                errorBodyLines.append(line)
                if errorBodyLines.count > 10 { break }
            }
            let errorBodyText = errorBodyLines.joined(separator: "\n")
            throw PaceCloudBridgeError.httpError(
                statusCode: httpResponse.statusCode,
                body: String(errorBodyText.prefix(300))
            )
        }

        var accumulatedResponseText = ""
        var hasLoggedTimeToFirstToken = false

        for try await line in byteStream.lines {
            // The bridge uses plain `data:` SSE lines (no `event:` prefix).
            // Format: `data: {"text":"..."}` or `data: [DONE]` or
            //         `data: {"error":"..."}`.
            guard line.hasPrefix("data: ") else { continue }
            let payloadString = String(line.dropFirst(6))

            // [DONE] is the end-of-stream sentinel.
            if payloadString == "[DONE]" { break }

            guard let payloadData = payloadString.data(using: .utf8),
                  let payloadDictionary = try? JSONSerialization.jsonObject(
                      with: payloadData
                  ) as? [String: Any] else {
                // Non-fatal: some SSE implementations emit blank data lines.
                // Only throw on lines that look like they should be parseable.
                if !payloadString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw PaceCloudBridgeError.malformedEventPayload(rawLine: line)
                }
                continue
            }

            // The bridge surfaces upstream CLI errors as `{"error":"..."}` events.
            // Fail fast — retrying a paid model call that already errored wastes quota.
            if let upstreamErrorMessage = payloadDictionary["error"] as? String {
                throw PaceCloudBridgeError.upstream(message: upstreamErrorMessage)
            }

            if let textChunk = payloadDictionary["text"] as? String, !textChunk.isEmpty {
                if !hasLoggedTimeToFirstToken {
                    let timeToFirstTokenMs = Int(Date().timeIntervalSince(startTime) * 1000)
                    print("⚡ Cloud bridge TTFT: \(timeToFirstTokenMs)ms (provider=\(upstreamProvider.rawValue))")
                    hasLoggedTimeToFirstToken = true
                }
                accumulatedResponseText += textChunk
                let accumulatedSnapshot = accumulatedResponseText
                onTextChunk(accumulatedSnapshot)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        let trimmedResponse = accumulatedResponseText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedResponse.isEmpty {
            print("⚠️ CloudBridgePlannerClient: empty response from bridge (provider=\(upstreamProvider.rawValue))")
        }

        return (text: trimmedResponse, duration: duration)
    }
}
