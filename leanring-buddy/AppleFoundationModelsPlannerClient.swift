//
//  AppleFoundationModelsPlannerClient.swift
//  leanring-buddy
//
//  `BuddyPlannerClient` backed by macOS 26's built-in 3B on-device
//  language model via the FoundationModels framework. This is the
//  fast path: stateful `LanguageModelSession` means the KV cache
//  persists across turns, so second-turn TTFT collapses to ~100-300ms
//  (vs the 5-13s we measured for Qwen3-14B over LM Studio HTTP).
//
//  Quality caveat: the system model is ~3B params at 2-bit weights,
//  scoring around 44% on MMLU per Apple. It's purpose-built for
//  summarization, extraction, refinement — exactly Pace's planner
//  job for short voice turns. For multi-step plan-act-observe with
//  the VLM element map prepended, escalate to `LocalPlannerClient`.
//  The router (Create ML intent classifier) decides which to use.
//
//  Why we maintain a session ourselves (not one per call): the
//  whole TTFT win comes from KV-cache reuse across turns. Building
//  a fresh `LanguageModelSession` each call discards the cache and
//  re-prefills the instructions every turn — that's the same anti-
//  pattern LM Studio's OpenAI-compat layer falls into. We hold the
//  session across turns and only rebuild when the system prompt
//  changes (which Pace's static `CompanionSystemPrompt` blocks make
//  rare).
//

import Foundation
import FoundationModels

@available(macOS 26.0, *)
@MainActor
final class AppleFoundationModelsPlannerClient: BuddyPlannerClient {
    let displayName = "Apple Foundation Models (on-device 3B)"

    /// The system model is text-only; image input goes through the
    /// upstream VLM + OCR pipeline which prepends an element map to
    /// `userPrompt` before this client is called. Same shape as
    /// `LocalPlannerClient`.
    let supportsImageInput = false

    /// The active session. Held across turns so its KV cache survives.
    /// Reset when `currentSessionInstructions` no longer matches the
    /// system prompt we're being asked to use (which should almost
    /// never happen — Pace's system prompt is byte-stable until the
    /// user toggles `EnableActions`).
    private var currentSession: LanguageModelSession?
    private var currentSessionInstructions: String?

    init() {
        // Print once at construction so we can see in any user-pasted
        // log which planner config is actually running — saves the
        // "did you rebuild?" round-trip during debugging.
        print("🧬 FM planner config: sampling=greedy, temperature=0, maxResponseTokens=400, resetPerTurn=true")
    }

    /// Reset the session — caller-facing API for "start a new
    /// conversation." Bound to `resetForNewTurn()` so CompanionManager
    /// can wipe stale session-internal transcript between user turns
    /// (otherwise FM's session grows unboundedly across agent-loop
    /// steps and busts the 4K context window after a few iterations).
    func resetSession() {
        currentSession = nil
        currentSessionInstructions = nil
    }

    func resetForNewTurn() {
        resetSession()
    }

    /// Wave 4: tiny "ping" prompt fired at app launch so the system
    /// model's weights are paged in before the user's first push-to-talk.
    /// Uses the same @Generable typed-output path the real planner uses
    /// (`PaceFMTurnResponse`) so the warmup exercises the exact runtime
    /// surface area — anything that would block the first real call is
    /// blocked here instead. RAM impact: zero new model weights (FM is
    /// in-process and bundled with macOS); the work is purely lighting
    /// up the existing system model.
    ///
    /// Bails silently when Apple Intelligence isn't available — the
    /// caller at app launch is fire-and-forget and there's no UX value
    /// in surfacing the unavailability here.
    static func warmUp() async {
        guard SystemLanguageModel.default.availability == .available else {
            return
        }
        let startedAt = Date()
        let warmUpSession = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: { "respond with a single short word." }
        )
        let warmUpGenerationOptions = GenerationOptions(
            samplingMode: .greedy,
            temperature: 0,
            maximumResponseTokens: 8
        )
        do {
            _ = try await warmUpSession.respond(
                to: "ping",
                generating: PaceFMTurnResponse.self,
                options: warmUpGenerationOptions
            )
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            print("🧬 FM warmup: \(elapsedMs)ms (system model resident)")
        } catch {
            print("⚠️ FM warmup skipped: \(error)")
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
            print("ℹ️ AppleFoundationModelsPlannerClient: \(images.count) image(s) attached but model is text-only — ignoring")
        }

        let startedAt = Date()
        let session = resolveSessionMatching(
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory
        )

        // Build the id→(label, x, y) map from the prompt BEFORE the
        // model call so we can resolve typed element IDs after.
        let elementCoordinateLookup = Self.parseElementMapFromUserPrompt(userPrompt: userPrompt)

        // Greedy sampling + temperature 0 = fully deterministic.
        let deterministicGenerationOptions = GenerationOptions(
            samplingMode: .greedy,
            temperature: 0,
            maximumResponseTokens: 400
        )

        // Typed Generable response: model picks element IDs from a
        // constrained set, can't emit free-text coordinates. Non-
        // streaming for now; PartiallyGenerated streaming is harder to
        // feed into the existing sentence-streamer and we want
        // correctness before TTS streaming back.
        let typedResponse: LanguageModelSession.Response<PaceFMTurnResponse>
        do {
            typedResponse = try await session.respond(
                to: userPrompt,
                generating: PaceFMTurnResponse.self,
                options: deterministicGenerationOptions
            )
        } catch {
            print("⚠️ FM typed response failed: \(error)")
            throw error
        }

        let timeToFirstTokenMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        print("⚡ FM Planner TTFT: \(timeToFirstTokenMilliseconds)ms (\(conversationHistory.count + 1) msgs)")
        PaceAPIAuditLog.shared.record(
            subsystem: "planner",
            operation: "fm.respond.typed",
            target: "apple-foundation-models-3b",
            durationMilliseconds: timeToFirstTokenMilliseconds,
            outcome: "ok",
            inputCharacterCount: userPrompt.count,
            detail: "\(conversationHistory.count + 1) msgs"
        )
        PaceTelemetryLog.recordPlannerTimeToFirstToken(
            milliseconds: timeToFirstTokenMilliseconds,
            modelIdentifier: displayName,
            messageCount: conversationHistory.count + 1
        )

        // Serialize the typed response back into the string-tag format
        // CompanionManager + StreamingSentenceTTSPipeline + PaceAction-
        // TagParser already consume. Bridges new model surface to old
        // pipeline without changing every layer.
        let serialisedText = Self.serializeTypedResponseToStringTags(
            typedResponse: typedResponse.content,
            elementCoordinateLookup: elementCoordinateLookup
        )

        // Feed the full text to the streaming TTS pipeline as one chunk.
        // Loses incremental sentence-dispatch on this turn; correctness
        // first, streaming returns when we move to PartiallyGenerated.
        onTextChunk(serialisedText)

        let totalDurationSeconds = Date().timeIntervalSince(startedAt)
        let trimmedResponseForLog = serialisedText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let truncatedForLog = trimmedResponseForLog.count > 240
            ? String(trimmedResponseForLog.prefix(240)) + "…"
            : trimmedResponseForLog
        print("🪶 FM raw response (typed→tags): \(truncatedForLog)")
        return (text: serialisedText, duration: totalDurationSeconds)
    }

    // MARK: - Element map parsing + serialization

    /// Pull `[N] role|cx,cy|label|text` lines out of the prompt and
    /// return a dictionary keyed by element ID. CompanionManager is
    /// responsible for emitting elements in this format (with the
    /// numeric ID prefix); this helper just inverts the operation so
    /// we can resolve IDs the model emits back to pixel coordinates.
    private static func parseElementMapFromUserPrompt(
        userPrompt: String
    ) -> [Int: (label: String, pixelX: Int, pixelY: Int)] {
        var elementCoordinateLookup: [Int: (label: String, pixelX: Int, pixelY: Int)] = [:]
        // Pattern: line starts with [<integer>] ROLE|X,Y|LABEL(|TEXT?)
        let elementLineRegex = try? NSRegularExpression(
            pattern: #"^\[(\d+)\]\s+\S+\|(\d+),(\d+)\|([^|\n]+)"#,
            options: [.anchorsMatchLines]
        )
        let entireRange = NSRange(userPrompt.startIndex..., in: userPrompt)
        elementLineRegex?.enumerateMatches(
            in: userPrompt,
            options: [],
            range: entireRange
        ) { match, _, _ in
            guard let match,
                  let idRange = Range(match.range(at: 1), in: userPrompt),
                  let xRange = Range(match.range(at: 2), in: userPrompt),
                  let yRange = Range(match.range(at: 3), in: userPrompt),
                  let labelRange = Range(match.range(at: 4), in: userPrompt),
                  let elementId = Int(userPrompt[idRange]),
                  let pixelX = Int(userPrompt[xRange]),
                  let pixelY = Int(userPrompt[yRange]) else {
                return
            }
            let label = String(userPrompt[labelRange]).trimmingCharacters(in: .whitespaces)
            elementCoordinateLookup[elementId] = (label: label, pixelX: pixelX, pixelY: pixelY)
        }
        return elementCoordinateLookup
    }

    /// Render a typed `PaceFMTurnResponse` as the string-tag format
    /// the rest of Pace consumes:
    ///   <spokenText> [POINT:x,y:label] [CLICK:x,y]
    /// Skips tags whose IDs are -1 or don't resolve in the element
    /// lookup (those are the "no action" cases — explicit refusals
    /// and pure Q&A).
    private static func serializeTypedResponseToStringTags(
        typedResponse: PaceFMTurnResponse,
        elementCoordinateLookup: [Int: (label: String, pixelX: Int, pixelY: Int)]
    ) -> String {
        var pieces: [String] = [typedResponse.spokenText]

        if typedResponse.pointAtElementId >= 0,
           let pointTarget = elementCoordinateLookup[typedResponse.pointAtElementId] {
            pieces.append("[POINT:\(pointTarget.pixelX),\(pointTarget.pixelY):\(pointTarget.label)]")
        } else {
            pieces.append("[POINT:none]")
        }

        if typedResponse.clickElementId >= 0,
           let clickTarget = elementCoordinateLookup[typedResponse.clickElementId] {
            pieces.append("[CLICK:\(clickTarget.pixelX),\(clickTarget.pixelY)]")
        }

        return pieces.joined(separator: " ")
    }

    /// Pick a session whose KV cache is valid for the current call.
    /// Reuses across turns when instructions are unchanged — which is
    /// the common case. Rebuilds and seeds with history when the
    /// instructions changed (e.g. user toggled `EnableActions`).
    private func resolveSessionMatching(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)]
    ) -> LanguageModelSession {
        if let existingSession = currentSession,
           currentSessionInstructions == systemPrompt {
            return existingSession
        }

        // Build a fresh session. Seed the prior history via Transcript
        // so the model has continuity, then store for reuse.
        let seededTranscript = buildTranscript(fromConversationHistory: conversationHistory)
        let freshSession: LanguageModelSession
        if seededTranscript.entries.isEmpty {
            freshSession = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: { systemPrompt }
            )
        } else {
            freshSession = LanguageModelSession(
                model: SystemLanguageModel.default,
                transcript: seededTranscript
            )
        }

        currentSession = freshSession
        currentSessionInstructions = systemPrompt
        return freshSession
    }

    /// Convert Pace's `(userPlaceholder, assistantResponse)` pairs into
    /// a `Transcript` for session seeding. Each pair becomes a
    /// `prompt` entry and a `response` entry. Pace already strips
    /// thinking blocks + action tags before storing the assistant
    /// response, so what we pass here is the user-facing spoken text.
    /// `Transcript` is a `RandomAccessCollection` of `Entry` — its
    /// `init(entries:)` takes any `Sequence<Entry>`.
    private func buildTranscript(
        fromConversationHistory conversationHistory: [(userPlaceholder: String, assistantResponse: String)]
    ) -> Transcript {
        var transcriptEntries: [Transcript.Entry] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            transcriptEntries.append(.prompt(Transcript.Prompt(
                segments: [.text(Transcript.TextSegment(content: userPlaceholder))]
            )))
            transcriptEntries.append(.response(Transcript.Response(
                assetIDs: [],
                segments: [.text(Transcript.TextSegment(content: assistantResponse))]
            )))
        }
        return Transcript(entries: transcriptEntries)
    }
}

private extension Transcript {
    /// `Transcript` is a `RandomAccessCollection`, not a struct with
    /// an `.entries` property. This helper exists so the resolver
    /// code reads naturally — `transcript.entries.isEmpty` is more
    /// honest than `transcript.isEmpty` (which would also work via
    /// the collection conformance but reads like a string check).
    var entries: [Entry] {
        Array(self)
    }
}
