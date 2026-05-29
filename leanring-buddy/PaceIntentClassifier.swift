//
//  PaceIntentClassifier.swift
//  leanring-buddy
//
//  Predicts what kind of turn the user just spoke (task #113) so the
//  pipeline can skip work the turn doesn't need. Four classes:
//
//    .pureKnowledge       "what is HTML"          → skip VLM, skip OCR/AX
//    .screenDescription   "what's on screen"      → run AX+OCR, maybe skip VLM
//    .screenAction        "click the save button" → full pipeline
//    .chitchat            "hi pace", "thanks"     → skip VLM, skip planner
//
//  Two backends ship behind the same public surface:
//
//    1. `RuleBasedClassifier` — keyword heuristic, no model file required.
//       Works today, lower accuracy. Used as the always-available
//       fallback when the .mlmodel isn't bundled.
//
//    2. `CoreMLClassifier` — uses a Create ML text-classifier .mlmodel
//       trained from `scripts/generate-intent-corpus.py` output. Higher
//       accuracy especially on phrasings the keyword heuristic misses
//       ("explain async/await" — no keyword match, but clearly knowledge).
//       Lazily instantiated when the model file is present in the bundle.
//
//  The classifier is read-only and stateless — `classify(_ transcript:)`
//  is the entire public surface. CompanionManager calls it once per
//  turn between PTT-release and the VLM/planner dispatch. Confidence
//  is returned alongside the prediction so callers can fall through to
//  the full pipeline when the model isn't sure.
//
//  Why not wired into CompanionManager yet
//  ---------------------------------------
//  This ships as a standalone module so it can be evaluated in
//  isolation first via PaceIntentClassifierTests. Once we've seen
//  classifier accuracy on the seed corpus + a few real-user examples,
//  CompanionManager.sendTranscriptToPlannerWithScreenshot will read
//  the prediction and branch the pipeline. Wiring is mechanical;
//  validating the classifier comes first.
//

import Foundation

/// What kind of turn the user is asking for. Drives pipeline routing
/// inside CompanionManager. The ordering of cases mirrors the cost-
/// to-execute axis: chitchat is cheapest (canned response), pureKnowledge
/// just needs the planner, screenDescription needs AX+OCR, screenAction
/// needs everything.
enum PaceIntent: String, CaseIterable {
    /// Factual question, no screen context required. e.g. "what is CSS".
    case pureKnowledge

    /// User wants a description of what's on screen. AX-tree + OCR is
    /// enough; VLM is optional. e.g. "what am I looking at".
    case screenDescription

    /// User wants Pace to do something via the action layer. Full VLM
    /// + planner + action exec needed. e.g. "click the save button".
    case screenAction

    /// Greeting or social filler. Canned response is fine. e.g. "hi pace".
    case chitchat

    /// Classifier could not confidently assign one of the above. The
    /// caller MUST treat this as "run the full pipeline" — never skip
    /// the VLM or planner on an unknown intent.
    case unknown
}

/// Result of a classification call. Confidence is roughly 0...1; a
/// low value tells CompanionManager to fall through to the full
/// pipeline regardless of the predicted class.
struct PaceIntentPrediction: Equatable {
    let intent: PaceIntent
    let confidence: Double
}

@MainActor
final class PaceIntentClassifier {
    /// Below this confidence the prediction is downgraded to .unknown
    /// at the public surface. Picked to match the practical floor where
    /// the classifier's wrong calls outweigh the latency it saves
    /// (this number deserves a calibration sweep once the .mlmodel is
    /// trained — placeholder for now).
    static let defaultMinimumConfidence: Double = 0.6

    private let backend: PaceIntentClassifierBackend
    private let minimumConfidence: Double

    init(minimumConfidence: Double = PaceIntentClassifier.defaultMinimumConfidence) {
        self.minimumConfidence = minimumConfidence
        // Backend selection: try Core ML first (higher accuracy), fall
        // through to rule-based when the model file isn't in the bundle.
        if let coreMLBackend = CoreMLBackedIntentClassifier.tryLoadFromBundle() {
            self.backend = coreMLBackend
            print("🧠 PaceIntentClassifier: using \(coreMLBackend.displayName)")
        } else {
            let ruleBasedBackend = RuleBasedIntentClassifier()
            self.backend = ruleBasedBackend
            print("🧠 PaceIntentClassifier: using \(ruleBasedBackend.displayName) (Core ML model not bundled)")
        }
    }

    /// Classify a transcript. Returns `.unknown` when the underlying
    /// backend's confidence is below `minimumConfidence`. Callers
    /// should treat `.unknown` as "run the full pipeline."
    func classify(_ transcript: String) -> PaceIntentPrediction {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PaceIntentPrediction(intent: .unknown, confidence: 0)
        }
        let backendPrediction = backend.classify(trimmed)
        if backendPrediction.confidence < minimumConfidence {
            return PaceIntentPrediction(intent: .unknown, confidence: backendPrediction.confidence)
        }
        return backendPrediction
    }
}

/// Internal interface so the two backends compose cleanly. Not exposed
/// outside this file — callers always go through `PaceIntentClassifier`.
@MainActor
private protocol PaceIntentClassifierBackend {
    var displayName: String { get }
    func classify(_ transcript: String) -> PaceIntentPrediction
}


// MARK: - Backend 1: rule-based (always available)

@MainActor
final class RuleBasedIntentClassifier: PaceIntentClassifierBackend {
    let displayName = "rule-based intent classifier"

    // Strong indicators for each class. Picked from the seed corpus
    // generation patterns — anything the seed generator emits should
    // be matchable here. False positives are biased toward the more
    // expensive class so we don't accidentally skip the VLM on an
    // ambiguous turn.
    private let chitchatStarters: [String] = [
        "hi pace", "hello pace", "hey there", "hi there", "good morning",
        "good evening", "what's up", "how are you", "how's it going",
        "thanks", "thank you", "appreciate it", "you're great",
        "you're awesome", "good job", "nice work", "bye for now",
        "talk later", "catch you later", "later pace", "see you",
        "alright", "okay cool", "got it", "sounds good", "perfect", "nice",
    ]

    private let knowledgePatterns: [String] = [
        "what is ", "what's ", "explain ", "tell me about ",
        "how does ", "remind me what ", "what does ",
        "in plain english what is ", "describe ",
    ]

    // Action verbs — when the transcript contains any of these AND
    // doesn't look like a description ("describe", "show me"), it's
    // probably a screen-action turn.
    private let actionVerbs: [String] = [
        "click", "tap", "press", "hit", "open", "launch",
        "choose", "select", "focus", "toggle", "type ",
        "scroll", "page down", "page up", "save with",
        "save the file", "quit the app",
    ]

    // Description hints — phrases that suggest the user wants Pace to
    // describe the screen rather than act on it.
    private let descriptionHints: [String] = [
        "what's on the screen", "what am i looking at",
        "describe what i'm looking at", "describe this",
        "summarise this", "summarize", "what does this show",
        "what does this say", "what's happening on screen",
        "read this", "what's in front of me", "give me the gist",
        "what can you see", "tell me what's open", "what's this window about",
        "walk me through", "what's visible", "scan the screen",
        "what's on display", "what page am i on", "what app is this",
        "explain what's shown", "describe my current view",
        "what's this all about", "lay out what's on the screen",
    ]

    func classify(_ transcript: String) -> PaceIntentPrediction {
        let lowercaseTranscript = transcript.lowercased()

        // Chitchat: very high confidence when the whole transcript
        // matches a known phrase (often a single short utterance).
        for chitchatPhrase in chitchatStarters {
            if lowercaseTranscript == chitchatPhrase
                || lowercaseTranscript.hasPrefix(chitchatPhrase + " ")
                || lowercaseTranscript == chitchatPhrase + "." {
                return PaceIntentPrediction(intent: .chitchat, confidence: 0.95)
            }
        }

        // Description hints checked BEFORE action verbs because phrases
        // like "describe this" don't start with an action verb but
        // contain words like "this" that the broader heuristic could
        // miscategorise. Order matters here.
        for descriptionHint in descriptionHints {
            if lowercaseTranscript.contains(descriptionHint) {
                return PaceIntentPrediction(intent: .screenDescription, confidence: 0.85)
            }
        }

        // Action: any action verb in the transcript.
        for actionVerb in actionVerbs {
            if lowercaseTranscript.contains(actionVerb) {
                return PaceIntentPrediction(intent: .screenAction, confidence: 0.80)
            }
        }

        // Pure-knowledge: starts with a "what is" / "explain" pattern.
        for knowledgePattern in knowledgePatterns {
            if lowercaseTranscript.hasPrefix(knowledgePattern) {
                return PaceIntentPrediction(intent: .pureKnowledge, confidence: 0.75)
            }
        }

        // Nothing matched — return .unknown with a deliberately low
        // confidence so the PaceIntentClassifier wrapper downgrades it
        // and CompanionManager runs the full pipeline.
        return PaceIntentPrediction(intent: .unknown, confidence: 0.0)
    }
}


// MARK: - Backend 2: Core ML (when the .mlmodel is bundled)

@MainActor
final class CoreMLBackedIntentClassifier: PaceIntentClassifierBackend {
    let displayName = "Core ML intent classifier"

    /// Attempts to load the bundled .mlmodel. Returns nil when the
    /// model file isn't in the app's resources — the caller falls
    /// back to the rule-based classifier in that case.
    static func tryLoadFromBundle() -> CoreMLBackedIntentClassifier? {
        // TODO(#113): once the .mlmodel is trained via Create ML and
        // dropped into the app bundle, this becomes:
        //
        //   guard let modelURL = Bundle.main.url(
        //     forResource: "PaceIntent", withExtension: "mlmodelc"
        //   ) else { return nil }
        //   guard let model = try? PaceIntent(contentsOf: modelURL) else {
        //     return nil
        //   }
        //   return CoreMLBackedIntentClassifier(model: model)
        //
        // For now, we return nil so the rule-based backend handles all
        // calls.
        return nil
    }

    private init() {
        // Once the real init takes a model handle, replace this.
    }

    func classify(_ transcript: String) -> PaceIntentPrediction {
        // TODO(#113): forward the transcript through the Core ML model.
        // Expected shape (depends on Create ML's output bindings):
        //
        //   let prediction = try model.prediction(text: transcript)
        //   guard let intent = PaceIntent(rawValue: prediction.label),
        //         let confidence = prediction.labelProbability[prediction.label] else {
        //     return PaceIntentPrediction(intent: .unknown, confidence: 0)
        //   }
        //   return PaceIntentPrediction(intent: intent, confidence: confidence)
        //
        // While the model isn't loaded, this backend instance shouldn't
        // exist (tryLoadFromBundle returns nil). Defensive return:
        return PaceIntentPrediction(intent: .unknown, confidence: 0)
    }
}
