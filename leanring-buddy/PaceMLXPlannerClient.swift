//
//  PaceMLXPlannerClient.swift
//  leanring-buddy
//
//  In-process MLX planner — runs Qwen3-4B-Instruct (or a sibling
//  bundled model) directly via `mlx-swift-examples` rather than
//  through LM Studio's HTTP loopback. The whole point is to drop
//  the LM Studio install dependency from the new-user setup story
//  so first-launch Pace just works.
//
//  Compiles cleanly with OR without the `MLXLLM` SPM module via
//  `#if canImport(MLXLLM)`. When the SPM dependency is absent every
//  method throws `PaceMLXPlannerError.runtimeNotLinked` and
//  `isRuntimeAvailable` returns false — the factory keeps the
//  current LM Studio / Apple FM / Direct API tiering intact.
//
//  Quality posture: a 4B in-process planner scores ~3-4 points
//  lower than qwen3-30b-a3b on the FM-fixture set. Bundled MLX is
//  opt-in (see `PaceBundledModelsSettings`); LM Studio remains the
//  gold-quality option for power users.
//

import Foundation

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
#endif

nonisolated enum PaceMLXPlannerError: LocalizedError {
    case runtimeNotLinked
    case modelLoadFailed(underlyingErrorDescription: String)
    case inferenceFailed(underlyingErrorDescription: String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotLinked:
            return "MLX runtime not linked into this build. Add `mlx-swift-examples` as a Swift Package dependency in Xcode → Project → Package Dependencies."
        case .modelLoadFailed(let underlyingErrorDescription):
            return "MLX model load failed: \(underlyingErrorDescription)"
        case .inferenceFailed(let underlyingErrorDescription):
            return "MLX inference failed: \(underlyingErrorDescription)"
        }
    }
}

@MainActor
final class PaceMLXPlannerClient: BuddyPlannerClient {

    // Compile-time visible to the factory so it knows whether to
    // even consider this client. `canImport(MLXLLM)` resolves at
    // compile time — true once the SPM dependency lands.
    nonisolated static var isRuntimeAvailable: Bool {
        #if canImport(MLXLLM)
        return true
        #else
        return false
        #endif
    }

    /// HuggingFace model identifier (e.g. `mlx-community/Qwen3-4B-Instruct-4bit`).
    /// Loaded lazily on first `generateResponseStreaming` — pipeline
    /// construction is ~200-500ms on Apple Silicon plus a one-time
    /// HuggingFace download on first launch.
    private let modelIdentifier: String
    private let generationTemperature: Float

    let displayName: String
    let supportsImageInput: Bool = false

    init(
        modelIdentifier: String = "mlx-community/Qwen3-4B-Instruct-4bit",
        generationTemperature: Float = 0.0
    ) {
        self.modelIdentifier = modelIdentifier
        self.generationTemperature = generationTemperature
        self.displayName = "MLX in-process (\(Self.shortenedModelLabel(forIdentifier: modelIdentifier)))"
    }

    /// Pre-fetch the configured model container — surfaces progress
    /// via the Hub package's NSProgress so callers can render a
    /// real percentage instead of an indeterminate spinner. Safe to
    /// call multiple times; subsequent calls return the cached
    /// container immediately. Throws on any load failure so the
    /// Settings UI can show a useful message instead of "downloading…
    /// (forever)".
    static func prefetchModel(
        modelIdentifier: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        #if canImport(MLXLLM)
        _ = try await Self.sharedModelContainer(
            modelIdentifier: modelIdentifier,
            progressHandler: progressHandler
        )
        #else
        _ = (modelIdentifier, progressHandler)
        throw PaceMLXPlannerError.runtimeNotLinked
        #endif
    }

    nonisolated static func shortenedModelLabel(forIdentifier modelIdentifier: String) -> String {
        // "mlx-community/Qwen3-4B-Instruct-4bit" → "Qwen3-4B"
        let lastSegment = modelIdentifier.split(separator: "/").last.map(String.init) ?? modelIdentifier
        let trimmedSegment = lastSegment
            .replacingOccurrences(of: "-Instruct-4bit", with: "")
            .replacingOccurrences(of: "-Instruct", with: "")
            .replacingOccurrences(of: "-4bit", with: "")
        return trimmedSegment
    }

    // MARK: - BuddyPlannerClient

    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        #if canImport(MLXLLM)
        let inferenceStartedAt = Date()

        let modelContainer: ModelContainer
        do {
            modelContainer = try await Self.sharedModelContainer(modelIdentifier: modelIdentifier)
        } catch {
            throw PaceMLXPlannerError.modelLoadFailed(
                underlyingErrorDescription: error.localizedDescription
            )
        }

        let combinedUserPrompt = Self.combineHistoryIntoUserPrompt(
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )
        let generationParameters = GenerateParameters(temperature: generationTemperature)
        let chatSession = ChatSession(
            modelContainer,
            instructions: systemPrompt.isEmpty ? nil : systemPrompt,
            generateParameters: generationParameters
        )

        var accumulatedText = ""
        do {
            for try await textChunk in chatSession.streamResponse(to: combinedUserPrompt) {
                accumulatedText += textChunk
                await onTextChunk(textChunk)
            }
        } catch {
            throw PaceMLXPlannerError.inferenceFailed(
                underlyingErrorDescription: error.localizedDescription
            )
        }

        let elapsedSeconds = Date().timeIntervalSince(inferenceStartedAt)
        return (text: accumulatedText, duration: elapsedSeconds)
        #else
        _ = (images, systemPrompt, conversationHistory, userPrompt, onTextChunk)
        throw PaceMLXPlannerError.runtimeNotLinked
        #endif
    }

    // MARK: - Pure helpers

    /// Pace passes the full conversation history with every turn —
    /// the planner protocol is stateless. ChatSession's per-call
    /// `respond(to:)` replaces its message buffer on every call so
    /// history doesn't carry over through that path; we flatten the
    /// history into a single prompt string instead. Result is one
    /// stable, stateless turn shape that matches LocalPlannerClient.
    nonisolated static func combineHistoryIntoUserPrompt(
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> String {
        guard !conversationHistory.isEmpty else { return userPrompt }
        var renderedHistory = ""
        for (priorUser, priorAssistant) in conversationHistory {
            renderedHistory += "User: \(priorUser)\nAssistant: \(priorAssistant)\n\n"
        }
        return renderedHistory + "User: \(userPrompt)"
    }

    #if canImport(MLXLLM)
    /// Single per-process model container. The 4B MLX assets are
    /// ~2-3 GB once dequantised; loading them multiple times would
    /// blow memory and double-trigger ANE warm-up.
    private static var cachedModelContainer: ModelContainer?
    private static let modelLoadLock = NSLock()

    private static func sharedModelContainer(
        modelIdentifier: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        modelLoadLock.lock()
        let cached = cachedModelContainer
        modelLoadLock.unlock()
        if let cached { return cached }

        let loaded = try await MLXLMCommon.loadModelContainer(
            id: modelIdentifier,
            progressHandler: progressHandler
        )

        modelLoadLock.lock()
        cachedModelContainer = loaded
        modelLoadLock.unlock()
        return loaded
    }
    #endif
}
