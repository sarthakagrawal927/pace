//
//  PaceFMIntentClassifier.swift
//  leanring-buddy
//
//  LLM-backed intent classifier using Apple Foundation Models' typed
//  `@Generable` output. Replaces the 200-line rule-based phrase-list
//  classifier — language understanding belongs to the language model,
//  not to a Swift if/contains tree.
//
//  Latency: greedy-sampled enum classification on a 3B in-process model
//  is ~80-200ms warm. The session is reused across calls so the system
//  prompt's KV cache survives, keeping the marginal cost low.
//
//  Availability: when Apple Intelligence isn't enabled / device isn't
//  eligible, `PaceIntentClassifierFactory` falls back to the rule-based
//  classifier so non-Apple-Intelligence Macs still route turns.
//

import Foundation
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct PaceFMIntentClassification {
    @Guide(description: """
    The single best route for handling the user's turn.
    - chitchat: greetings, thanks, goodbyes, mic checks like "can you hear me", "are you there".
    - pureKnowledge: factual or self-history questions answerable WITHOUT looking at the current screen ("what is HTML", "what apps did I use today").
    - screenDescription: user wants Pace to look at and describe the current screen ("what's on the screen", "what am I looking at").
    - screenAction: user wants Pace to DO something via the action layer — click, type, open, launch, play, pause, create, draft, etc.
    - phoneLargeModel: user explicitly asked for a bigger/stronger model ("phone a large model", "hard mode", "use the big model").
    - unknown: anything else ambiguous; CompanionManager will run the full pipeline.
    """)
    let route: PaceFMIntentRoute
}

@available(macOS 26.0, *)
@Generable
enum PaceFMIntentRoute: String {
    case chitchat
    case pureKnowledge
    case screenDescription
    case screenAction
    case phoneLargeModel
    case unknown

    var asPaceIntent: PaceIntent {
        switch self {
        case .chitchat: return .chitchat
        case .pureKnowledge: return .pureKnowledge
        case .screenDescription: return .screenDescription
        case .screenAction: return .screenAction
        case .phoneLargeModel: return .phoneLargeModel
        case .unknown: return .unknown
        }
    }
}

@available(macOS 26.0, *)
@MainActor
final class PaceFMIntentClassifier {
    private static let routingInstructions = """
    You classify a single user voice turn into ONE routing category for Pace, a macOS voice companion. Pick the cheapest accurate route. When in doubt, prefer unknown over a wrong specific route — unknown triggers the full pipeline so nothing breaks.
    """

    private var session: LanguageModelSession?

    func classify(_ transcript: String) async -> PaceIntentPrediction {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return PaceIntentPrediction(intent: .unknown, confidence: 0)
        }

        let resolvedSession = resolveSession()
        let generationOptions = GenerationOptions(
            samplingMode: .greedy,
            temperature: 0,
            maximumResponseTokens: 30
        )

        do {
            let typedResponse: LanguageModelSession.Response<PaceFMIntentClassification>
            typedResponse = try await resolvedSession.respond(
                to: "user said: \"\(trimmedTranscript)\"",
                generating: PaceFMIntentClassification.self,
                options: generationOptions
            )
            return PaceIntentPrediction(
                intent: typedResponse.content.route.asPaceIntent,
                confidence: 0.95
            )
        } catch {
            // Falling back to .unknown means CompanionManager runs the
            // full pipeline — safe degradation, never a wrong route.
            print("⚠️ FM intent classifier failed: \(error.localizedDescription) — falling through to full pipeline")
            return PaceIntentPrediction(intent: .unknown, confidence: 0)
        }
    }

    private func resolveSession() -> LanguageModelSession {
        if let session {
            return session
        }
        let newSession = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: Instructions(Self.routingInstructions)
        )
        session = newSession
        return newSession
    }
}

@MainActor
enum PaceIntentClassifierFactory {
    static func makeDefault() -> any PaceIntentClassifying {
        if #available(macOS 26.0, *) {
            let systemLanguageModel = SystemLanguageModel.default
            if case .available = systemLanguageModel.availability {
                print("🧠 PaceIntentClassifier: Apple Foundation Models backend")
                return PaceFMIntentClassifierAdapter(classifier: PaceFMIntentClassifier())
            }
        }
        print("🧠 PaceIntentClassifier: rule-based fallback (Apple Intelligence unavailable)")
        return PaceRuleBasedIntentClassifierAdapter(classifier: PaceIntentClassifier())
    }
}

@MainActor
protocol PaceIntentClassifying: AnyObject {
    func classify(_ transcript: String) async -> PaceIntentPrediction
}

/// Rule-based classifier wrapped in the async protocol shape so both
/// backends present the same surface to CompanionManager.
@MainActor
final class PaceRuleBasedIntentClassifierAdapter: PaceIntentClassifying {
    private let classifier: PaceIntentClassifier

    init(classifier: PaceIntentClassifier) {
        self.classifier = classifier
    }

    func classify(_ transcript: String) async -> PaceIntentPrediction {
        classifier.classify(transcript)
    }
}

@available(macOS 26.0, *)
@MainActor
final class PaceFMIntentClassifierAdapter: PaceIntentClassifying {
    private let classifier: PaceFMIntentClassifier

    init(classifier: PaceFMIntentClassifier) {
        self.classifier = classifier
    }

    func classify(_ transcript: String) async -> PaceIntentPrediction {
        await classifier.classify(transcript)
    }
}
