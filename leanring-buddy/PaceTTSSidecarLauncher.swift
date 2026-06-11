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
    /// LaunchAgent label + path. The plist runs the bundled launcher
    /// script under launchd so the sidecar survives Pace quit/relaunch
    /// AND avoids the LaunchServices subprocess-spawn restriction that
    /// silently blocks Process.run() from /Applications-installed apps.
    private static let launchAgentLabel = "com.pace.tts-sidecar"
    private static var launchAgentPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

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
            // First: try installing/loading a LaunchAgent. This is the
            // reliable path — launchd owns the sidecar process so it
            // survives Pace quits AND isn't blocked by LaunchServices'
            // restriction on /Applications-installed apps spawning
            // arbitrary subprocesses (which silently kills the inline
            // Process.run path used to work in /tmp dev builds).
            if await Self.installAndLoadLaunchAgent(portNumber: portNumber) {
                return
            }
            // Fallback: the inline subprocess spawn (dev builds in
            // /tmp/.../Pace.app find their launcher this way).
            await Self.spawnSidecar(portNumber: portNumber)
        }
    }

    /// Writes the LaunchAgent plist (or rewrites it when the script path
    /// changed because the app moved) and asks launchd to start it.
    /// Returns true once the agent is loaded and the sidecar is up.
    private static func installAndLoadLaunchAgent(portNumber: Int) async -> Bool {
        guard let launcherScriptURL = locateLauncherScript() else {
            print("🔊 TTS sidecar launcher: bundled start-tts-server.sh not found — cannot install LaunchAgent")
            return false
        }
        let expectedPlistContents = renderLaunchAgentPlist(
            launcherScriptPath: launcherScriptURL.path,
            portNumber: portNumber
        )
        let plistURL = launchAgentPath
        let fileManager = FileManager.default
        let existingContents = (try? String(contentsOf: plistURL, encoding: .utf8)) ?? ""
        if existingContents != expectedPlistContents {
            try? fileManager.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try expectedPlistContents.write(to: plistURL, atomically: true, encoding: .utf8)
                print("🔊 TTS sidecar: wrote LaunchAgent plist at \(plistURL.path)")
            } catch {
                print("🔊 TTS sidecar launcher: could not write LaunchAgent plist: \(error.localizedDescription)")
                return false
            }
            _ = runLaunchctl(arguments: ["unload", plistURL.path])
        }
        let loadResult = runLaunchctl(arguments: ["load", plistURL.path])
        if loadResult.terminationStatus != 0 {
            // load fails when already loaded; that's fine.
            print("🔊 TTS sidecar LaunchAgent already loaded (or load returned \(loadResult.terminationStatus)).")
        } else {
            print("🔊 TTS sidecar LaunchAgent loaded.")
        }
        // Poll up to 90s for the sidecar to bind (first run downloads the
        // model, subsequent runs are 5-15s).
        let modelsURL = URL(string: "http://localhost:\(portNumber)/v1/models")!
        for _ in 0..<90 {
            if await isSidecarReachable(modelsURL: modelsURL) {
                print("🔊 TTS sidecar via LaunchAgent: ready on port \(portNumber)")
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("🔊 TTS sidecar via LaunchAgent: did not become reachable within 90s — see /tmp/pace-tts-sidecar.log")
        return false
    }

    private static func renderLaunchAgentPlist(launcherScriptPath: String, portNumber: Int) -> String {
        // Inline plist generation so the format is co-located with the
        // launch code and stays in sync if either side changes.
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(launchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/bash</string>
                <string>\(launcherScriptPath)</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
                <key>PORT</key>
                <string>\(portNumber)</string>
            </dict>
            <key>WorkingDirectory</key>
            <string>/tmp</string>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
                <key>NetworkState</key>
                <true/>
            </dict>
            <key>StandardOutPath</key>
            <string>/tmp/pace-tts-sidecar.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/pace-tts-sidecar.log</string>
        </dict>
        </plist>
        """
    }

    private static func runLaunchctl(arguments: [String]) -> (terminationStatus: Int32, output: String) {
        let launchctlProcess = Process()
        launchctlProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctlProcess.arguments = arguments
        let outputPipe = Pipe()
        launchctlProcess.standardOutput = outputPipe
        launchctlProcess.standardError = outputPipe
        do {
            try launchctlProcess.run()
            launchctlProcess.waitUntilExit()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return (launchctlProcess.terminationStatus, String(data: outputData, encoding: .utf8) ?? "")
        } catch {
            return (-1, "launchctl exec failed: \(error.localizedDescription)")
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
