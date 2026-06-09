//
//  PacePlannerModelResolver.swift
//  leanring-buddy
//
//  Resolves which model identifier the planner should actually send
//  to LM Studio at runtime.
//
//  Why this exists
//  ---------------
//  The default `LocalPlannerModelIdentifier` in Info.plist is one
//  hard-coded string (today: `qwen/qwen3-14b`). The moment the user's
//  LM Studio doesn't have that exact model downloaded, every voice
//  turn 400s with "Invalid model identifier" — and the user has to
//  edit Info.plist and rebuild to recover. Bad UX.
//
//  This resolver fixes that:
//
//    1. At app warmup, we query `/v1/models` to see what's actually
//       loaded.
//    2. If the configured identifier is present, we use it as-is.
//    3. Otherwise we pick the smallest chat-looking model that IS
//       present (Qwen3 family preferred, in size order
//       0.6b → 1.7b → 4b → 8b → 14b → 30b). Smaller wins because
//       this is a voice-latency-sensitive product.
//    4. If none of the heuristics match, we fall back to the first
//       chat model we see.
//    5. If `/v1/models` itself is unreachable, we just return the
//       configured value and let the first request hit the existing
//       error path.
//
//  The resolved identifier is cached in a static so subsequent reads
//  by `LocalPlannerClient.makeFromInfoPlist` see it without making
//  another HTTP call.
//

import Foundation

enum PacePlannerModelResolver {
    /// Set by `resolveAndCache(...)` at app warmup. `LocalPlannerClient
    /// .makeFromInfoPlist` reads this before falling back to the raw
    /// Info.plist value, so once the resolver picks a model, every
    /// subsequent planner construction uses it.
    private static let cachedResolvedIdentifierLock = NSLock()
    private static var cachedResolvedIdentifier: String?

    static var resolvedIdentifier: String? {
        cachedResolvedIdentifierLock.lock()
        defer { cachedResolvedIdentifierLock.unlock() }
        return cachedResolvedIdentifier
    }

    /// Pick a model identifier, cache it, and return it. Idempotent —
    /// later calls re-resolve and update the cache (so warmup re-runs
    /// pick up newly-downloaded models without restart).
    @discardableResult
    static func resolveAndCache(
        configuredIdentifier: String,
        plannerBaseURL: URL
    ) async -> String {
        let availableLoadedModelIdentifiers = await fetchLoadedModelIdentifiers(plannerBaseURL: plannerBaseURL)

        let resolvedIdentifier: String
        if availableLoadedModelIdentifiers.isEmpty {
            // No connectivity / empty model list — let the existing
            // error path surface the issue rather than guessing.
            resolvedIdentifier = configuredIdentifier
            print("🧭 Planner resolver: /v1/models empty or unreachable, keeping configured '\(configuredIdentifier)'")
        } else if availableLoadedModelIdentifiers.contains(configuredIdentifier) {
            resolvedIdentifier = configuredIdentifier
            print("🧭 Planner resolver: configured '\(configuredIdentifier)' is loaded — using it")
        } else if let smallestChatModel = pickSmallestChatModel(from: availableLoadedModelIdentifiers) {
            resolvedIdentifier = smallestChatModel
            print("🧭 Planner resolver: configured '\(configuredIdentifier)' is NOT loaded. Falling back to '\(smallestChatModel)' (smallest chat model present).")
        } else {
            resolvedIdentifier = configuredIdentifier
            print("🧭 Planner resolver: configured '\(configuredIdentifier)' not loaded and no chat-looking fallback found. Keeping configured value.")
        }

        cachedResolvedIdentifierLock.lock()
        cachedResolvedIdentifier = resolvedIdentifier
        cachedResolvedIdentifierLock.unlock()

        logModelSizeAdviceIfWarranted(forResolvedIdentifier: resolvedIdentifier)

        return resolvedIdentifier
    }

    /// If the resolved planner is in a too-large-for-voice size class,
    /// print a one-line actionable tip so the user has a clear path to
    /// the millisecond regime. Pace is positioned on speed; a 14B
    /// model on prefill cannot physically be sub-second on any prompt
    /// of interesting size — we've measured this. A 1.7B model can.
    private static func logModelSizeAdviceIfWarranted(forResolvedIdentifier identifier: String) {
        let approximateBillions = approximateParameterBillions(from: identifier)
        guard approximateBillions >= 8 else { return }
        let estimatedTTFTSeconds = max(2, Int(approximateBillions * 0.5))
        print("⚡ Speed tip: '\(identifier)' is \(approximateBillions)B params — expect ~\(estimatedTTFTSeconds)s TTFT on typical prompts. For sub-second voice, download `qwen3-1.7b-instruct` (~1.5GB) in LM Studio. Pace's resolver will auto-pick it.")
    }

    // MARK: - HTTP

    private static func fetchLoadedModelIdentifiers(plannerBaseURL: URL) async -> [String] {
        do {
            try PaceLocalEndpointGuard.validateLocalHTTPURL(
                plannerBaseURL,
                settingName: "LocalPlannerBaseURL"
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            print("⚠️ Planner resolver: \(message)")
            return []
        }

        var request = URLRequest(url: plannerBaseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        let probeSessionConfiguration = URLSessionConfiguration.ephemeral
        probeSessionConfiguration.timeoutIntervalForRequest = 2
        probeSessionConfiguration.timeoutIntervalForResource = 4
        let probeSession = URLSession(configuration: probeSessionConfiguration)
        defer { probeSession.invalidateAndCancel() }

        do {
            let (responseData, response) = try await probeSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }
            // LM Studio's /v1/models response shape: { "data": [{ "id": ... }, ...] }
            guard let topLevel = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let modelEntries = topLevel["data"] as? [[String: Any]] else {
                return []
            }
            return modelEntries.compactMap { entry in entry["id"] as? String }
        } catch {
            return []
        }
    }

    // MARK: - Heuristics

    /// Order of preference: smallest first, by an inferred parameter
    /// count. Models without a recognizable size in the name are
    /// scored last. Embeddings and the VLM family (`ui-venus`,
    /// `nomic-embed`) are excluded — those aren't chat models.
    nonisolated static func pickSmallestChatModel(from loadedIdentifiers: [String]) -> String? {
        let chatModelIdentifiers = loadedIdentifiers.filter { isLikelyChatModel($0) }
        guard !chatModelIdentifiers.isEmpty else { return nil }
        let sortedBySize = chatModelIdentifiers
            .map { ($0, approximateParameterBillions(from: $0)) }
            .sorted { lhs, rhs in lhs.1 < rhs.1 }
        return sortedBySize.first?.0
    }

    /// `true` if the identifier looks like a chat model. The screen
    /// of names is conservative: we reject things we know are *not*
    /// chat models (embeddings, vision models), and accept the rest.
    nonisolated static func isLikelyChatModel(_ modelIdentifier: String) -> Bool {
        let lowercased = modelIdentifier.lowercased()
        let nonChatHints = [
            "embed",      // text-embedding-*
            "embedding",
            "ui-venus",   // vision-language models we use as the VLM
            "vl-",        // qwen3-vl-*, etc.
            "qwen3-vl",
            "moondream",
            "llava"
        ]
        for nonChatHint in nonChatHints {
            if lowercased.contains(nonChatHint) {
                return false
            }
        }
        return true
    }

    /// Extracts the "Nb"/"Nmb" parameter count from a model
    /// identifier — handles names like `qwen3-1.7b`,
    /// `qwen/qwen3-30b-a3b`, `gemma-3-12b`, `phi-4-mini`. Returns
    /// `Double.greatestFiniteMagnitude` when no size token is found so
    /// the model sorts after all sized ones.
    nonisolated static func approximateParameterBillions(from modelIdentifier: String) -> Double {
        let lowercased = modelIdentifier.lowercased()

        // Match patterns like `1.7b`, `0.6b`, `30b`, `14b`.
        let billionPattern = #"(\d+(?:\.\d+)?)\s*b\b"#
        if let regex = try? NSRegularExpression(pattern: billionPattern),
           let match = regex.firstMatch(in: lowercased, range: NSRange(lowercased.startIndex..., in: lowercased)),
           let sizeRange = Range(match.range(at: 1), in: lowercased),
           let sizeValue = Double(lowercased[sizeRange]) {
            return sizeValue
        }

        // Match patterns like `7m`, `350m` and convert to billions.
        let millionPattern = #"(\d+(?:\.\d+)?)\s*m\b"#
        if let regex = try? NSRegularExpression(pattern: millionPattern),
           let match = regex.firstMatch(in: lowercased, range: NSRange(lowercased.startIndex..., in: lowercased)),
           let sizeRange = Range(match.range(at: 1), in: lowercased),
           let sizeValue = Double(lowercased[sizeRange]) {
            return sizeValue / 1000.0
        }

        return Double.greatestFiniteMagnitude
    }
}
