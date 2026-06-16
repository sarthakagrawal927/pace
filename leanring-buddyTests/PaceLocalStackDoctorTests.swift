//
//  PaceLocalStackDoctorTests.swift
//  leanring-buddyTests
//
//  Tests for PaceLocalStackDoctor's pure classification helpers.
//  All checks that hit the real network are intentionally NOT tested here —
//  only the static helpers that classify already-received response bodies
//  are covered, because those are the logic worth protecting from regressions.
//

import Foundation
import Testing

@testable import Pace

struct PaceLocalStackDoctorTests {

    // MARK: - embeddingsResponseStatus

    @Test func embeddingsResponseStatusIsOkForValidEmbeddingArray() {
        let validBody = """
        {
            "object": "list",
            "data": [
                {
                    "object": "embedding",
                    "index": 0,
                    "embedding": [0.12, -0.34, 0.56]
                }
            ],
            "model": "text-embedding-nomic-embed-text-v1.5"
        }
        """
        let status = PaceLocalStackDoctor.embeddingsResponseStatus(fromResponseBody: validBody)
        #expect(status == .ok)
    }

    @Test func embeddingsResponseStatusIsFailForEmptyEmbeddingArray() {
        // A model that loads as type:llm may return an empty embedding array
        // instead of a proper error — still a failure for our purposes.
        let emptyEmbeddingBody = """
        {
            "data": [
                {
                    "embedding": []
                }
            ]
        }
        """
        let status = PaceLocalStackDoctor.embeddingsResponseStatus(fromResponseBody: emptyEmbeddingBody)
        #expect(status == .fail)
    }

    @Test func embeddingsResponseStatusIsFailForErrorResponse() {
        // LM Studio returns an error object when no embeddings model is loaded.
        let errorBody = """
        {
            "error": {
                "code": "model_not_found",
                "message": "No models loaded"
            }
        }
        """
        let status = PaceLocalStackDoctor.embeddingsResponseStatus(fromResponseBody: errorBody)
        #expect(status == .fail)
    }

    @Test func embeddingsResponseStatusIsFailForEmptyBody() {
        let status = PaceLocalStackDoctor.embeddingsResponseStatus(fromResponseBody: "")
        #expect(status == .fail)
    }

    @Test func embeddingsResponseStatusIsFailForMalformedJSON() {
        let status = PaceLocalStackDoctor.embeddingsResponseStatus(fromResponseBody: "not json at all {{{")
        #expect(status == .fail)
    }

    @Test func embeddingsResponseStatusIsFailWhenDataKeyIsMissing() {
        // A chat-completion response from a non-embedding model looks like this —
        // no "data" key, so the helper correctly fails.
        let chatCompletionBody = """
        {
            "choices": [
                {"message": {"content": "hello"}}
            ]
        }
        """
        let status = PaceLocalStackDoctor.embeddingsResponseStatus(fromResponseBody: chatCompletionBody)
        #expect(status == .fail)
    }

    // MARK: - modelStateInV0ModelsResponse

    @Test func modelStateIsLoadedWhenIdMatchesAndStateIsLoaded() {
        let responseBody = """
        {
            "data": [
                {
                    "id": "google/gemma-3-12b",
                    "state": "loaded",
                    "type": "llm"
                }
            ]
        }
        """
        let state = PaceLocalStackDoctor.modelStateInV0ModelsResponse(
            responseBody: responseBody,
            targetModelIdentifier: "google/gemma-3-12b"
        )
        #expect(state == .loaded)
    }

    @Test func modelStateIsPresentButNotLoadedWhenStateIsNotLoaded() {
        let responseBody = """
        {
            "data": [
                {
                    "id": "google/gemma-3-12b",
                    "state": "not-loaded",
                    "type": "llm"
                }
            ]
        }
        """
        let state = PaceLocalStackDoctor.modelStateInV0ModelsResponse(
            responseBody: responseBody,
            targetModelIdentifier: "google/gemma-3-12b"
        )
        #expect(state == .presentButNotLoaded)
    }

    @Test func modelStateIsNotFoundWhenIdIsAbsent() {
        let responseBody = """
        {
            "data": [
                {
                    "id": "some-other-model",
                    "state": "loaded"
                }
            ]
        }
        """
        let state = PaceLocalStackDoctor.modelStateInV0ModelsResponse(
            responseBody: responseBody,
            targetModelIdentifier: "google/gemma-3-12b"
        )
        #expect(state == .notFound)
    }

    @Test func modelStateIsNotFoundForEmptyDataArray() {
        let responseBody = """
        {
            "data": []
        }
        """
        let state = PaceLocalStackDoctor.modelStateInV0ModelsResponse(
            responseBody: responseBody,
            targetModelIdentifier: "google/gemma-3-12b"
        )
        #expect(state == .notFound)
    }

    @Test func modelStateIsNotFoundForMalformedJSON() {
        let state = PaceLocalStackDoctor.modelStateInV0ModelsResponse(
            responseBody: "not json {{{",
            targetModelIdentifier: "google/gemma-3-12b"
        )
        #expect(state == .notFound)
    }

    @Test func modelStateIsLoadedWhenMultipleModelsAndTargetIsLoaded() {
        // The list contains several models; only the target should match.
        let responseBody = """
        {
            "data": [
                {
                    "id": "text-embedding-nomic-embed-text-v1.5",
                    "state": "loaded",
                    "type": "embeddings"
                },
                {
                    "id": "google/gemma-3-12b",
                    "state": "loaded",
                    "type": "llm"
                },
                {
                    "id": "ui-venus-1.5-2b",
                    "state": "not-loaded",
                    "type": "vlm"
                }
            ]
        }
        """
        let plannerState = PaceLocalStackDoctor.modelStateInV0ModelsResponse(
            responseBody: responseBody,
            targetModelIdentifier: "google/gemma-3-12b"
        )
        #expect(plannerState == .loaded)

        let vlmState = PaceLocalStackDoctor.modelStateInV0ModelsResponse(
            responseBody: responseBody,
            targetModelIdentifier: "ui-venus-1.5-2b"
        )
        #expect(vlmState == .presentButNotLoaded)
    }

    // MARK: - apiV0Root

    @Test func apiV0RootStripsV1SuffixAndAppendsApiV0() {
        let result = PaceLocalStackDoctor.apiV0Root(fromV1BaseURL: "http://localhost:1234/v1")
        #expect(result == "http://localhost:1234/api/v0")
    }

    @Test func apiV0RootLeavesURLUntouchedWhenNoV1Suffix() {
        // If the URL doesn't end in /v1 (unusual config), it falls back to the
        // original so we don't silently break the endpoint.
        let result = PaceLocalStackDoctor.apiV0Root(fromV1BaseURL: "http://localhost:1234")
        #expect(result == "http://localhost:1234")
    }
}
