//
//  PaceActionExecutor+SystemToolsAppsMedia.swift
//  leanring-buddy
//
//  Extracted from PaceActionExecutor.swift (god-class decomposition Phase B):
//  open app/URL, timers, flows, download, music, volume, brightness.
//

import AppKit
import Foundation

@MainActor
extension PaceActionExecutor {

    // MARK: - System tools (apps & media)

    // MARK: - System tools

    @discardableResult
    func openApplication(named applicationName: String) async -> PaceActionExecutionObservation {
        let trimmedApplicationName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedApplicationName.isEmpty else {
            return PaceActionExecutionObservation(
                toolName: "open_app",
                summary: "No application name was provided."
            )
        }

        print("🧰 Open app \"\(trimmedApplicationName)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "open_app",
                summary: "Would open app: \(trimmedApplicationName)"
            )
        }

        guard let applicationURL = Self.findApplicationURL(named: trimmedApplicationName) else {
            print("⚠️ PaceActionExecutor: could not find app named \(trimmedApplicationName)")
            return PaceActionExecutionObservation(
                toolName: "open_app",
                summary: "Could not find app: \(trimmedApplicationName)"
            )
        }

        let openErrorDescription: String? = await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
                if let error {
                    print("⚠️ PaceActionExecutor: failed to open \(trimmedApplicationName): \(error.localizedDescription)")
                }
                continuation.resume(returning: error?.localizedDescription)
            }
        }

        if let openErrorDescription {
            return PaceActionExecutionObservation(
                toolName: "open_app",
                summary: "Failed to open app \(trimmedApplicationName): \(openErrorDescription)"
            )
        }

        return PaceActionExecutionObservation(
            toolName: "open_app",
            summary: "Opened app: \(trimmedApplicationName)"
        )
    }

    /// Public hook so CompanionManager can hand the scheduler a speak
    /// closure after it has finished wiring its TTS client. Without this
    /// the scheduler fires silently — it has no idea how to talk on its
    /// own.
    func setTimerOnFireSpeakCallback(_ speakCallback: @escaping (String) -> Void) {
        timerScheduler.onFire = speakCallback
    }

    /// Reload any persisted timers from disk so a quit+restart doesn't
    /// silently swallow an in-flight nudge.
    func rehydratePersistedTimers() {
        timerScheduler.rehydrate()
    }

    func startTimer(_ timerRequest: PaceTimerRequest) async -> PaceActionExecutionObservation {
        let durationInSeconds = max(0.001, timerRequest.durationInSeconds)
        let trimmedLabel = timerRequest.label.trimmingCharacters(in: .whitespacesAndNewlines)
        print("🧰 Start timer label=\"\(trimmedLabel)\" duration=\(durationInSeconds)s")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "start_timer",
                summary: "Would start timer for \(Int(durationInSeconds))s\(trimmedLabel.isEmpty ? "" : ": \(trimmedLabel)")."
            )
        }
        let scheduledTimer = timerScheduler.schedule(
            label: trimmedLabel,
            durationInSeconds: durationInSeconds
        )
        let minutesRemaining = Int((durationInSeconds / 60.0).rounded())
        let humanDurationText: String
        if minutesRemaining >= 1 {
            humanDurationText = "\(minutesRemaining) minute\(minutesRemaining == 1 ? "" : "s")"
        } else {
            humanDurationText = "\(Int(durationInSeconds)) seconds"
        }
        let labelSuffix = trimmedLabel.isEmpty ? "" : " for \(trimmedLabel)"
        return PaceActionExecutionObservation(
            toolName: "start_timer",
            summary: "Timer set\(labelSuffix) for \(humanDurationText) — fires at \(scheduledTimer.fireDate.formatted(date: .omitted, time: .shortened))."
        )
    }

    func recordFlow(_ flowRequest: PaceFlowActionRequest) -> PaceActionExecutionObservation {
        let flowName = flowRequest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flowName.isEmpty else {
            return PaceActionExecutionObservation(
                toolName: "record_flow",
                summary: "Flow recording needs a name."
            )
        }
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "record_flow",
                summary: "Would record flow \"\(flowName)\"."
            )
        }
        // CompanionManager owns the live recorder + the eventual save
        // into PaceFlowStore on stop. The callback returns the
        // spoken-ready summary so the executor observation reads
        // exactly like the panel TTS would say it.
        let recorderSummary = startFlowRecordingCallback(flowName)
        return PaceActionExecutionObservation(
            toolName: "record_flow",
            summary: recorderSummary
        )
    }

    func runFlow(_ flowRequest: PaceFlowActionRequest) -> PaceActionExecutionObservation {
        let flowName = flowRequest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flowName.isEmpty else {
            return PaceActionExecutionObservation(
                toolName: "run_flow",
                summary: "Flow replay needs a name."
            )
        }
        let storedFlow = PaceFlowStore().load(named: flowName)
        guard let storedFlow else {
            return PaceActionExecutionObservation(
                toolName: "run_flow",
                summary: "No recorded flow named \"\(flowName)\" was found."
            )
        }
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "run_flow",
                summary: "Would replay flow \"\(storedFlow.name)\" (\(storedFlow.steps.count) step\(storedFlow.steps.count == 1 ? "" : "s"))."
            )
        }
        // CompanionManager applies the per-session approval cache,
        // drives the replayer, and speaks completion/failure copy. The
        // executor just kicks off the call and reports a neutral
        // observation back to the planner loop.
        let didStartReplay = runFlowCallback(storedFlow)
        if didStartReplay {
            return PaceActionExecutionObservation(
                toolName: "run_flow",
                summary: "Replaying flow \"\(storedFlow.name)\" (\(storedFlow.steps.count) step\(storedFlow.steps.count == 1 ? "" : "s"))."
            )
        }
        return PaceActionExecutionObservation(
            toolName: "run_flow",
            summary: "Flow \"\(storedFlow.name)\" is ready — pending approval."
        )
    }

    func downloadFile(_ downloadRequest: PaceFileDownloadRequest) async -> PaceActionExecutionObservation {
        let downloadURL = downloadRequest.url
        print("🧰 Download file \"\(downloadURL.absoluteString)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "download_file",
                summary: "Would download file: \(downloadURL.absoluteString)"
            )
        }

        guard let downloadsDirectoryURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first else {
            return PaceActionExecutionObservation(
                toolName: "download_file",
                summary: "Could not locate the Downloads folder."
            )
        }

        do {
            let (temporaryFileURL, response) = try await URLSession.shared.download(from: downloadURL)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                try? FileManager.default.removeItem(at: temporaryFileURL)
                return PaceActionExecutionObservation(
                    toolName: "download_file",
                    summary: "Download failed with HTTP \(httpResponse.statusCode): \(downloadURL.absoluteString)"
                )
            }

            let sanitizedFilename = PaceDownloadFilenameSanitizer.sanitizedFilename(
                suggestedFilename: downloadRequest.suggestedFilename ?? response.suggestedFilename,
                downloadURL: downloadURL
            )
            let existingFilenames = Set(
                (try? FileManager.default.contentsOfDirectory(atPath: downloadsDirectoryURL.path)) ?? []
            )
            let finalFilename = PaceDownloadFilenameSanitizer.collisionFreeFilename(
                sanitizedFilename,
                existingFilenames: existingFilenames
            )
            let destinationURL = downloadsDirectoryURL.appendingPathComponent(finalFilename)
            try FileManager.default.moveItem(at: temporaryFileURL, to: destinationURL)

            let downloadedByteCount = (try? FileManager.default.attributesOfItem(
                atPath: destinationURL.path
            )[.size] as? Int) ?? 0
            return PaceActionExecutionObservation(
                toolName: "download_file",
                summary: "Downloaded \(finalFilename) (\(downloadedByteCount) bytes) to ~/Downloads."
            )
        } catch {
            return PaceActionExecutionObservation(
                toolName: "download_file",
                summary: "Download failed: \(error.localizedDescription)"
            )
        }
    }

    func openURL(_ rawURLString: String) async -> PaceActionExecutionObservation {
        let trimmedURLString = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURLString.isEmpty else {
            return PaceActionExecutionObservation(toolName: "open_url", summary: "No URL was provided.")
        }

        let normalizedURLString: String = {
            if trimmedURLString.contains("://") {
                return trimmedURLString
            }
            return "https://\(trimmedURLString)"
        }()

        guard let url = URL(string: normalizedURLString) else {
            return PaceActionExecutionObservation(
                toolName: "open_url",
                summary: "Could not parse URL: \(trimmedURLString)"
            )
        }

        print("🧰 Open URL \"\(url.absoluteString)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "open_url",
                summary: "Would open URL: \(url.absoluteString)"
            )
        }

        if let preferredBrowser = PaceLocalMemoryStore.string(for: .preferredBrowser),
           let browserURL = Self.findApplicationURL(named: preferredBrowser) {
            let openErrorDescription: String? = await withCheckedContinuation { continuation in
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: browserURL,
                    configuration: configuration
                ) { _, error in
                    continuation.resume(returning: error?.localizedDescription)
                }
            }

            if let openErrorDescription {
                return PaceActionExecutionObservation(
                    toolName: "open_url",
                    summary: "Failed to open URL in \(preferredBrowser): \(openErrorDescription)"
                )
            }

            return PaceActionExecutionObservation(
                toolName: "open_url",
                summary: "Opened URL in \(preferredBrowser): \(url.absoluteString)"
            )
        }

        let didOpen = NSWorkspace.shared.open(url)
        return PaceActionExecutionObservation(
            toolName: "open_url",
            summary: didOpen ? "Opened URL: \(url.absoluteString)" : "Failed to open URL: \(url.absoluteString)"
        )
    }

    func controlMusic(_ musicCommand: PaceMusicCommand) async -> PaceActionExecutionObservation {
        print("🧰 Music \(musicCommand.rawValue) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "music",
                summary: "Would run Music command: \(musicCommand.rawValue)"
            )
        }

        switch musicCommand {
        case .play, .pause:
            await openApplication(named: "Music")
            try? await Task.sleep(nanoseconds: 200_000_000)
            let scriptVerb = (musicCommand == .play) ? "play" : "pause"
            let scriptResult = runAppleScript(source: """
            tell application "Music"
                \(scriptVerb)
            end tell
            """)
            if let errorDescription = scriptResult.errorDescription {
                return PaceActionExecutionObservation(
                    toolName: "music",
                    summary: "Music \(musicCommand.rawValue) failed: \(errorDescription)"
                )
            }
            return PaceActionExecutionObservation(
                toolName: "music",
                summary: "Music command completed: \(musicCommand.rawValue)"
            )
        case .playPause:
            postAuxiliaryKeyEvent(keyType: Self.mediaPlayPauseKeyType)
        case .next:
            postAuxiliaryKeyEvent(keyType: Self.mediaNextKeyType)
        case .previous:
            postAuxiliaryKeyEvent(keyType: Self.mediaPreviousKeyType)
        }

        return PaceActionExecutionObservation(
            toolName: "music",
            summary: "Music command completed: \(musicCommand.rawValue)"
        )
    }

    func adjustVolume(_ adjustment: PaceSystemAdjustment) async {
        print("🧰 Volume \(adjustment) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else { return }

        for _ in 0..<adjustment.stepCount {
            switch adjustment.direction {
            case .up:
                postAuxiliaryKeyEvent(keyType: Self.soundUpKeyType)
            case .down:
                postAuxiliaryKeyEvent(keyType: Self.soundDownKeyType)
            }
            try? await Task.sleep(nanoseconds: 55_000_000)
        }
    }

    func adjustBrightness(_ adjustment: PaceSystemAdjustment) async {
        print("🧰 Brightness \(adjustment) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else { return }

        for _ in 0..<adjustment.stepCount {
            switch adjustment.direction {
            case .up:
                postAuxiliaryKeyEvent(keyType: Self.brightnessUpKeyType)
            case .down:
                postAuxiliaryKeyEvent(keyType: Self.brightnessDownKeyType)
            }
            try? await Task.sleep(nanoseconds: 55_000_000)
        }
    }

}
