//
//  PaceRemoteModelManifest.swift
//  leanring-buddy
//
//  Optional remote model manifest (PROJECT_STATUS #6). When
//  `RemoteModelManifestURL` is set in Info.plist, Pace fetches a small JSON
//  document between Sparkle releases and uses it to override bundled model
//  identifiers. Cached locally with a 24-hour TTL; fetch failures are silent.
//

import Foundation

nonisolated struct PaceRemoteModelManifest: Codable, Equatable {
    let plannerModelIdentifier: String?
    let embedderModelIdentifier: String?
    let vlmModelIdentifier: String?
    let publishedAt: String?

    private static let cacheKey = "pace.remoteModelManifest.cachedJSON"
    private static let cacheTimestampKey = "pace.remoteModelManifest.cachedAt"
    private static let cacheTTL: TimeInterval = 86_400

    static func manifestURLFromInfoPlist() -> URL? {
        guard let rawURL = Bundle.main.object(forInfoDictionaryKey: "RemoteModelManifestURL") as? String else {
            return nil
        }
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            return nil
        }
        return url
    }

    static func cachedManifest(now: Date = Date()) -> PaceRemoteModelManifest? {
        guard let cachedAt = UserDefaults.standard.object(forKey: cacheTimestampKey) as? Date,
              now.timeIntervalSince(cachedAt) < cacheTTL,
              let cachedJSON = UserDefaults.standard.string(forKey: cacheKey),
              let data = cachedJSON.data(using: .utf8),
              let manifest = try? JSONDecoder().decode(PaceRemoteModelManifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    static func refreshIfNeeded(now: Date = Date()) async {
        guard let manifestURL = manifestURLFromInfoPlist() else { return }
        if let cachedAt = UserDefaults.standard.object(forKey: cacheTimestampKey) as? Date,
           now.timeIntervalSince(cachedAt) < cacheTTL {
            return
        }

        do {
            var request = URLRequest(url: manifestURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 8
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return
            }
            _ = try JSONDecoder().decode(PaceRemoteModelManifest.self, from: data)
            guard let jsonString = String(data: data, encoding: .utf8) else { return }
            UserDefaults.standard.set(jsonString, forKey: cacheKey)
            UserDefaults.standard.set(now, forKey: cacheTimestampKey)
        } catch {
            // Best-effort only — bundled Info.plist defaults remain authoritative on failure.
        }
    }

    static func resolvedPlannerModelIdentifier(fallback: String) -> String {
        trimmedIdentifier(cachedManifest()?.plannerModelIdentifier) ?? fallback
    }

    static func resolvedEmbedderModelIdentifier(fallback: String) -> String {
        trimmedIdentifier(cachedManifest()?.embedderModelIdentifier) ?? fallback
    }

    static func resolvedVLMModelIdentifier(fallback: String) -> String {
        trimmedIdentifier(cachedManifest()?.vlmModelIdentifier) ?? fallback
    }

    private static func trimmedIdentifier(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
