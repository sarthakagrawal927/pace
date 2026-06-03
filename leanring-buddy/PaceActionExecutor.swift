//
//  PaceActionExecutor.swift
//  leanring-buddy
//
//  Executes mouse and keyboard actions on the user's behalf via
//  CGEvent. This is the layer that turns pace from a pointer into an
//  agent: it actually clicks, types, and presses keys.
//
//  All actions are gated by `EnableActions` in Info.plist. When the
//  flag is off, every method here becomes a no-op and we log instead.
//  When it's on, we still introduce small inter-action delays so the
//  target app has time to respond to focus / hover / key-down state
//  changes — without these, fast multi-step sequences race the UI.
//

import AppKit
import CoreGraphics
import EventKit
import Foundation

/// A single mouse position expressed in *screenshot pixel space*. The
/// executor converts to display-points and CG global coords internally
/// using the same screen-capture metadata the pointing layer uses, so
/// callers never need to think about coordinate spaces.
struct ScreenshotPixelLocation {
    let xInScreenshotPixels: Int
    let yInScreenshotPixels: Int
    /// 1-based screen index from the screenshot label. nil = cursor screen.
    let screenNumber: Int?
}

@MainActor
final class PaceActionExecutor {
    /// Read from Info.plist at construction so a release build with the
    /// flag set false is guaranteed not to execute anything.
    let actionsAreEnabled: Bool

    /// Delay between consecutive actions when a single planner response
    /// chains several (e.g. click then type). Gives the focused app
    /// time to accept input. 75ms is the smallest reliable value across
    /// the common macOS apps tested during development.
    private let interActionDelay: TimeInterval = 0.075

    /// Hybrid targeter that tries the accessibility tree first before
    /// falling back to raw CGEvent clicks. Single-click only — double-
    /// click and drag still go through CGEvent because AX doesn't have
    /// a built-in "double-press" action.
    private let axTargeter = PaceAXTargeter()
    private let eventStore = EKEventStore()

    init(actionsAreEnabledOverride: Bool? = nil) {
        if let actionsAreEnabledOverride {
            self.actionsAreEnabled = actionsAreEnabledOverride
        } else {
            let rawFlag = AppBundleConfiguration.stringValue(forKey: "EnableActions")?.lowercased()
            self.actionsAreEnabled = (rawFlag == "true" || rawFlag == "1" || rawFlag == "yes")
        }
        if actionsAreEnabled {
            print("🤖 PaceActionExecutor: actions ENABLED — real clicks and keystrokes will be sent")
        } else {
            print("🤖 PaceActionExecutor: actions DISABLED (Info.plist EnableActions != true) — dry-run only")
        }
    }

    // MARK: - High-level entry point

    /// Executes a serial sequence of actions parsed from legacy inline tags.
    /// Kept as a compatibility wrapper around the richer tool-plan shape.
    @discardableResult
    func executeActionSequence(
        _ actions: [PaceParsedAction],
        screenCaptures: [CompanionScreenCapture]
    ) async -> [PaceActionExecutionObservation] {
        await executeActionPlan(
            PaceActionExecutionPlan.serial(actions: actions),
            screenCaptures: screenCaptures
        )
    }

    /// Executes a tool plan: outer steps are sequential; actions within one
    /// step are a parallel group at the planner contract level. UI-mutating
    /// actions still run in source order because macOS focus/cursor state is
    /// global and not safe to mutate concurrently.
    @discardableResult
    func executeActionPlan(
        _ actionExecutionPlan: PaceActionExecutionPlan,
        screenCaptures: [CompanionScreenCapture]
    ) async -> [PaceActionExecutionObservation] {
        guard !actionExecutionPlan.steps.isEmpty else { return [] }

        var observations: [PaceActionExecutionObservation] = []

        for (stepIndex, step) in actionExecutionPlan.steps.enumerated() {
            guard !step.actions.isEmpty else { continue }

            for (actionIndex, action) in step.actions.enumerated() {
                if let observation = await executeSingleAction(action, screenCaptures: screenCaptures) {
                    observations.append(observation)
                }

                let isLastActionInStep = (actionIndex == step.actions.count - 1)
                if !isLastActionInStep {
                    try? await Task.sleep(nanoseconds: UInt64(interActionDelay * 1_000_000_000))
                }
            }

            let isLastStep = (stepIndex == actionExecutionPlan.steps.count - 1)
            if !isLastStep {
                try? await Task.sleep(nanoseconds: UInt64(interActionDelay * 1_000_000_000))
            }
        }

        return observations
    }

    private func executeSingleAction(
        _ action: PaceParsedAction,
        screenCaptures: [CompanionScreenCapture]
    ) async -> PaceActionExecutionObservation? {
        switch action {
        case .click(let location):
            await clickAtScreenshotLocation(location, screenCaptures: screenCaptures, clickCount: 1)
        case .doubleClick(let location):
            await clickAtScreenshotLocation(location, screenCaptures: screenCaptures, clickCount: 2)
        case .type(let textToType):
            await typeText(textToType)
        case .pressKey(let keyName, let modifiers):
            await pressKey(named: keyName, withModifiers: modifiers)
        case .scroll(let direction, let amount):
            await scroll(direction: direction, amountInLines: amount)
        case .openApplication(let applicationName):
            return await openApplication(named: applicationName)
        case .openURL(let urlString):
            return await openURL(urlString)
        case .controlMusic(let musicCommand):
            return await controlMusic(musicCommand)
        case .adjustVolume(let adjustment):
            await adjustVolume(adjustment)
        case .adjustBrightness(let adjustment):
            await adjustBrightness(adjustment)
        case .listCalendarEvents(let calendarQuery):
            return await listCalendarEvents(calendarQuery)
        case .createReminder(let reminderRequest):
            return await createReminder(reminderRequest)
        case .finder(let finderRequest):
            return await performFinderRequest(finderRequest)
        case .createNote(let noteRequest):
            return await createNote(noteRequest)
        case .appendNote(let noteRequest):
            return await appendNote(noteRequest)
        case .searchNotes(let query):
            return await searchNotes(query: query)
        case .composeMail(let mailDraft):
            return await composeMail(mailDraft)
        case .createThingsToDo(let thingsToDoRequest):
            return await createThingsToDo(thingsToDoRequest)
        case .runShortcut(let shortcutName):
            return await runShortcut(named: shortcutName)
        case .openMessages(let messageRequest):
            return await openMessages(messageRequest)
        }

        return nil
    }

    // MARK: - Mouse

    private func clickAtScreenshotLocation(
        _ screenshotPixelLocation: ScreenshotPixelLocation,
        screenCaptures: [CompanionScreenCapture],
        clickCount: Int
    ) async {
        guard let displayGlobalPoint = convertScreenshotPixelToDisplayGlobalPoint(
            screenshotPixelLocation: screenshotPixelLocation,
            screenCaptures: screenCaptures
        ) else {
            print("⚠️ PaceActionExecutor: could not resolve display coordinates for click — skipping")
            return
        }

        print("🖱️  Click x\(clickCount) at \(Int(displayGlobalPoint.x)),\(Int(displayGlobalPoint.y)) (enabled: \(actionsAreEnabled))")

        guard actionsAreEnabled else { return }

        // Try the AX path first for single clicks. If AX finds a
        // pressable element and the press succeeds, we skip the CGEvent
        // path entirely — it's more robust against layout shifts and
        // synthesises a semantically correct activation event.
        // Double-clicks still go through CGEvent because AX has no
        // "double-press" primitive.
        if clickCount == 1, axTargeter.tryClickViaAccessibility(atGlobalCGPoint: displayGlobalPoint) {
            return
        }

        // Move the system cursor first so the visual position matches the
        // synthetic click and so any hover state (tooltips, menu reveals)
        // settles before the click lands.
        let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: displayGlobalPoint,
            mouseButton: .left
        )
        moveEvent?.post(tap: .cghidEventTap)

        try? await Task.sleep(nanoseconds: 30_000_000) // 30ms hover settle

        for clickIndex in 0..<clickCount {
            let downEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: displayGlobalPoint,
                mouseButton: .left
            )
            downEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex + 1))
            downEvent?.post(tap: .cghidEventTap)

            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms hold

            let upEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: displayGlobalPoint,
                mouseButton: .left
            )
            upEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex + 1))
            upEvent?.post(tap: .cghidEventTap)

            if clickIndex < clickCount - 1 {
                try? await Task.sleep(nanoseconds: 40_000_000) // 40ms between clicks of a double-click
            }
        }
    }

    private func scroll(direction: PaceScrollDirection, amountInLines: Int) async {
        print("🖱️  Scroll \(direction) by \(amountInLines) lines (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else { return }

        let verticalDelta: Int32 = {
            switch direction {
            case .up: return Int32(amountInLines)
            case .down: return -Int32(amountInLines)
            }
        }()

        if let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: verticalDelta,
            wheel2: 0,
            wheel3: 0
        ) {
            scrollEvent.post(tap: .cghidEventTap)
        }
    }

    // MARK: - System tools

    @discardableResult
    private func openApplication(named applicationName: String) async -> PaceActionExecutionObservation {
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

    private func openURL(_ rawURLString: String) async -> PaceActionExecutionObservation {
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

    private func controlMusic(_ musicCommand: PaceMusicCommand) async -> PaceActionExecutionObservation {
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

    private func adjustVolume(_ adjustment: PaceSystemAdjustment) async {
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

    private func adjustBrightness(_ adjustment: PaceSystemAdjustment) async {
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

    private func listCalendarEvents(_ calendarQuery: PaceCalendarQuery) async -> PaceActionExecutionObservation {
        print("🧰 Calendar list \(calendarQuery.range.rawValue) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "calendar",
                summary: "Would list calendar events for \(calendarQuery.range.displayName)."
            )
        }

        guard await requestCalendarAccessIfNeeded() else {
            return PaceActionExecutionObservation(
                toolName: "calendar",
                summary: "Calendar access was not granted."
            )
        }

        let now = Date()
        let dateInterval = calendarQuery.dateInterval(relativeTo: now)
        let predicate = eventStore.predicateForEvents(
            withStart: dateInterval.start,
            end: dateInterval.end,
            calendars: nil
        )
        let matchingEvents = eventStore.events(matching: predicate)
            .filter { $0.endDate >= now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(12)

        guard !matchingEvents.isEmpty else {
            return PaceActionExecutionObservation(
                toolName: "calendar",
                summary: "No calendar events found for \(calendarQuery.range.displayName)."
            )
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let eventSummaries = matchingEvents.map { event in
            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeTitle = title?.isEmpty == false ? title! : "Untitled event"
            let locationSuffix: String = {
                guard let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !location.isEmpty else {
                    return ""
                }
                return " at \(location)"
            }()
            return "\(formatter.string(from: event.startDate)): \(safeTitle)\(locationSuffix)"
        }

        return PaceActionExecutionObservation(
            toolName: "calendar",
            summary: "Calendar events for \(calendarQuery.range.displayName):\n" + eventSummaries.joined(separator: "\n")
        )
    }

    private func createReminder(_ reminderRequest: PaceReminderRequest) async -> PaceActionExecutionObservation {
        print("🧰 Create reminder \"\(reminderRequest.title)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Would create reminder: \(reminderRequest.title)"
            )
        }

        guard await requestReminderAccessIfNeeded() else {
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Reminder access was not granted."
            )
        }

        guard let reminderCalendar = eventStore.defaultCalendarForNewReminders() else {
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Could not find a default reminders list."
            )
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = reminderCalendar
        reminder.title = reminderRequest.title
        reminder.notes = reminderRequest.notes

        do {
            try eventStore.save(reminder, commit: true)
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Created reminder: \(reminderRequest.title)"
            )
        } catch {
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Failed to create reminder: \(error.localizedDescription)"
            )
        }
    }

    private func performFinderRequest(_ finderRequest: PaceFinderRequest) async -> PaceActionExecutionObservation {
        let expandedPath = NSString(string: finderRequest.path).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath)
        print("🧰 Finder \(finderRequest.action.rawValue) \"\(expandedPath)\" (enabled: \(actionsAreEnabled))")

        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "finder",
                summary: "Would \(finderRequest.action.rawValue) path: \(expandedPath)"
            )
        }

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return PaceActionExecutionObservation(
                toolName: "finder",
                summary: "Path does not exist: \(expandedPath)"
            )
        }

        switch finderRequest.action {
        case .open:
            let didOpen = NSWorkspace.shared.open(fileURL)
            return PaceActionExecutionObservation(
                toolName: "finder",
                summary: didOpen ? "Opened path: \(expandedPath)" : "Failed to open path: \(expandedPath)"
            )
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return PaceActionExecutionObservation(
                toolName: "finder",
                summary: "Revealed path in Finder: \(expandedPath)"
            )
        }
    }

    private func createNote(_ noteRequest: PaceNoteRequest) async -> PaceActionExecutionObservation {
        print("🧰 Notes create \"\(noteRequest.title)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "Would create note: \(noteRequest.title)"
            )
        }

        await openApplication(named: "Notes")
        let scriptResult = runAppleScript(source: """
        tell application "Notes"
            activate
            make new note at default account with properties {name:"\(Self.appleScriptEscaped(noteRequest.title))", body:"\(Self.appleScriptEscaped(noteRequest.body))"}
        end tell
        """)

        if let errorDescription = scriptResult.errorDescription {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "Failed to create note: \(errorDescription)"
            )
        }

        return PaceActionExecutionObservation(
            toolName: "notes",
            summary: "Created note: \(noteRequest.title)"
        )
    }

    private func appendNote(_ noteRequest: PaceNoteRequest) async -> PaceActionExecutionObservation {
        print("🧰 Notes append \"\(noteRequest.title)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "Would append to note: \(noteRequest.title)"
            )
        }

        await openApplication(named: "Notes")
        let scriptResult = runAppleScript(source: """
        tell application "Notes"
            activate
            set matchingNotes to notes whose name is "\(Self.appleScriptEscaped(noteRequest.title))"
            if (count of matchingNotes) is 0 then
                make new note at default account with properties {name:"\(Self.appleScriptEscaped(noteRequest.title))", body:"\(Self.appleScriptEscaped(noteRequest.body))"}
            else
                set targetNote to item 1 of matchingNotes
                set body of targetNote to (body of targetNote) & "<br><br>" & "\(Self.appleScriptEscaped(noteRequest.body))"
            end if
        end tell
        """)

        if let errorDescription = scriptResult.errorDescription {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "Failed to append note: \(errorDescription)"
            )
        }

        return PaceActionExecutionObservation(
            toolName: "notes",
            summary: "Appended note: \(noteRequest.title)"
        )
    }

    private func searchNotes(query: String) async -> PaceActionExecutionObservation {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        print("🧰 Notes search \"\(trimmedQuery)\" (enabled: \(actionsAreEnabled))")
        guard !trimmedQuery.isEmpty else {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "No note search query was provided."
            )
        }
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "Would search notes for: \(trimmedQuery)"
            )
        }

        await openApplication(named: "Notes")
        let scriptResult = runAppleScript(source: """
        tell application "Notes"
            set matchingTitles to {}
            repeat with candidateNote in notes
                set candidateName to name of candidateNote
                set candidateBody to body of candidateNote
                if candidateName contains "\(Self.appleScriptEscaped(trimmedQuery))" or candidateBody contains "\(Self.appleScriptEscaped(trimmedQuery))" then
                    set end of matchingTitles to candidateName
                end if
            end repeat
            set AppleScript's text item delimiters to linefeed
            return matchingTitles as text
        end tell
        """)

        if let errorDescription = scriptResult.errorDescription {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "Failed to search notes: \(errorDescription)"
            )
        }

        let output = scriptResult.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty else {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "No notes found for: \(trimmedQuery)"
            )
        }

        return PaceActionExecutionObservation(
            toolName: "notes",
            summary: "Notes found for \(trimmedQuery):\n\(output)"
        )
    }

    private func composeMail(_ mailDraft: PaceMailDraft) async -> PaceActionExecutionObservation {
        print("🧰 Mail compose \"\(mailDraft.subject)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "mail",
                summary: "Would compose mail draft: \(mailDraft.subject)"
            )
        }

        await openApplication(named: "Mail")
        let recipientLines = mailDraft.recipients.map { recipient in
            "make new to recipient at end of to recipients with properties {address:\"\(Self.appleScriptEscaped(recipient))\"}"
        }
        .joined(separator: "\n            ")

        let scriptResult = runAppleScript(source: """
        tell application "Mail"
            activate
            set newMessage to make new outgoing message with properties {subject:"\(Self.appleScriptEscaped(mailDraft.subject))", content:"\(Self.appleScriptEscaped(mailDraft.body))", visible:true}
            tell newMessage
                \(recipientLines)
            end tell
        end tell
        """)

        if let errorDescription = scriptResult.errorDescription {
            return PaceActionExecutionObservation(
                toolName: "mail",
                summary: "Failed to compose mail draft: \(errorDescription)"
            )
        }

        return PaceActionExecutionObservation(
            toolName: "mail",
            summary: "Created mail draft: \(mailDraft.subject)"
        )
    }

    private func createThingsToDo(_ request: PaceThingsToDoRequest) async -> PaceActionExecutionObservation {
        print("🧰 Things create \"\(request.title)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "things",
                summary: "Would create Things to-do: \(request.title)"
            )
        }

        guard Self.findApplicationURL(named: "Things3") != nil || Self.findApplicationURL(named: "Things") != nil else {
            return PaceActionExecutionObservation(
                toolName: "things",
                summary: "Things is not installed."
            )
        }

        let notesClause = request.notes.map { "notes:\"\(Self.appleScriptEscaped($0))\"" } ?? "notes:\"\""
        let scriptResult = runAppleScript(source: """
        tell application "Things3"
            activate
            make new to do with properties {name:"\(Self.appleScriptEscaped(request.title))", \(notesClause)}
        end tell
        """)

        if let errorDescription = scriptResult.errorDescription {
            return PaceActionExecutionObservation(
                toolName: "things",
                summary: "Failed to create Things to-do: \(errorDescription)"
            )
        }

        return PaceActionExecutionObservation(
            toolName: "things",
            summary: "Created Things to-do: \(request.title)"
        )
    }

    private func runShortcut(named shortcutName: String) async -> PaceActionExecutionObservation {
        let trimmedShortcutName = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        print("🧰 Shortcuts run \"\(trimmedShortcutName)\" (enabled: \(actionsAreEnabled))")
        guard !trimmedShortcutName.isEmpty else {
            return PaceActionExecutionObservation(toolName: "shortcuts", summary: "No shortcut name was provided.")
        }

        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "shortcuts",
                summary: "Would run shortcut: \(trimmedShortcutName)"
            )
        }

        let scriptResult = runAppleScript(source: """
        tell application "Shortcuts Events"
            run shortcut "\(Self.appleScriptEscaped(trimmedShortcutName))"
        end tell
        """)

        if let errorDescription = scriptResult.errorDescription {
            return PaceActionExecutionObservation(
                toolName: "shortcuts",
                summary: "Failed to run shortcut: \(errorDescription)"
            )
        }

        return PaceActionExecutionObservation(
            toolName: "shortcuts",
            summary: "Ran shortcut: \(trimmedShortcutName)"
        )
    }

    private func openMessages(_ request: PaceMessageRequest) async -> PaceActionExecutionObservation {
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

    private func postAuxiliaryKeyEvent(keyType: Int32) {
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

    private func requestCalendarAccessIfNeeded() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(macOS 14.0, *) {
                eventStore.requestFullAccessToEvents { granted, error in
                    if let error {
                        print("⚠️ PaceActionExecutor: calendar access error: \(error.localizedDescription)")
                    }
                    continuation.resume(returning: granted)
                }
            } else {
                eventStore.requestAccess(to: .event) { granted, error in
                    if let error {
                        print("⚠️ PaceActionExecutor: calendar access error: \(error.localizedDescription)")
                    }
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func requestReminderAccessIfNeeded() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(macOS 14.0, *) {
                eventStore.requestFullAccessToReminders { granted, error in
                    if let error {
                        print("⚠️ PaceActionExecutor: reminders access error: \(error.localizedDescription)")
                    }
                    continuation.resume(returning: granted)
                }
            } else {
                eventStore.requestAccess(to: .reminder) { granted, error in
                    if let error {
                        print("⚠️ PaceActionExecutor: reminders access error: \(error.localizedDescription)")
                    }
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func runAppleScript(source: String) -> (output: String?, errorDescription: String?) {
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

    private static func findApplicationURL(named applicationName: String) -> URL? {
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

    private static func appleScriptEscaped(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func findApplicationURL(
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

    private static func normalizeApplicationName(_ applicationName: String) -> String {
        applicationName
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static let soundUpKeyType: Int32 = 0
    private static let soundDownKeyType: Int32 = 1
    private static let brightnessUpKeyType: Int32 = 2
    private static let brightnessDownKeyType: Int32 = 3
    private static let mediaPlayPauseKeyType: Int32 = 16
    private static let mediaNextKeyType: Int32 = 17
    private static let mediaPreviousKeyType: Int32 = 18

    // MARK: - Keyboard

    private func typeText(_ textToType: String) async {
        print("⌨️  Type \(textToType.count) chars (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else { return }

        // Use unicode-string CGEvents so we don't have to map every char to
        // a key code. This works for any printable text including emoji.
        // Each grapheme gets its own keyDown + keyUp pair.
        for unicodeCharacter in textToType {
            let utf16Units = Array(String(unicodeCharacter).utf16)
            guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { continue }
            keyDownEvent.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
            keyDownEvent.post(tap: .cghidEventTap)

            guard let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            keyUpEvent.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
            keyUpEvent.post(tap: .cghidEventTap)

            try? await Task.sleep(nanoseconds: 8_000_000) // 8ms between chars feels natural
        }
    }

    private func pressKey(named keyName: String, withModifiers modifiers: [PaceKeyboardModifier]) async {
        print("⌨️  Press \(keyName) with modifiers \(modifiers) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else { return }

        guard let virtualKeyCode = Self.virtualKeyCode(forKeyName: keyName) else {
            print("⚠️ PaceActionExecutor: unknown key name \(keyName)")
            return
        }

        let modifierFlags = Self.cgEventFlags(forModifiers: modifiers)

        if let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyCode, keyDown: true) {
            keyDownEvent.flags = modifierFlags
            keyDownEvent.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: 15_000_000)
        if let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyCode, keyDown: false) {
            keyUpEvent.flags = modifierFlags
            keyUpEvent.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Key name → virtual key code

    private static func virtualKeyCode(forKeyName keyName: String) -> CGKeyCode? {
        // Subset of common named keys. Add more on demand. Letter/number
        // keys are intentionally NOT included — use the [TYPE:...] action
        // for those, which goes through unicode-string events.
        switch keyName.lowercased() {
        case "return", "enter": return 0x24
        case "tab": return 0x30
        case "space": return 0x31
        case "delete", "backspace": return 0x33
        case "escape", "esc": return 0x35
        case "up", "uparrow": return 0x7E
        case "down", "downarrow": return 0x7D
        case "left", "leftarrow": return 0x7B
        case "right", "rightarrow": return 0x7C
        case "home": return 0x73
        case "end": return 0x77
        case "pageup": return 0x74
        case "pagedown": return 0x79
        default:
            return nil
        }
    }

    private static func cgEventFlags(forModifiers modifiers: [PaceKeyboardModifier]) -> CGEventFlags {
        var combinedFlags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command: combinedFlags.insert(.maskCommand)
            case .option: combinedFlags.insert(.maskAlternate)
            case .control: combinedFlags.insert(.maskControl)
            case .shift: combinedFlags.insert(.maskShift)
            }
        }
        return combinedFlags
    }

    // MARK: - Coordinate conversion

    /// Maps a screenshot-pixel coordinate to a global CG point (the
    /// coordinate space CGEvent expects: top-left origin, points). The
    /// math mirrors the pointing logic in CompanionManager so what the
    /// user sees the cursor *point at* is exactly where a click would land.
    private func convertScreenshotPixelToDisplayGlobalPoint(
        screenshotPixelLocation: ScreenshotPixelLocation,
        screenCaptures: [CompanionScreenCapture]
    ) -> CGPoint? {
        let targetCapture: CompanionScreenCapture? = {
            if let screenNumber = screenshotPixelLocation.screenNumber,
               screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
        }()

        guard let capture = targetCapture else { return nil }

        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let displayFrame = capture.displayFrame

        let clampedScreenshotX = max(0, min(CGFloat(screenshotPixelLocation.xInScreenshotPixels), screenshotWidth))
        let clampedScreenshotY = max(0, min(CGFloat(screenshotPixelLocation.yInScreenshotPixels), screenshotHeight))

        let displayLocalX = clampedScreenshotX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedScreenshotY * (displayHeight / screenshotHeight)

        // CG global coordinates have top-left origin on the main screen.
        // CompanionScreenCapture.displayFrame is in AppKit coords (bottom-left
        // origin), so we need to convert here. The main screen's height in
        // AppKit coords minus the AppKit y of the top of the display gives
        // the CG y of the top of the display.
        guard let mainScreen = NSScreen.screens.first else { return nil }
        let mainScreenHeight = mainScreen.frame.height
        let displayCGTopY = mainScreenHeight - (displayFrame.origin.y + displayHeight)

        let globalCGPoint = CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: displayLocalY + displayCGTopY
        )

        return globalCGPoint
    }
}

// MARK: - Parsed action types

struct PaceActionExecutionObservation {
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

struct PaceActionExecutionPlan {
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

struct PaceActionExecutionStep {
    let actions: [PaceParsedAction]
}

/// One action Claude wants pace to perform on the user's behalf.
/// Parsed out of the assistant's response by `PaceActionTagParser`.
enum PaceParsedAction {
    case click(ScreenshotPixelLocation)
    case doubleClick(ScreenshotPixelLocation)
    case type(String)
    case pressKey(name: String, modifiers: [PaceKeyboardModifier])
    case scroll(PaceScrollDirection, amountInLines: Int)
    case openApplication(String)
    case openURL(String)
    case controlMusic(PaceMusicCommand)
    case adjustVolume(PaceSystemAdjustment)
    case adjustBrightness(PaceSystemAdjustment)
    case listCalendarEvents(PaceCalendarQuery)
    case createReminder(PaceReminderRequest)
    case finder(PaceFinderRequest)
    case createNote(PaceNoteRequest)
    case appendNote(PaceNoteRequest)
    case searchNotes(String)
    case composeMail(PaceMailDraft)
    case createThingsToDo(PaceThingsToDoRequest)
    case runShortcut(String)
    case openMessages(PaceMessageRequest)

    var approvalDescription: String {
        switch self {
        case .click(let location):
            return "Click at \(location.approvalDescription)"
        case .doubleClick(let location):
            return "Double-click at \(location.approvalDescription)"
        case .type(let text):
            return "Type \(text.count) characters"
        case .pressKey(let keyName, let modifiers):
            let modifierPrefix = modifiers.isEmpty
                ? ""
                : modifiers.map(\.rawValue).joined(separator: "+") + "+"
            return "Press \(modifierPrefix)\(keyName)"
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

private extension ScreenshotPixelLocation {
    var approvalDescription: String {
        let screenSuffix = screenNumber.map { ", screen \($0)" } ?? ""
        return "\(xInScreenshotPixels), \(yInScreenshotPixels)\(screenSuffix)"
    }
}

enum PaceKeyboardModifier: String {
    case command, option, control, shift
}

enum PaceScrollDirection: String, CustomStringConvertible {
    case up, down

    var description: String { rawValue }
}

struct PaceSystemAdjustment: CustomStringConvertible {
    let direction: PaceAdjustmentDirection
    let stepCount: Int

    var description: String {
        "\(direction.rawValue):\(stepCount)"
    }
}

enum PaceAdjustmentDirection: String {
    case up, down
}

enum PaceMusicCommand: String, Equatable {
    case play
    case pause
    case playPause
    case next
    case previous
}

struct PaceCalendarQuery {
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

enum PaceCalendarRange: String, Equatable {
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

struct PaceReminderRequest {
    let title: String
    let notes: String?
}

struct PaceFinderRequest {
    let path: String
    let action: PaceFinderAction
}

enum PaceFinderAction: String, Equatable {
    case open
    case reveal
}

struct PaceNoteRequest {
    let title: String
    let body: String
}

struct PaceMailDraft {
    let recipients: [String]
    let subject: String
    let body: String
}

struct PaceThingsToDoRequest {
    let title: String
    let notes: String?
}

struct PaceMessageRequest {
    let recipient: String?
    let text: String?
}

// MARK: - Action tag parser

/// Result of pulling all action tags out of Claude's response.
struct PaceActionTagParseResult {
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

enum PaceActionTagParser {
    private struct ToolCallDTO: Decodable {
        let tool: String
        let app: String?
        let name: String?
        let url: String?
        let command: String?
        let direction: String?
        let title: String?
        let query: String?
        let text: String?
        let body: String?
        let notes: String?
        let range: String?
        let key: String?
        let path: String?
        let action: String?
        let to: String?
        let subject: String?
        let recipient: String?
        let steps: Int?
        let amount: Int?
        let x: Int?
        let y: Int?
        let screen: Int?

        enum CodingKeys: String, CodingKey {
            case tool, app, name, url, command, direction, title, query, text, body, notes, range, key, path, action, to, subject, recipient, steps, amount, x, y, screen
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.tool = try container.decode(String.self, forKey: .tool)
            self.app = Self.decodeStringIfPresent(from: container, forKey: .app)
            self.name = Self.decodeStringIfPresent(from: container, forKey: .name)
            self.url = Self.decodeStringIfPresent(from: container, forKey: .url)
            self.command = Self.decodeStringIfPresent(from: container, forKey: .command)
            self.direction = Self.decodeStringIfPresent(from: container, forKey: .direction)
            self.title = Self.decodeStringIfPresent(from: container, forKey: .title)
            self.query = Self.decodeStringIfPresent(from: container, forKey: .query)
            self.text = Self.decodeStringIfPresent(from: container, forKey: .text)
            self.body = Self.decodeStringIfPresent(from: container, forKey: .body)
            self.notes = Self.decodeStringIfPresent(from: container, forKey: .notes)
            self.range = Self.decodeStringIfPresent(from: container, forKey: .range)
            self.key = Self.decodeStringIfPresent(from: container, forKey: .key)
            self.path = Self.decodeStringIfPresent(from: container, forKey: .path)
            self.action = Self.decodeStringIfPresent(from: container, forKey: .action)
            self.to = Self.decodeStringIfPresent(from: container, forKey: .to)
            self.subject = Self.decodeStringIfPresent(from: container, forKey: .subject)
            self.recipient = Self.decodeStringIfPresent(from: container, forKey: .recipient)
            self.steps = Self.decodeIntIfPresent(from: container, forKey: .steps)
            self.amount = Self.decodeIntIfPresent(from: container, forKey: .amount)
            self.x = Self.decodeIntIfPresent(from: container, forKey: .x)
            self.y = Self.decodeIntIfPresent(from: container, forKey: .y)
            self.screen = Self.decodeIntIfPresent(from: container, forKey: .screen)
        }

        private static func decodeStringIfPresent(
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> String? {
            if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
                return stringValue
            }
            if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                return String(intValue)
            }
            return nil
        }

        private static func decodeIntIfPresent(
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Int? {
            if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                return intValue
            }
            if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
    }

    /// Tag formats supported (case-insensitive on tag name):
    ///   [CLICK:x,y]                or [CLICK:x,y:screen2]
    ///   [DOUBLE_CLICK:x,y]         or [DOUBLE_CLICK:x,y:screen2]
    ///   [TYPE:hello world]
    ///   [KEY:Return]               or [KEY:cmd+s]   or [KEY:cmd+shift+t]
    ///   [SCROLL:up:3]              or [SCROLL:down:5]
    ///   [OPEN_APP:Safari]
    ///   [VOLUME:up:2]              or [VOLUME:down]
    ///   [BRIGHTNESS:up]            or [BRIGHTNESS:down:3]
    ///
    /// Preferred grouped format:
    ///   <tool_calls>
    ///   [[{"tool":"open_app","app":"Music"},{"tool":"music","command":"play"}]]
    ///   </tool_calls>
    ///
    /// Order of tags in the response is preserved in the returned actions array.
    static func parseActions(from responseText: String) -> PaceActionTagParseResult {
        let (toolCallSteps, responseTextWithoutToolCallBlocks) = parseToolCallBlocks(in: responseText)

        // One regex that matches any of the supported tag shapes. We use a
        // single pass so we can walk matches in source order. Group 1 is the
        // tag name; group 2 is the everything-after-the-colon payload.
        let actionTagPattern = #"\[(CLICK|DOUBLE_CLICK|TYPE|KEY|SCROLL|OPEN_APP|OPEN_URL|MUSIC|VOLUME|BRIGHTNESS|CALENDAR|REMINDER):([^\]]+)\]"#

        guard let actionTagRegex = try? NSRegularExpression(
            pattern: actionTagPattern,
            options: [.caseInsensitive]
        ) else {
            let allActions = toolCallSteps.flatMap(\.actions)
            return PaceActionTagParseResult(
                spokenText: responseTextWithoutToolCallBlocks,
                actions: allActions,
                executionPlan: PaceActionExecutionPlan(steps: toolCallSteps),
                firstClickVisualisationLocation: firstClickVisualisationLocation(in: allActions)
            )
        }

        let entireRange = NSRange(responseTextWithoutToolCallBlocks.startIndex..., in: responseTextWithoutToolCallBlocks)
        let matches = actionTagRegex.matches(in: responseTextWithoutToolCallBlocks, options: [], range: entireRange)

        var parsedActions: [PaceParsedAction] = []
        var spokenTextWithoutActionTags = responseTextWithoutToolCallBlocks

        // Build spoken text by removing matches in reverse so ranges stay valid.
        let matchesInForwardOrder = matches
        let matchesInReverseOrder = matches.reversed()

        for match in matchesInForwardOrder {
            guard let fullRange = Range(match.range, in: responseTextWithoutToolCallBlocks),
                  let nameRange = Range(match.range(at: 1), in: responseTextWithoutToolCallBlocks),
                  let payloadRange = Range(match.range(at: 2), in: responseTextWithoutToolCallBlocks) else {
                continue
            }
            let tagName = String(responseTextWithoutToolCallBlocks[nameRange]).uppercased()
            let payload = String(responseTextWithoutToolCallBlocks[payloadRange])

            if let parsedAction = parseSingleAction(tagName: tagName, payload: payload) {
                parsedActions.append(parsedAction)
            }
            _ = fullRange // silence unused warning; we use it via the reverse loop below
        }

        for match in matchesInReverseOrder {
            guard let fullRange = Range(match.range, in: spokenTextWithoutActionTags) else { continue }
            spokenTextWithoutActionTags.removeSubrange(fullRange)
        }

        let cleanedSpokenText = spokenTextWithoutActionTags
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let executionSteps = toolCallSteps + parsedActions.map { PaceActionExecutionStep(actions: [$0]) }
        let allActions = executionSteps.flatMap(\.actions)

        return PaceActionTagParseResult(
            spokenText: cleanedSpokenText,
            actions: allActions,
            executionPlan: PaceActionExecutionPlan(steps: executionSteps),
            firstClickVisualisationLocation: firstClickVisualisationLocation(in: allActions)
        )
    }

    private static func parseSingleAction(tagName: String, payload: String) -> PaceParsedAction? {
        switch tagName {
        case "CLICK":
            return parseScreenshotPixelLocationPayload(payload).map { .click($0) }
        case "DOUBLE_CLICK":
            return parseScreenshotPixelLocationPayload(payload).map { .doubleClick($0) }
        case "TYPE":
            // TYPE payload is free text — pass through verbatim.
            return .type(payload)
        case "KEY":
            return parseKeyPayload(payload)
        case "SCROLL":
            return parseScrollPayload(payload)
        case "OPEN_APP":
            return parseOpenApplicationPayload(payload)
        case "OPEN_URL":
            return parseOpenURLPayload(payload)
        case "MUSIC":
            return parseMusicPayload(payload)
        case "VOLUME":
            return parseSystemAdjustmentPayload(payload).map { .adjustVolume($0) }
        case "BRIGHTNESS":
            return parseSystemAdjustmentPayload(payload).map { .adjustBrightness($0) }
        case "CALENDAR":
            return parseCalendarPayload(payload)
        case "REMINDER":
            return parseReminderPayload(payload)
        default:
            return nil
        }
    }

    private static func parseToolCallBlocks(in responseText: String) -> (steps: [PaceActionExecutionStep], strippedText: String) {
        let pattern = #"<tool_calls>(.*?)</tool_calls>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return ([], responseText)
        }

        let entireRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = regex.matches(in: responseText, options: [], range: entireRange)
        guard !matches.isEmpty else { return ([], responseText) }

        var parsedSteps: [PaceActionExecutionStep] = []
        var strippedText = responseText

        for match in matches {
            guard let jsonRange = Range(match.range(at: 1), in: responseText) else { continue }
            let jsonText = String(responseText[jsonRange])
            parsedSteps.append(contentsOf: decodeToolCallSteps(from: jsonText))
        }

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: strippedText) else { continue }
            strippedText.removeSubrange(fullRange)
        }

        return (parsedSteps, strippedText)
    }

    private static func decodeToolCallSteps(from jsonText: String) -> [PaceActionExecutionStep] {
        guard let jsonData = jsonText.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()

        if let groupedToolCalls = try? decoder.decode([[ToolCallDTO]].self, from: jsonData) {
            return groupedToolCalls.compactMap { toolCallGroup in
                let actions = toolCallGroup.compactMap(parseToolCall)
                return actions.isEmpty ? nil : PaceActionExecutionStep(actions: actions)
            }
        }

        if let flatToolCalls = try? decoder.decode([ToolCallDTO].self, from: jsonData) {
            return flatToolCalls.compactMap { toolCall in
                guard let action = parseToolCall(toolCall) else { return nil }
                return PaceActionExecutionStep(actions: [action])
            }
        }

        return []
    }

    private static func parseToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        guard let toolKind = PaceToolRegistry.kind(forToolName: toolCall.tool) else {
            return nil
        }

        switch toolKind {
        case .click:
            return parseToolCallLocation(toolCall).map { .click($0) }
        case .doubleClick:
            return parseToolCallLocation(toolCall).map { .doubleClick($0) }
        case .type:
            guard let text = toolCall.text, !text.isEmpty else { return nil }
            return .type(text)
        case .key:
            return parseKeyPayload(toolCall.key ?? toolCall.command ?? "")
        case .scroll:
            return parseScrollPayload(
                [
                    toolCall.direction,
                    (toolCall.amount ?? toolCall.steps).map(String.init)
                ]
                .compactMap { $0 }
                .joined(separator: ":")
            )
        case .openApp:
            return parseOpenApplicationPayload(toolCall.app ?? toolCall.name ?? "")
        case .openURL:
            return parseOpenURLPayload(toolCall.url ?? toolCall.text ?? "")
        case .music:
            return parseMusicPayload(toolCall.command ?? "")
        case .volume:
            return parseSystemAdjustmentPayload(
                [
                    toolCall.direction,
                    toolCall.steps.map(String.init)
                ]
                .compactMap { $0 }
                .joined(separator: ":")
            ).map { .adjustVolume($0) }
        case .brightness:
            return parseSystemAdjustmentPayload(
                [
                    toolCall.direction,
                    toolCall.steps.map(String.init)
                ]
                .compactMap { $0 }
                .joined(separator: ":")
            ).map { .adjustBrightness($0) }
        case .calendar:
            return parseCalendarPayload(toolCall.range ?? "today")
        case .reminder:
            return parseReminderPayload(toolCall.title ?? toolCall.text ?? "")
        case .finder:
            return parseFinderToolCall(toolCall)
        case .notes:
            return parseNoteToolCall(toolCall)
        case .mail:
            return parseMailToolCall(toolCall)
        case .things:
            return parseThingsToolCall(toolCall)
        case .shortcuts:
            return parseShortcutToolCall(toolCall)
        case .messages:
            return parseMessagesToolCall(toolCall)
        }
    }

    private static func parseToolCallLocation(_ toolCall: ToolCallDTO) -> ScreenshotPixelLocation? {
        guard let xPixel = toolCall.x, let yPixel = toolCall.y else { return nil }
        return ScreenshotPixelLocation(
            xInScreenshotPixels: xPixel,
            yInScreenshotPixels: yPixel,
            screenNumber: toolCall.screen
        )
    }

    private static func firstClickVisualisationLocation(in actions: [PaceParsedAction]) -> ScreenshotPixelLocation? {
        for action in actions {
            switch action {
            case .click(let location), .doubleClick(let location):
                return location
            default:
                continue
            }
        }
        return nil
    }

    /// Parses `x,y` or `x,y:screenN` into a ScreenshotPixelLocation.
    private static func parseScreenshotPixelLocationPayload(_ payload: String) -> ScreenshotPixelLocation? {
        let payloadComponents = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard let coordinateComponent = payloadComponents.first else { return nil }

        let xyComponents = coordinateComponent.split(separator: ",", omittingEmptySubsequences: false)
        guard xyComponents.count == 2,
              let xPixel = Int(xyComponents[0].trimmingCharacters(in: .whitespaces)),
              let yPixel = Int(xyComponents[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }

        var screenNumber: Int? = nil
        for trailingComponent in payloadComponents.dropFirst() {
            let trimmedTrailingComponent = trailingComponent.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmedTrailingComponent.hasPrefix("screen") {
                let digitsString = trimmedTrailingComponent.dropFirst("screen".count)
                screenNumber = Int(digitsString)
            }
        }

        return ScreenshotPixelLocation(
            xInScreenshotPixels: xPixel,
            yInScreenshotPixels: yPixel,
            screenNumber: screenNumber
        )
    }

    /// Parses `Return`, `cmd+s`, `cmd+shift+t` into a pressKey action.
    private static func parseKeyPayload(_ payload: String) -> PaceParsedAction? {
        let plusSeparatedTokens = payload.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let mainKeyToken = plusSeparatedTokens.last, !mainKeyToken.isEmpty else { return nil }

        var modifiers: [PaceKeyboardModifier] = []
        for modifierToken in plusSeparatedTokens.dropLast() {
            switch modifierToken {
            case "cmd", "command", "meta": modifiers.append(.command)
            case "opt", "option", "alt": modifiers.append(.option)
            case "ctrl", "control": modifiers.append(.control)
            case "shift": modifiers.append(.shift)
            default: continue
            }
        }

        return .pressKey(name: mainKeyToken, modifiers: modifiers)
    }

    /// Parses `up:3` / `down:5` into a scroll action.
    private static func parseScrollPayload(_ payload: String) -> PaceParsedAction? {
        let payloadComponents = payload.split(separator: ":", omittingEmptySubsequences: true)
        guard let directionString = payloadComponents.first,
              let direction = PaceScrollDirection(rawValue: directionString.trimmingCharacters(in: .whitespaces).lowercased()) else {
            return nil
        }

        let amountInLines: Int = {
            if payloadComponents.count >= 2,
               let parsedAmount = Int(payloadComponents[1].trimmingCharacters(in: .whitespaces)) {
                return max(1, min(parsedAmount, 50)) // clamp to a reasonable range
            }
            return 3
        }()

        return .scroll(direction, amountInLines: amountInLines)
    }

    private static func parseOpenApplicationPayload(_ payload: String) -> PaceParsedAction? {
        let applicationName = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !applicationName.isEmpty else { return nil }
        return .openApplication(applicationName)
    }

    private static func parseOpenURLPayload(_ payload: String) -> PaceParsedAction? {
        let urlString = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return nil }
        return .openURL(urlString)
    }

    private static func parseMusicPayload(_ payload: String) -> PaceParsedAction? {
        let normalizedCommand = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch normalizedCommand {
        case "play":
            return .controlMusic(.play)
        case "pause":
            return .controlMusic(.pause)
        case "play_pause", "playpause", "toggle":
            return .controlMusic(.playPause)
        case "next", "next_track":
            return .controlMusic(.next)
        case "previous", "prev", "previous_track":
            return .controlMusic(.previous)
        default:
            return nil
        }
    }

    private static func parseCalendarPayload(_ payload: String) -> PaceParsedAction? {
        let normalizedRange = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let range: PaceCalendarRange
        switch normalizedRange {
        case "today", "":
            range = .today
        case "tomorrow":
            range = .tomorrow
        case "week", "next_week", "next_7_days", "next 7 days":
            range = .week
        default:
            return nil
        }
        return .listCalendarEvents(PaceCalendarQuery(range: range))
    }

    private static func parseReminderPayload(_ payload: String) -> PaceParsedAction? {
        let reminderTitle = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reminderTitle.isEmpty else { return nil }
        return .createReminder(PaceReminderRequest(title: reminderTitle, notes: nil))
    }

    private static func parseFinderToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let path = (toolCall.path ?? toolCall.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        let normalizedAction = (toolCall.action ?? "open")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let finderAction: PaceFinderAction = normalizedAction == "reveal" ? .reveal : .open

        return .finder(PaceFinderRequest(path: path, action: finderAction))
    }

    private static func parseNoteToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let normalizedAction = (toolCall.action ?? "create")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let title = (toolCall.title ?? toolCall.name ?? "Pace note")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (toolCall.body ?? toolCall.text ?? toolCall.notes ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedAction == "search" || normalizedAction == "find" {
            let query = (toolCall.query ?? toolCall.text ?? toolCall.title ?? toolCall.name ?? body)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return nil }
            return .searchNotes(query)
        }

        guard !title.isEmpty || !body.isEmpty else { return nil }
        let noteRequest = PaceNoteRequest(
            title: title.isEmpty ? "Pace note" : title,
            body: body
        )

        if normalizedAction == "append" || normalizedAction == "add" || normalizedAction == "update" {
            return .appendNote(noteRequest)
        }

        return .createNote(noteRequest)
    }

    private static func parseMailToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let recipients = (toolCall.to ?? toolCall.recipient ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let subject = (toolCall.subject ?? toolCall.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (toolCall.body ?? toolCall.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty || !body.isEmpty || !recipients.isEmpty else { return nil }

        return .composeMail(PaceMailDraft(
            recipients: recipients,
            subject: subject.isEmpty ? "Untitled" : subject,
            body: body
        ))
    }

    private static func parseThingsToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let title = (toolCall.title ?? toolCall.text ?? toolCall.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return .createThingsToDo(PaceThingsToDoRequest(title: title, notes: toolCall.notes))
    }

    private static func parseShortcutToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let shortcutName = (toolCall.name ?? toolCall.title ?? toolCall.command ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortcutName.isEmpty else { return nil }
        return .runShortcut(shortcutName)
    }

    private static func parseMessagesToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let recipient = (toolCall.recipient ?? toolCall.to ?? toolCall.name)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (toolCall.text ?? toolCall.body)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .openMessages(PaceMessageRequest(
            recipient: recipient?.isEmpty == false ? recipient : nil,
            text: text?.isEmpty == false ? text : nil
        ))
    }

    /// Parses `up`, `down`, `up:3`, `down:5` into a relative system adjustment.
    private static func parseSystemAdjustmentPayload(_ payload: String) -> PaceSystemAdjustment? {
        let payloadComponents = payload.split(separator: ":", omittingEmptySubsequences: true)
        guard let directionString = payloadComponents.first,
              let direction = PaceAdjustmentDirection(rawValue: directionString.trimmingCharacters(in: .whitespaces).lowercased()) else {
            return nil
        }

        let stepCount: Int = {
            if payloadComponents.count >= 2,
               let parsedStepCount = Int(payloadComponents[1].trimmingCharacters(in: .whitespaces)) {
                return max(1, min(parsedStepCount, 10))
            }
            return 2
        }()

        return PaceSystemAdjustment(direction: direction, stepCount: stepCount)
    }
}
