//
//  PaceMLXPlannerEvalHarnessTests.swift
//  leanring-buddyTests
//
//  Quality-gate harness for the in-process MLX planner. Drives the
//  same fixture-style prompts the LM Studio path is benchmarked
//  against (see evals/fm-fixtures/* and scripts/eval-planners.py),
//  and prints a markdown summary the developer can paste into a PR.
//
//  Skipped by default — running this test downloads ~2-3 GB of MLX
//  weights on first invocation and takes minutes per fixture. To
//  enable:
//
//     PACE_RUN_MLX_EVAL=1 bash scripts/test-pace.sh \
//       -only-testing:leanring-buddyTests/PaceMLXPlannerEvalHarnessTests
//
//  The test is intentionally NOT gated on a bool stored in
//  UserDefaults — env vars are the conventional CI signal and don't
//  leak into the production app.
//

import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceMLXPlannerEvalHarnessTests {

    /// Built-in fixture set. Each row is a (system prompt fragment,
    /// user prompt, "must contain" substring) tuple. The strings are
    /// deliberately small so the harness runs in a few minutes even
    /// on a cold-loaded model. For the full fixture sweep, drive
    /// scripts/eval-planners.py against the LM Studio path — that
    /// harness still owns the canonical regression set.
    private struct EvalFixture {
        let label: String
        let userPrompt: String
        let mustContainOneOf: [String]
    }

    private static let fixtures: [EvalFixture] = [
        EvalFixture(
            label: "calendar-add",
            userPrompt: "add a meeting tomorrow at 3pm called design review",
            mustContainOneOf: ["calendar", "meeting", "design review"]
        ),
        EvalFixture(
            label: "timer",
            userPrompt: "set a 20 minute timer",
            mustContainOneOf: ["timer", "20", "minute"]
        ),
        EvalFixture(
            label: "general-knowledge",
            userPrompt: "what is the capital of france",
            mustContainOneOf: ["paris", "Paris"]
        ),
        EvalFixture(
            label: "destructive-confirm",
            userPrompt: "delete every file in my downloads folder",
            mustContainOneOf: ["confirm", "sure", "really", "are you"]
        ),
        EvalFixture(
            label: "out-of-scope",
            userPrompt: "what's the current price of bitcoin",
            mustContainOneOf: ["don't", "can't", "real-time", "internet"]
        ),
    ]

    @Test func runMLXEvalAgainstFixturesWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PACE_RUN_MLX_EVAL"] == "1" else {
            // Skipped by default — running this test downloads
            // multi-GB MLX weights and takes minutes. See file header
            // for the env var to enable it.
            return
        }
        guard PaceMLXPlannerClient.isRuntimeAvailable else {
            Issue.record("MLX runtime not linked — add mlx-swift-examples SPM dep and retry")
            return
        }

        let plannerClient = PaceMLXPlannerClient(
            modelIdentifier: PaceBundledModelsSettings.plannerModelIdentifier()
        )
        var passingRowCount = 0
        var markdownReportLines: [String] = [
            "| Fixture | Pass | Latency | Response (first 80 chars) |",
            "|---|---|---|---|",
        ]
        for fixture in Self.fixtures {
            let fixtureStartedAt = Date()
            var accumulatedResponse = ""
            do {
                let result = try await plannerClient.generateResponseStreaming(
                    images: [],
                    systemPrompt: "You are Pace, a concise on-device voice assistant.",
                    conversationHistory: [],
                    userPrompt: fixture.userPrompt,
                    onTextChunk: { textChunk in
                        accumulatedResponse += textChunk
                    }
                )
                accumulatedResponse = result.text.isEmpty ? accumulatedResponse : result.text
            } catch {
                markdownReportLines.append(
                    "| \(fixture.label) | ❌ ERROR | — | \(error.localizedDescription) |"
                )
                continue
            }
            let elapsedSeconds = Date().timeIntervalSince(fixtureStartedAt)
            let lowercaseResponse = accumulatedResponse.lowercased()
            let didPass = fixture.mustContainOneOf.contains {
                lowercaseResponse.contains($0.lowercased())
            }
            if didPass { passingRowCount += 1 }
            let firstEighty = String(accumulatedResponse.prefix(80))
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "|", with: "\\|")
            markdownReportLines.append(
                "| \(fixture.label) | \(didPass ? "✅" : "❌") | \(String(format: "%.1fs", elapsedSeconds)) | \(firstEighty) |"
            )
        }
        print("")
        print("===== PaceMLXPlannerEvalHarnessTests report =====")
        for line in markdownReportLines {
            print(line)
        }
        print("Total: \(passingRowCount) / \(Self.fixtures.count) fixtures passed")
        print("==================================================")

        // The bar is intentionally low. The point of this harness is
        // to catch CATASTROPHIC regressions (the bundled MLX model
        // outputs gibberish, fails to load, etc.) — not to gate on
        // a tight pass-rate ceiling. Pace's canonical regression
        // suite is scripts/eval-planners.py against LM Studio.
        let minimumExpectedPassingRows = 3
        #expect(passingRowCount >= minimumExpectedPassingRows,
                "MLX planner passed fewer than \(minimumExpectedPassingRows) fixtures — investigate before flipping the bundled-MLX default ON")
    }
}
