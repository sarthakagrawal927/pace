//
//  LocalPlannerClient.swift
//  leanring-buddy
//
//  Text-only OpenAI-compatible chat-completions client that drives a
//  local reasoning model (LM Studio by default). The only conformer to
//  `BuddyPlannerClient` today.
//
//  This client has no vision — it relies on the local VLM's element-map
//  text being prepended to the user prompt upstream by
//  `CompanionManager.buildUserPromptWithLocalVLMContextIfEnabled`.
//

import Foundation

final class LocalPlannerClient: BuddyPlannerClient {
    let displayName: String

    /// Local 4-8B reasoners are text-only. CompanionManager will skip
    /// attaching screenshots when this is false and rely on the VLM's
    /// element-map text instead.
    let supportsImageInput = false

    private let baseURL: URL
    private let modelIdentifier: String
    private let urlSession: URLSession

    init(baseURL: URL, modelIdentifier: String) {
        self.baseURL = PaceLocalEndpointGuard.resolvedLocalOpenAICompatibleBaseURL(
            configuredURL: baseURL,
            settingName: "LocalPlannerBaseURL"
        )
        self.modelIdentifier = modelIdentifier
        self.displayName = "Local Planner (\(modelIdentifier))"

        let urlSessionConfiguration = URLSessionConfiguration.default
        // Local inference on small CPUs can spend a while on the first
        // token. 180s gives a cold-load model time without hanging the UI
        // indefinitely; warm calls are typically <5s.
        urlSessionConfiguration.timeoutIntervalForRequest = 180
        urlSessionConfiguration.timeoutIntervalForResource = 240
        urlSessionConfiguration.waitsForConnectivity = false
        urlSessionConfiguration.urlCache = nil
        urlSessionConfiguration.httpCookieStorage = nil
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
    }

    /// Construct from Info.plist values. Falls back to localhost:1234
    /// (LM Studio default) + a small Qwen reasoner when unset.
    /// Consults `PacePlannerModelResolver.resolvedIdentifier` first so
    /// that if the warmup step picked a different model (because the
    /// configured one wasn't loaded), every subsequent request uses
    /// the resolved one instead of 404ing.
    @MainActor
    static func makeFromInfoPlist() -> LocalPlannerClient {
        let configuredBaseURL = AppBundleConfiguration
            .stringValue(forKey: "LocalPlannerBaseURL")
            ?? "http://localhost:1234/v1"
        let configuredModelIdentifier = AppBundleConfiguration
            .stringValue(forKey: "LocalPlannerModelIdentifier")
            ?? "qwen3-4b-instruct"

        let resolvedBaseURL = PaceLocalEndpointGuard.resolvedLocalOpenAICompatibleBaseURL(
            configuredURLString: configuredBaseURL,
            settingName: "LocalPlannerBaseURL"
        )

        let effectiveModelIdentifier = PacePlannerModelResolver.resolvedIdentifier
            ?? configuredModelIdentifier

        return LocalPlannerClient(
            baseURL: resolvedBaseURL,
            modelIdentifier: effectiveModelIdentifier
        )
    }

    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        // Local reasoners are text-only. We discard images and rely on
        // the upstream local VLM having produced an element-map text
        // block that's already inside `userPrompt`. Log if images came
        // in so the user notices the mismatched config.
        if !images.isEmpty {
            print("ℹ️ LocalPlannerClient: received \(images.count) image(s) but model is text-only — ignoring")
        }

        let chatCompletionsURL = baseURL.appendingPathComponent("chat/completions")

        var messages: [[String: Any]] = []
        messages.append(["role": "system", "content": systemPrompt])
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }
        messages.append(["role": "user", "content": userPrompt])

        // 1024 max_tokens balances "thinking models need room for the
        // <think> block + answer" against "shorter cap = faster end-to-
        // end + TTS starts sooner". For voice UX, response brevity is
        // already enforced by the system prompt, so 1024 is plenty.
        //
        // `cache_prompt: true` is a hint understood by LM Studio's
        // llama.cpp engine (and llama-server directly) to reuse the KV
        // cache across requests that share a prefix. The MLX engine
        // auto-caches prefixes regardless. Unknown JSON fields are
        // ignored by spec-compliant OpenAI-compatible servers, so
        // sending it costs nothing if the runtime doesn't support it.
        //
        // The system prompt is a `static let` and the conversation
        // history is appended in order, so the request prefix is
        // byte-stable across turns — exactly what the cache wants.
        let requestBody: [String: Any] = [
            "model": modelIdentifier,
            "messages": messages,
            "max_tokens": 1024,
            "temperature": 0.4,
            "stream": true,
            "cache_prompt": true
        ]

        let maximumPlannerAttempts = 3

        for plannerAttemptNumber in 1...maximumPlannerAttempts {
            let startTime = Date()
            var requestBodyForAttempt = requestBody
            if plannerAttemptNumber > 1 {
                requestBodyForAttempt["cache_prompt"] = false
            }
            let requestBodyData = try JSONSerialization.data(withJSONObject: requestBodyForAttempt)
            var request = URLRequest(url: chatCompletionsURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // LM Studio doesn't require a real token; harmless dummy keeps
            // OpenAI-compatible proxies (LiteLLM, vLLM with auth) happy.
            request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
            request.httpBody = requestBodyData

            let (byteStream, response) = try await urlSession.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(
                    domain: "LocalPlannerClient",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Local planner returned a non-HTTP response."]
                )
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                var errorBodyChunks: [String] = []
                for try await line in byteStream.lines {
                    errorBodyChunks.append(line)
                }
                let errorBody = errorBodyChunks.joined(separator: "\n")
                throw NSError(
                    domain: "LocalPlannerClient",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Local planner HTTP \(httpResponse.statusCode): \(errorBody)"]
                )
            }

            var accumulatedResponseText = ""
            var hasLoggedTimeToFirstToken = false

            for try await line in byteStream.lines {
                // OpenAI-compatible SSE: every event is prefixed with `data: `.
                guard line.hasPrefix("data: ") else { continue }
                let jsonString = String(line.dropFirst(6))

                // End-of-stream sentinel.
                guard jsonString != "[DONE]" else { break }

                guard let jsonData = jsonString.data(using: .utf8),
                      let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let choices = eventPayload["choices"] as? [[String: Any]],
                      let firstChoice = choices.first,
                      let delta = firstChoice["delta"] as? [String: Any] else {
                    continue
                }

                // Some local servers also stream `reasoning_content` for
                // thinking models. We only surface the user-facing `content`.
                if let textChunk = delta["content"] as? String, !textChunk.isEmpty {
                    if !hasLoggedTimeToFirstToken {
                        let timeToFirstTokenMs = Int(Date().timeIntervalSince(startTime) * 1000)
                        print("⚡ Planner TTFT: \(timeToFirstTokenMs)ms (model=\(modelIdentifier), \(messages.count) msgs)")
                        PaceTelemetryLog.recordPlannerTimeToFirstToken(
                            milliseconds: timeToFirstTokenMs,
                            modelIdentifier: modelIdentifier,
                            messageCount: messages.count
                        )
                        hasLoggedTimeToFirstToken = true
                    }
                    accumulatedResponseText += textChunk
                    // Thinking models (Qwen3-Thinking, DeepSeek-R1-Distill, etc.)
                    // sometimes emit `<think>…</think>` blocks inline inside
                    // `content` rather than via a separate `reasoning_content`
                    // field. We strip them defensively so the spoken response
                    // and downstream action-tag parser never see thinking
                    // output. Stripping happens on every chunk so the UI
                    // preview (and the final `text` return) are both clean.
                    let strippedSoFar = LocalPlannerClient.stripThinkingBlocks(from: accumulatedResponseText)
                    let snapshotOfStrippedText = strippedSoFar
                    await onTextChunk(snapshotOfStrippedText)
                }
            }

            let duration = Date().timeIntervalSince(startTime)
            let strippedFinalText = LocalPlannerClient.stripThinkingBlocks(from: accumulatedResponseText)
            if !strippedFinalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (text: strippedFinalText, duration: duration)
            }

            print("⚠️ LocalPlannerClient: empty planner stream from \(modelIdentifier); retrying")
        }

        print("⚠️ LocalPlannerClient: streaming stayed empty; falling back to non-streaming completion")
        return try await generateNonStreamingFallbackResponse(
            chatCompletionsURL: chatCompletionsURL,
            requestBody: requestBody,
            messageCount: messages.count,
            onTextChunk: onTextChunk
        )
    }

    private func generateNonStreamingFallbackResponse(
        chatCompletionsURL: URL,
        requestBody: [String: Any],
        messageCount: Int,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        var fallbackRequestBody = requestBody
        fallbackRequestBody["stream"] = false
        fallbackRequestBody["cache_prompt"] = false

        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: fallbackRequestBody)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "LocalPlannerClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Local planner fallback returned a non-HTTP response."]
            )
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "LocalPlannerClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Local planner fallback HTTP \(httpResponse.statusCode): \(errorBody)"]
            )
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let rawContent = message["content"] as? String else {
            throw NSError(
                domain: "LocalPlannerClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Local planner fallback returned an unexpected payload."]
            )
        }

        let strippedContent = LocalPlannerClient.stripThinkingBlocks(from: rawContent)
        let duration = Date().timeIntervalSince(startTime)
        let fallbackLatencyMs = Int(duration * 1000)
        print("⚡ Planner fallback response: \(fallbackLatencyMs)ms (model=\(modelIdentifier), \(messageCount) msgs)")
        await onTextChunk(strippedContent)
        return (text: strippedContent, duration: duration)
    }

    /// Removes any `<think>…</think>` blocks (case-insensitive) from `rawAssistantText`.
    /// An unterminated open `<think>` at the tail of a still-streaming response
    /// is also dropped — that's the common mid-stream case where the closing
    /// tag hasn't arrived yet, and we don't want partial thinking output in
    /// the spoken preview.
    nonisolated static func stripThinkingBlocks(from rawAssistantText: String) -> String {
        guard !rawAssistantText.isEmpty else { return rawAssistantText }

        let lowercasedOpeningTag = "<think>"
        let lowercasedClosingTag = "</think>"

        var currentText = rawAssistantText
        // Repeat in case there are multiple complete blocks.
        while true {
            let lowercasedSnapshot = currentText.lowercased()
            guard let openingTagRange = lowercasedSnapshot.range(of: lowercasedOpeningTag) else {
                break
            }
            let closingSearchStart = openingTagRange.upperBound
            if let closingTagRange = lowercasedSnapshot.range(
                of: lowercasedClosingTag,
                range: closingSearchStart..<lowercasedSnapshot.endIndex
            ) {
                // Mirror the range from the lowercased snapshot into the
                // original-case text so we strip the exact bytes the user
                // sees, preserving any surrounding capitalisation.
                let originalStartOffset = lowercasedSnapshot.distance(
                    from: lowercasedSnapshot.startIndex,
                    to: openingTagRange.lowerBound
                )
                let originalEndOffset = lowercasedSnapshot.distance(
                    from: lowercasedSnapshot.startIndex,
                    to: closingTagRange.upperBound
                )
                let originalStart = currentText.index(currentText.startIndex, offsetBy: originalStartOffset)
                let originalEnd = currentText.index(currentText.startIndex, offsetBy: originalEndOffset)
                currentText.removeSubrange(originalStart..<originalEnd)
            } else {
                // Unterminated open tag — happens mid-stream before the
                // closing tag arrives. Drop everything from the opening
                // tag onward; the closing tag (and the rest of the
                // thinking body) will arrive in later chunks and be
                // stripped on the next call.
                let originalStartOffset = lowercasedSnapshot.distance(
                    from: lowercasedSnapshot.startIndex,
                    to: openingTagRange.lowerBound
                )
                let originalStart = currentText.index(currentText.startIndex, offsetBy: originalStartOffset)
                currentText.removeSubrange(originalStart..<currentText.endIndex)
                break
            }
        }

        return currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
