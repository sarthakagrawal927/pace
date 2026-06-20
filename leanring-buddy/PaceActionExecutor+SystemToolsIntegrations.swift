//
//  PaceActionExecutor+SystemToolsIntegrations.swift
//  leanring-buddy
//
//  Extracted from PaceActionExecutor.swift (god-class decomposition Phase B):
//  Things, Shortcuts, Messages, AppleScript helpers, MCP-adjacent utilities.
//

import AppKit
import Contacts
import EventKit
import Foundation

@MainActor
extension PaceActionExecutor {

    // MARK: - System tools (integrations & helpers)

    func openMessages(_ request: PaceMessageRequest) async -> PaceActionExecutionObservation {
        print("🧰 Messages open (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "messages",
                summary: "Would open Messages."
            )
        }

        await openApplication(named: "Messages")
        return PaceActionExecutionObservation(
            toolName: "messages",
            summary: request.recipient?.isEmpty == false
                ? "Opened Messages. Recipient requested: \(request.recipient!)."
                : "Opened Messages."
        )
    }

    func postAuxiliaryKeyEvent(keyType: Int32) {
        let keyDownData = (keyType << 16) | (0xA << 8)
        let keyUpData = (keyType << 16) | (0xB << 8)

        for eventData in [keyDownData, keyUpData] {
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int(eventData),
                data2: -1
            )?.cgEvent else {
                continue
            }
            event.post(tap: .cghidEventTap)
        }
    }

    func requestCalendarAccessIfNeeded() async -> Bool {
        // No mid-action TCC prompt: check status, fail with an error
        // observation if missing. The user grants once from Settings on
        // their own time, never during a voice turn.
        return Self.isEventKitAccessAlreadyGranted(for: .event)
    }

    func requestReminderAccessIfNeeded() async -> Bool {
        return Self.isEventKitAccessAlreadyGranted(for: .reminder)
    }

    static func isEventKitAccessAlreadyGranted(for entityType: EKEntityType) -> Bool {
        let authorizationStatus = EKEventStore.authorizationStatus(for: entityType)
        // The app targets macOS 26+, where `.fullAccess` is the only status
        // that grants both read and write to EventKit entities. The legacy
        // `.authorized` case was retired on macOS 14.
        return authorizationStatus == .fullAccess
    }

    func runAppleScript(source: String) -> (output: String?, errorDescription: String?) {
        guard let script = NSAppleScript(source: source) else {
            return (nil, "Could not compile AppleScript.")
        }

        var errorInfo: NSDictionary?
        let resultDescriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "\(errorInfo)"
            return (nil, message)
        }

        return (resultDescriptor.stringValue, nil)
    }

    struct PaceLocalCommandResult {
        let output: String
        let errorOutput: String
        let terminationStatus: Int32

        var failureSummary: String {
            let trimmedErrorOutput = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedErrorOutput.isEmpty {
                return trimmedErrorOutput
            }

            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedOutput.isEmpty {
                return trimmedOutput
            }

            return "command exited with status \(terminationStatus)"
        }
    }

    func runShortcutsCommand(arguments: [String]) -> PaceLocalCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return PaceLocalCommandResult(
                output: "",
                errorOutput: error.localizedDescription,
                terminationStatus: 1
            )
        }

        let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        let standardErrorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()

        return PaceLocalCommandResult(
            output: String(data: standardOutputData, encoding: .utf8) ?? "",
            errorOutput: String(data: standardErrorData, encoding: .utf8) ?? "",
            terminationStatus: process.terminationStatus
        )
    }

    static func findApplicationURL(named applicationName: String) -> URL? {
        let trimmedApplicationName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedApplicationName.isEmpty else { return nil }

        if trimmedApplicationName.contains("."),
           let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmedApplicationName) {
            return bundleURL
        }

        let requestedAppName = trimmedApplicationName.hasSuffix(".app")
            ? String(trimmedApplicationName.dropLast(4))
            : trimmedApplicationName
        let normalizedRequestedName = normalizeApplicationName(requestedAppName)

        let searchRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]

        for searchRoot in searchRoots {
            guard let appURL = findApplicationURL(
                matchingNormalizedName: normalizedRequestedName,
                under: searchRoot
            ) else {
                continue
            }
            return appURL
        }

        return nil
    }

    static func appleScriptEscaped(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func findApplicationURL(
        matchingNormalizedName normalizedRequestedName: String,
        under searchRoot: URL
    ) -> URL? {
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isApplicationKey]
        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        for case let candidateURL as URL in enumerator {
            guard candidateURL.pathExtension.lowercased() == "app" else { continue }
            let candidateName = candidateURL.deletingPathExtension().lastPathComponent
            if normalizeApplicationName(candidateName) == normalizedRequestedName {
                return candidateURL
            }
        }

        return nil
    }

    static func normalizeApplicationName(_ applicationName: String) -> String {
        applicationName
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    static let soundUpKeyType: Int32 = 0
    static let soundDownKeyType: Int32 = 1
    static let brightnessUpKeyType: Int32 = 2
    static let brightnessDownKeyType: Int32 = 3
    static let mediaPlayPauseKeyType: Int32 = 16
    static let mediaNextKeyType: Int32 = 17
    static let mediaPreviousKeyType: Int32 = 18
}
