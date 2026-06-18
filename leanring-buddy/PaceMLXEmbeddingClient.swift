//
//  PaceMLXEmbeddingClient.swift
//  leanring-buddy
//
//  In-process MLX embedding model — runs a BERT-class embedder
//  (default: nomic-embed-text-v1.5 MLX) directly via
//  `mlx-swift-examples` MLXEmbedders, no LM Studio HTTP hop.
//  Slots into the existing `PaceTextEmbedding` protocol so the
//  chained-fallback wiring (`PaceChainedTextEmbeddingClient`)
//  consumes it without any changes.
//
//  Compiles cleanly with OR without the `MLXEmbedders` SPM module:
//  guarded by `#if canImport(MLXEmbedders)`. When the SPM dep is
//  absent, `isRuntimeAvailable == false` and every embed call
//  throws — the chained client routes around to Apple NL.
//

import Foundation

#if canImport(MLXEmbedders)
import MLXEmbedders
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

    static var isRuntimeAvailable: Bool {
        #if canImport(MLXEmbedders)
        return true
        #else
        return false
        #endif
    }

    /// HuggingFace model identifier for the bundled embedder. The
    /// nomic-embed family is the same lineage Pace's LM Studio path
    /// runs today, so swapping in-process should give comparable
    /// recall on the LoCoMo benchmark.
    private let modelIdentifier: String

    init(modelIdentifier: String = "mlx-community/nomic-embed-text-v1.5") {
        self.modelIdentifier = modelIdentifier
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        #if canImport(MLXEmbedders)
        let modelContainer: EmbeddingModelContainer
        do {
            modelContainer = try await Self.sharedModelContainer(modelIdentifier: modelIdentifier)
        } catch {
            throw PaceMLXEmbeddingError.modelLoadFailed(
                underlyingErrorDescription: error.localizedDescription
            )
        }

        do {
            let vectors = try await modelContainer.perform { context in
                return try await context.embed(texts: texts)
            }
            // mlx-swift-examples returns [[Float]] already; just
            // pass through. The shape check below catches any future
            // API drift where the count doesn't match.
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
    private static var cachedModelContainer: EmbeddingModelContainer?
    private static let modelLoadLock = NSLock()

    private static func sharedModelContainer(modelIdentifier: String) async throws -> EmbeddingModelContainer {
        modelLoadLock.lock()
        let cached = cachedModelContainer
        modelLoadLock.unlock()
        if let cached { return cached }

        let configuration = EmbeddingConfiguration(id: modelIdentifier)
        let loaded = try await EmbeddingModelFactory.shared.loadContainer(configuration: configuration)

        modelLoadLock.lock()
        cachedModelContainer = loaded
        modelLoadLock.unlock()
        return loaded
    }
    #endif
}
