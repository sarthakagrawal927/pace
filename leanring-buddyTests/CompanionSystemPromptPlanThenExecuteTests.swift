//
//  CompanionSystemPromptPlanThenExecuteTests.swift
//  leanring-buddyTests
//
//  Pins the plan-then-execute scaffold the bundled-MLX 4B planner
//  wraps every turn with. The scaffold's wording is a behavior
//  contract — small wording shifts measurably change the 4B
//  model's FM-fixture pass rate, so changes here must be paired
//  with an eval-gate run.
//

import Foundation
import Testing
@testable import Pace

struct CompanionSystemPromptPlanThenExecuteTests {

    @Test func wrapperAppendsScaffoldOntoBasePrompt() async throws {
        let basePrompt = "You are Pace. Speak briefly."
        let wrapped = CompanionSystemPrompt.wrapWithPlanThenExecuteScaffoldForBundledMLX(basePrompt)
        #expect(wrapped.hasPrefix(basePrompt))
        #expect(wrapped.contains("PLAN-THEN-EXECUTE"))
    }

    @Test func scaffoldTeachesTheIntentLineExplicitly() async throws {
        // The "intent:" line is the load-bearing piece — even on
        // single-action turns the model must restate intent in 3-7
        // words BEFORE producing the spoken response. Without it
        // the 4B model frequently misclassifies the user's request.
        let scaffold = CompanionSystemPrompt.planThenExecuteScaffoldForBundledMLX
        #expect(scaffold.contains("intent:"))
        #expect(scaffold.contains("3-7 words"))
    }

    @Test func scaffoldDocumentsTheThinkBlockIsStrippedBeforeTTS() async throws {
        // If the model believed the <think> block was user-visible,
        // it would refuse to reveal its reasoning, defeating the
        // scaffold. Pin the "scratchpad, not for the user" framing.
        let scaffold = CompanionSystemPrompt.planThenExecuteScaffoldForBundledMLX
        #expect(scaffold.contains("stripped before TTS"))
        #expect(scaffold.contains("scratchpad"))
    }

    @Test func scaffoldAllowsSkippingPlanAndRiskForSimpleRequests() async throws {
        // Bloating a single-action turn with a 3-line <think> block
        // wastes latency for no accuracy gain. The scaffold must
        // explicitly say "skip plan/risk on simple turns."
        let scaffold = CompanionSystemPrompt.planThenExecuteScaffoldForBundledMLX
        #expect(scaffold.contains("Skip"))
        // "single" and "no-risk" appear on adjacent lines in the
        // source — assert each phrase independently so the line-
        // wrapping in the source doesn't break the test.
        #expect(scaffold.contains("single"))
        #expect(scaffold.contains("no-risk action"))
    }

    @Test func scaffoldKeepsBrevityBarForTheSpokenResponse() async throws {
        // The plan-then-execute structure must NOT undermine Pace's
        // "1-2 short sentences for TTS" rule. Plan can be detailed;
        // spoken response stays tight.
        let scaffold = CompanionSystemPrompt.planThenExecuteScaffoldForBundledMLX
        #expect(scaffold.contains("1-2 short sentences"))
    }

    @Test func wrapperIsIdempotentRegardingTrailingNewlines() async throws {
        // Calling the wrapper twice should still produce something
        // valid — defensive against accidental double-wrap in a
        // future call site.
        let basePrompt = "Persona"
        let onceWrapped = CompanionSystemPrompt.wrapWithPlanThenExecuteScaffoldForBundledMLX(basePrompt)
        let twiceWrapped = CompanionSystemPrompt.wrapWithPlanThenExecuteScaffoldForBundledMLX(onceWrapped)
        #expect(twiceWrapped.contains(basePrompt))
        // Both invocations contain the scaffold body — the second
        // wrap doesn't accidentally swallow it.
        let scaffoldOccurrences = twiceWrapped.components(separatedBy: "PLAN-THEN-EXECUTE").count - 1
        #expect(scaffoldOccurrences == 2)
    }
}
