//
//  PaceIntentClassifierTests.swift
//  leanring-buddyTests
//
//  Smoke coverage for the rule-based intent classifier (task #113).
//  The Core ML-backed backend isn't tested here because the model file
//  doesn't ship in the bundle yet — once it does, add a parallel test
//  suite that runs against the trained .mlmodel.
//
//  These tests do NOT assert exact confidence numbers — those are
//  tuning knobs that may shift. They assert intent classification
//  on canonical phrasings from the seed corpus generator, which is
//  the contract callers (CompanionManager) actually depend on.
//

import Testing
@testable import Pace

@MainActor
struct PaceIntentClassifierTests {

    @Test func chitchatGreetings() async throws {
        let classifier = PaceIntentClassifier()
        for greeting in ["hi pace", "hello pace", "hey there", "good morning", "thanks"] {
            let prediction = classifier.classify(greeting)
            #expect(prediction.intent == .chitchat, "expected chitchat for \(greeting), got \(prediction.intent)")
        }
    }

    @Test func chitchatGratitude() async throws {
        let classifier = PaceIntentClassifier()
        let prediction = classifier.classify("thank you")
        #expect(prediction.intent == .chitchat)
    }

    @Test func pureKnowledgeQuestions() async throws {
        let classifier = PaceIntentClassifier()
        for question in [
            "what is html",
            "explain css",
            "tell me about transformers",
            "how does dns work",
        ] {
            let prediction = classifier.classify(question)
            #expect(prediction.intent == .pureKnowledge, "expected pureKnowledge for \(question), got \(prediction.intent)")
            #expect(prediction.route == .answerDirectly)
        }
    }

    @Test func micCheckQuestionsRouteToChitchatAndNotTheScreenPipeline() async throws {
        let classifier = PaceIntentClassifier()
        for question in [
            "can you hear me",
            "Can you hear me?",
            "are you there",
            "hey pace, do you hear me?",
            "mic check",
        ] {
            let prediction = classifier.classify(question)
            #expect(prediction.intent == .chitchat,
                "expected chitchat for \(question), got \(prediction.intent)")
        }
    }

    @Test func wakePhraseGreetingsHitTheChitchatFastPath() async throws {
        let classifier = PaceIntentClassifier()
        for greeting in [
            "Hey Pace, how is it going?",
            "hey pace how's it going",
            "Hi Pace, how are you?",
            "how is it going?",
            "how are things",
        ] {
            let prediction = classifier.classify(greeting)
            #expect(prediction.intent == .chitchat, "expected chitchat for \(greeting), got \(prediction.intent)")
        }
    }

    @Test func wakePhrasePrefixDoesNotChangeNonChitchatRouting() async throws {
        let classifier = PaceIntentClassifier()
        #expect(classifier.classify("hey pace, what is html").intent == .pureKnowledge)
        #expect(classifier.classify("ok pace, what apps did i use today").intent == .pureKnowledge)
        #expect(classifier.classify("hey pace, click the save button").intent == .screenAction)
        #expect(classifier.classify("hey pace, what's on the screen").intent == .screenDescription)
    }

    @Test func journalRecallQuestionsRouteTextOnly() async throws {
        let classifier = PaceIntentClassifier()
        for question in [
            "what apps did i use today",
            "what did i do today",
            "how did i spend my time this afternoon",
            "what have i been working on",
            "what was i doing earlier",
        ] {
            let prediction = classifier.classify(question)
            #expect(prediction.intent == .pureKnowledge, "expected pureKnowledge for \(question), got \(prediction.intent)")
            #expect(prediction.route == .answerDirectly)
        }
    }

    @Test func screenDescriptionRequests() async throws {
        let classifier = PaceIntentClassifier()
        for request in [
            "what's on the screen",
            "what am i looking at",
            "describe this",
            "what does this show",
        ] {
            let prediction = classifier.classify(request)
            #expect(prediction.intent == .screenDescription, "expected screenDescription for \(request), got \(prediction.intent)")
            #expect(prediction.route == .readScreen)
        }
    }

    @Test func screenActionClicks() async throws {
        let classifier = PaceIntentClassifier()
        for command in [
            "click the save button",
            "tap the menu icon",
            "press the back button",
            "open settings",
        ] {
            let prediction = classifier.classify(command)
            #expect(prediction.intent == .screenAction, "expected screenAction for \(command), got \(prediction.intent)")
            #expect(prediction.route == .executeTool)
        }
    }

    @Test func explicitLargeModelRequestsRouteToPhoneLargeModel() async throws {
        let classifier = PaceIntentClassifier()
        for request in [
            "phone a large model for this",
            "ask the big model",
            "use a large model and think deeply",
        ] {
            let prediction = classifier.classify(request)
            #expect(prediction.intent == .phoneLargeModel, "expected phoneLargeModel for \(request), got \(prediction.intent)")
            #expect(prediction.route == .phoneLargeModel)
        }
    }

    @Test func screenActionKeyboard() async throws {
        let classifier = PaceIntentClassifier()
        for command in [
            "press command s to save",
            "save the file",
            "quit the app",
            "page down",
        ] {
            let prediction = classifier.classify(command)
            #expect(prediction.intent == .screenAction, "expected screenAction for \(command), got \(prediction.intent)")
        }
    }

    @Test func localToolRequestsRouteToScreenAction() async throws {
        let classifier = PaceIntentClassifier()
        for command in [
            "open app Music",
            "open URL https://example.com",
            "play music",
            "turn volume down",
            "increase brightness",
            "read calendar",
            "create reminder to send invoice",
            "open Finder",
            "make a note called idea",
        ] {
            let prediction = classifier.classify(command)
            #expect(prediction.intent == .screenAction, "expected screenAction for \(command), got \(prediction.intent)")
            #expect(prediction.route == .executeTool)
        }
    }

    @Test func emptyTranscriptReturnsUnknown() async throws {
        let classifier = PaceIntentClassifier()
        #expect(classifier.classify("").intent == .unknown)
        #expect(classifier.classify("   ").intent == .unknown)
    }

    @Test func ambiguousTranscriptReturnsUnknown() async throws {
        // No keywords match — should be safely unknown so the caller
        // runs the full pipeline rather than skipping work blindly.
        let classifier = PaceIntentClassifier()
        let prediction = classifier.classify("the weather is nice today")
        #expect(prediction.intent == .unknown)
        #expect(prediction.route == .fullPipeline)
    }

    @Test func confidenceFloorDowngradesLowQualityPrediction() async throws {
        // Force the classifier to require near-impossible confidence so
        // every prediction falls back to .unknown. Verifies the
        // minimumConfidence threshold actually downgrades results.
        let classifier = PaceIntentClassifier(minimumConfidence: 0.99)
        let prediction = classifier.classify("click the save button")
        #expect(prediction.intent == .unknown)
    }

    @Test func ambiguousEditCommandsAskForClarification() async throws {
        let clarification = PaceIntentClarifier.clarification(for: "rewrite that")

        #expect(clarification?.question == "Edit selected text or the focused field?")
        #expect(clarification?.options == ["Selected text", "Focused field"])
    }

    @Test func ambiguousDestructiveCommandsAskForClarification() async throws {
        let clarification = PaceIntentClarifier.clarification(for: "delete that")

        #expect(clarification?.question == "What should I delete?")
        #expect(clarification?.options == ["Selected text", "Current item"])
    }

    @Test func explicitEditTargetsDoNotAskForClarification() async throws {
        #expect(PaceIntentClarifier.clarification(for: "rewrite the selected text") == nil)
        #expect(PaceIntentClarifier.clarification(for: "fix the focused field") == nil)
    }

    @Test func clarificationResolverRewritesAmbiguousEditTargets() async throws {
        let clarification = try #require(PaceIntentClarifier.clarification(for: "rewrite that"))
        let pendingClarification = PacePendingIntentClarification(
            originalTranscript: "rewrite that",
            clarification: clarification
        )

        #expect(PaceIntentClarificationResolver.clarifiedTranscript(
            for: pendingClarification,
            selectedOption: "Selected text"
        ) == "rewrite the selected text")

        #expect(PaceIntentClarificationResolver.clarifiedTranscript(
            for: pendingClarification,
            selectedOption: "Focused field"
        ) == "rewrite the focused field")
    }

    @Test func clarificationResolverRewritesDestructiveTargetsWithoutReasking() async throws {
        let clarification = try #require(PaceIntentClarifier.clarification(for: "delete this"))
        let pendingClarification = PacePendingIntentClarification(
            originalTranscript: "delete this",
            clarification: clarification
        )

        let clarifiedTranscript = PaceIntentClarificationResolver.clarifiedTranscript(
            for: pendingClarification,
            selectedOption: "Current item"
        )

        #expect(clarifiedTranscript == "delete the current item")
        #expect(PaceIntentClarifier.clarification(for: clarifiedTranscript ?? "") == nil)
    }

    @Test func clarificationResolverRejectsUnknownOptions() async throws {
        let clarification = try #require(PaceIntentClarifier.clarification(for: "rewrite it"))
        let pendingClarification = PacePendingIntentClarification(
            originalTranscript: "rewrite it",
            clarification: clarification
        )

        #expect(PaceIntentClarificationResolver.clarifiedTranscript(
            for: pendingClarification,
            selectedOption: "Whole document"
        ) == nil)
    }

    @Test func largeModelRequestsBecomeUnsupportedLocalOnlyResponses() async throws {
        let classifier = PaceIntentClassifier()
        let prediction = classifier.classify("ask the big model")
        let unsupportedResponse = PaceIntentUnsupportedDetector.unsupportedResponse(
            for: "ask the big model",
            prediction: prediction
        )

        #expect(prediction.route == .phoneLargeModel)
        #expect(unsupportedResponse?.spokenText == "I only use local models on this Mac.")
        #expect(unsupportedResponse?.reason == "Cloud or large-model escalation is not available.")
    }
}
