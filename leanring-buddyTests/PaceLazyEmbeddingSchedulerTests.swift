//
//  PaceLazyEmbeddingSchedulerTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceLazyEmbeddingSchedulerTests {

    // Stub embedding client that returns a known vector list. Lets
    // us drive the scheduler without LM Studio or Apple NL.
    private final class StubEmbeddingClient: PaceTextEmbedding, @unchecked Sendable {
        let vectorsToReturn: [[Float]]
        init(vectorsToReturn: [[Float]]) {
            self.vectorsToReturn = vectorsToReturn
        }
        func embed(_ texts: [String]) async throws -> [[Float]] {
            return vectorsToReturn
        }
    }

    private final class ThrowingEmbeddingClient: PaceTextEmbedding, @unchecked Sendable {
        struct StubError: Error {}
        func embed(_ texts: [String]) async throws -> [[Float]] {
            throw StubError()
        }
    }

    @Test func emptyInputSkipsScheduling() async throws {
        // Nothing to embed → scheduler should not even create a
        // detached task. We can't directly observe the no-task path,
        // but we can verify the persist callback is NOT fired.
        var persistInvocationCount = 0
        let memoryIndex = PaceMemoryIndex()
        let scheduler = PaceLazyEmbeddingScheduler(
            memoryIndex: memoryIndex,
            embeddingClientFactory: { StubEmbeddingClient(vectorsToReturn: []) },
            onEmbeddingsPersisted: { persistInvocationCount += 1 }
        )
        scheduler.schedule([])
        // Drain the runloop a hair just in case a detached task was
        // erroneously created.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(persistInvocationCount == 0)
    }

    @Test func wrongCardinalityFromClientDoesNotWriteEmbeddings() async throws {
        // Client returned fewer vectors than entry ids — the
        // scheduler must NOT zip-then-silently-drop the mismatch;
        // it should skip the whole write. Otherwise a quirky
        // embedding model could leave half the entries embedded
        // and half not, then we'd never re-embed.
        var persistInvocationCount = 0
        let memoryIndex = PaceMemoryIndex()
        let scheduler = PaceLazyEmbeddingScheduler(
            memoryIndex: memoryIndex,
            // Two entries asked, ONE vector returned — cardinality mismatch.
            embeddingClientFactory: { StubEmbeddingClient(vectorsToReturn: [[1, 2, 3]]) },
            onEmbeddingsPersisted: { persistInvocationCount += 1 }
        )
        scheduler.schedule([(id: "a", text: "first"), (id: "b", text: "second")])
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(persistInvocationCount == 0)
    }

    @Test func embeddingClientFailureDoesNotInvokePersist() async throws {
        var persistInvocationCount = 0
        let memoryIndex = PaceMemoryIndex()
        let scheduler = PaceLazyEmbeddingScheduler(
            memoryIndex: memoryIndex,
            embeddingClientFactory: { ThrowingEmbeddingClient() },
            onEmbeddingsPersisted: { persistInvocationCount += 1 }
        )
        scheduler.schedule([(id: "a", text: "first")])
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(persistInvocationCount == 0)
    }

    @Test func successfulEmbeddingTriggersPersistCallback() async throws {
        var persistInvocationCount = 0
        let memoryIndex = PaceMemoryIndex()
        let scheduler = PaceLazyEmbeddingScheduler(
            memoryIndex: memoryIndex,
            embeddingClientFactory: { StubEmbeddingClient(vectorsToReturn: [[1, 2, 3]]) },
            onEmbeddingsPersisted: { persistInvocationCount += 1 }
        )
        scheduler.schedule([(id: "a", text: "first")])
        // Poll briefly — the detached task hops back to the main actor asynchronously.
        for _ in 0..<30 where persistInvocationCount == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(persistInvocationCount == 1)
    }
}
