//
//  PaceTTSSidecarLauncher.swift
//  leanring-buddy
//
//  Launches the local Kokoro TTS sidecar (mlx-audio on
//  localhost:8880) from Pace itself so the user never has to remember
//  scripts/start-tts-server.sh. Idempotent: if the sidecar is already
//  reachable on the configured port, we skip the spawn entirely.
//
//  The subprocess is started detached from the app process group so
//  Pace's quit/relaunch does not nuke the sidecar — leaving the model
//  resident in RAM keeps the next launch warm. The user can still
//  manage the process manually (`pkill mlx_audio.server`) when they
//  want the RAM back.
//

import Foundation

@MainActor
enum PaceTTSSidecarLauncher {
    /// Probes the configured base URL with a short HEAD-equivalent
    /// request, then spawns the sidecar if nothing is listening.
    static func startIfNotRunning() {
        let baseURLString = AppBundleConfiguration.stringValue(forKey: "LocalTTSServerBaseURL")
            ?? "http://localhost:8880/v1"
        guard let modelsURL = URL(string: baseURLString)?.appendingPathComponent("models") else {
            print("🔊 TTS sidecar launcher: invalid LocalTTSServerBaseURL — skipping")
            return
        }
        guard let portNumber = URLComponents(string: baseURLString)?.port ?? Self.defaultPort(for: baseURLString) else {
            print("🔊 TTS sidecar launcher: could not determine port — skipping")
            return
        }

        Task.detached(priority: .userInitiated) {
            if await Self.isSidecarReachable(modelsURL: modelsURL) {
                print("🔊 TTS sidecar already running on port \(portNumber)")
                return
            }
            await Self.spawnSidecar(portNumber: portNumber)
        }
    }

    private static func defaultPort(for baseURLString: String) -> Int? {
        if baseURLString.contains(":8880") { return 8880 }
        return nil
    }

    private static func isSidecarReachable(modelsURL: URL) async -> Bool {
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 1.5
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse else {
            return false
        }
        return (200..<500).contains(httpResponse.statusCode)
    }

    private static func spawnSidecar(portNumber: Int) async {
        // Locate the launcher script next to the running app bundle.
        // Debug builds find it in the developer source tree; release
        // builds bundle the script alongside the binary.
        let launcherScriptURL = locateLauncherScript()
        guard let launcherScriptURL else {
            print("🔊 TTS sidecar launcher: scripts/start-tts-server.sh not found — sidecar will not be auto-started")
            return
        }

        let sidecarProcess = Process()
        sidecarProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
        sidecarProcess.arguments = [launcherScriptURL.path]
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["PORT"] = String(portNumber)
        // Make sure uv/uvx are findable when Pace was launched via
        // LaunchServices and inherits a minimal PATH.
        let existingPATH = processEnvironment["PATH"] ?? ""
        let augmentedPATH = "/opt/homebrew/bin:/usr/local/bin:" + existingPATH
        processEnvironment["PATH"] = augmentedPATH
        sidecarProcess.environment = processEnvironment

        // Detach: dropping stdin/stdout/stderr to /dev/null and not
        // calling `waitUntilExit` lets the sidecar outlive Pace.
        let nullFileHandle = FileHandle(forUpdatingAtPath: "/dev/null")
        sidecarProcess.standardInput = nullFileHandle
        sidecarProcess.standardOutput = nullFileHandle
        sidecarProcess.standardError = nullFileHandle

        do {
            try sidecarProcess.run()
            print("🔊 TTS sidecar launching (pid \(sidecarProcess.processIdentifier), port \(portNumber)) — first run downloads the model")
        } catch {
            print("🔊 TTS sidecar launch failed: \(error.localizedDescription)")
        }
    }

    private static func locateLauncherScript() -> URL? {
        let fileManager = FileManager.default
        // Bundled alongside the .app first.
        if let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("scripts/start-tts-server.sh"),
           fileManager.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }
        // Developer source tree (Debug builds): walk up from the
        // executable looking for the scripts directory.
        var searchURL = Bundle.main.executableURL?
            .deletingLastPathComponent()
        for _ in 0..<8 {
            guard let candidateURL = searchURL else { break }
            let scriptURL = candidateURL.appendingPathComponent("scripts/start-tts-server.sh")
            if fileManager.fileExists(atPath: scriptURL.path) {
                return scriptURL
            }
            searchURL = candidateURL.deletingLastPathComponent()
        }
        // Fallback: hardcoded repo path so dev builds always work.
        let developerScriptURL = URL(fileURLWithPath:
            "/Users/sarthak/Desktop/fleet/pace/scripts/start-tts-server.sh"
        )
        if fileManager.fileExists(atPath: developerScriptURL.path) {
            return developerScriptURL
        }
        return nil
    }
}
