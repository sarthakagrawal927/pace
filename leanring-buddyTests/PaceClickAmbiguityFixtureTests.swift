//
//  PaceClickAmbiguityFixtureTests.swift
//  leanring-buddyTests
//
//  File-driven ambiguity eval fixtures from evals/click-ambiguity-fixtures/.
//  Closes the "manual ambiguity evals → unit tests" item in
//  docs/prds/click-executor-improvements.md.
//

import Foundation
import Testing

@testable import Pace

struct PaceClickAmbiguityFixtureTests {

    private struct Fixture: Decodable {
        struct Candidate: Decodable {
            let label: String?
            let confidence: Double
        }

        let name: String
        let candidates: [Candidate]
        let expectAmbiguous: Bool
        let expectedOfferedLabels: [String]?
    }

    private static let fixtureURLs: [URL] = {
        let fileManager = FileManager.default
        let fixtureDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("evals/click-ambiguity-fixtures")
        return (try? fileManager.contentsOfDirectory(
            at: fixtureDirectory,
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }()

    @Test(arguments: fixtureURLs)
    func ambiguityFixturesMatchExpectedOutcome(fixtureURL: URL) throws {
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: fixtureURL)
        )

        let candidateSet = PaceClickCandidateSet(
            candidates: fixture.candidates.map { row in
                PaceClickCandidate(
                    location: nil,
                    label: row.label,
                    confidence: row.confidence,
                    expectStateChange: true
                )
            },
            clickCount: 1
        )

        let offeredCandidates = PaceClickCandidateAmbiguity.isAmbiguous(candidateSet)

        if fixture.expectAmbiguous {
            #expect(offeredCandidates != nil, "Expected ambiguity for \(fixture.name)")
            let offeredLabels = offeredCandidates?.compactMap(\.label) ?? []
            if let expectedOfferedLabels = fixture.expectedOfferedLabels {
                #expect(offeredLabels == expectedOfferedLabels, "Fixture \(fixture.name)")
            }
        } else {
            #expect(offeredCandidates == nil, "Expected no ambiguity for \(fixture.name)")
        }
    }
}
