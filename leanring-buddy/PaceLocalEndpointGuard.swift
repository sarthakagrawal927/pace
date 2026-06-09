//
//  PaceLocalEndpointGuard.swift
//  leanring-buddy
//
//  Shared fail-closed guard for local HTTP model endpoints.
//

import Foundation

struct PaceLocalEndpointGuardError: LocalizedError, Equatable {
    let settingName: String
    let rejectedValue: String
    let reason: String

    var errorDescription: String? {
        "\(settingName) must point to a loopback HTTP endpoint. Refusing \(rejectedValue): \(reason)"
    }
}

enum PaceLocalEndpointGuard {
    static let defaultOpenAICompatibleBaseURL = URL(string: "http://localhost:1234/v1")!

    static func resolvedLocalOpenAICompatibleBaseURL(
        configuredURLString: String?,
        defaultURL: URL = defaultOpenAICompatibleBaseURL,
        settingName: String
    ) -> URL {
        let trimmedConfiguredURLString = configuredURLString?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let trimmedConfiguredURLString,
              !trimmedConfiguredURLString.isEmpty,
              let configuredURL = URL(string: trimmedConfiguredURLString) else {
            return defaultURL
        }

        return resolvedLocalOpenAICompatibleBaseURL(
            configuredURL: configuredURL,
            defaultURL: defaultURL,
            settingName: settingName
        )
    }

    static func resolvedLocalOpenAICompatibleBaseURL(
        configuredURL: URL,
        defaultURL: URL = defaultOpenAICompatibleBaseURL,
        settingName: String
    ) -> URL {
        do {
            try validateLocalHTTPURL(configuredURL, settingName: settingName)
            return configuredURL
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            print("⚠️ \(message). Falling back to \(defaultURL.absoluteString)")
            return defaultURL
        }
    }

    static func validateLocalHTTPURL(_ url: URL, settingName: String) throws {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw PaceLocalEndpointGuardError(
                settingName: settingName,
                rejectedValue: url.absoluteString,
                reason: "scheme must be http or https"
            )
        }

        guard let rawHost = url.host(percentEncoded: false),
              !rawHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PaceLocalEndpointGuardError(
                settingName: settingName,
                rejectedValue: url.absoluteString,
                reason: "host is missing"
            )
        }

        let normalizedHost = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        guard isLoopbackHost(normalizedHost) else {
            throw PaceLocalEndpointGuardError(
                settingName: settingName,
                rejectedValue: url.absoluteString,
                reason: "host '\(rawHost)' is not localhost, 127.0.0.0/8, or ::1"
            )
        }
    }

    nonisolated static func isLoopbackHost(_ normalizedHost: String) -> Bool {
        if normalizedHost == "localhost" || normalizedHost == "::1" {
            return true
        }

        if normalizedHost == "0:0:0:0:0:0:0:1" {
            return true
        }

        let ipv4Octets = normalizedHost.split(separator: ".", omittingEmptySubsequences: false)
        guard ipv4Octets.count == 4 else { return false }
        guard ipv4Octets.first == "127" else { return false }

        return ipv4Octets.allSatisfy { octet in
            guard !octet.isEmpty, let value = Int(octet) else { return false }
            return (0...255).contains(value)
        }
    }
}
