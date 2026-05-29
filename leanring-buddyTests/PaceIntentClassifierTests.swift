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
    }

    @Test func confidenceFloorDowngradesLowQualityPrediction() async throws {
        // Force the classifier to require near-impossible confidence so
        // every prediction falls back to .unknown. Verifies the
        // minimumConfidence threshold actually downgrades results.
        let classifier = PaceIntentClassifier(minimumConfidence: 0.99)
        let prediction = classifier.classify("click the save button")
        #expect(prediction.intent == .unknown)
    }
}
