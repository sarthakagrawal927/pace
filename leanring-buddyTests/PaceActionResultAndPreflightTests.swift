//
//  PaceActionResultAndPreflightTests.swift
//  leanring-buddyTests
//

import Testing
@testable import Pace

@MainActor
struct PaceActionResultAndPreflightTests {
    @Test func preflightReportsMissingPermissionsAndAutomationWarning() async throws {
        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .click(ScreenshotPixelLocation(xInScreenshotPixels: 10, yInScreenshotPixels: 20, screenNumber: nil)),
            .listCalendarEvents(PaceCalendarQuery(range: .today)),
            .createReminder(PaceReminderRequest(title: "Pay rent", notes: nil)),
            .createNote(PaceNoteRequest(title: "Idea", body: "Ship it")),
        ])

        let issues = PaceToolPreflight.evaluate(
            actionExecutionPlan: actionPlan,
            environment: PaceToolPreflightEnvironment(
                actionsAreEnabled: true,
                hasAccessibilityPermission: false,
                hasCalendarPermission: false,
                hasRemindersPermission: false,
                configuredMCPServerNames: []
            )
        )

        #expect(issues.contains { $0.title == "Accessibility permission missing" })
        #expect(issues.contains { $0.title == "Calendar permission missing" })
        #expect(issues.contains { $0.title == "Reminders permission missing" })
        #expect(issues.contains { $0.title == "Automation may prompt" && $0.severity == .warning })
    }

    @Test func preflightReportsMissingMCPServer() async throws {
        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .mcp(PaceMCPToolCall(serverName: "altic", toolName: "notes_create", arguments: [:]))
        ])

        let issues = PaceToolPreflight.evaluate(
            actionExecutionPlan: actionPlan,
            environment: PaceToolPreflightEnvironment(
                actionsAreEnabled: true,
                hasAccessibilityPermission: true,
                hasCalendarPermission: true,
                hasRemindersPermission: true,
                configuredMCPServerNames: ["apple"]
            )
        )

        #expect(issues.contains { $0.title == "MCP server not configured: altic" && $0.severity == .blocking })
    }

    @Test func actionResultDetectsFailedObservation() async throws {
        let result = PaceActionRunRecord.completed(observations: [
            PaceActionExecutionObservation(toolName: "notes", summary: "Failed to create note: not authorized")
        ])

        #expect(result.status == .failed)
        #expect(result.title == "Action needs attention")
    }

    @Test func plannedActionResultIncludesPreflightText() async throws {
        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .openURL("https://example.com")
        ])
        let result = PaceActionRunRecord.planned(
            actionExecutionPlan: actionPlan,
            preflightIssues: [
                PaceToolPreflightIssue(
                    severity: .warning,
                    title: "Automation may prompt",
                    repairHint: "Approve the prompt."
                )
            ]
        )

        #expect(result.status == .planned)
        #expect(result.detail.contains("Open URL"))
        #expect(result.detail.contains("Automation may prompt"))
    }
}
