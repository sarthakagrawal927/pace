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
//  Compiles cleanly with OR without the `MLXLLM` SPM module:
//
//  - When MLXLLM is present (after the SPM dependency is added in
//    Xcode → Project → Package Dependencies → +
//    https://github.com/ml-explore/mlx-swift-examples), the real
//    inference path activates and `isRuntimeAvailable` flips to
//    true. The factory then prefers this client when the user has
//    opted in to bundled models.
//
//  - When MLXLLM is absent, every method throws
//    `PaceMLXPlannerError.runtimeNotLinked` and
//    `isRuntimeAvailable` returns false. The factory keeps the
//    current LM Studio / Apple FM / Direct API tiering intact.
//
//  Quality posture: a 4B in-process planner scores ~3-4 points
//  lower than qwen3-30b-a3b on the FM-fixture set. Bundled MLX
//  is opt-in (see `PaceBundledModelsSettings`); LM Studio remains
//  the gold-quality option for power users.
//

import Foundation

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
import Hub
#endif

nonisolated enum PaceMLXPlannerError: LocalizedError {
    case runtimeNotLinked
    case modelNotInstalled(modelIdentifier: String)
    case modelLoadFailed(underlyingErrorDescription: String)
    case inferenceFailed(underlyingErrorDescription: String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotLinked:
            return "MLX runtime not linked into this build. Add `mlx-swift-examples` as a Swift Package dependency in Xcode → Project → Package Dependencies."
        case .modelNotInstalled(let modelIdentifier):
            return "MLX model \(modelIdentifier) is not installed. Run the bundled-models first-launch download."
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
    /// construction is ~200-500ms on Apple Silicon and we don't want
    /// to pay it at factory time.
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

        let chatMessages = Self.buildChatMessages(
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        do {
            let fullText: String = try await modelContainer.perform { context in
                let userInput = UserInput(chat: chatMessages)
                let modelInput = try await context.processor.prepare(input: userInput)
                let stream = try MLXLMCommon.generate(
                    input: modelInput,
                    parameters: GenerateParameters(temperature: generationTemperature),
                    context: context
                )
                var accumulatedText = ""
                for await event in stream {
                    switch event {
                    case .chunk(let textChunk):
                        accumulatedText += textChunk
                        await onTextChunk(textChunk)
                    default:
                        // `.info(_)` etc. carry diagnostic data we
                        // don't surface to the streaming callback —
                        // it's not user-facing token text.
                        break
                    }
                }
                return accumulatedText
            }
            let elapsedSeconds = Date().timeIntervalSince(inferenceStartedAt)
            return (text: fullText, duration: elapsedSeconds)
        } catch {
            throw PaceMLXPlannerError.inferenceFailed(
                underlyingErrorDescription: error.localizedDescription
            )
        }
        #else
        // SPM dependency not added yet — fail loud rather than
        // silently returning empty text. The factory should not
        // select this client when isRuntimeAvailable == false; if
        // it did, something is mis-wired and a loud error is better
        // than a silent empty response.
        _ = (images, systemPrompt, conversationHistory, userPrompt, onTextChunk)
        throw PaceMLXPlannerError.runtimeNotLinked
        #endif
    }

    // MARK: - Pure helpers (testable without MLXLLM)

    #if canImport(MLXLLM)
    /// Single per-process model container. The 4B MLX assets are
    /// ~2-3 GB once dequantised; loading them multiple times would
    /// blow memory and double-trigger ANE warm-up.
    private static var cachedModelContainer: ModelContainer?
    private static let modelLoadLock = NSLock()

    private static func sharedModelContainer(modelIdentifier: String) async throws -> ModelContainer {
        modelLoadLock.lock()
        let cached = cachedModelContainer
        modelLoadLock.unlock()
        if let cached { return cached }

        let modelConfiguration = ModelConfiguration(id: modelIdentifier)
        let loaded = try await LLMModelFactory.shared.loadContainer(configuration: modelConfiguration)

        modelLoadLock.lock()
        cachedModelContainer = loaded
        modelLoadLock.unlock()
        return loaded
    }

    nonisolated static func buildChatMessages(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> [Chat.Message] {
        var messages: [Chat.Message] = []
        let trimmedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystemPrompt.isEmpty {
            messages.append(.system(trimmedSystemPrompt))
        }
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(.user(userPlaceholder))
            messages.append(.assistant(assistantResponse))
        }
        messages.append(.user(userPrompt))
        return messages
    }
    #endif
}
