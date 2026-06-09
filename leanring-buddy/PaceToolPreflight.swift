//
//  PaceToolPreflight.swift
//  leanring-buddy
//
//  Pure preflight checks for local tool plans. These checks do not grant
//  permissions or touch other apps; they turn known missing state into clear
//  warnings before the approval popup and into the Action Result Center.
//

import Foundation

enum PaceToolPreflightSeverity: Equatable {
    case warning
    case blocking

    var displayName: String {
        switch self {
        case .warning:
            return "warning"
        case .blocking:
            return "blocked"
        }
    }
}

struct PaceToolPreflightIssue: Equatable {
    let severity: PaceToolPreflightSeverity
    let title: String
    let repairHint: String

    static func formatForApproval(_ issues: [PaceToolPreflightIssue]) -> String? {
        let formattedIssues = formatLines(issues)
        guard !formattedIssues.isEmpty else { return nil }
        return "Preflight:\n" + formattedIssues
    }

    static func formatForUser(_ issues: [PaceToolPreflightIssue]) -> String? {
        let formattedIssues = formatLines(issues)
        return formattedIssues.isEmpty ? nil : formattedIssues
    }

    private static func formatLines(_ issues: [PaceToolPreflightIssue]) -> String {
        issues
            .map { issue in
                "- [\(issue.severity.displayName)] \(issue.title): \(issue.repairHint)"
            }
            .joined(separator: "\n")
    }
}

struct PaceToolPreflightEnvironment {
    let actionsAreEnabled: Bool
    let hasAccessibilityPermission: Bool
    let hasCalendarPermission: Bool
    let hasRemindersPermission: Bool
    let configuredMCPServerNames: Set<String>

    static let fullyGranted = PaceToolPreflightEnvironment(
        actionsAreEnabled: true,
        hasAccessibilityPermission: true,
        hasCalendarPermission: true,
        hasRemindersPermission: true,
        configuredMCPServerNames: []
    )
}

enum PaceToolPreflight {
    static func evaluate(
        actionExecutionPlan: PaceActionExecutionPlan,
        environment: PaceToolPreflightEnvironment
    ) -> [PaceToolPreflightIssue] {
        var issues: [PaceToolPreflightIssue] = []

        if !environment.actionsAreEnabled {
            issues.append(PaceToolPreflightIssue(
                severity: .blocking,
                title: "Actions are disabled",
                repairHint: "Set EnableActions=true in Info.plist, then rebuild."
            ))
        }

        let actions = actionExecutionPlan.flattenedActions
        if actions.contains(where: requiresAccessibilityPermission),
           !environment.hasAccessibilityPermission {
            issues.append(PaceToolPreflightIssue(
                severity: .blocking,
                title: "Accessibility permission missing",
                repairHint: "Open Pace's panel and grant Accessibility."
            ))
        }

        if actions.contains(where: isCalendarAction),
           !environment.hasCalendarPermission {
            issues.append(PaceToolPreflightIssue(
                severity: .blocking,
                title: "Calendar permission missing",
                repairHint: "Use the Calendar row in Local Tools."
            ))
        }

        if actions.contains(where: isReminderAction),
           !environment.hasRemindersPermission {
            issues.append(PaceToolPreflightIssue(
                severity: .blocking,
                title: "Reminders permission missing",
                repairHint: "Use the Reminders row in Local Tools."
            ))
        }

        if actions.contains(where: mayRequireAutomationPermission) {
            issues.append(PaceToolPreflightIssue(
                severity: .warning,
                title: "Automation may prompt",
                repairHint: "Approve the native macOS prompt, or open Privacy & Security > Automation."
            ))
        }

        let missingMCPServerNames = missingMCPServers(
            in: actions,
            configuredServerNames: environment.configuredMCPServerNames
        )
        for serverName in missingMCPServerNames {
            issues.append(PaceToolPreflightIssue(
                severity: .blocking,
                title: "MCP server not configured: \(serverName)",
                repairHint: "Add it to ~/.config/pace/mcp-servers.json."
            ))
        }

        return issues
    }

    private static func requiresAccessibilityPermission(_ action: PaceParsedAction) -> Bool {
        switch action {
        case .click, .doubleClick, .clickCandidates, .type, .setTextValue, .editSelectedText,
             .undoLastMutation, .pressKey, .snapWindow, .scroll:
            return true
        case .readClipboard, .openApplication, .openURL, .controlMusic, .adjustVolume, .adjustBrightness,
             .listCalendarEvents, .createCalendarEvent, .createReminder, .finder, .createNote, .appendNote,
             .searchNotes, .composeMail, .createThingsToDo, .runShortcut, .openMessages, .mcp:
            return false
        }
    }

    private static func isCalendarAction(_ action: PaceParsedAction) -> Bool {
        switch action {
        case .listCalendarEvents, .createCalendarEvent:
            return true
        default:
            return false
        }
    }

    private static func isReminderAction(_ action: PaceParsedAction) -> Bool {
        if case .createReminder = action {
            return true
        }
        return false
    }

    private static func mayRequireAutomationPermission(_ action: PaceParsedAction) -> Bool {
        switch action {
        case .controlMusic, .createNote, .appendNote, .searchNotes, .composeMail,
             .createThingsToDo, .runShortcut, .openMessages, .mcp:
            return true
        case .click, .doubleClick, .clickCandidates, .type, .setTextValue, .editSelectedText,
             .undoLastMutation, .pressKey, .snapWindow, .scroll,
             .readClipboard, .openApplication, .openURL,
             .adjustVolume, .adjustBrightness, .listCalendarEvents, .createCalendarEvent,
             .createReminder, .finder:
            return false
        }
    }

    private static func missingMCPServers(
        in actions: [PaceParsedAction],
        configuredServerNames: Set<String>
    ) -> [String] {
        let requiredServerNames = Set(actions.compactMap { action -> String? in
            guard case .mcp(let mcpToolCall) = action else { return nil }
            return mcpToolCall.serverName
        })

        return requiredServerNames
            .subtracting(configuredServerNames)
            .sorted()
    }
}
