//
//  PaceActionTagParserTypes.swift
//  leanring-buddy
//
//  Extracted from PaceActionExecutor.swift (Wave 6a split): the parsed
//  action DTO types and PaceFastActionCommandParser — the types that
//  PaceActionTagParser produces and the deterministic fast-path parser
//  that bypasses the planner for known no-screen commands.
//

import AppKit
import EventKit
import Foundation

// MARK: - Parsed action types

nonisolated struct PaceActionExecutionObservation {
    let toolName: String
    let summary: String

    static func formatForPlanner(_ observations: [PaceActionExecutionObservation]) -> String {
        observations
            .enumerated()
            .map { index, observation in
                "[\(index + 1)] \(observation.toolName): \(observation.summary)"
            }
            .joined(separator: "\n")
    }

    static func formatForUserFeedback(_ observations: [PaceActionExecutionObservation]) -> String? {
        let userVisibleSummaries = observations
            .map(\.summary)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let firstSummary = userVisibleSummaries.first else {
            return nil
        }

        if userVisibleSummaries.count == 1 {
            return firstSummary
        }

        return "\(firstSummary), plus \(userVisibleSummaries.count - 1) more action result\(userVisibleSummaries.count == 2 ? "" : "s")."
    }
}

nonisolated struct PaceActionExecutionPlan {
    let steps: [PaceActionExecutionStep]

    static func serial(actions: [PaceParsedAction]) -> PaceActionExecutionPlan {
        PaceActionExecutionPlan(
            steps: actions.map { PaceActionExecutionStep(actions: [$0]) }
        )
    }

    var flattenedActions: [PaceParsedAction] {
        steps.flatMap(\.actions)
    }

    var approvalSummary: String {
        steps
            .enumerated()
            .flatMap { stepIndex, step in
                step.actions.enumerated().map { actionIndex, action in
                    let stepLabel = "Step \(stepIndex + 1)"
                    let riskLabel = PaceToolRegistry.riskDisplayName(for: action)
                    if step.actions.count == 1 {
                        return "\(stepLabel): [\(riskLabel)] \(action.approvalDescription)"
                    }
                    return "\(stepLabel).\(actionIndex + 1): [\(riskLabel)] \(action.approvalDescription)"
                }
            }
            .joined(separator: "\n")
    }
}

nonisolated struct PaceActionExecutionStep {
    let actions: [PaceParsedAction]
}

nonisolated enum PaceActionMutation {
    case axValue(element: AXUIElement, oldValue: String, summary: String)
}

/// One action Claude wants pace to perform on the user's behalf.
/// Parsed out of the assistant's response by `PaceActionTagParser`.
nonisolated enum PaceParsedAction {
    case click(ScreenshotPixelLocation)
    case doubleClick(ScreenshotPixelLocation)
    case clickCandidates(PaceClickCandidateSet)
    case type(String)
    case setTextValue(PaceSetTextValueRequest)
    case editSelectedText(PaceVoiceEditRequest)
    case undoLastMutation
    case pressKey(name: String, modifiers: [PaceKeyboardModifier])
    case readClipboard
    case snapWindow(PaceWindowSnapRequest)
    case scroll(PaceScrollDirection, amountInLines: Int)
    case openApplication(String)
    case openURL(String)
    case controlMusic(PaceMusicCommand)
    case adjustVolume(PaceSystemAdjustment)
    case adjustBrightness(PaceSystemAdjustment)
    case listCalendarEvents(PaceCalendarQuery)
    case createCalendarEvent(PaceCalendarEventRequest)
    case createReminder(PaceReminderRequest)
    case finder(PaceFinderRequest)
    case createNote(PaceNoteRequest)
    case appendNote(PaceNoteRequest)
    case searchNotes(String)
    case composeMail(PaceMailDraft)
    case createThingsToDo(PaceThingsToDoRequest)
    case runShortcut(String)
    case openMessages(PaceMessageRequest)
    case downloadFile(PaceFileDownloadRequest)
    case startTimer(PaceTimerRequest)
    case recordFlow(PaceFlowActionRequest)
    case runFlow(PaceFlowActionRequest)
    case mcp(PaceMCPToolCall)

    /// Audit-log operation slug — the verb part. Mirrors the case name.
    var auditOperationName: String {
        switch self {
        case .click: return "click"
        case .doubleClick: return "double_click"
        case .clickCandidates: return "click_candidates"
        case .type: return "type"
        case .setTextValue: return "set_value"
        case .editSelectedText: return "edit_selection"
        case .undoLastMutation: return "undo"
        case .pressKey: return "key_press"
        case .readClipboard: return "clipboard_read"
        case .snapWindow: return "window_snap"
        case .scroll: return "scroll"
        case .openApplication: return "open_app"
        case .openURL: return "open_url"
        case .controlMusic: return "music"
        case .adjustVolume: return "volume"
        case .adjustBrightness: return "brightness"
        case .listCalendarEvents: return "calendar_read"
        case .createCalendarEvent: return "calendar_create"
        case .createReminder: return "reminder_create"
        case .finder: return "finder"
        case .createNote: return "note_create"
        case .appendNote: return "note_append"
        case .searchNotes: return "note_search"
        case .composeMail: return "mail_draft"
        case .createThingsToDo: return "things_create"
        case .runShortcut: return "shortcut_run"
        case .openMessages: return "messages_open"
        case .downloadFile: return "download_file"
        case .startTimer: return "start_timer"
        case .recordFlow: return "record_flow"
        case .runFlow: return "run_flow"
        case .mcp: return "mcp_call"
        }
    }

    /// Audit-log target — the noun: what app, server, or URL the action
    /// touches. Sizes capped so even pathological inputs stay log-safe.
    var auditTarget: String {
        switch self {
        case .openApplication(let appName):
            return appName
        case .openURL(let urlString):
            return String(urlString.prefix(120))
        case .runShortcut(let name):
            return name
        case .openMessages(let request):
            return request.recipient ?? "messages"
        case .composeMail(let draft):
            return draft.recipients.first ?? "mail"
        case .createCalendarEvent(let request):
            return String(request.title.prefix(60))
        case .createReminder(let request):
            return String(request.title.prefix(60))
        case .createNote(let request), .appendNote(let request):
            return String(request.title.prefix(60))
        case .searchNotes(let query):
            return String(query.prefix(60))
        case .createThingsToDo(let request):
            return String(request.title.prefix(60))
        case .finder(let request):
            return String(request.path.prefix(120))
        case .downloadFile(let request):
            return String(request.url.absoluteString.prefix(120))
        case .startTimer(let request):
            return String(request.label.prefix(60))
        case .recordFlow(let request), .runFlow(let request):
            return String(request.name.prefix(80))
        case .mcp(let toolCall):
            return "\(toolCall.serverName).\(toolCall.toolName)"
        case .pressKey(let keyName, let modifiers):
            let modifierPrefix = modifiers.isEmpty
                ? ""
                : modifiers.map(\.rawValue).joined(separator: "+") + "+"
            return "\(modifierPrefix)\(keyName)"
        case .controlMusic(let command):
            return command.rawValue
        case .adjustVolume, .adjustBrightness:
            return auditOperationName
        case .scroll(let direction, _):
            return direction.rawValue
        case .snapWindow(let request):
            return request.position.rawValue
        default:
            return ""
        }
    }

    var approvalDescription: String {
        switch self {
        case .click(let location):
            return "Click at \(location.approvalDescription)"
        case .doubleClick(let location):
            return "Double-click at \(location.approvalDescription)"
        case .clickCandidates(let clickCandidateSet):
            let candidateCount = clickCandidateSet.candidates.count
            if clickCandidateSet.clickCount == 2 {
                return "Double-click best of \(candidateCount) candidates"
            }
            return "Click best of \(candidateCount) candidates"
        case .type(let text):
            return "Type \(text.count) characters"
        case .setTextValue(let setTextValueRequest):
            switch setTextValueRequest.target {
            case .focused:
                return "Set focused text value"
            case .selection:
                return "Replace selected text"
            }
        case .editSelectedText(let voiceEditRequest):
            return "Edit selected text: \(voiceEditRequest.operation.displayName)"
        case .undoLastMutation:
            return "Undo last editable text change"
        case .pressKey(let keyName, let modifiers):
            let modifierPrefix = modifiers.isEmpty
                ? ""
                : modifiers.map(\.rawValue).joined(separator: "+") + "+"
            return "Press \(modifierPrefix)\(keyName)"
        case .readClipboard:
            return "Read clipboard text"
        case .snapWindow(let snapWindowRequest):
            return "Snap focused window: \(snapWindowRequest.position.displayName)"
        case .scroll(let direction, let amountInLines):
            return "Scroll \(direction.rawValue) \(amountInLines) lines"
        case .openApplication(let applicationName):
            return "Open app: \(applicationName)"
        case .openURL(let urlString):
            return "Open URL: \(urlString)"
        case .controlMusic(let musicCommand):
            return "Control Music: \(musicCommand.rawValue)"
        case .adjustVolume(let adjustment):
            return "Adjust volume: \(adjustment.description)"
        case .adjustBrightness(let adjustment):
            return "Adjust brightness: \(adjustment.description)"
        case .listCalendarEvents(let calendarQuery):
            return "Read Calendar: \(calendarQuery.range.displayName)"
        case .createCalendarEvent(let calendarEventRequest):
            return "Create calendar event: \(calendarEventRequest.title)"
        case .createReminder(let reminderRequest):
            return "Create reminder: \(reminderRequest.title)"
        case .finder(let finderRequest):
            return "Finder \(finderRequest.action.rawValue): \(finderRequest.path)"
        case .createNote(let noteRequest):
            let trimmedBody = noteRequest.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBody.isEmpty else {
                return "Create note: \(noteRequest.title)"
            }
            return "Create note: \(noteRequest.title) — \(Self.truncatedForApproval(trimmedBody))"
        case .appendNote(let noteRequest):
            return "Append note: \(noteRequest.title) — \(Self.truncatedForApproval(noteRequest.body))"
        case .searchNotes(let query):
            return "Search notes: \(query)"
        case .composeMail(let mailDraft):
            return "Compose mail draft: \(mailDraft.subject)"
        case .createThingsToDo(let thingsToDoRequest):
            return "Create Things to-do: \(thingsToDoRequest.title)"
        case .runShortcut(let shortcutName):
            return "Run shortcut: \(shortcutName)"
        case .openMessages(let messageRequest):
            if let recipient = messageRequest.recipient, !recipient.isEmpty {
                return "Open Messages for: \(recipient)"
            }
            return "Open Messages"
        case .downloadFile(let downloadRequest):
            return "Download file to ~/Downloads: \(downloadRequest.url.absoluteString)"
        case .startTimer(let timerRequest):
            let durationMinutes = Int((timerRequest.durationInSeconds / 60.0).rounded())
            if durationMinutes >= 1, !timerRequest.label.isEmpty {
                return "Start \(durationMinutes)-minute timer: \(timerRequest.label)"
            }
            if durationMinutes >= 1 {
                return "Start \(durationMinutes)-minute timer"
            }
            return "Start timer for \(Int(timerRequest.durationInSeconds))s"
        case .recordFlow(let flowRequest):
            return "Record flow: \(flowRequest.name)"
        case .runFlow(let flowRequest):
            return "Run recorded flow: \(flowRequest.name)"
        case .mcp(let mcpToolCall):
            return "Call MCP tool: \(mcpToolCall.approvalDescription)"
        }
    }

    private static func truncatedForApproval(_ text: String) -> String {
        let maximumApprovalCharacters = 80
        guard text.count > maximumApprovalCharacters else {
            return text
        }
        let prefix = text.prefix(maximumApprovalCharacters)
        return "\(prefix)…"
    }
}

extension ScreenshotPixelLocation {
    nonisolated var approvalDescription: String {
        let screenSuffix = screenNumber.map { ", screen \($0)" } ?? ""
        return "\(xInScreenshotPixels), \(yInScreenshotPixels)\(screenSuffix)"
    }
}

nonisolated enum PaceKeyboardModifier: String {
    case command, option, control, shift
}

nonisolated struct PaceWindowSnapRequest {
    let position: PaceWindowSnapPosition
}

nonisolated enum PaceWindowSnapPosition: String {
    case left
    case right
    case top
    case bottom
    case maximize
    case center

    var displayName: String {
        switch self {
        case .left:
            return "left half"
        case .right:
            return "right half"
        case .top:
            return "top half"
        case .bottom:
            return "bottom half"
        case .maximize:
            return "maximize"
        case .center:
            return "center"
        }
    }

    func targetFrame(in visibleFrame: CGRect) -> CGRect {
        switch self {
        case .left:
            return CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width / 2,
                height: visibleFrame.height
            )
        case .right:
            return CGRect(
                x: visibleFrame.midX,
                y: visibleFrame.minY,
                width: visibleFrame.width / 2,
                height: visibleFrame.height
            )
        case .top:
            return CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width,
                height: visibleFrame.height / 2
            )
        case .bottom:
            return CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.midY,
                width: visibleFrame.width,
                height: visibleFrame.height / 2
            )
        case .maximize:
            return visibleFrame
        case .center:
            let width = visibleFrame.width * 0.8
            let height = visibleFrame.height * 0.85
            return CGRect(
                x: visibleFrame.midX - (width / 2),
                y: visibleFrame.midY - (height / 2),
                width: width,
                height: height
            )
        }
    }
}

nonisolated struct PaceSetTextValueRequest {
    let value: String
    let target: PaceSetTextValueTarget
}

nonisolated enum PaceSetTextValueTarget: String {
    case focused
    case selection

    var dryRunVerb: String {
        switch self {
        case .focused:
            return "set focused text to"
        case .selection:
            return "replace selected text with"
        }
    }
}

nonisolated enum PaceScrollDirection: String, CustomStringConvertible {
    case up, down

    var description: String { rawValue }
}

nonisolated struct PaceSystemAdjustment: CustomStringConvertible {
    let direction: PaceAdjustmentDirection
    let stepCount: Int

    var description: String {
        "\(direction.rawValue):\(stepCount)"
    }
}

nonisolated enum PaceAdjustmentDirection: String {
    case up, down
}

nonisolated enum PaceMusicCommand: String, Equatable {
    case play
    case pause
    case playPause
    case next
    case previous
}

nonisolated struct PaceCalendarQuery {
    let range: PaceCalendarRange

    func dateInterval(relativeTo date: Date) -> DateInterval {
        let calendar = Calendar.current
        switch range {
        case .today:
            let startOfToday = calendar.startOfDay(for: date)
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? date
            return DateInterval(start: startOfToday, end: endOfToday)
        case .tomorrow:
            let startOfToday = calendar.startOfDay(for: date)
            let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? date
            let endOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfTomorrow) ?? startOfTomorrow
            return DateInterval(start: startOfTomorrow, end: endOfTomorrow)
        case .week:
            let endOfRange = calendar.date(byAdding: .day, value: 7, to: date) ?? date
            return DateInterval(start: date, end: endOfRange)
        }
    }
}

nonisolated struct PaceCalendarEventRequest {
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let notes: String?
    let location: String?
    let calendarTitle: String?

    var displaySummary: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = isAllDay ? .none : .short

        let timeSummary: String
        if isAllDay {
            timeSummary = formatter.string(from: startDate)
        } else {
            timeSummary = "\(formatter.string(from: startDate)) - \(formatter.string(from: endDate))"
        }

        return "\(title) (\(timeSummary))"
    }
}

nonisolated enum PaceCalendarRange: String, Equatable {
    case today
    case tomorrow
    case week

    var displayName: String {
        switch self {
        case .today: return "today"
        case .tomorrow: return "tomorrow"
        case .week: return "the next 7 days"
        }
    }
}

nonisolated struct PaceReminderRequest {
    let title: String
    let notes: String?
}

nonisolated struct PaceTimerRequest {
    let label: String
    let durationInSeconds: TimeInterval
}

nonisolated struct PaceFlowActionRequest {
    let name: String
}

nonisolated struct PaceFinderRequest {
    let path: String
    let action: PaceFinderAction
}

nonisolated enum PaceFinderAction: String, Equatable {
    case open
    case reveal
}

nonisolated struct PaceNoteRequest {
    let title: String
    let body: String
}

nonisolated struct PaceMailDraft {
    let recipients: [String]
    let subject: String
    let body: String
}

nonisolated struct PaceStreamingMailDraftState {
    let lastWrittenSnapshot: PaceStreamingMailDraftSnapshot
    let pendingSnapshot: PaceStreamingMailDraftSnapshot?
    let lastWriteDate: Date

    func withPendingSnapshot(
        _ pendingSnapshot: PaceStreamingMailDraftSnapshot
    ) -> PaceStreamingMailDraftState {
        PaceStreamingMailDraftState(
            lastWrittenSnapshot: lastWrittenSnapshot,
            pendingSnapshot: pendingSnapshot,
            lastWriteDate: lastWriteDate
        )
    }
}

nonisolated struct PaceThingsToDoRequest {
    let title: String
    let notes: String?
}

nonisolated struct PaceMessageRequest {
    let recipient: String?
    let text: String?
}

// MARK: - Action tag parser

/// Result of pulling all action tags out of Claude's response.
nonisolated struct PaceActionTagParseResult {
    /// The assistant text with every recognised action tag stripped.
    /// Safe to feed to TTS.
    let spokenText: String
    /// The parsed actions, in the order they appeared in the response.
    let actions: [PaceParsedAction]
    /// Grouped tool-call plan. Outer steps run sequentially; actions
    /// within one step are the model's requested parallel group.
    let executionPlan: PaceActionExecutionPlan
    /// The first click/double-click coordinate, if any — used by the
    /// existing cursor-flight visualization so the user sees pace
    /// move to the target before it executes.
    let firstClickVisualisationLocation: ScreenshotPixelLocation?
}

nonisolated struct PaceFastActionParseResult {
    let spokenText: String
    let executionPlan: PaceActionExecutionPlan
}

/// Deterministic parser for no-screen, no-reasoning commands that are common
/// enough to execute without burning a VLM/planner turn. It intentionally
/// avoids clicks, typing, scrolling, and open-ended app names; those stay on
/// the normal planner path where screen context and approval copy are richer.
nonisolated enum PaceFastActionCommandParser {
    private static let knownApplicationAliases: [String: String] = [
        "apple music": "Music",
        "arc": "Arc",
        "calendar": "Calendar",
        "chrome": "Google Chrome",
        "cursor": "Cursor",
        "discord": "Discord",
        "facetime": "FaceTime",
        "figma": "Figma",
        "finder": "Finder",
        "firefox": "Firefox",
        "google chrome": "Google Chrome",
        "iterm": "iTerm",
        "iterm2": "iTerm",
        "linear": "Linear",
        "mail": "Mail",
        "messages": "Messages",
        "music": "Music",
        "notes": "Notes",
        "notion": "Notion",
        "obsidian": "Obsidian",
        "photos": "Photos",
        "preview": "Preview",
        "raycast": "Raycast",
        "reminders": "Reminders",
        "safari": "Safari",
        "settings": "System Settings",
        "slack": "Slack",
        "spotify": "Spotify",
        "system settings": "System Settings",
        "terminal": "Terminal",
        "visual studio code": "Visual Studio Code",
        "vs code": "Visual Studio Code",
        "vscode": "Visual Studio Code",
        "xcode": "Xcode",
        "zoom": "zoom.us"
    ]

    static func parse(transcript: String) -> PaceFastActionParseResult? {
        let normalizedTranscript = normalizeTranscript(transcript)
        guard !normalizedTranscript.isEmpty else { return nil }

        if let musicCommand = parseMusicCommand(from: normalizedTranscript) {
            let spokenText = spokenTextForMusicCommand(musicCommand)
            return PaceFastActionParseResult(
                spokenText: spokenText,
                executionPlan: .serial(actions: [.controlMusic(musicCommand)])
            )
        }

        if isUndoCommand(normalizedTranscript) {
            return PaceFastActionParseResult(
                spokenText: "undoing that.",
                executionPlan: .serial(actions: [.undoLastMutation])
            )
        }

        if let voiceEditRequest = PaceVoiceEditProcessor.parseCommand(normalizedTranscript) {
            return PaceFastActionParseResult(
                spokenText: "editing selection.",
                executionPlan: .serial(actions: [.editSelectedText(voiceEditRequest)])
            )
        }

        if let keyPress = parseKeyPressCommand(from: normalizedTranscript) {
            return PaceFastActionParseResult(
                spokenText: keyPress.spokenText,
                executionPlan: .serial(actions: [.pressKey(name: keyPress.keyName, modifiers: keyPress.modifiers)])
            )
        }

        if let snapWindowRequest = parseWindowSnapCommand(from: normalizedTranscript) {
            return PaceFastActionParseResult(
                spokenText: "moving the window.",
                executionPlan: .serial(actions: [.snapWindow(snapWindowRequest)])
            )
        }

        if let messageRequest = parseOpenMessagesCommand(from: normalizedTranscript) {
            return PaceFastActionParseResult(
                spokenText: messageRequest.recipient?.isEmpty == false
                    ? "opening Messages for \(messageRequest.recipient!)."
                    : "opening Messages.",
                executionPlan: .serial(actions: [.openMessages(messageRequest)])
            )
        }

        if let volumeAdjustment = parseSystemAdjustment(
            from: normalizedTranscript,
            noun: "volume"
        ) {
            return PaceFastActionParseResult(
                spokenText: "adjusting volume.",
                executionPlan: .serial(actions: [.adjustVolume(volumeAdjustment)])
            )
        }

        if let brightnessAdjustment = parseSystemAdjustment(
            from: normalizedTranscript,
            noun: "brightness"
        ) {
            return PaceFastActionParseResult(
                spokenText: "adjusting brightness.",
                executionPlan: .serial(actions: [.adjustBrightness(brightnessAdjustment)])
            )
        }

        if let urlString = parseURLCommand(from: normalizedTranscript) {
            return PaceFastActionParseResult(
                spokenText: "opening \(displayNameForOpenedURL(urlString)).",
                executionPlan: .serial(actions: [.openURL(urlString)])
            )
        }

        if let applicationName = parseKnownApplicationCommand(from: normalizedTranscript) {
            return PaceFastActionParseResult(
                spokenText: "opening \(applicationName).",
                executionPlan: .serial(actions: [.openApplication(applicationName)])
            )
        }

        return nil
    }

    private static func normalizeTranscript(_ transcript: String) -> String {
        var normalizedTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        for wakePrefix in ["hey pace ", "pace ", "ok pace ", "okay pace "] {
            if normalizedTranscript.hasPrefix(wakePrefix) {
                normalizedTranscript.removeFirst(wakePrefix.count)
                break
            }
        }

        return normalizedTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
    }

    private static func isUndoCommand(_ normalizedTranscript: String) -> Bool {
        switch normalizedTranscript {
        case "undo that", "undo last", "undo the last thing", "revert that", "revert last", "change it back":
            return true
        default:
            return false
        }
    }

    private struct FastKeyPressCommand {
        let keyName: String
        let modifiers: [PaceKeyboardModifier]
        let spokenText: String
    }

    private static func parseKeyPressCommand(from normalizedTranscript: String) -> FastKeyPressCommand? {
        switch normalizedTranscript {
        case "save", "save this", "save file", "save the file", "press command s", "press cmd s", "command s", "cmd s", "hit command s":
            return FastKeyPressCommand(
                keyName: "s",
                modifiers: [.command],
                spokenText: "saving."
            )
        case "new tab", "open new tab", "open a new tab", "press command t", "press cmd t", "command t", "cmd t":
            return FastKeyPressCommand(
                keyName: "t",
                modifiers: [.command],
                spokenText: "opening a new tab."
            )
        case "close tab", "close this tab", "close the tab", "press command w", "press cmd w", "command w", "cmd w":
            return FastKeyPressCommand(
                keyName: "w",
                modifiers: [.command],
                spokenText: "closing the tab."
            )
        case "reopen closed tab", "reopen the closed tab", "reopen last closed tab", "press command shift t", "press cmd shift t", "command shift t", "cmd shift t":
            return FastKeyPressCommand(
                keyName: "t",
                modifiers: [.command, .shift],
                spokenText: "reopening the tab."
            )
        default:
            return nil
        }
    }

    private static func parseWindowSnapCommand(from normalizedTranscript: String) -> PaceWindowSnapRequest? {
        let position: PaceWindowSnapPosition
        switch normalizedTranscript {
        case "snap window left", "move window left", "put window left", "put the window left", "move the window left", "snap the window left", "resize window left", "left half window", "window left half":
            position = .left
        case "snap window right", "move window right", "put window right", "put the window right", "move the window right", "snap the window right", "resize window right", "right half window", "window right half":
            position = .right
        case "snap window top", "move window top", "put window top", "put the window top", "move the window top", "snap the window top", "top half window", "window top half":
            position = .top
        case "snap window bottom", "move window bottom", "put window bottom", "put the window bottom", "move the window bottom", "snap the window bottom", "bottom half window", "window bottom half":
            position = .bottom
        case "maximize window", "maximize the window", "make window full size", "make the window full size":
            position = .maximize
        case "center window", "center the window", "move window center", "move the window center":
            position = .center
        default:
            return nil
        }

        return PaceWindowSnapRequest(position: position)
    }

    private static func parseOpenMessagesCommand(from normalizedTranscript: String) -> PaceMessageRequest? {
        guard !messageCommandContainsBodyOrSendIntent(normalizedTranscript) else { return nil }

        if normalizedTranscript == "open messages"
            || normalizedTranscript == "open messages app"
            || normalizedTranscript == "launch messages" {
            return PaceMessageRequest(recipient: nil, text: nil)
        }

        let recipientPrefixes = [
            "open messages to ",
            "open message to ",
            "open messages with ",
            "open message with ",
            "message "
        ]

        for recipientPrefix in recipientPrefixes {
            guard normalizedTranscript.hasPrefix(recipientPrefix) else { continue }
            let rawRecipientName = String(normalizedTranscript.dropFirst(recipientPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let recipientName = normalizedRecipientName(rawRecipientName) else { return nil }
            return PaceMessageRequest(recipient: recipientName, text: nil)
        }

        return nil
    }

    private static func messageCommandContainsBodyOrSendIntent(_ normalizedTranscript: String) -> Bool {
        let blockedFragments = [
            " saying ",
            " say ",
            " that ",
            " telling ",
            " tell ",
            " about ",
            " with text ",
            " body ",
            "send message",
            "send a message",
            "text "
        ]
        return blockedFragments.contains { normalizedTranscript.contains($0) }
    }

    private static func normalizedRecipientName(_ rawRecipientName: String) -> String? {
        guard !rawRecipientName.isEmpty else { return nil }
        guard rawRecipientName.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\{}[]<>")) == nil else {
            return nil
        }

        let words = rawRecipientName
            .split(separator: " ")
            .map { word in
                let lowercasedWord = word.lowercased()
                guard let firstCharacter = lowercasedWord.first else { return "" }
                return firstCharacter.uppercased() + lowercasedWord.dropFirst()
            }
        let recipientName = words.joined(separator: " ")
        return recipientName.isEmpty ? nil : recipientName
    }

    private static func parseMusicCommand(from normalizedTranscript: String) -> PaceMusicCommand? {
        switch normalizedTranscript {
        case "play music", "start music", "resume music", "play the music":
            return .play
        case "pause music", "stop music", "pause the music":
            return .pause
        case "toggle music", "play pause music", "play or pause music":
            return .playPause
        case "next song", "next track", "skip song", "skip track", "music next":
            return .next
        case "previous song", "previous track", "last song", "last track", "music previous":
            return .previous
        default:
            return nil
        }
    }

    private static func spokenTextForMusicCommand(_ musicCommand: PaceMusicCommand) -> String {
        switch musicCommand {
        case .play:
            return "playing music."
        case .pause:
            return "pausing music."
        case .playPause:
            return "toggling music."
        case .next:
            return "skipping ahead."
        case .previous:
            return "going back."
        }
    }

    private static func parseSystemAdjustment(
        from normalizedTranscript: String,
        noun: String
    ) -> PaceSystemAdjustment? {
        let direction: PaceAdjustmentDirection
        if normalizedTranscript == "\(noun) up"
            || normalizedTranscript == "turn \(noun) up"
            || normalizedTranscript == "turn the \(noun) up"
            || normalizedTranscript == "increase \(noun)"
            || normalizedTranscript == "raise \(noun)"
            || normalizedTranscript == "make \(noun) louder"
            || normalizedTranscript == "make the \(noun) louder"
            || normalizedTranscript.hasPrefix("\(noun) up ")
            || normalizedTranscript.hasPrefix("turn \(noun) up ")
            || normalizedTranscript.hasPrefix("turn the \(noun) up ") {
            direction = .up
        } else if normalizedTranscript == "\(noun) down"
            || normalizedTranscript == "turn \(noun) down"
            || normalizedTranscript == "turn the \(noun) down"
            || normalizedTranscript == "decrease \(noun)"
            || normalizedTranscript == "lower \(noun)"
            || normalizedTranscript == "make \(noun) quieter"
            || normalizedTranscript == "make the \(noun) quieter"
            || normalizedTranscript.hasPrefix("\(noun) down ")
            || normalizedTranscript.hasPrefix("turn \(noun) down ")
            || normalizedTranscript.hasPrefix("turn the \(noun) down ") {
            direction = .down
        } else {
            return nil
        }

        return PaceSystemAdjustment(
            direction: direction,
            stepCount: parseStepCount(from: normalizedTranscript)
        )
    }

    private static func parseStepCount(from normalizedTranscript: String) -> Int {
        let tokens = normalizedTranscript
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        guard let requestedStepCount = tokens.first else { return 2 }
        return max(1, min(requestedStepCount, 10))
    }

    /// Popular web destinations addressable by spoken name. Lets
    /// "open hacker news on chrome" resolve to a URL on the deterministic
    /// fast path (sub-200ms, no VLM, no planner) instead of a multi-second
    /// VLM+planner turn. Only unambiguous WEB destinations belong here —
    /// names that clash with local apps (Music, Maps, Calendar) stay out so
    /// they route to app-launch instead.
    private static let knownWebsiteAliases: [String: String] = [
        "hacker news": "https://news.ycombinator.com",
        "hackernews": "https://news.ycombinator.com",
        "hn": "https://news.ycombinator.com",
        "github": "https://github.com",
        "youtube": "https://youtube.com",
        "gmail": "https://mail.google.com",
        "google": "https://google.com",
        "reddit": "https://reddit.com",
        "twitter": "https://x.com",
        "x": "https://x.com",
        "linkedin": "https://linkedin.com",
        "chatgpt": "https://chatgpt.com",
        "claude": "https://claude.ai",
        "amazon": "https://amazon.com",
        "netflix": "https://netflix.com",
        "wikipedia": "https://wikipedia.org",
        "stack overflow": "https://stackoverflow.com",
        "stackoverflow": "https://stackoverflow.com",
        "product hunt": "https://producthunt.com"
    ]

    private static func parseURLCommand(from normalizedTranscript: String) -> String? {
        for prefix in ["open ", "go to ", "visit ", "navigate to "] {
            guard normalizedTranscript.hasPrefix(prefix) else { continue }
            let rawURLTarget = strippingBrowserSuffix(
                from: String(normalizedTranscript.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            // 1. A literal URL ("github.com", "https://…").
            if let directURL = normalizedURLString(from: rawURLTarget) {
                return directURL
            }
            // 2. A spoken site name ("hacker news", "github").
            if let mappedSiteURL = knownWebsiteAliases[rawURLTarget] {
                return mappedSiteURL
            }
            return nil
        }
        return nil
    }

    /// Drops a trailing " on/in/using <browser>" so "open hacker news on
    /// chrome" → "hacker news". Pace opens URLs in the user's preferred
    /// browser, so the specific browser name is best-effort, not binding.
    private static func strippingBrowserSuffix(from target: String) -> String {
        let browserNames: Set<String> = [
            "chrome", "google chrome", "safari", "arc", "firefox",
            "edge", "brave", "the browser", "my browser", "browser"
        ]
        for connector in [" on ", " in ", " using "] {
            guard let connectorRange = target.range(of: connector, options: .backwards) else {
                continue
            }
            let suffix = String(target[connectorRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if browserNames.contains(suffix) {
                return String(target[..<connectorRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return target
    }

    private static func normalizedURLString(from rawURLTarget: String) -> String? {
        guard !rawURLTarget.isEmpty, !rawURLTarget.contains(" ") else { return nil }
        if rawURLTarget.hasPrefix("http://") || rawURLTarget.hasPrefix("https://") {
            return rawURLTarget
        }
        guard rawURLTarget.contains(".") else { return nil }
        return "https://\(rawURLTarget)"
    }

    /// Proper-cased product names so Pace says "opening Hacker News" rather
    /// than reading the raw URL aloud. Keyed by host (sans "www.").
    private static let websiteDisplayNames: [String: String] = [
        "news.ycombinator.com": "Hacker News",
        "github.com": "GitHub",
        "youtube.com": "YouTube",
        "mail.google.com": "Gmail",
        "google.com": "Google",
        "reddit.com": "Reddit",
        "x.com": "X",
        "twitter.com": "X",
        "linkedin.com": "LinkedIn",
        "chatgpt.com": "ChatGPT",
        "claude.ai": "Claude",
        "amazon.com": "Amazon",
        "netflix.com": "Netflix",
        "wikipedia.org": "Wikipedia",
        "stackoverflow.com": "Stack Overflow",
        "producthunt.com": "Product Hunt"
    ]

    /// A speakable name for an opened URL: the curated product name when the
    /// host is known, otherwise the main domain label capitalized
    /// ("example.com" → "Example"). Never reads the full URL aloud.
    private static func displayNameForOpenedURL(_ urlString: String) -> String {
        guard let host = URL(string: urlString)?.host?.lowercased() else {
            return urlString
        }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let curatedName = websiteDisplayNames[normalizedHost] {
            return curatedName
        }
        let hostLabels = normalizedHost.split(separator: ".")
        guard hostLabels.count >= 2 else { return normalizedHost }
        let mainLabel = String(hostLabels[hostLabels.count - 2])
        return mainLabel.prefix(1).uppercased() + mainLabel.dropFirst()
    }

    private static func parseKnownApplicationCommand(from normalizedTranscript: String) -> String? {
        let candidateApplicationName: String?
        if normalizedTranscript.hasPrefix("open app ") {
            candidateApplicationName = String(normalizedTranscript.dropFirst("open app ".count))
        } else if normalizedTranscript.hasPrefix("open application ") {
            candidateApplicationName = String(normalizedTranscript.dropFirst("open application ".count))
        } else if normalizedTranscript.hasPrefix("open ") {
            candidateApplicationName = String(normalizedTranscript.dropFirst("open ".count))
        } else if normalizedTranscript.hasPrefix("launch ") {
            candidateApplicationName = String(normalizedTranscript.dropFirst("launch ".count))
        } else if normalizedTranscript.hasPrefix("start ") {
            candidateApplicationName = String(normalizedTranscript.dropFirst("start ".count))
        } else {
            candidateApplicationName = nil
        }

        guard let candidateApplicationName else { return nil }
        let normalizedCandidate = candidateApplicationName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return knownApplicationAliases[normalizedCandidate]
    }
}
