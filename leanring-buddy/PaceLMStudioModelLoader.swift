//
//  PaceLMStudioModelLoader.swift
//  leanring-buddy
//
//  Auto-load the planner + VLM models into LM Studio at app launch
//  and auto-unload them at app quit, so the user doesn't have to
//  manage LM Studio's state manually.
//
//  Two mechanisms cooperate:
//
//  - **Load (launch)**: fire a tiny chat-completion at LM Studio with
//    the configured `model` field. LM Studio's JIT loading takes that
//    as a hint and loads the model if it isn't already. The same
//    request prefills + warms the model so the user's first PTT turn
//    doesn't pay the cold-load tax (which is typically 5-15s on a
//    14B class model).
//
//  - **Unload (quit)**: shell out to the `lms` CLI (shipped with LM
//    Studio at `~/.lmstudio/bin/lms`) and `lms unload <model>` each
//    configured model. Done synchronously from `applicationWillTerminate`
//    so we don't leave 5-20 GB of weights resident in RAM after Pace
//    quits — a user-requested behavior on this branch.
//
//  Failures are non-fatal: if LM Studio is offline at launch, Pace
//  starts anyway and the first voice turn will hit the existing error
//  path. If `lms` isn't on PATH at quit, we log and skip — the user
//  can manually unload via LM Studio's UI.
//

import Foundation

enum PaceLMStudioModelLoader {
    private static let lmStudioBaseURL = URL(string: "http://localhost:1234")!
    private static let warmupTimeoutSeconds: TimeInterval = 120

    /// How often the keepalive pings each configured model. LM Studio's
    /// idle-auto-unload defaults vary by version and user setting; 60s
    /// is short enough to beat any default we've seen and infrequent
    /// enough to add ~zero perceptible CPU/GPU load. Each ping is a
    /// `max_tokens: 1` chat completion that costs the model less than
    /// a real turn's prefill.
    private static let keepaliveIntervalSeconds: TimeInterval = 60

    /// The running keepalive task. Cancelled on app quit (after the
    /// shutdown unload completes). One task drives pings for every
    /// configured model.
    private static var keepaliveTask: Task<Void, Never>?

    // MARK: - Launch: load + warm models

    /// Kick off warmup for the configured planner (and VLM, if
    /// enabled). Fire-and-forget — returns immediately so the rest of
    /// app launch isn't blocked. Each model warmup runs concurrently.
    /// After warmup finishes, starts the periodic keepalive heartbeat.
    static func warmUpConfiguredModelsAsync() {
        Task.detached(priority: .userInitiated) {
            await warmUpConfiguredModels()
            await startKeepaliveLoopIfNotRunning()
        }
    }

    /// Awaitable version for tests / one-shot scripts.
    static func warmUpConfiguredModels() async {
        let configuredPlannerIdentifier = AppBundleConfiguration
            .stringValue(forKey: "LocalPlannerModelIdentifier")
            ?? "qwen3-4b-instruct"
        let useLocalVLM = AppBundleConfiguration
            .stringValue(forKey: "UseLocalVLMForScreenContext")?
            .lowercased() == "true"
        let vlmModelIdentifier = AppBundleConfiguration
            .stringValue(forKey: "LocalVLMModelIdentifier")
            ?? "ui-venus-1.5-2b"
        // The embedding model powers retrieval re-ranking on every turn
        // that injects LOCAL CONTEXT. Without warming it here, the first
        // such turn after launch has to wait for JIT load — observed in
        // the audit log as embeddings transport_error timeouts.
        let embeddingModelIdentifier = AppBundleConfiguration
            .stringValue(forKey: "RetrievalEmbeddingModel")
            ?? "text-embedding-nomic-embed-text-v1.5"

        print("🔥 LM Studio warmup: starting (planner=\(configuredPlannerIdentifier), vlm=\(useLocalVLM ? vlmModelIdentifier : "off"), embeddings=\(embeddingModelIdentifier))")

        guard await isLMStudioReachable() else {
            print("⚠️  LM Studio warmup: server unreachable at localhost:1234. Start LM Studio and ensure JIT loading is on.")
            return
        }

        // Resolve the planner identifier against what's actually
        // loaded in LM Studio. If the configured model isn't there,
        // the resolver picks the smallest available chat model and
        // caches that for the rest of the session — every subsequent
        // LocalPlannerClient picks it up via PacePlannerModelResolver
        // .resolvedIdentifier instead of 404ing.
        let plannerModelIdentifier = await PacePlannerModelResolver.resolveAndCache(
            configuredIdentifier: configuredPlannerIdentifier,
            plannerBaseURL: lmStudioBaseURL.appendingPathComponent("v1")
        )

        // Run planner + VLM warmups concurrently — they're independent
        // and the user wins by getting both ready faster.
        async let plannerWarmup: Void = sendChatCompletionWarmup(
            modelIdentifier: plannerModelIdentifier,
            role: "planner"
        )
        async let vlmWarmup: Void = {
            guard useLocalVLM else { return }
            await sendChatCompletionWarmup(
                modelIdentifier: vlmModelIdentifier,
                role: "VLM"
            )
        }()
        async let embeddingsWarmup: Void = sendEmbeddingsWarmup(
            modelIdentifier: embeddingModelIdentifier
        )
        _ = await (plannerWarmup, vlmWarmup, embeddingsWarmup)
        print("🔥 LM Studio warmup: complete")
    }

    /// One-shot tiny embedding call so the embedding model is JIT-loaded
    /// before the first retrieval-using turn arrives. Mirrors
    /// `sendChatCompletionWarmup` but hits /v1/embeddings.
    private static func sendEmbeddingsWarmup(modelIdentifier: String) async {
        let startedAt = Date()
        let embeddingsURL = lmStudioBaseURL.appendingPathComponent("v1/embeddings")
        var request = URLRequest(url: embeddingsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = warmupTimeoutSeconds

        let requestBody: [String: Any] = [
            "model": modelIdentifier,
            "input": "ok",
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            print("⚠️  LM Studio warmup (embeddings/\(modelIdentifier)): encode failed: \(error.localizedDescription)")
            return
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            if let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode) {
                print("🔥 LM Studio warmup (embeddings/\(modelIdentifier)): loaded in \(durationMilliseconds)ms")
            } else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                print("⚠️  LM Studio warmup (embeddings/\(modelIdentifier)): HTTP \(statusCode) after \(durationMilliseconds)ms")
            }
        } catch {
            print("⚠️  LM Studio warmup (embeddings/\(modelIdentifier)): \(error.localizedDescription)")
        }
    }

    /// Quick reachability check: hit `/v1/models` with a 2-second
    /// timeout. Avoids burning 120 seconds on a `chat/completions`
    /// call to a server that isn't running.
    private static func isLMStudioReachable() async -> Bool {
        var request = URLRequest(url: lmStudioBaseURL.appendingPathComponent("v1/models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        let probeSession = URLSession(configuration: probeURLSessionConfiguration())
        defer { probeSession.invalidateAndCancel() }

        do {
            let (_, response) = try await probeSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    /// Send a tiny chat-completion to load + warm the model. We ask
    /// for a single-token response (`max_tokens: 1`) so the model has
    /// to do its full warm-up cycle but we don't waste time on
    /// generation. LM Studio's JIT loader honors the `model` field
    /// and loads it if not present.
    private static func sendChatCompletionWarmup(modelIdentifier: String, role: String) async {
        let startedAt = Date()
        let warmupURL = lmStudioBaseURL.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: warmupURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = warmupTimeoutSeconds

        let requestBody: [String: Any] = [
            "model": modelIdentifier,
            "messages": [
                ["role": "user", "content": "ok"]
            ],
            "max_tokens": 1,
            "temperature": 0,
            "stream": false
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            print("⚠️  LM Studio warmup (\(role)/\(modelIdentifier)): could not encode warmup body: \(error.localizedDescription)")
            return
        }

        let warmupSession = URLSession(configuration: warmupURLSessionConfiguration())
        defer { warmupSession.invalidateAndCancel() }

        do {
            let (responseData, urlResponse) = try await warmupSession.data(for: request)
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                print("⚠️  LM Studio warmup (\(role)/\(modelIdentifier)): non-HTTP response after \(elapsedMs)ms")
                return
            }
            if (200...299).contains(httpResponse.statusCode) {
                print("✅ LM Studio warmup (\(role)/\(modelIdentifier)): ready in \(elapsedMs)ms")
            } else {
                let responseBody = String(data: responseData, encoding: .utf8)?
                    .prefix(200) ?? "<binary>"
                print("⚠️  LM Studio warmup (\(role)/\(modelIdentifier)) → HTTP \(httpResponse.statusCode) after \(elapsedMs)ms. Body: \(responseBody)")
                if httpResponse.statusCode == 404 {
                    print("    → Either the model isn't downloaded in LM Studio, or JIT loading is disabled. In LM Studio: Developer → JIT Loading → enable; or pre-load the model in Chat.")
                }
            }
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            print("⚠️  LM Studio warmup (\(role)/\(modelIdentifier)) failed after \(elapsedMs)ms: \(error.localizedDescription)")
        }
    }

    // MARK: - Keepalive: prevent idle auto-unload

    /// Start a recurring background task that pings each configured
    /// model every `keepaliveIntervalSeconds`. The ping is a
    /// `max_tokens: 1` chat completion — minimal real cost, but enough
    /// activity that LM Studio's idle-unload timer never fires. Without
    /// this, eval runs showed the model state degrading turn-over-turn
    /// because LM Studio was partial-unloading between calls.
    @MainActor
    static func startKeepaliveLoopIfNotRunning() {
        guard keepaliveTask == nil else { return }
        keepaliveTask = Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(keepaliveIntervalSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await sendKeepalivePings()
            }
        }
        print("💓 LM Studio keepalive: pings every \(Int(keepaliveIntervalSeconds))s")
    }

    @MainActor
    static func stopKeepaliveLoop() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    /// Issue one keepalive ping per configured model, in parallel.
    /// Failures are silent — the model is either temporarily busy or
    /// has been unloaded by another agent; either way the next ping
    /// will catch it.
    private static func sendKeepalivePings() async {
        let plannerIdentifier = PacePlannerModelResolver.resolvedIdentifier
            ?? AppBundleConfiguration.stringValue(forKey: "LocalPlannerModelIdentifier")
            ?? "qwen3-4b-instruct"
        let useLocalVLM = AppBundleConfiguration
            .stringValue(forKey: "UseLocalVLMForScreenContext")?
            .lowercased() == "true"
        let vlmIdentifier = AppBundleConfiguration
            .stringValue(forKey: "LocalVLMModelIdentifier")
            ?? "ui-venus-1.5-2b"

        async let plannerPing: Void = sendSingleKeepalivePing(modelIdentifier: plannerIdentifier)
        async let vlmPing: Void = {
            guard useLocalVLM else { return }
            await sendSingleKeepalivePing(modelIdentifier: vlmIdentifier)
        }()
        _ = await (plannerPing, vlmPing)
    }

    private static func sendSingleKeepalivePing(modelIdentifier: String) async {
        var request = URLRequest(url: lmStudioBaseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let requestBody: [String: Any] = [
            "model": modelIdentifier,
            "messages": [["role": "user", "content": "."]],
            "max_tokens": 1,
            "temperature": 0,
            "stream": false
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            return
        }

        let keepaliveSession = URLSession(configuration: warmupURLSessionConfiguration())
        defer { keepaliveSession.invalidateAndCancel() }
        _ = try? await keepaliveSession.data(for: request)
        // Intentionally don't log per-ping — at 1/min for two models
        // that's 2,880 lines a day of console spam for normal idle.
    }

    // MARK: - Quit: unload models

    /// Synchronously unload the configured models via the `lms` CLI.
    /// Called from `applicationWillTerminate` so the user reclaims
    /// the model's RAM (5-20+ GB for the planner) as soon as Pace
    /// quits. Documented requirement on this branch.
    static func unloadConfiguredModelsSynchronously() {
        let plannerModelIdentifier = AppBundleConfiguration
            .stringValue(forKey: "LocalPlannerModelIdentifier")
            ?? "qwen3-4b-instruct"
        let vlmModelIdentifier = AppBundleConfiguration
            .stringValue(forKey: "LocalVLMModelIdentifier")
            ?? "ui-venus-1.5-2b"

        guard let lmsExecutablePath = locateLMSCLI() else {
            print("⚠️  LM Studio unload: `lms` CLI not found. Install LM Studio's CLI or unload manually in LM Studio.")
            return
        }

        unloadModelViaLMSCLI(modelIdentifier: plannerModelIdentifier, lmsExecutablePath: lmsExecutablePath)
        unloadModelViaLMSCLI(modelIdentifier: vlmModelIdentifier, lmsExecutablePath: lmsExecutablePath)
    }

    /// Look for the `lms` CLI in the standard install locations.
    /// LM Studio installs it at `~/.lmstudio/bin/lms` by default; the
    /// user may also have linked it onto PATH via `npx lms bootstrap`.
    private static func locateLMSCLI() -> String? {
        let candidateExecutablePaths = [
            ("\(NSHomeDirectory())/.lmstudio/bin/lms"),
            "/usr/local/bin/lms",
            "/opt/homebrew/bin/lms"
        ]
        let fileManager = FileManager.default
        for candidatePath in candidateExecutablePaths {
            if fileManager.isExecutableFile(atPath: candidatePath) {
                return candidatePath
            }
        }
        return nil
    }

    /// Fire `lms unload <model>` synchronously. ~50-200ms typical.
    /// Failures are logged and swallowed — we're in the quit path and
    /// shouldn't crash on the way out.
    private static func unloadModelViaLMSCLI(modelIdentifier: String, lmsExecutablePath: String) {
        let unloadProcess = Process()
        unloadProcess.executableURL = URL(fileURLWithPath: lmsExecutablePath)
        unloadProcess.arguments = ["unload", modelIdentifier]

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        unloadProcess.standardOutput = standardOutputPipe
        unloadProcess.standardError = standardErrorPipe

        do {
            try unloadProcess.run()
            unloadProcess.waitUntilExit()
            if unloadProcess.terminationStatus == 0 {
                print("🧹 LM Studio unload: \(modelIdentifier) unloaded")
            } else {
                let errorOutput = String(
                    data: standardErrorPipe.fileHandleForReading.availableData,
                    encoding: .utf8
                ) ?? ""
                print("⚠️  LM Studio unload (\(modelIdentifier)) exited \(unloadProcess.terminationStatus): \(errorOutput)")
            }
        } catch {
            print("⚠️  LM Studio unload (\(modelIdentifier)) failed to launch: \(error.localizedDescription)")
        }
    }

    // MARK: - URLSession config

    private static func probeURLSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 4
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return configuration
    }

    private static func warmupURLSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = warmupTimeoutSeconds
        configuration.timeoutIntervalForResource = warmupTimeoutSeconds + 30
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return configuration
    }
}
