//
//  DirectAPIPlannerClient.swift
//  leanring-buddy
//
//  BuddyPlannerClient conformer that streams against an OpenAI-compatible
//  /v1/chat/completions endpoint using a BYO API key from the macOS
//  Keychain. The user picks this tier explicitly in Settings → Planner,
//  pastes their Anthropic / OpenAI / OpenRouter / Custom key, and Pace
//  routes turns directly to that provider.
//
//  This is one of two intentional breaks of Pace's no-cloud-LLM principle
//  (the other being CloudBridgePlannerClient). Both are user-consented,
//  default-off, and both tint the menu-bar capsule amber while a turn is
//  in flight so egress is always visible.
//
//  See PRD: docs/prds/planner-tier-picker.md
//

import Foundation

// MARK: - PaceDirectAPIError

enum PaceDirectAPIError: LocalizedError {
    /// The user has not stored an API key for the active provider. The
    /// factory falls back to LocalPlannerClient and surfaces a yellow
    /// "no key set" status row in Settings — the request never fires.
    case missingAPIKey(provider: PaceDirectAPIProvider)
    /// HTTP 401. Carved out as its own case so the panel can show a more
    /// helpful "your API key looks wrong" copy without parsing strings.
    case invalidAPIKey(provider: PaceDirectAPIProvider)
    /// Any non-2xx HTTP status. The raw upstream body is attached so the
    /// user sees the provider's verbatim error (`"model 'foo' does not
    /// exist"`) instead of a vague generic.
    case httpError(statusCode: Int, bodyExcerpt: String)
    /// SSE event payload that we could not decode as JSON.
    case malformedSSEPayload(rawLine: String)
    /// The server returned a non-HTTP response (should not happen against
    /// well-known cloud providers; fail closed anyway).
    case unexpectedNonHTTPResponse
    /// The validated endpoint URL was missing or invalid.
    case invalidEndpointURL(reason: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Direct API: no API key stored for \(provider.displayLabel). Open Settings → Planner → Direct API to paste one."
        case .invalidAPIKey(let provider):
            return "Direct API: \(provider.displayLabel) rejected the API key (HTTP 401). Re-check the key in Settings → Planner."
        case .httpError(let statusCode, let bodyExcerpt):
            return "Direct API HTTP \(statusCode): \(bodyExcerpt)"
        case .malformedSSEPayload(let rawLine):
            return "Direct API: malformed SSE event line: \(rawLine)"
        case .unexpectedNonHTTPResponse:
            return "Direct API: provider returned a non-HTTP response."
        case .invalidEndpointURL(let reason):
            return "Direct API: invalid endpoint URL — \(reason)"
        }
    }
}

// MARK: - DirectAPIPlannerClient

@MainActor
final class DirectAPIPlannerClient: BuddyPlannerClient {
    let displayName: String

    /// v1 keeps the Direct-API path text-only. The local VLM already
    /// serializes the screen into a text element map upstream, so paying
    /// to ship base64-encoded screenshots to a cloud model expands the
    /// attack surface for no immediate user benefit.
    let supportsImageInput = false

    private let provider: PaceDirectAPIProvider
    private let endpointURL: URL
    private let modelIdentifier: String
    private let urlSession: URLSession

    init(
        provider: PaceDirectAPIProvider,
        endpointURL: URL,
        modelIdentifier: String,
        urlSession: URLSession? = nil
    ) {
        self.provider = provider
        self.endpointURL = endpointURL
        self.modelIdentifier = modelIdentifier
        self.displayName = "Direct API \(provider.displayLabel) (\(modelIdentifier))"

        if let providedSession = urlSession {
            self.urlSession = providedSession
        } else {
            let urlSessionConfiguration = URLSessionConfiguration.default
            // Cloud streams can be slow on cold-load — match the cloud-bridge
            // client's timeouts so quality bars are aligned across tiers.
            urlSessionConfiguration.timeoutIntervalForRequest = 300
            urlSessionConfiguration.timeoutIntervalForResource = 360
            urlSessionConfiguration.waitsForConnectivity = false
            urlSessionConfiguration.urlCache = nil
            urlSessionConfiguration.httpCookieStorage = nil
            self.urlSession = URLSession(configuration: urlSessionConfiguration)
        }
    }

    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        if !images.isEmpty {
            print("ℹ️ DirectAPIPlannerClient: received \(images.count) image(s) but path is text-only — ignoring")
        }

        // Load the API key at request time. Holding the key in a local
        // String here is the ONLY legal place outside PaceKeychainStore
        // where the value exists in memory — never assign to a property,
        // never log, never include in audit-log detail strings.
        guard let apiKeyForProvider = PaceKeychainStore.loadAPIKey(for: provider),
              !apiKeyForProvider.isEmpty else {
            throw PaceDirectAPIError.missingAPIKey(provider: provider)
        }

        var messages: [[String: Any]] = []
        messages.append(["role": "system", "content": systemPrompt])
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }
        messages.append(["role": "user", "content": userPrompt])

        let requestBody: [String: Any] = [
            "model": modelIdentifier,
            "messages": messages,
            "max_tokens": 1024,
            "temperature": 0.4,
            "stream": true
        ]

        let requestBodyData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if provider.usesAnthropicAuthHeader {
            request.setValue(apiKeyForProvider, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(apiKeyForProvider)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = requestBodyData

        let estimatedInputCharacterCount =
            systemPrompt.count
            + userPrompt.count
            + conversationHistory.reduce(0) { $0 + $1.userPlaceholder.count + $1.assistantResponse.count }

        print("📡 Pace planner via Direct API — provider=\(provider.rawValue) model=\(modelIdentifier)")

        let startTime = Date()

        let (byteStream, response) = try await urlSession.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PaceDirectAPIError.unexpectedNonHTTPResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyLines: [String] = []
            for try await rawErrorLine in byteStream.lines {
                errorBodyLines.append(rawErrorLine)
                if errorBodyLines.count > 10 { break }
            }
            let errorBodyText = errorBodyLines.joined(separator: "\n")
            let truncatedErrorBodyExcerpt = String(errorBodyText.prefix(300))
            PaceAPIAuditLog.shared.record(
                subsystem: "planner.directAPI",
                operation: "chat.completions.stream",
                target: "\(provider.rawValue)/\(modelIdentifier)",
                durationMilliseconds: Int(Date().timeIntervalSince(startTime) * 1000),
                outcome: "http_\(httpResponse.statusCode)",
                inputCharacterCount: estimatedInputCharacterCount,
                detail: "tier=directAPI provider=\(provider.rawValue) status=\(httpResponse.statusCode)"
            )
            if httpResponse.statusCode == 401 {
                throw PaceDirectAPIError.invalidAPIKey(provider: provider)
            }
            throw PaceDirectAPIError.httpError(
                statusCode: httpResponse.statusCode,
                bodyExcerpt: truncatedErrorBodyExcerpt
            )
        }

        var accumulatedResponseText = ""
        var hasLoggedTimeToFirstToken = false

        for try await rawSSELine in byteStream.lines {
            guard rawSSELine.hasPrefix("data: ") else { continue }
            let payloadString = String(rawSSELine.dropFirst(6))
            if payloadString == "[DONE]" { break }

            guard let payloadData = payloadString.data(using: .utf8),
                  let payloadDictionary = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                if !payloadString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw PaceDirectAPIError.malformedSSEPayload(rawLine: rawSSELine)
                }
                continue
            }

            guard let choices = payloadDictionary["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any] else {
                continue
            }

            if let textChunk = delta["content"] as? String, !textChunk.isEmpty {
                if !hasLoggedTimeToFirstToken {
                    let timeToFirstTokenMs = Int(Date().timeIntervalSince(startTime) * 1000)
                    print("⚡ Direct API TTFT: \(timeToFirstTokenMs)ms (provider=\(provider.rawValue), model=\(modelIdentifier))")
                    hasLoggedTimeToFirstToken = true
                }
                accumulatedResponseText += textChunk
                // Same thinking-block strip as LocalPlannerClient — some
                // Anthropic-via-OAI-shim proxies surface `<think>…</think>`
                // blocks inline, and the spoken output must stay clean.
                let strippedSoFar = LocalPlannerClient.stripThinkingBlocks(from: accumulatedResponseText)
                onTextChunk(strippedSoFar)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        let strippedFinalText = LocalPlannerClient.stripThinkingBlocks(from: accumulatedResponseText)
        PaceAPIAuditLog.shared.record(
            subsystem: "planner.directAPI",
            operation: "chat.completions.stream",
            target: "\(provider.rawValue)/\(modelIdentifier)",
            durationMilliseconds: Int(duration * 1000),
            outcome: "ok",
            inputCharacterCount: estimatedInputCharacterCount,
            outputCharacterCount: strippedFinalText.count,
            detail: "tier=directAPI provider=\(provider.rawValue)"
        )
        return (text: strippedFinalText, duration: duration)
    }

    /// Builds the URLRequest that `generateResponseStreaming` would fire,
    /// without any network I/O. Exposed for unit tests verifying that
    /// each provider gets the correct authentication headers.
    nonisolated static func makeRequest(
        provider: PaceDirectAPIProvider,
        endpointURL: URL,
        modelIdentifier: String,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String
    ) throws -> URLRequest {
        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user",   "content": userPrompt]
        ]
        let requestBody: [String: Any] = [
            "model": modelIdentifier,
            "messages": messages,
            "max_tokens": 1024,
            "temperature": 0.4,
            "stream": true
        ]

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if provider.usesAnthropicAuthHeader {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        return request
    }
}
