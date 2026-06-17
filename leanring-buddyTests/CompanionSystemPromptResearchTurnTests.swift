//
//  CompanionSystemPromptResearchTurnTests.swift
//  leanring-buddyTests
//
//  Pins the contract of `CompanionSystemPrompt.buildForResearchTurn`
//  — the prompt research turns ship to claude/codex CLI.
//
//  Why these tests matter: the research prompt is what tells the
//  headless CLI to (a) use its OWN web tools instead of expecting
//  Pace's tool dialect, (b) return concise spoken prose instead of
//  action JSON, and (c) drop the agent-mode tool-docs that would
//  cost ~700 tokens of prefill on every research turn. If any of
//  those three guarantees regresses, the CLI will start emitting
//  garbage at the user (action JSON gets read aloud as `{"tool":...}`
//  which is the worst possible UX).
//

import Foundation
import Testing
@testable import Pace

struct CompanionSystemPromptResearchTurnTests {

    @Test func researchPromptOmitsAgentModeToolDocs() async throws {
        // The research prompt MUST NOT carry Pace's local action-tag
        // dialect — the CLI would see "use {\"tool\":\"click\"}" and
        // emit click JSON instead of a researched answer.
        let prompt = CompanionSystemPrompt.buildForResearchTurn()
        #expect(!prompt.contains("[CLICK:"))
        #expect(!prompt.contains("[TYPE:"))
        #expect(!prompt.contains("[SCROLL:"))
        #expect(!prompt.contains("[KEY:"))
        #expect(!prompt.contains("<tool_calls>"))
        #expect(!prompt.contains("draw_annotation"))
        #expect(!prompt.contains("plan-act-observe loop"))
    }

    @Test func researchPromptOmitsPointingRules() async throws {
        // Pointing rules talk about element IDs and screenshot
        // coordinates — useless on a screenless research turn. We
        // verify by absence of the structural pointing-rule phrases
        // (the v10 envelope's pointAtElementId/clickElementId field
        // names and the "i can't see X on this screen" template the
        // pointingRules block teaches). The literal `[POINT:` tag
        // syntax DOES appear because the research prompt's "no
        // action output" rule references it by name to forbid it —
        // can't test for that one's absence.
        let prompt = CompanionSystemPrompt.buildForResearchTurn()
        #expect(!prompt.contains("pointAtElementId"))
        #expect(!prompt.contains("clickElementId"))
        #expect(!prompt.contains("element ID"))
        #expect(!prompt.contains("i can't see"))
    }

    @Test func researchPromptInstructsCLIToUseItsOwnTools() async throws {
        // The whole point of this prompt is: "you have web tools,
        // use them." If that instruction drops out, the CLI will
        // try to answer from memory and the user gets stale info.
        let prompt = CompanionSystemPrompt.buildForResearchTurn().lowercased()
        #expect(prompt.contains("web search"))
        #expect(prompt.contains("web fetch"))
    }

    @Test func researchPromptInstructsConciseSpokenOutput() async throws {
        // Pace speaks the reply through TTS. The prompt must say
        // "no markdown bullets / no headers / paragraphs only" or
        // the CLI's default markdown output gets read literally
        // ("hash hash overview asterisk asterisk first point...").
        let prompt = CompanionSystemPrompt.buildForResearchTurn().lowercased()
        #expect(prompt.contains("paragraphs"))
        #expect(prompt.contains("no markdown"))
    }

    @Test func researchPromptExplicitlyForbidsActionJSON() async throws {
        // Without this rule, claude/codex sometimes echo back tool
        // call shapes ("I would call WebSearch...") that get spoken.
        let prompt = CompanionSystemPrompt.buildForResearchTurn().lowercased()
        #expect(prompt.contains("no action json"))
        #expect(prompt.contains("no tool_calls block"))
    }

    @Test func researchPromptKeepsBaseVoiceRules() async throws {
        // Personality and TTS-friendly tone are universal across
        // every Pace turn. Research must inherit them.
        let prompt = CompanionSystemPrompt.buildForResearchTurn()
        #expect(prompt.contains("you are pace"))
        #expect(prompt.contains("write for the ear"))
    }

    @Test func researchPromptThreadsSummaryInjection() async throws {
        let summaryInjection = "<conversation_so_far>user asked about Claude Code yesterday</conversation_so_far>"
        let prompt = CompanionSystemPrompt.buildForResearchTurn(
            threadSummaryInjection: summaryInjection
        )
        #expect(prompt.hasPrefix("<conversation_so_far>"))
        #expect(prompt.contains("user asked about Claude Code yesterday"))
    }

    @Test func researchPromptIsShorterThanAgentModePrompt() async throws {
        // Sanity check on the "save ~700 tokens of prefill" claim.
        // The research prompt should be materially smaller than the
        // full agent-mode prompt — otherwise the savings story dies.
        let researchPrompt = CompanionSystemPrompt.buildForResearchTurn()
        let fullAgentPrompt = CompanionSystemPrompt.build(includeAgentMode: true)
        #expect(researchPrompt.count < fullAgentPrompt.count)
        // Concretely: research prompt should be at most ~50% the size
        // of the full agent-mode prompt with all the tool docs.
        #expect(researchPrompt.count < fullAgentPrompt.count / 2)
    }
}
