//
//  PaceActionExecutorDryRunTests.swift
//  leanring-buddyTests
//

import Testing
@testable import Pace

@MainActor
struct PaceActionExecutorDryRunTests {
    @Test func dryRunAppleAndSystemToolsReturnNonMutatingObservations() async throws {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)
        #expect(executor.actionsAreEnabled == false)

        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .openApplication("Notes"),
            .openURL("example.com"),
            .controlMusic(.playPause),
            .listCalendarEvents(PaceCalendarQuery(range: .today)),
            .createReminder(PaceReminderRequest(title: "Dry run reminder", notes: nil)),
            .finder(PaceFinderRequest(path: "~/Downloads", action: .reveal)),
            .createNote(PaceNoteRequest(title: "Dry run note", body: "No note should be created.")),
            .appendNote(PaceNoteRequest(title: "Dry run note", body: "Append nothing.")),
            .searchNotes("Dry run"),
            .composeMail(PaceMailDraft(
                recipients: ["alex@example.com"],
                subject: "Dry run",
                body: "No draft should be opened."
            )),
            .createThingsToDo(PaceThingsToDoRequest(title: "Dry run task", notes: nil)),
            .runShortcut("Dry Run Shortcut"),
            .openMessages(PaceMessageRequest(recipient: "Alex", text: "Dry run message")),
        ])

        let observations = await executor.executeActionPlan(
            actionPlan,
            screenCaptures: []
        )
        let formattedObservations = PaceActionExecutionObservation.formatForPlanner(observations)

        #expect(formattedObservations.contains("Would open app: Notes"))
        #expect(formattedObservations.contains("Would open URL: https://example.com"))
        #expect(formattedObservations.contains("Would run Music command: playPause"))
        #expect(formattedObservations.contains("Would list calendar events for today."))
        #expect(formattedObservations.contains("Would create reminder: Dry run reminder"))
        #expect(formattedObservations.contains("Would reveal path:"))
        #expect(formattedObservations.contains("Would create note: Dry run note"))
        #expect(formattedObservations.contains("Would append to note: Dry run note"))
        #expect(formattedObservations.contains("Would search notes for: Dry run"))
        #expect(formattedObservations.contains("Would compose mail draft"))
        #expect(formattedObservations.contains("Would create Things to-do: Dry run task"))
        #expect(formattedObservations.contains("Would run shortcut: Dry Run Shortcut"))
        #expect(formattedObservations.contains("Would open Messages"))
    }

    @Test func userFeedbackSummarizesToolResults() async throws {
        let feedback = PaceActionExecutionObservation.formatForUserFeedback([
            PaceActionExecutionObservation(toolName: "notes", summary: "Created note: Idea")
        ])

        #expect(feedback == "Created note: Idea")

        let multiActionFeedback = PaceActionExecutionObservation.formatForUserFeedback([
            PaceActionExecutionObservation(toolName: "open_app", summary: "Opened app: Notes"),
            PaceActionExecutionObservation(toolName: "notes", summary: "Created note: Idea")
        ])

        #expect(multiActionFeedback == "Opened app: Notes, plus 1 more action result.")
    }
}
