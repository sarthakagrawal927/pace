//
//  PaceEmbeddingRerankerTests.swift
//  leanring-buddyTests
//
//  Pure-function and fake-embedder coverage for the embedding re-rank
//  layer. No network: LMStudioEmbeddingClient is exercised only through
//  the PaceTextEmbedding protocol with deterministic fakes.
//

import Testing

@testable import Pace

private struct FakeEmbedder: PaceTextEmbedding {
    let vectorsByText: [String: [Float]]

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { vectorsByText[$0] ?? [0, 0, 0] }
    }
}

private struct FailingEmbedder: PaceTextEmbedding {
    func embed(_ texts: [String]) async throws -> [[Float]] {
        throw PaceEmbeddingClientError(message: "endpoint down")
    }
}

private func makeMatch(excerpt: String, score: Double) -> PaceRetrievalMatch {
    PaceRetrievalMatch(
        documentId: "doc-\(excerpt.hashValue)",
        chunkId: "chunk-\(excerpt.hashValue)",
        source: .file,
        title: excerpt,
        excerpt: excerpt,
        localURL: nil,
        modifiedAt: nil,
        score: score
    )
}

struct PaceEmbeddingRerankerTests {

    // MARK: - cosineSimilarity

    @Test func cosineOfIdenticalVectorsIsOne() {
        let similarity = PaceEmbeddingReranker.cosineSimilarity([1, 2, 3], [1, 2, 3])
        #expect(abs(similarity - 1.0) < 1e-9)
    }

    @Test func cosineOfOrthogonalVectorsIsZero() {
        let similarity = PaceEmbeddingReranker.cosineSimilarity([1, 0], [0, 1])
        #expect(abs(similarity) < 1e-9)
    }

    @Test func cosineOfMismatchedLengthsIsZero() {
        #expect(PaceEmbeddingReranker.cosineSimilarity([1, 0], [1, 0, 0]) == 0)
    }

    @Test func cosineOfZeroVectorIsZero() {
        #expect(PaceEmbeddingReranker.cosineSimilarity([0, 0], [1, 1]) == 0)
    }

    // MARK: - blendedScores

    @Test func blendIsEqualWeightAfterNormalization() {
        let blended = PaceEmbeddingReranker.blendedScores(
            lexical: [0, 10],
            semantic: [1, 0]
        )
        // First: lexical 0, semantic 1 → 0.5. Second: lexical 1, semantic 0 → 0.5.
        #expect(abs(blended[0] - 0.5) < 1e-9)
        #expect(abs(blended[1] - 0.5) < 1e-9)
    }

    @Test func constantLexicalSignalLetsSemanticDecide() {
        let blended = PaceEmbeddingReranker.blendedScores(
            lexical: [3, 3, 3],
            semantic: [0, 0.5, 1]
        )
        #expect(blended[2] > blended[1])
        #expect(blended[1] > blended[0])
    }

    // MARK: - rerank

    @Test func rerankPromotesSemanticallyCloserMatch() async {
        // Lexical order puts "quarterly numbers" first, but the query
        // vector sits on the "invoice email" axis.
        let matches = [
            makeMatch(excerpt: "quarterly numbers", score: 10),
            makeMatch(excerpt: "invoice email", score: 9),
        ]
        let embedder = FakeEmbedder(vectorsByText: [
            "find the invoice": [1, 0, 0],
            "quarterly numbers": [0, 1, 0],
            "invoice email": [0.95, 0, 0.1],
        ])
        let reranked = await PaceEmbeddingReranker.rerank(
            queryText: "find the invoice",
            matches: matches,
            embedder: embedder
        )
        #expect(reranked.first?.excerpt == "invoice email")
        #expect(reranked.count == 2)
    }

    @Test func rerankFallsBackToLexicalOrderOnEmbedderFailure() async {
        let matches = [
            makeMatch(excerpt: "first", score: 10),
            makeMatch(excerpt: "second", score: 9),
        ]
        let reranked = await PaceEmbeddingReranker.rerank(
            queryText: "anything",
            matches: matches,
            embedder: FailingEmbedder()
        )
        #expect(reranked.map(\.excerpt) == ["first", "second"])
    }

    @Test func rerankPassesThroughSingleMatchWithoutEmbedding() async {
        let matches = [makeMatch(excerpt: "only", score: 1)]
        let reranked = await PaceEmbeddingReranker.rerank(
            queryText: "q",
            matches: matches,
            embedder: FailingEmbedder()  // would throw if called
        )
        #expect(reranked.count == 1)
    }
}
