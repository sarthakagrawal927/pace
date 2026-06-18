//
//  PaceMLXEmbeddingClient.swift
//  leanring-buddy
//
//  In-process MLX embedder — runs an encoder model
//  (default: nomic-embed-text-v1.5) via `mlx-swift-examples`
//  MLXEmbedders, no LM Studio HTTP hop.
//
//  Conforms to `PaceTextEmbedding`, slotting into the existing
//  `PaceChainedTextEmbeddingClient` chain without any contract
//  changes.
//

import Foundation

#if canImport(MLXEmbedders)
import MLX
import MLXEmbedders
import Tokenizers
#endif

nonisolated enum PaceMLXEmbeddingError: LocalizedError {
    case runtimeNotLinked
    case modelLoadFailed(underlyingErrorDescription: String)
    case embeddingFailed(underlyingErrorDescription: String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotLinked:
            return "MLX embedders runtime not linked. Add `mlx-swift-examples` (with the MLXEmbedders product) to the project's Swift Package dependencies."
        case .modelLoadFailed(let underlyingErrorDescription):
            return "MLX embedding model load failed: \(underlyingErrorDescription)"
        case .embeddingFailed(let underlyingErrorDescription):
            return "MLX embedding inference failed: \(underlyingErrorDescription)"
        }
    }
}

final class PaceMLXEmbeddingClient: PaceTextEmbedding {

    nonisolated static var isRuntimeAvailable: Bool {
        #if canImport(MLXEmbedders)
        return true
        #else
        return false
        #endif
    }

    /// HuggingFace model identifier (default: nomic-embed-text-v1.5).
    private let modelIdentifier: String

    init(modelIdentifier: String = "nomic-ai/nomic-embed-text-v1.5") {
        self.modelIdentifier = modelIdentifier
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        #if canImport(MLXEmbedders)
        let modelContainer: MLXEmbedders.ModelContainer
        do {
            modelContainer = try await Self.sharedModelContainer(modelIdentifier: modelIdentifier)
        } catch {
            throw PaceMLXEmbeddingError.modelLoadFailed(
                underlyingErrorDescription: error.localizedDescription
            )
        }

        let inputTextsCopy = texts
        do {
            let vectors: [[Float]] = await modelContainer.perform { (model, tokenizer, pooling) in
                Self.computeEmbeddingVectors(
                    forTexts: inputTextsCopy,
                    model: model,
                    tokenizer: tokenizer,
                    pooling: pooling
                )
            }
            guard vectors.count == texts.count else {
                throw PaceMLXEmbeddingError.embeddingFailed(
                    underlyingErrorDescription: "got \(vectors.count) vectors for \(texts.count) texts"
                )
            }
            return vectors
        } catch let error as PaceMLXEmbeddingError {
            throw error
        } catch {
            throw PaceMLXEmbeddingError.embeddingFailed(
                underlyingErrorDescription: error.localizedDescription
            )
        }
        #else
        _ = texts
        throw PaceMLXEmbeddingError.runtimeNotLinked
        #endif
    }

    #if canImport(MLXEmbedders)
    /// Tokenize → pad-to-max → forward → pool → normalize. Mirrors
    /// the canonical usage pattern in mlx-swift-examples' Embedders
    /// README; the only Pace-specific decision is the pad-to-16
    /// minimum which keeps the encoder happy on very short queries.
    nonisolated static func computeEmbeddingVectors(
        forTexts texts: [String],
        model: EmbeddingModel,
        tokenizer: Tokenizer,
        pooling: Pooling
    ) -> [[Float]] {
        let tokenizedInputs: [[Int]] = texts.map { text in
            tokenizer.encode(text: text, addSpecialTokens: true)
        }
        let paddingTokenId = tokenizer.eosTokenId ?? 0
        let maxTokenCount = tokenizedInputs.reduce(into: 16) { runningMax, tokens in
            runningMax = max(runningMax, tokens.count)
        }
        let paddedInputs = stacked(
            tokenizedInputs.map { tokens in
                let paddingCount = maxTokenCount - tokens.count
                let paddedTokens = tokens + Array(repeating: paddingTokenId, count: paddingCount)
                return MLXArray(paddedTokens)
            }
        )
        let attentionMask = (paddedInputs .!= paddingTokenId)
        let tokenTypeIds = MLXArray.zeros(like: paddedInputs)
        let pooledOutput = pooling(
            model(
                paddedInputs,
                positionIds: nil,
                tokenTypeIds: tokenTypeIds,
                attentionMask: attentionMask
            ),
            normalize: true,
            applyLayerNorm: true
        )
        // `eval()` is mutating-void in current mlx-swift — call it
        // for its side effect of materialising the lazy graph, then
        // iterate the array along its leading axis (one row per
        // input text).
        pooledOutput.eval()
        return pooledOutput.map { $0.asArray(Float.self) }
    }

    private static var cachedModelContainer: MLXEmbedders.ModelContainer?
    private static let modelLoadLock = NSLock()

    private static func sharedModelContainer(modelIdentifier: String) async throws -> MLXEmbedders.ModelContainer {
        modelLoadLock.lock()
        let cached = cachedModelContainer
        modelLoadLock.unlock()
        if let cached { return cached }

        let configuration = MLXEmbedders.ModelConfiguration(id: modelIdentifier)
        let loaded = try await MLXEmbedders.loadModelContainer(configuration: configuration)

        modelLoadLock.lock()
        cachedModelContainer = loaded
        modelLoadLock.unlock()
        return loaded
    }
    #endif
}
