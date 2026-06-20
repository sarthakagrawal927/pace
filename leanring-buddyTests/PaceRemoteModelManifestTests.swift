//
//  PaceRemoteModelManifestTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Pace

@Suite(.serialized)
struct PaceRemoteModelManifestTests {

    @Test func cachedManifestOverridesFallbackIdentifiers() throws {
        let defaults = UserDefaults.standard
        let cacheKey = "pace.remoteModelManifest.cachedJSON"
        let cacheTimestampKey = "pace.remoteModelManifest.cachedAt"
        let priorJSON = defaults.string(forKey: cacheKey)
        let priorTimestamp = defaults.object(forKey: cacheTimestampKey) as? Date
        defer {
            if let priorJSON {
                defaults.set(priorJSON, forKey: cacheKey)
            } else {
                defaults.removeObject(forKey: cacheKey)
            }
            if let priorTimestamp {
                defaults.set(priorTimestamp, forKey: cacheTimestampKey)
            } else {
                defaults.removeObject(forKey: cacheTimestampKey)
            }
        }

        defaults.set(
            """
            {"plannerModelIdentifier":"pace-ai/test-planner","embedderModelIdentifier":"pace-ai/test-embedder","vlmModelIdentifier":"pace-ai/test-vlm","publishedAt":"2026-06-20"}
            """,
            forKey: cacheKey
        )
        defaults.set(Date(), forKey: cacheTimestampKey)

        #expect(
            PaceRemoteModelManifest.resolvedPlannerModelIdentifier(fallback: "fallback-planner")
                == "pace-ai/test-planner"
        )
        #expect(
            PaceRemoteModelManifest.resolvedEmbedderModelIdentifier(fallback: "fallback-embedder")
                == "pace-ai/test-embedder"
        )
        #expect(
            PaceRemoteModelManifest.resolvedVLMModelIdentifier(fallback: "fallback-vlm")
                == "pace-ai/test-vlm"
        )
    }

    @Test func staleCacheFallsBackToBundledDefaults() throws {
        let defaults = UserDefaults.standard
        let cacheKey = "pace.remoteModelManifest.cachedJSON"
        let cacheTimestampKey = "pace.remoteModelManifest.cachedAt"
        let priorJSON = defaults.string(forKey: cacheKey)
        let priorTimestamp = defaults.object(forKey: cacheTimestampKey) as? Date
        defer {
            if let priorJSON {
                defaults.set(priorJSON, forKey: cacheKey)
            } else {
                defaults.removeObject(forKey: cacheKey)
            }
            if let priorTimestamp {
                defaults.set(priorTimestamp, forKey: cacheTimestampKey)
            } else {
                defaults.removeObject(forKey: cacheTimestampKey)
            }
        }

        defaults.set(
            """
            {"plannerModelIdentifier":"pace-ai/stale"}
            """,
            forKey: cacheKey
        )
        defaults.set(Date(timeIntervalSinceNow: -200_000), forKey: cacheTimestampKey)

        #expect(PaceRemoteModelManifest.cachedManifest() == nil)
        #expect(
            PaceRemoteModelManifest.resolvedPlannerModelIdentifier(fallback: "fallback-planner")
                == "fallback-planner"
        )
    }
}
