//
//  PaceLocalStackDoctor.swift
//  leanring-buddy
//
//  Runs a series of async health checks against the local Pace stack
//  (LM Studio, planner model, embedding model, VLM, TTS sidecar) and
//  returns a list of PaceDoctorCheck results the Settings → Diagnostics
//  tab renders. No mutations — read-only probes only.
//

import Foundation

// MARK: - Result Types

enum PaceDoctorStatus {
    case ok
    case warn
    case fail
}

struct PaceDoctorCheck: Identifiable {
    let id = UUID()
    let title: String
    let status: PaceDoctorStatus
    let detail: String
    /// Shown in smaller tertiary text under the detail. Nil when the check passed.
    let fixHint: String?
}

// MARK: - Doctor

@MainActor
final class PaceLocalStackDoctor {

    // MARK: - Config Helpers

    /// Reads a plist string key with a caller-supplied fallback.
    private static func configString(_ key: String, fallback: String) -> String {
        AppBundleConfiguration.stringValue(forKey: key) ?? fallback
    }

    /// Reads a plist bool key. Returns nil when the key is absent so callers
    /// can distinguish "not set" from "set to false".
    private static func configBool(_ key: String) -> Bool? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) else {
            return nil
        }
        // Info.plist bools come back as NSNumber when read at runtime.
        if let number = raw as? NSNumber { return number.boolValue }
        if let string = raw as? String { return string.lowercased() == "true" }
        return nil
    }

    /// Derives the LM Studio /api/v0 root from a /v1 base URL.
    /// "http://localhost:1234/v1" → "http://localhost:1234/api/v0"
    /// Falls back to the /v1 URL untouched when the suffix doesn't match.
    nonisolated static func apiV0Root(fromV1BaseURL v1URL: String) -> String {
        if v1URL.hasSuffix("/v1") {
            return String(v1URL.dropLast("/v1".count)) + "/api/v0"
        }
        return v1URL
    }

    // MARK: - Pure Classification Helpers (unit-testable without network)

    /// Inspects a raw `/v1/embeddings` response body and decides whether
    /// embeddings are being served. Returns `.ok` when the response contains
    /// a non-empty `data[0].embedding` array; `.fail` otherwise.
    nonisolated static func embeddingsResponseStatus(fromResponseBody bodyString: String) -> PaceDoctorStatus {
        guard let bodyData = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let firstEntry = dataArray.first,
              let embeddingArray = firstEntry["embedding"] as? [Any],
              !embeddingArray.isEmpty
        else {
            return .fail
        }
        return .ok
    }

    /// Inspects a raw `/api/v0/models` response body and returns whether
    /// the given model identifier is present with `state == "loaded"`.
    /// Returns `.loaded`, `.presentButNotLoaded`, or `.notFound`.
    enum ModelV0State {
        case loaded
        case presentButNotLoaded
        case notFound
    }

    nonisolated static func modelStateInV0ModelsResponse(
        responseBody: String,
        targetModelIdentifier: String
    ) -> ModelV0State {
        guard let bodyData = responseBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]]
        else {
            return .notFound
        }

        for entry in dataArray {
            let entryID = entry["id"] as? String ?? ""
            if entryID == targetModelIdentifier {
                let state = entry["state"] as? String ?? ""
                return state == "loaded" ? .loaded : .presentButNotLoaded
            }
        }
        return .notFound
    }

    // MARK: - URLSession Factory

    /// A short-timeout session so a stalled local server doesn't block the UI.
    private static func makeShortTimeoutSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration)
    }

    // MARK: - Individual Checks

    private static func checkLMStudioServer(
        plannerBaseURL: String,
        urlSession: URLSession
    ) async -> PaceDoctorCheck {
        let modelsURL = plannerBaseURL.trimmingCharacters(in: .init(charactersIn: "/")) + "/models"
        guard let url = URL(string: modelsURL) else {
            return PaceDoctorCheck(
                title: "LM Studio server",
                status: .fail,
                detail: "Configured planner URL '\(plannerBaseURL)' is not a valid URL.",
                fixHint: "Check LocalPlannerBaseURL in Info.plist."
            )
        }
        do {
            let (_, response) = try await urlSession.data(from: url)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0
            if (200..<300).contains(statusCode) {
                return PaceDoctorCheck(
                    title: "LM Studio server",
                    status: .ok,
                    detail: "Server is reachable at \(plannerBaseURL).",
                    fixHint: nil
                )
            } else {
                return PaceDoctorCheck(
                    title: "LM Studio server",
                    status: .fail,
                    detail: "Server responded with HTTP \(statusCode).",
                    fixHint: "LM Studio may not be running correctly. Try `lms server start` or restart LM Studio."
                )
            }
        } catch {
            return PaceDoctorCheck(
                title: "LM Studio server",
                status: .fail,
                detail: "Could not reach the LM Studio server at \(plannerBaseURL).",
                fixHint: "LM Studio's local server is off. Start it: `lms server start`, or LM Studio → Developer → Start Server."
            )
        }
    }

    private static func checkPlannerModelLoaded(
        plannerBaseURL: String,
        plannerModelIdentifier: String,
        urlSession: URLSession
    ) async -> PaceDoctorCheck {
        let apiV0Base = apiV0Root(fromV1BaseURL: plannerBaseURL)
        let apiV0ModelsURLString = apiV0Base + "/models"

        if let apiV0URL = URL(string: apiV0ModelsURLString) {
            do {
                let (data, response) = try await urlSession.data(from: apiV0URL)
                let httpResponse = response as? HTTPURLResponse
                let statusCode = httpResponse?.statusCode ?? 0

                if (200..<300).contains(statusCode),
                   let responseBody = String(data: data, encoding: .utf8) {
                    let modelState = modelStateInV0ModelsResponse(
                        responseBody: responseBody,
                        targetModelIdentifier: plannerModelIdentifier
                    )
                    switch modelState {
                    case .loaded:
                        return PaceDoctorCheck(
                            title: "Planner model loaded",
                            status: .ok,
                            detail: "\(plannerModelIdentifier) is loaded and ready.",
                            fixHint: nil
                        )
                    case .presentButNotLoaded:
                        return PaceDoctorCheck(
                            title: "Planner model loaded",
                            status: .fail,
                            detail: "\(plannerModelIdentifier) is downloaded but not currently loaded.",
                            fixHint: "Load `\(plannerModelIdentifier)` in LM Studio: `lms load \(plannerModelIdentifier)`, or select it in the LM Studio model picker."
                        )
                    case .notFound:
                        return PaceDoctorCheck(
                            title: "Planner model loaded",
                            status: .fail,
                            detail: "\(plannerModelIdentifier) was not found in the LM Studio model list.",
                            fixHint: "Download and load `\(plannerModelIdentifier)` in LM Studio: `lms load \(plannerModelIdentifier)`."
                        )
                    }
                }
                // /api/v0 returned a non-success code — fall through to /v1 fallback below.
            } catch {
                // /api/v0 is unreachable — fall through to /v1 fallback below.
            }
        }

        // Fallback: check /v1/models membership (can't confirm load state, only presence).
        let v1ModelsURLString = plannerBaseURL.trimmingCharacters(in: .init(charactersIn: "/")) + "/models"
        guard let v1URL = URL(string: v1ModelsURLString) else {
            return PaceDoctorCheck(
                title: "Planner model loaded",
                status: .warn,
                detail: "Could not verify \(plannerModelIdentifier) — /api/v0 and /v1/models are both unreachable.",
                fixHint: "Start the LM Studio server first."
            )
        }

        do {
            let (data, response) = try await urlSession.data(from: v1URL)
            let httpResponse = response as? HTTPURLResponse
            guard (200..<300).contains(httpResponse?.statusCode ?? 0),
                  let bodyString = String(data: data, encoding: .utf8)
            else {
                return PaceDoctorCheck(
                    title: "Planner model loaded",
                    status: .warn,
                    detail: "Could not confirm \(plannerModelIdentifier) is loaded — /api/v0 unavailable.",
                    fixHint: "Cannot confirm the model's load state. Check LM Studio manually."
                )
            }

            if bodyString.contains(plannerModelIdentifier) {
                return PaceDoctorCheck(
                    title: "Planner model loaded",
                    status: .warn,
                    detail: "\(plannerModelIdentifier) appears in the model list, but its load state couldn't be confirmed (/api/v0 unavailable).",
                    fixHint: "This is likely fine, but verify the model is loaded in LM Studio."
                )
            } else {
                return PaceDoctorCheck(
                    title: "Planner model loaded",
                    status: .fail,
                    detail: "\(plannerModelIdentifier) was not found in the model list.",
                    fixHint: "Download and load `\(plannerModelIdentifier)` in LM Studio: `lms load \(plannerModelIdentifier)`."
                )
            }
        } catch {
            return PaceDoctorCheck(
                title: "Planner model loaded",
                status: .warn,
                detail: "Could not verify \(plannerModelIdentifier) — server unreachable during model list check.",
                fixHint: "Start the LM Studio server first."
            )
        }
    }

    private static func checkEmbeddingModelServing(
        embeddingBaseURL: String,
        embeddingModelIdentifier: String,
        urlSession: URLSession
    ) async -> PaceDoctorCheck {
        // The critical check: POST to /embeddings and verify a real embedding
        // vector comes back. A model that loads as type:llm (e.g. qwen3-embedding)
        // will return an error here instead of an embedding array.
        let embeddingsURLString = embeddingBaseURL.trimmingCharacters(in: .init(charactersIn: "/")) + "/embeddings"
        guard let embeddingsURL = URL(string: embeddingsURLString) else {
            return PaceDoctorCheck(
                title: "Embedding model serving",
                status: .fail,
                detail: "Configured embedding URL '\(embeddingBaseURL)' is not a valid URL.",
                fixHint: "Check RetrievalEmbeddingBaseURL in Info.plist."
            )
        }

        let requestBody: [String: Any] = [
            "model": embeddingModelIdentifier,
            "input": "healthcheck"
        ]

        guard let requestData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return PaceDoctorCheck(
                title: "Embedding model serving",
                status: .fail,
                detail: "Could not serialize the embeddings probe request.",
                fixHint: nil
            )
        }

        var request = URLRequest(url: embeddingsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestData

        do {
            let (data, _) = try await urlSession.data(for: request)
            let responseBodyString = String(data: data, encoding: .utf8) ?? ""
            let embeddingStatus = embeddingsResponseStatus(fromResponseBody: responseBodyString)

            switch embeddingStatus {
            case .ok:
                return PaceDoctorCheck(
                    title: "Embedding model serving",
                    status: .ok,
                    detail: "\(embeddingModelIdentifier) returned a valid embedding vector.",
                    fixHint: nil
                )
            case .fail:
                return PaceDoctorCheck(
                    title: "Embedding model serving",
                    status: .fail,
                    detail: "\(embeddingModelIdentifier) did not return embedding vectors — semantic recall silently falls back to keyword search.",
                    fixHint: "Your embedding model isn't serving embeddings. Load a real embedding model like `text-embedding-nomic-embed-text-v1.5` (it loads as type:embeddings). Note: `qwen3-embedding-0.6b` loads as type:llm and won't serve /v1/embeddings."
                )
            default:
                return PaceDoctorCheck(
                    title: "Embedding model serving",
                    status: .fail,
                    detail: "Unexpected response from the embeddings endpoint.",
                    fixHint: "Verify the embedding model is loaded in LM Studio and supports /v1/embeddings."
                )
            }
        } catch {
            return PaceDoctorCheck(
                title: "Embedding model serving",
                status: .fail,
                detail: "Could not reach the embeddings endpoint at \(embeddingBaseURL).",
                fixHint: "Your embedding model isn't serving embeddings — semantic recall silently falls back to keyword. Load a real embedding model like `text-embedding-nomic-embed-text-v1.5` in LM Studio."
            )
        }
    }

    private static func checkVLMLoaded(
        vlmBaseURL: String,
        vlmModelIdentifier: String,
        urlSession: URLSession
    ) async -> PaceDoctorCheck {
        let apiV0Base = apiV0Root(fromV1BaseURL: vlmBaseURL)
        let apiV0ModelsURLString = apiV0Base + "/models"

        guard let apiV0URL = URL(string: apiV0ModelsURLString) else {
            return PaceDoctorCheck(
                title: "VLM loaded (Read My Screen)",
                status: .warn,
                detail: "Configured VLM URL '\(vlmBaseURL)' is not a valid URL.",
                fixHint: "Check LocalVLMBaseURL in Info.plist, or turn off Read My Screen."
            )
        }

        do {
            let (data, response) = try await urlSession.data(from: apiV0URL)
            let httpResponse = response as? HTTPURLResponse
            guard (200..<300).contains(httpResponse?.statusCode ?? 0),
                  let responseBody = String(data: data, encoding: .utf8)
            else {
                return PaceDoctorCheck(
                    title: "VLM loaded (Read My Screen)",
                    status: .warn,
                    detail: "Could not check VLM state — LM Studio /api/v0 unavailable.",
                    fixHint: "Ensure LM Studio is running, then verify \(vlmModelIdentifier) is loaded."
                )
            }

            let modelState = modelStateInV0ModelsResponse(
                responseBody: responseBody,
                targetModelIdentifier: vlmModelIdentifier
            )
            switch modelState {
            case .loaded:
                return PaceDoctorCheck(
                    title: "VLM loaded (Read My Screen)",
                    status: .ok,
                    detail: "\(vlmModelIdentifier) is loaded and ready for screen analysis.",
                    fixHint: nil
                )
            case .presentButNotLoaded:
                return PaceDoctorCheck(
                    title: "VLM loaded (Read My Screen)",
                    status: .warn,
                    detail: "\(vlmModelIdentifier) is downloaded but not currently loaded.",
                    fixHint: "Screen-reading needs `\(vlmModelIdentifier)` loaded in LM Studio (or turn off Read My Screen in Settings → General)."
                )
            case .notFound:
                return PaceDoctorCheck(
                    title: "VLM loaded (Read My Screen)",
                    status: .warn,
                    detail: "\(vlmModelIdentifier) was not found in LM Studio.",
                    fixHint: "Screen-reading needs `\(vlmModelIdentifier)` loaded in LM Studio (or turn off Read My Screen in Settings → General)."
                )
            }
        } catch {
            return PaceDoctorCheck(
                title: "VLM loaded (Read My Screen)",
                status: .warn,
                detail: "Could not verify \(vlmModelIdentifier) — LM Studio unreachable during VLM check.",
                fixHint: "Ensure LM Studio is running, then verify `\(vlmModelIdentifier)` is loaded (or turn off Read My Screen)."
            )
        }
    }

    private static func checkTTSSidecar(
        ttsServerBaseURL: String,
        urlSession: URLSession
    ) async -> PaceDoctorCheck {
        // Probe the sidecar root. Strip any trailing /v1 to hit the plain
        // HTTP root, which the sidecar (mlx-audio / kokoro-fastapi) serves.
        let strippedBase = ttsServerBaseURL.hasSuffix("/v1")
            ? String(ttsServerBaseURL.dropLast("/v1".count))
            : ttsServerBaseURL.trimmingCharacters(in: .init(charactersIn: "/"))

        guard let probeURL = URL(string: strippedBase + "/") else {
            return PaceDoctorCheck(
                title: "TTS sidecar",
                status: .warn,
                detail: "Configured TTS URL '\(ttsServerBaseURL)' is not a valid URL.",
                fixHint: "Check LocalTTSServerBaseURL in Info.plist."
            )
        }

        do {
            let (_, response) = try await urlSession.data(from: probeURL)
            let httpResponse = response as? HTTPURLResponse
            // Any HTTP response (even 404) means the sidecar process is alive.
            if httpResponse != nil {
                return PaceDoctorCheck(
                    title: "TTS sidecar",
                    status: .ok,
                    detail: "Kokoro TTS sidecar is reachable at \(ttsServerBaseURL).",
                    fixHint: nil
                )
            } else {
                return PaceDoctorCheck(
                    title: "TTS sidecar",
                    status: .warn,
                    detail: "No HTTP response from TTS sidecar at \(ttsServerBaseURL) — Pace falls back to the Apple voice.",
                    fixHint: "TTS sidecar offline. Run `scripts/start-tts-server.sh` for Kokoro."
                )
            }
        } catch {
            return PaceDoctorCheck(
                title: "TTS sidecar",
                status: .warn,
                detail: "TTS sidecar is offline at \(ttsServerBaseURL) — Pace falls back to the Apple voice automatically.",
                fixHint: "TTS sidecar offline — Pace falls back to the Apple voice. Run `scripts/start-tts-server.sh` for Kokoro."
            )
        }
    }

    // MARK: - Public Entry Point

    func runChecks() async -> [PaceDoctorCheck] {
        // Read config once so all checks use the same values.
        let plannerBaseURL = Self.configString("LocalPlannerBaseURL", fallback: "http://localhost:1234/v1")
        let plannerModelIdentifier = Self.configString("LocalPlannerModelIdentifier", fallback: "google/gemma-3-12b")

        // Embedding base URL: prefer RetrievalEmbeddingBaseURL, fall back to
        // LocalVLMBaseURL, then the standard LM Studio default.
        let embeddingBaseURL: String = {
            if let explicit = AppBundleConfiguration.stringValue(forKey: "RetrievalEmbeddingBaseURL") {
                return explicit
            }
            if let vlmBase = AppBundleConfiguration.stringValue(forKey: "LocalVLMBaseURL") {
                return vlmBase
            }
            return "http://localhost:1234/v1"
        }()
        let embeddingModelIdentifier = Self.configString(
            "RetrievalEmbeddingModel",
            fallback: "text-embedding-nomic-embed-text-v1.5"
        )

        let vlmBaseURL = Self.configString("LocalVLMBaseURL", fallback: "http://localhost:1234/v1")
        let vlmModelIdentifier = Self.configString("LocalVLMModelIdentifier", fallback: "ui-venus-1.5-2b")

        // UseLocalVLMForScreenContext defaults to true when absent — matches Info.plist default.
        let useLocalVLMForScreenContext = Self.configBool("UseLocalVLMForScreenContext") ?? true

        let ttsServerBaseURL = Self.configString("LocalTTSServerBaseURL", fallback: "http://localhost:8880/v1")
        let ttsProvider = Self.configString("TTSProvider", fallback: "localServer")

        let urlSession = Self.makeShortTimeoutSession()

        var checks: [PaceDoctorCheck] = []

        // 1. LM Studio server reachable.
        let serverCheck = await Self.checkLMStudioServer(
            plannerBaseURL: plannerBaseURL,
            urlSession: urlSession
        )
        checks.append(serverCheck)

        // 2. Planner model loaded.
        let plannerCheck = await Self.checkPlannerModelLoaded(
            plannerBaseURL: plannerBaseURL,
            plannerModelIdentifier: plannerModelIdentifier,
            urlSession: urlSession
        )
        checks.append(plannerCheck)

        // 3. Embedding model actually serving /v1/embeddings.
        let embeddingCheck = await Self.checkEmbeddingModelServing(
            embeddingBaseURL: embeddingBaseURL,
            embeddingModelIdentifier: embeddingModelIdentifier,
            urlSession: urlSession
        )
        checks.append(embeddingCheck)

        // 4. VLM loaded — only when the Read My Screen toggle is on.
        if useLocalVLMForScreenContext {
            let vlmCheck = await Self.checkVLMLoaded(
                vlmBaseURL: vlmBaseURL,
                vlmModelIdentifier: vlmModelIdentifier,
                urlSession: urlSession
            )
            checks.append(vlmCheck)
        }

        // 5. TTS sidecar — only when the sidecar TTS provider is selected.
        if ttsProvider == "localServer" {
            let ttsCheck = await Self.checkTTSSidecar(
                ttsServerBaseURL: ttsServerBaseURL,
                urlSession: urlSession
            )
            checks.append(ttsCheck)
        }

        return checks
    }
}
