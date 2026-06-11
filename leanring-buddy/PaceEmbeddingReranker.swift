//
//  PaceEmbeddingReranker.swift
//  leanring-buddy
//
//  Embedding-backed re-ranking over the lexical retrieval store.
//  PaceInMemoryRetrievalStore stays the synchronous candidate generator
//  (BM25 + title/phrase boosts); this layer re-orders its top matches by
//  semantic similarity using a local embedding model served over the
//  OpenAI-compatible /v1/embeddings endpoint (LM Studio with
//  Qwen3-Embedding-0.6B-8bit by default — see pace-model-manifest).
//
//  Failure posture: best-effort. Endpoint down, model missing, or any
//  decode error returns the lexical order unchanged — retrieval never
//  gets WORSE because the embedding sidecar is unavailable.
//

import Foundation

protocol PaceTextEmbedding {
    /// Embeds each text into one vector. Order-preserving; one vector per input.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

struct PaceEmbeddingClientError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

/// OpenAI-compatible /v1/embeddings client (LM Studio locally).
final class LMStudioEmbeddingClient: PaceTextEmbedding {
    // Matches the artifact name `lms ls` reports for the downloaded model
    // (the 8bit suffix is a quantization detail LM Studio's API identifier
    // does not carry). Override via the RetrievalEmbeddingModel plist key.
    static let defaultModelIdentifier = "qwen3-embedding-0.6b"

    private let baseURL: URL
    private let modelIdentifier: String
    private let urlSession: URLSession
    private let requestTimeoutInSeconds: TimeInterval

    init(
        baseURL: URL? = nil,
        modelIdentifier: String? = nil,
        urlSession: URLSession = .shared,
        requestTimeoutInSeconds: TimeInterval = 10
    ) {
        let configuredBase = AppBundleConfiguration.stringValue(forKey: "RetrievalEmbeddingBaseURL")
            ?? AppBundleConfiguration.stringValue(forKey: "LocalVLMBaseURL")
            ?? "http://localhost:1234/v1"
        self.baseURL = baseURL ?? URL(string: configuredBase) ?? URL(fileURLWithPath: "/dev/null")
        self.modelIdentifier = modelIdentifier
            ?? AppBundleConfiguration.stringValue(forKey: "RetrievalEmbeddingModel")
            ?? Self.defaultModelIdentifier
        self.urlSession = urlSession
        self.requestTimeoutInSeconds = requestTimeoutInSeconds
    }

    private struct EmbeddingsRequest: Encodable {
        let model: String
        let input: [String]
    }

    private struct EmbeddingsResponse: Decodable {
        struct Item: Decodable {
            let index: Int
            let embedding: [Float]
        }

        let data: [Item]
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var request = URLRequest(url: baseURL.appendingPathComponent("embeddings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeoutInSeconds
        request.httpBody = try JSONEncoder().encode(
            EmbeddingsRequest(model: modelIdentifier, input: texts)
        )

        let requestStartedAt = Date()
        let inputCharacterCount = texts.reduce(0) { $0 + $1.count }
        func auditEmbedCall(outcome: String, detail: String? = nil) {
            PaceAPIAuditLog.shared.record(
                subsystem: "embeddings",
                operation: "embeddings",
                target: modelIdentifier,
                durationMilliseconds: Int(Date().timeIntervalSince(requestStartedAt) * 1000),
                outcome: outcome,
                inputCharacterCount: inputCharacterCount,
                detail: detail ?? "\(texts.count) inputs"
            )
        }

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                auditEmbedCall(outcome: "non_2xx")
                throw PaceEmbeddingClientError(
                    message: "embeddings endpoint returned non-2xx for model \(modelIdentifier)"
                )
            }
            let decoded = try JSONDecoder().decode(EmbeddingsResponse.self, from: data)
            guard decoded.data.count == texts.count else {
                auditEmbedCall(outcome: "count_mismatch")
                throw PaceEmbeddingClientError(
                    message: "embeddings endpoint returned \(decoded.data.count) vectors for \(texts.count) inputs"
                )
            }
            auditEmbedCall(outcome: "ok")
            return decoded.data.sorted { $0.index < $1.index }.map(\.embedding)
        } catch let error as PaceEmbeddingClientError {
            throw error
        } catch {
            auditEmbedCall(outcome: "transport_error", detail: String(error.localizedDescription.prefix(160)))
            throw error
        }
    }
}

enum PaceEmbeddingReranker {
    /// Weight of the semantic score in the blend. Lexical keeps equal say so
    /// exact-keyword hits (file names, app names) can't be drowned by a
    /// vaguely-similar chunk.
    static let semanticWeight = 0.5

    /// Re-orders lexical matches by blended (lexical, semantic) score.
    /// Returns `matches` unchanged on ANY embedding failure.
    static func rerank(
        queryText: String,
        matches: [PaceRetrievalMatch],
        embedder: PaceTextEmbedding
    ) async -> [PaceRetrievalMatch] {
        guard matches.count > 1 else { return matches }
        do {
            let vectors = try await embedder.embed([queryText] + matches.map(\.excerpt))
            guard let queryVector = vectors.first, vectors.count == matches.count + 1 else {
                return matches
            }
            let semantic = vectors.dropFirst().map { cosineSimilarity(queryVector, $0) }
            let blended = blendedScores(
                lexical: matches.map(\.score),
                semantic: semantic
            )
            // Ties broken by raw semantic similarity. With min-max
            // normalization the equal-weight blend ties whenever lexical and
            // semantic disagree on a pair (both normalize to 1 vs 0), and a
            // stable sort would silently keep lexical order — making the
            // reranker a no-op exactly when it has something to say.
            return zip(matches, zip(blended, semantic))
                .sorted { lhs, rhs in
                    if lhs.1.0 == rhs.1.0 {
                        return lhs.1.1 > rhs.1.1
                    }
                    return lhs.1.0 > rhs.1.0
                }
                .map(\.0)
        } catch {
            return matches
        }
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i])
            normA += Double(a[i]) * Double(a[i])
            normB += Double(b[i]) * Double(b[i])
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / ((normA * normB).squareRoot())
    }

    /// Min-max normalizes each signal to [0, 1] then blends. Constant
    /// signals normalize to 0 so the other signal decides alone.
    static func blendedScores(lexical: [Double], semantic: [Double]) -> [Double] {
        let normalizedLexical = minMaxNormalized(lexical)
        let normalizedSemantic = minMaxNormalized(semantic)
        return zip(normalizedLexical, normalizedSemantic).map {
            (1 - semanticWeight) * $0 + semanticWeight * $1
        }
    }

    private static func minMaxNormalized(_ values: [Double]) -> [Double] {
        guard let minValue = values.min(), let maxValue = values.max(),
              maxValue > minValue else {
            return values.map { _ in 0 }
        }
        return values.map { ($0 - minValue) / (maxValue - minValue) }
    }
}
