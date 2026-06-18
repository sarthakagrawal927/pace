//
//  PaceChainedTextEmbeddingClient.swift
//  leanring-buddy
//
//  Tries a primary `PaceTextEmbedding` first; on throw, all-empty
//  vectors, or wrong-cardinality result, falls back to a secondary.
//  Used to wire LM Studio (preferred, high-quality nomic) primary +
//  Apple NaturalLanguage (always-available, lower quality) fallback,
//  so semantic recall works even on a clean Mac with no sidecar
//  installed.
//
//  Picking the "right" client is left implicit per-call rather than
//  cached, because LM Studio's reachability is genuinely transient —
//  the user can quit LM Studio mid-session. Re-probing per call is
//  what makes the system feel honest: when LM Studio is up, every
//  recall benefits from the better model; when it isn't, recall
//  still happens just at a lower quality bar.
//

import Foundation

final class PaceChainedTextEmbeddingClient: PaceTextEmbedding {
    private let primaryClient: any PaceTextEmbedding
    private let fallbackClient: any PaceTextEmbedding

    init(
        primary: any PaceTextEmbedding,
        fallback: any PaceTextEmbedding
    ) {
        self.primaryClient = primary
        self.fallbackClient = fallback
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        do {
            let primaryVectors = try await primaryClient.embed(texts)
            // Treat wrong-count or all-zero outputs as a primary
            // failure too. A primary that "succeeds" by returning
            // a uniform zero vector would silently break recall
            // without flipping us to the fallback otherwise.
            if primaryVectors.count == texts.count,
               primaryVectorsHaveAnyNonZeroSignal(primaryVectors) {
                return primaryVectors
            }
        } catch {
            // Primary failed — log once at the lowest level so a
            // missing LM Studio doesn't spam the console on every
            // turn. Fallthrough to fallback.
            print("ℹ️  Primary embedding client failed (\(error.localizedDescription)). Falling back to Apple NL.")
        }
        return try await fallbackClient.embed(texts)
    }

    /// Quick non-zero-signal probe — we only need to know that AT
    /// LEAST ONE vector has a non-zero component to trust the primary
    /// result. Scanning every component of every vector is wasteful;
    /// scanning the first non-zero we find is sufficient.
    private func primaryVectorsHaveAnyNonZeroSignal(_ vectors: [[Float]]) -> Bool {
        for vector in vectors {
            for component in vector where component != 0 {
                return true
            }
        }
        return false
    }
}

extension PaceChainedTextEmbeddingClient {
    /// Default factory. Preference order:
    ///   1. Bundled MLX (when SPM runtime is linked AND the user has
    ///      opted into in-process embeddings) — zero LM Studio
    ///      dependency, runs entirely in-process.
    ///   2. LM Studio HTTP — the gold-quality nomic embedding when
    ///      it's reachable; failure tips to the next fallback.
    ///   3. Apple NL — always-available baseline that ships with
    ///      every Mac. Lower quality but free.
    ///
    /// Keep this the only place that hard-codes the preference
    /// order so the choice stays trivially auditable.
    static func makePaceDefault() -> PaceChainedTextEmbeddingClient {
        let primaryClient: any PaceTextEmbedding = {
            if PaceBundledModelsSettings.isUsingMLXInProcessEmbedder() {
                return PaceMLXEmbeddingClient(
                    modelIdentifier: PaceBundledModelsSettings.embedderModelIdentifier()
                )
            }
            return LMStudioEmbeddingClient()
        }()
        return PaceChainedTextEmbeddingClient(
            primary: primaryClient,
            fallback: PaceAppleNLEmbeddingClient()
        )
    }
}
