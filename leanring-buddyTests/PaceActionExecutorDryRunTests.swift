//
//  PaceActionExecutorDryRunTests.swift
//  leanring-buddyTests
//

import CoreGraphics
import Foundation
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
            .readClipboard,
            .setTextValue(PaceSetTextValueRequest(value: "Dry run text", target: .focused)),
            .undoLastMutation,
            .snapWindow(PaceWindowSnapRequest(position: .left)),
            .listCalendarEvents(PaceCalendarQuery(range: .today)),
            .createCalendarEvent(PaceCalendarEventRequest(
                title: "Dry run calendar event",
                startDate: Date(timeIntervalSince1970: 1_780_000_000),
                endDate: Date(timeIntervalSince1970: 1_780_003_600),
                isAllDay: false,
                notes: nil,
                location: nil,
                calendarTitle: nil
            )),
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
            .mcp(PaceMCPToolCall(
                serverName: "altic",
                toolName: "notes_create",
                arguments: ["title": .string("Dry run MCP note")]
            )),
        ])

        let observations = await executor.executeActionPlan(
            actionPlan,
            screenCaptures: []
        )
        let formattedObservations = PaceActionExecutionObservation.formatForPlanner(observations)

        #expect(formattedObservations.contains("Would open app: Notes"))
        #expect(formattedObservations.contains("Would open URL: https://example.com"))
        #expect(formattedObservations.contains("Would run Music command: playPause"))
        #expect(formattedObservations.contains("Would read clipboard text."))
        #expect(formattedObservations.contains("Would set focused text to"))
        #expect(formattedObservations.contains("Would undo the last editable text change."))
        #expect(formattedObservations.contains("Would snap focused window: left half"))
        #expect(formattedObservations.contains("Would list calendar events for today."))
        #expect(formattedObservations.contains("Would create calendar event: Dry run calendar event"))
        #expect(formattedObservations.contains("Would create reminder: Dry run reminder"))
        #expect(formattedObservations.contains("Would reveal path:"))
        #expect(formattedObservations.contains("Would create note: Dry run note"))
        #expect(formattedObservations.contains("Would append to note: Dry run note"))
        #expect(formattedObservations.contains("Would search notes for: Dry run"))
        #expect(formattedObservations.contains("Would compose mail draft"))
        #expect(formattedObservations.contains("Would create Things to-do: Dry run task"))
        #expect(formattedObservations.contains("Would run shortcut: Dry Run Shortcut"))
        #expect(formattedObservations.contains("Would open Messages"))
        #expect(formattedObservations.contains("Would call MCP tool: altic.notes_create"))
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

    @Test func mailtoDraftURLCarriesRecipientsAndSubjectWithoutBody() async throws {
        let mailtoURL = PaceActionExecutor.mailtoDraftURL(
            subject: "Project status & launch",
            resolvedRecipients: ["alex@example.com", "priya@example.com"]
        )

        #expect(mailtoURL?.absoluteString == "mailto:alex@example.com,priya@example.com?subject=Project%20status%20%26%20launch")
    }

    @Test func mailComposeBodyCandidatePrefersLargeBodyAreaOverHeaderFields() async throws {
        let bodyCandidate = PaceMailComposeBodyCandidateMetadata(
            role: "AXTextArea",
            title: nil,
            description: "Message Body",
            help: nil,
            value: nil,
            placeholder: nil,
            frame: CGRect(x: 0, y: 120, width: 680, height: 420)
        )
        let subjectCandidate = PaceMailComposeBodyCandidateMetadata(
            role: "AXTextField",
            title: "Subject:",
            description: nil,
            help: nil,
            value: "Project status",
            placeholder: "Subject",
            frame: CGRect(x: 0, y: 60, width: 680, height: 28)
        )

        #expect(bodyCandidate.score > subjectCandidate.score)
        #expect(subjectCandidate.score < 0)
    }

    @Test func fastKeyCommandsHaveVirtualKeyCodes() async throws {
        #expect(PaceActionExecutor.virtualKeyCode(forKeyName: "a") == 0x00)
        #expect(PaceActionExecutor.virtualKeyCode(forKeyName: "s") == 0x01)
        #expect(PaceActionExecutor.virtualKeyCode(forKeyName: "t") == 0x11)
        #expect(PaceActionExecutor.virtualKeyCode(forKeyName: "w") == 0x0D)
    }

    @Test func shortcutListParsingMatchesInstalledShortcutNamesCaseInsensitively() async throws {
        let installedShortcutNames = PaceActionExecutor.installedShortcutNames(fromListOutput: """

        Morning Brief
          Ship Pace
        Open Raycast

        """)

        #expect(installedShortcutNames == ["Morning Brief", "Ship Pace", "Open Raycast"])
        #expect(PaceActionExecutor.shortcutList(
            installedShortcutNames,
            containsShortcutNamed: "ship pace"
        ))
        #expect(PaceActionExecutor.shortcutList(
            installedShortcutNames,
            containsShortcutNamed: "  Morning   Brief  "
        ))
        #expect(!PaceActionExecutor.shortcutList(
            installedShortcutNames,
            containsShortcutNamed: "Missing Shortcut"
        ))
    }

    @Test func mcpClientRefreshesConfiguredServerNamesFromProvider() async throws {
        final class MutableMCPConfigurationBox {
            var serverConfigurations: [String: PaceMCPServerConfiguration] = [:]
        }

        let configurationBox = MutableMCPConfigurationBox()
        let client = PaceMCPStdioClient(
            serverConfigurationsProvider: {
                configurationBox.serverConfigurations
            },
            requestTimeoutInSeconds: 1
        )

        #expect(client.configuredServerNames == [])

        configurationBox.serverConfigurations = [
            "altic": PaceMCPServerConfiguration(command: "/usr/bin/true")
        ]

        #expect(client.configuredServerNames == ["altic"])
    }

    @Test func clickCandidateSelectorUsesHighConfidenceShortcut() async throws {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 10, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.85,
                    expectStateChange: true
                ),
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 200, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save Draft",
                    confidence: 0.84,
                    expectStateChange: true
                )
            ],
            clickCount: 1
        )

        let selectedCandidate = candidateSet.bestCandidate(
            currentGlobalCursorPoint: CGPoint(x: 200, y: 20),
            screenCaptures: [],
            coordinateConverter: { location, _ in
                CGPoint(x: location.xInScreenshotPixels, y: location.yInScreenshotPixels)
            }
        )

        #expect(selectedCandidate?.location?.xInScreenshotPixels == 10)
    }

    @Test func clickCandidateSelectorUsesCursorProximityWhenConfidenceIsAmbiguous() async throws {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 10, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.7,
                    expectStateChange: true
                ),
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 200, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.65,
                    expectStateChange: true
                )
            ],
            clickCount: 1
        )

        let selectedCandidate = candidateSet.bestCandidate(
            currentGlobalCursorPoint: CGPoint(x: 205, y: 20),
            screenCaptures: [],
            coordinateConverter: { location, _ in
                CGPoint(x: location.xInScreenshotPixels, y: location.yInScreenshotPixels)
            }
        )

        #expect(selectedCandidate?.location?.xInScreenshotPixels == 200)
    }

    @Test func clickCandidateOrderingKeepsFallbackCandidatesAfterBestMatch() async throws {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 20, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.68,
                    expectStateChange: true
                ),
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 210, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.64,
                    expectStateChange: true
                ),
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 400, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.20,
                    expectStateChange: true
                )
            ],
            clickCount: 1
        )

        let orderedCandidates = candidateSet.orderedCandidates(
            currentGlobalCursorPoint: CGPoint(x: 205, y: 20),
            screenCaptures: [],
            coordinateConverter: { location, _ in
                CGPoint(x: location.xInScreenshotPixels, y: location.yInScreenshotPixels)
            }
        )

        #expect(orderedCandidates.compactMap { $0.location?.xInScreenshotPixels } == [210, 20, 400])
    }

    @Test func clickCandidateSelectorUsesRecencyWhenConfidenceIsAmbiguous() async throws {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 10, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.68,
                    expectStateChange: true
                ),
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 300, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.64,
                    expectStateChange: true,
                    recency: PaceClickCandidateRecency(rank: 0, lastSeenMillisecondsAgo: nil)
                )
            ],
            clickCount: 1
        )

        let selectedCandidate = candidateSet.bestCandidate(
            currentGlobalCursorPoint: nil,
            screenCaptures: [],
            coordinateConverter: { location, _ in
                CGPoint(x: location.xInScreenshotPixels, y: location.yInScreenshotPixels)
            }
        )

        #expect(selectedCandidate?.location?.xInScreenshotPixels == 300)
    }

    @Test func clickCandidateSelectorUsesFocusedWindowWhenConfidenceIsAmbiguous() async throws {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 10, yInScreenshotPixels: 20, screenNumber: nil),
                    label: "Save",
                    confidence: 0.70,
                    expectStateChange: true
                ),
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 310, yInScreenshotPixels: 220, screenNumber: nil),
                    label: "Save",
                    confidence: 0.64,
                    expectStateChange: true
                )
            ],
            clickCount: 1
        )

        let selectedCandidate = candidateSet.bestCandidate(
            currentGlobalCursorPoint: nil,
            focusedWindowGlobalFrame: CGRect(x: 250, y: 180, width: 200, height: 140),
            screenCaptures: [],
            coordinateConverter: { location, _ in
                CGPoint(x: location.xInScreenshotPixels, y: location.yInScreenshotPixels)
            }
        )

        #expect(selectedCandidate?.location?.xInScreenshotPixels == 310)
    }

    @Test func clickCandidateExecutionReportsFailureWhenAllCandidatesFail() async throws {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                PaceClickCandidate(
                    location: ScreenshotPixelLocation(xInScreenshotPixels: 10, yInScreenshotPixels: 20, screenNumber: 99),
                    label: "Missing button",
                    confidence: 0.7,
                    expectStateChange: true
                )
            ],
            clickCount: 1
        )

        let observations = await executor.executeActionPlan(
            PaceActionExecutionPlan.serial(actions: [.clickCandidates(candidateSet)]),
            screenCaptures: []
        )

        #expect(observations.count == 1)
        #expect(observations.first?.toolName == "click_candidates")
        #expect(observations.first?.summary.contains("Click failed after trying 1 of 1 candidate") == true)
        #expect(observations.first?.summary.contains("\"Missing button\"") == true)
    }

    @Test func axLabelResolverNormalizesCommonSeparators() async throws {
        #expect(PaceAXLabelPressResolver.normalizeLabel("Save_Draft-now") == "save draft now")
    }
}
