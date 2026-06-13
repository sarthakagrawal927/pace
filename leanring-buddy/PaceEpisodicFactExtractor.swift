//
//  PaceEpisodicFactExtractor.swift
//  leanring-buddy
//
//  LLM-backed episodic fact extractor. Mirrors the exact shape of
//  `PaceThreadSummarizer.swift`: a protocol, an Apple Foundation
//  Models implementation using a typed `@Generable` envelope, an
//  LM Studio fallback that speaks OpenAI-compatible chat completions,
//  and a factory that picks Apple FM when Apple Intelligence is
//  available and falls back to LM Studio otherwise.
//
//  This extractor is FIRE-AND-FORGET. CompanionManager invokes it
//  from a detached task after every completed turn; the user-facing
//  TTS/planner pipeline does NOT await it. Latency / failure of the
//  extractor never affects the spoken response time.
//
//  Why FM is preferred
//  -------------------
//  The Apple FM call is in-process and adds ~0 RAM delta (the model
//  is shared with the planner tier). LM Studio holds 18.6 GB +
//  1.5 GB resident; the extractor is small but firing it through LM
//  Studio when FM is available would still contend for the planner
//  on the same loopback endpoint. FM keeps episodic extraction off
//  the critical path entirely.
//

import Foundation
import FoundationModels

// MARK: - Protocol

/// Episodic-fact extraction contract. Implementations return facts
/// the store should consider; the store itself applies dedup +
/// tombstone + LRU policy on top.
protocol PaceEpisodicFactExtractor: Sendable {
    func extract(
        userTranscript: String,
        assistantSpokenText: String,
        frontmostAppName: String?,
        turnId: String
    ) async -> [PaceEpisodicFact]
}

// MARK: - Prompt rules

/// Behavior contract for both Apple FM and LM Studio implementations.
/// Pulled into its own enum so any change here is one diff-able
/// artifact (same pattern as `PaceThreadSummarizerPrompt`).
enum PaceEpisodicFactExtractorPrompt {
    static let extractorInstructions = """
    you are extracting DURABLE FACTS about the user from a single voice turn between the user and pace, an on-device macos assistant.

    rules:
    - extract ONLY facts that will still matter a week from now. multi-day relevance is the bar.
    - REJECT ephemeral states ("i'm hungry", "i'm tired", "i'm bored", "right now i need a break"). they are not facts.
    - REJECT actions the user just asked pace to do ("open safari", "click save", "send the email"). these are commands, not facts.
    - REJECT vague observations ("that's interesting", "okay", "sounds good"). they carry no fact.
    - prefer concrete subject/predicate/value triples ("user", "prefers", "dark mode") over freeform sentences.
    - confidence is 0.0 to 1.0. only emit facts at 0.7 or higher — the calling code filters anything lower out anyway.
    - tag each fact with topic hashtags from this list when relevant: #preference, #work, #family, #health, #finance, #relationship, #travel, #project. include multiple when appropriate.
    - if no durable fact is present, return an empty facts array. do not invent facts to fill space.
    - never write any text outside the structured response.
    """

    /// Render the user-prompt body the extractor sees. Same template
    /// for both runtimes so they receive byte-identical inputs.
    static func renderUserPrompt(
        userTranscript: String,
        assistantSpokenText: String,
        frontmostAppName: String?,
        turnId: String
    ) -> String {
        var promptPieces: [String] = []
        promptPieces.append("TURN_ID: \(turnId)")
        if let frontmostAppName, !frontmostAppName.isEmpty {
            promptPieces.append("FRONTMOST_APP: \(frontmostAppName)")
        }
        promptPieces.append("USER_TRANSCRIPT:\n\(userTranscript)")
        if !assistantSpokenText.isEmpty {
            promptPieces.append("ASSISTANT_REPLY:\n\(assistantSpokenText)")
        }
        promptPieces.append("extract durable facts now. respond with the structured facts array.")
        return promptPieces.joined(separator: "\n\n")
    }
}

// MARK: - Apple FM envelope

/// Single-field typed envelope so the FM call cannot stray off
/// schema. Mirrors the `PaceThreadSummaryResponse` shape exactly.
@available(macOS 26.0, *)
@Generable
struct PaceEpisodicFactExtractionResponse {
    @Guide(description: "Durable facts extracted from this turn. Empty array when no fact is durable enough to keep. Never invent facts to fill space.")
    let facts: [GeneratedEpisodicFact]
}

@available(macOS 26.0, *)
@Generable
struct GeneratedEpisodicFact {
    @Guide(description: "Who the fact is about. Lowercase. Examples: 'user', 'user's mom', 'work milestone'. Never an empty string.")
    let subject: String

    @Guide(description: "Relation between subject and value. Lowercase short phrase. Examples: 'prefers', 'is in', 'happens on', 'works at'.")
    let predicate: String

    @Guide(description: "What the predicate evaluates to. Concrete noun phrase. Lowercase. Examples: 'dark mode', 'the hospital', 'Friday'. Never an empty string.")
    let value: String

    @Guide(description: "Confidence 0.0 to 1.0 that this fact is durable and accurately captured from the transcript. Emit only facts at 0.7 or higher.")
    let confidence: Double

    @Guide(description: "Optional ISO8601 date string after which this fact should no longer be trusted. Use only for facts that intrinsically expire — a deadline, a scheduled event. Omit for stable preferences.")
    let expiresAt: String?

    @Guide(description: "Topic hashtags chosen from #preference, #work, #family, #health, #finance, #relationship, #travel, #project. Include multiple when appropriate. Never empty.")
    let topicHashtags: [String]
}

// MARK: - Shared converter

/// Common gluing layer between the FM response shape and Pace's
/// canonical `PaceEpisodicFact`. Lives outside `@available` because
/// `GeneratedEpisodicFact` only exists under macOS 26; the converter
/// takes the typed fields directly so the LM Studio path can reuse
/// it too.
enum PaceExtractedFactBuilder {
    static func buildFact(
        subject: String,
        predicate: String,
        value: String,
        confidence: Double,
        expiresAtISOString: String?,
        topicHashtags: [String],
        sourceTurnId: String,
        extractedAt: Date
    ) -> PaceEpisodicFact? {
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPredicate = predicate.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSubject.isEmpty,
              !trimmedPredicate.isEmpty,
              !trimmedValue.isEmpty else {
            return nil
        }
        let expiresAt = expiresAtISOString.flatMap { ISO8601DateFormatter().date(from: $0) }
        let stableSeed = "\(trimmedSubject)|\(trimmedPredicate)|\(trimmedValue)|\(sourceTurnId)"
        return PaceEpisodicFact(
            identifier: "episodic-llm-\(abs(stableSeed.hashValue))",
            extractedAt: extractedAt,
            subject: trimmedSubject,
            predicate: trimmedPredicate,
            value: trimmedValue,
            confidence: confidence,
            expiresAt: expiresAt,
            topicHashtags: topicHashtags.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            sourceTurnId: sourceTurnId
        )
    }
}

// MARK: - Apple FM extractor (preferred)

/// Apple Foundation Models conformer. Constructs a one-shot
/// `LanguageModelSession` per call — the extractor is short-context
/// and stateless, so the KV-cache reuse the planner gets is not
/// worth the session lifetime management here.
@available(macOS 26.0, *)
final class PaceEpisodicFoundationModelFactExtractor: PaceEpisodicFactExtractor, @unchecked Sendable {
    var now: () -> Date = Date.init

    func extract(
        userTranscript: String,
        assistantSpokenText: String,
        frontmostAppName: String?,
        turnId: String
    ) async -> [PaceEpisodicFact] {
        let trimmedTranscript = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return [] }

        let extractorSession = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: { PaceEpisodicFactExtractorPrompt.extractorInstructions }
        )
        let renderedUserPrompt = PaceEpisodicFactExtractorPrompt.renderUserPrompt(
            userTranscript: trimmedTranscript,
            assistantSpokenText: assistantSpokenText,
            frontmostAppName: frontmostAppName,
            turnId: turnId
        )
        let deterministicGenerationOptions = GenerationOptions(
            samplingMode: .greedy,
            temperature: 0,
            maximumResponseTokens: 600
        )
        do {
            let typedResponse = try await extractorSession.respond(
                to: renderedUserPrompt,
                generating: PaceEpisodicFactExtractionResponse.self,
                options: deterministicGenerationOptions
            )
            let extractedAt = now()
            return typedResponse.content.facts.compactMap { generated in
                PaceExtractedFactBuilder.buildFact(
                    subject: generated.subject,
                    predicate: generated.predicate,
                    value: generated.value,
                    confidence: generated.confidence,
                    expiresAtISOString: generated.expiresAt,
                    topicHashtags: generated.topicHashtags,
                    sourceTurnId: turnId,
                    extractedAt: extractedAt
                )
            }
        } catch {
            // Extractor failures are silent on purpose — episodic
            // memory is best-effort, and we never want to slow the
            // user-facing path with retries.
            print("⚠️ Episodic FM extractor call failed: \(error)")
            return []
        }
    }
}

// MARK: - LM Studio extractor (fallback)

/// LM Studio fallback. Loopback-guarded base URL, OpenAI-compatible
/// `/v1/chat/completions`, JSON-only response constrained by an
/// explicit `response_format` hint plus an aggressive system rule.
final class PaceEpisodicLMStudioFactExtractor: PaceEpisodicFactExtractor, @unchecked Sendable {
    private let localPlannerEndpointURL: URL
    private let configuredModelIdentifier: String
    var now: () -> Date = Date.init

    init(
        localPlannerEndpointURL: URL,
        configuredModelIdentifier: String
    ) {
        self.localPlannerEndpointURL = localPlannerEndpointURL
        self.configuredModelIdentifier = configuredModelIdentifier
    }

    func extract(
        userTranscript: String,
        assistantSpokenText: String,
        frontmostAppName: String?,
        turnId: String
    ) async -> [PaceEpisodicFact] {
        let trimmedTranscript = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return [] }

        let chatCompletionsURL = localPlannerEndpointURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        var urlRequest = URLRequest(url: chatCompletionsURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let strictJSONSystemRule = """
        \(PaceEpisodicFactExtractorPrompt.extractorInstructions)

        respond with a single json object exactly matching:
        {"facts": [{"subject": "string", "predicate": "string", "value": "string", "confidence": 0.0, "expiresAt": null, "topicHashtags": ["#preference"]}]}
        emit nothing outside this object.
        """

        let requestPayload: [String: Any] = [
            "model": configuredModelIdentifier,
            "stream": false,
            "temperature": 0,
            "max_tokens": 600,
            "response_format": ["type": "json_object"],
            "messages": [
                [
                    "role": "system",
                    "content": strictJSONSystemRule,
                ],
                [
                    "role": "user",
                    "content": PaceEpisodicFactExtractorPrompt.renderUserPrompt(
                        userTranscript: trimmedTranscript,
                        assistantSpokenText: assistantSpokenText,
                        frontmostAppName: frontmostAppName,
                        turnId: turnId
                    ),
                ],
            ],
        ]
        guard let requestBody = try? JSONSerialization.data(withJSONObject: requestPayload) else {
            return []
        }
        urlRequest.httpBody = requestBody

        do {
            let (responseData, urlResponse) = try await URLSession.shared.data(for: urlRequest)
            guard let httpResponse = urlResponse as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }
            return Self.parseFacts(
                fromOpenAIResponseData: responseData,
                sourceTurnId: turnId,
                extractedAt: now()
            )
        } catch {
            print("⚠️ Episodic LM Studio extractor call failed: \(error)")
            return []
        }
    }

    /// Visible for testing: extract the assistant message content as
    /// JSON and decode the typed facts. Tolerant of stray prose
    /// around the JSON object so a model that ignores the
    /// `response_format` hint still mostly works.
    static func parseFacts(
        fromOpenAIResponseData responseData: Data,
        sourceTurnId: String,
        extractedAt: Date
    ) -> [PaceEpisodicFact] {
        guard let parsedRootJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choicesArray = parsedRootJSON["choices"] as? [[String: Any]],
              let firstChoice = choicesArray.first,
              let messageDictionary = firstChoice["message"] as? [String: Any],
              let messageContent = messageDictionary["content"] as? String else {
            return []
        }
        return parseFacts(
            fromContentString: messageContent,
            sourceTurnId: sourceTurnId,
            extractedAt: extractedAt
        )
    }

    /// Visible for testing: parse the model's content string into
    /// facts. Locates the outermost `{...}` substring and decodes it.
    static func parseFacts(
        fromContentString contentString: String,
        sourceTurnId: String,
        extractedAt: Date
    ) -> [PaceEpisodicFact] {
        guard let jsonSubstring = extractOutermostJSONObject(in: contentString),
              let jsonData = jsonSubstring.data(using: .utf8),
              let parsedJSON = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let factsArray = parsedJSON["facts"] as? [[String: Any]] else {
            return []
        }
        return factsArray.compactMap { factDictionary -> PaceEpisodicFact? in
            guard let subject = factDictionary["subject"] as? String,
                  let predicate = factDictionary["predicate"] as? String,
                  let value = factDictionary["value"] as? String else {
                return nil
            }
            let confidence = (factDictionary["confidence"] as? Double)
                ?? (factDictionary["confidence"] as? NSNumber)?.doubleValue
                ?? 0
            let expiresAtISOString = factDictionary["expiresAt"] as? String
            let topicHashtags = factDictionary["topicHashtags"] as? [String] ?? []
            return PaceExtractedFactBuilder.buildFact(
                subject: subject,
                predicate: predicate,
                value: value,
                confidence: confidence,
                expiresAtISOString: expiresAtISOString,
                topicHashtags: topicHashtags,
                sourceTurnId: sourceTurnId,
                extractedAt: extractedAt
            )
        }
    }

    private static func extractOutermostJSONObject(in contentString: String) -> String? {
        guard let openingBraceIndex = contentString.firstIndex(of: "{"),
              let closingBraceIndex = contentString.lastIndex(of: "}"),
              openingBraceIndex <= closingBraceIndex else {
            return nil
        }
        return String(contentString[openingBraceIndex...closingBraceIndex])
    }
}

// MARK: - No-op extractor

/// Returned by the factory when neither Apple FM nor LM Studio are
/// reachable at construction time. Lets the wiring in
/// `CompanionManager` stay non-optional — calling `extract` on the
/// no-op extractor is cheap and safe.
final class PaceEpisodicNoOpFactExtractor: PaceEpisodicFactExtractor, @unchecked Sendable {
    func extract(
        userTranscript: String,
        assistantSpokenText: String,
        frontmostAppName: String?,
        turnId: String
    ) async -> [PaceEpisodicFact] {
        []
    }
}

// MARK: - Factory

/// Choose the extractor implementation. Apple FM wins whenever
/// Apple Intelligence is `available`; otherwise we fall back to the
/// LM Studio HTTP path. Same selection logic as the thread-summary
/// factory.
enum PaceEpisodicFactExtractorFactory {
    @MainActor
    static func makeDefault() -> PaceEpisodicFactExtractor {
        if #available(macOS 26.0, *) {
            let systemLanguageModel = SystemLanguageModel.default
            if case .available = systemLanguageModel.availability {
                return PaceEpisodicFoundationModelFactExtractor()
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
        return PaceEpisodicLMStudioFactExtractor(
            localPlannerEndpointURL: validatedEndpointURL,
            configuredModelIdentifier: configuredModelIdentifier
        )
    }
}
