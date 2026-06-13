//
//  PaceThreadSummarizer.swift
//  leanring-buddy
//
//  Detached FM call that produces an updated rolling summary from
//  `(priorSummary, displacedTurnPair)`. Apple Foundation Models is
//  the preferred runtime because the call is short and latency-
//  sensitive; LM Studio is the fallback when Apple Intelligence is
//  unavailable.
//
//  Why this lives in its own file
//  ------------------------------
//  The summary prompt is a behavior contract — small wording changes
//  here change end-to-end memory quality, so it deserves a separate
//  diff-able artifact. Same reasoning as `CompanionSystemPrompt.swift`.
//
//  Latency target: ≤300ms warm. Detached from the user-facing turn
//  — `CompanionManager` never awaits this call inside the planner
//  path. The version snapshot the caller captures before invoking
//  this protects against out-of-order arrivals on the next turn.
//

import Foundation
import FoundationModels

// MARK: - Input

struct PaceThreadSummarizerInput {
    let priorSummary: String?
    let displacedTurnPair: PaceThreadTurnPair
    let sessionStartedAt: Date
    let frontmostApplicationName: String?
}

// MARK: - Protocol

protocol PaceThreadSummarizerClient {
    func updatedSummary(
        for input: PaceThreadSummarizerInput
    ) async throws -> String
}

// MARK: - Prompt rules

/// The prompt rules are pulled out as constants so they diff cleanly.
/// Any change here is a behavior change.
enum PaceThreadSummarizerPrompt {
    static let summarizerInstructions = """
    you are compressing a voice conversation between the user and pace, an on-device macos assistant.

    given a PRIOR_SUMMARY (may be empty) and a NEW_TURN that just fell out of the verbatim window, produce an UPDATED_SUMMARY of at most four sentences.

    rules:
    - preserve durable facts about user state, current task, and any pending intent the user expressed.
    - drop social filler, repeated greetings, and action-tag noise.
    - write in third person, present tense.
    - do not invent details that were not in the inputs.
    - never exceed four sentences or 400 tokens.
    """

    /// Render the user prompt the summarizer FM call sees. Layout is
    /// deterministic so the FM path can pattern-match.
    static func renderUserPrompt(for input: PaceThreadSummarizerInput) -> String {
        let priorSummaryBlock = input.priorSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let renderedPriorSummary = priorSummaryBlock.isEmpty ? "(empty — first compaction)" : priorSummaryBlock

        var userPromptPieces: [String] = []
        userPromptPieces.append("PRIOR_SUMMARY:\n\(renderedPriorSummary)")
        userPromptPieces.append("NEW_TURN:\nUser: \(input.displacedTurnPair.userText)\nPace: \(input.displacedTurnPair.assistantText)")
        if let frontmostApplicationName = input.frontmostApplicationName,
           !frontmostApplicationName.isEmpty {
            userPromptPieces.append("CONTEXT:\nfrontmost app at turn time: \(frontmostApplicationName)")
        }
        userPromptPieces.append("write the UPDATED_SUMMARY now.")
        return userPromptPieces.joined(separator: "\n\n")
    }
}

// MARK: - Apple FM client (preferred)

@available(macOS 26.0, *)
@Generable
struct PaceThreadSummaryResponse {
    @Guide(description: "Updated rolling summary, at most four sentences, third person, present tense. Do not invent details that were not in PRIOR_SUMMARY or NEW_TURN.")
    let updatedSummary: String
}

@available(macOS 26.0, *)
final class PaceThreadFoundationModelSummarizer: PaceThreadSummarizerClient {
    func updatedSummary(
        for input: PaceThreadSummarizerInput
    ) async throws -> String {
        let summarizerSession = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: { PaceThreadSummarizerPrompt.summarizerInstructions }
        )
        let renderedUserPrompt = PaceThreadSummarizerPrompt.renderUserPrompt(for: input)
        let deterministicGenerationOptions = GenerationOptions(
            samplingMode: .greedy,
            temperature: 0,
            maximumResponseTokens: 400
        )
        let typedResponse = try await summarizerSession.respond(
            to: renderedUserPrompt,
            generating: PaceThreadSummaryResponse.self,
            options: deterministicGenerationOptions
        )
        return typedResponse.content.updatedSummary
    }
}

// MARK: - LM Studio fallback

/// Used when Apple Intelligence is unavailable. Reuses the existing
/// loopback-guarded `LocalPlannerClient` HTTP shape — there is no new
/// network surface here, the call is the same OpenAI-compatible
/// `/v1/chat/completions` endpoint.
final class PaceThreadLMStudioSummarizer: PaceThreadSummarizerClient {
    private let localPlannerEndpointURL: URL
    private let configuredModelIdentifier: String

    init(
        localPlannerEndpointURL: URL,
        configuredModelIdentifier: String
    ) {
        self.localPlannerEndpointURL = localPlannerEndpointURL
        self.configuredModelIdentifier = configuredModelIdentifier
    }

    func updatedSummary(
        for input: PaceThreadSummarizerInput
    ) async throws -> String {
        let chatCompletionsURL = localPlannerEndpointURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        var urlRequest = URLRequest(url: chatCompletionsURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestPayload: [String: Any] = [
            "model": configuredModelIdentifier,
            "stream": false,
            "temperature": 0,
            "max_tokens": 400,
            "messages": [
                [
                    "role": "system",
                    "content": PaceThreadSummarizerPrompt.summarizerInstructions,
                ],
                [
                    "role": "user",
                    "content": PaceThreadSummarizerPrompt.renderUserPrompt(for: input),
                ],
            ],
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestPayload)

        let (responseData, urlResponse) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = urlResponse as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PaceThreadSummarizerError.upstreamHTTPFailure
        }
        return try Self.extractSummaryText(fromOpenAIResponseData: responseData)
    }

    static func extractSummaryText(
        fromOpenAIResponseData responseData: Data
    ) throws -> String {
        guard let parsedJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choicesArray = parsedJSON["choices"] as? [[String: Any]],
              let firstChoice = choicesArray.first,
              let messageDictionary = firstChoice["message"] as? [String: Any],
              let messageContent = messageDictionary["content"] as? String else {
            throw PaceThreadSummarizerError.malformedResponseJSON
        }
        return messageContent
    }
}

// MARK: - Errors

enum PaceThreadSummarizerError: Error, Equatable {
    case upstreamHTTPFailure
    case malformedResponseJSON
}

// MARK: - Factory

enum PaceThreadSummarizerClientFactory {
    /// Prefer Apple Foundation Models when available; otherwise fall
    /// back to LM Studio. Pace already biases short/latency-sensitive
    /// turns to Apple FM, and the summarizer fits that profile
    /// exactly. The LM Studio fallback shares its endpoint guard with
    /// the existing planner so a misconfigured plist cannot route the
    /// summarizer off-machine.
    @MainActor
    static func makeDefault() -> PaceThreadSummarizerClient {
        if #available(macOS 26.0, *) {
            let systemLanguageModel = SystemLanguageModel.default
            if case .available = systemLanguageModel.availability {
                return PaceThreadFoundationModelSummarizer()
            }
        }

        let configuredEndpointURLString = AppBundleConfiguration
            .stringValue(forKey: "LocalPlannerBaseURL")
        let configuredModelIdentifier = AppBundleConfiguration
            .stringValue(forKey: "LocalPlannerModelIdentifier") ?? "google/gemma-3-12b"
        let validatedEndpointURL = PaceLocalEndpointGuard
            .resolvedLocalOpenAICompatibleBaseURL(
                configuredURLString: configuredEndpointURLString,
                settingName: "LocalPlannerBaseURL"
            )
        return PaceThreadLMStudioSummarizer(
            localPlannerEndpointURL: validatedEndpointURL,
            configuredModelIdentifier: configuredModelIdentifier
        )
    }
}
