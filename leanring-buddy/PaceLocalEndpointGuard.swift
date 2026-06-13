//
//  PaceLocalEndpointGuard.swift
//  leanring-buddy
//
//  Shared fail-closed guard for local HTTP model endpoints.
//

import Foundation

nonisolated struct PaceLocalEndpointGuardError: LocalizedError, Equatable {
    let settingName: String
    let rejectedValue: String
    let reason: String

    var errorDescription: String? {
        "\(settingName) must point to a loopback HTTP endpoint. Refusing \(rejectedValue): \(reason)"
    }
}

nonisolated enum PaceLocalEndpointGuard {
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

    /// Separate validator for the cloud-bridge endpoint. Lives behind its own
    /// function so that future tightening of the planner guard (e.g. adding
    /// allowed-port restrictions) does not accidentally affect the bridge entry
    /// point, which has different operational assumptions. Delegates to the
    /// existing loopback validator under the hood.
    ///
    /// The fact that the bridge then fans out to Anthropic/OpenAI/Google is the
    /// user's consented choice; Pace's guard only cares that *Pace* is speaking
    /// to a loopback address, not a remote host.
    static func validatedCloudBridgeURL(from configuredURLString: String?) -> URL {
        let defaultCloudBridgeURL = URL(string: "http://localhost:3456")!
        return resolvedLocalOpenAICompatibleBaseURL(
            configuredURLString: configuredURLString,
            defaultURL: defaultCloudBridgeURL,
            settingName: "CloudBridgeBaseURL"
        )
    }

    /// Validator for the Direct-API (BYO key) endpoint. INTENTIONALLY separate
    /// from `validateLocalHTTPURL` — Direct-API is consented cloud egress
    /// while the loopback guard is on-device-only. Mixing the two is the
    /// single biggest exfiltration risk in this codebase; they must stay
    /// in distinct functions with distinct test files.
    ///
    /// Rules:
    ///   - Scheme must be `http` or `https`.
    ///   - `https` is allowed for ANY host (cloud egress on purpose).
    ///   - `http` is only allowed when the host is loopback (so a local
    ///     OpenAI-compatible proxy still works for testing). Any plaintext
    ///     to a remote host fails closed — Pace will not send an API key
    ///     in the clear to a non-loopback host.
    ///   - Host must be present and non-empty.
    ///
    /// Throws `PaceLocalEndpointGuardError` on rejection — called from the
    /// Settings save path so the user sees the failure inline.
    static func validatedDirectAPIURL(from configuredURLString: String?) throws -> URL {
        let settingName = "DirectAPIEndpointURL"
        let trimmedConfiguredURLString = configuredURLString?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let trimmedConfiguredURLString,
              !trimmedConfiguredURLString.isEmpty else {
            throw PaceLocalEndpointGuardError(
                settingName: settingName,
                rejectedValue: configuredURLString ?? "",
                reason: "endpoint URL is empty"
            )
        }

        guard let parsedURL = URL(string: trimmedConfiguredURLString) else {
            throw PaceLocalEndpointGuardError(
                settingName: settingName,
                rejectedValue: trimmedConfiguredURLString,
                reason: "URL is not parseable"
            )
        }

        let scheme = parsedURL.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw PaceLocalEndpointGuardError(
                settingName: settingName,
                rejectedValue: trimmedConfiguredURLString,
                reason: "scheme must be http or https"
            )
        }

        guard let rawHost = parsedURL.host(percentEncoded: false),
              !rawHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PaceLocalEndpointGuardError(
                settingName: settingName,
                rejectedValue: trimmedConfiguredURLString,
                reason: "host is missing"
            )
        }

        let normalizedHost = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if scheme == "http" && !isLoopbackHost(normalizedHost) {
            throw PaceLocalEndpointGuardError(
                settingName: settingName,
                rejectedValue: trimmedConfiguredURLString,
                reason: "http is only allowed for loopback hosts — use https for '\(rawHost)'"
            )
        }

        return parsedURL
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
