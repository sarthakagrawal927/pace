//
//  PaceActionExecutor+SystemToolsNotesMail.swift
//  leanring-buddy
//
//  Extracted from PaceActionExecutor.swift (god-class decomposition Phase B):
//  Finder, Notes, Mail compose/streaming, contact resolution.
//

import AppKit
import ApplicationServices
import Contacts
import EventKit
import Foundation

@MainActor
extension PaceActionExecutor {

    // MARK: - System tools (notes & mail)

    func performFinderRequest(_ finderRequest: PaceFinderRequest) async -> PaceActionExecutionObservation {
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

    func createNote(_ noteRequest: PaceNoteRequest) async -> PaceActionExecutionObservation {
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

    func appendNote(_ noteRequest: PaceNoteRequest) async -> PaceActionExecutionObservation {
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

    func searchNotes(query: String) async -> PaceActionExecutionObservation {
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

    func composeMail(_ mailDraft: PaceMailDraft) async -> PaceActionExecutionObservation {
        print("🧰 Mail compose \"\(mailDraft.subject)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "mail",
                summary: "Would compose mail draft: \(mailDraft.subject)"
            )
        }

        let recipientResolution = await resolveMailRecipients(mailDraft.recipients)
        await openApplication(named: "Mail")
        let scriptResult = await createMailDraftViaMailtoAndAccessibility(
            mailDraft,
            resolvedRecipients: recipientResolution.recipients
        )

        if let errorDescription = scriptResult.errorDescription {
            return PaceActionExecutionObservation(
                toolName: "mail",
                summary: "Failed to compose mail draft: \(errorDescription)"
            )
        }

        let unresolvedRecipientSuffix: String = {
            guard !recipientResolution.unresolvedNames.isEmpty else { return "" }
            return " Unresolved contacts used as-is: \(recipientResolution.unresolvedNames.joined(separator: ", "))."
        }()
        return PaceActionExecutionObservation(
            toolName: "mail",
            summary: "Created mail draft: \(mailDraft.subject).\(unresolvedRecipientSuffix)"
        )
    }

    func writeStreamingMailDraft(
        _ snapshot: PaceStreamingMailDraftSnapshot,
        isFinalWrite: Bool
    ) async -> PaceActionExecutionObservation? {
        let mailDraft = snapshot.normalizedMailDraft
        let shouldCreateDraft = activeStreamingMailDraftState == nil
        let recipientResolution = shouldCreateDraft
            ? await resolveMailRecipients(mailDraft.recipients)
            : MailRecipientResolution(recipients: mailDraft.recipients, unresolvedNames: [])

        if shouldCreateDraft {
            await openApplication(named: "Mail")
        }

        let scriptResult: (output: String?, errorDescription: String?)
        if shouldCreateDraft {
            scriptResult = await createMailDraftViaMailtoAndAccessibility(
                mailDraft,
                resolvedRecipients: recipientResolution.recipients
            )
        } else {
            scriptResult = await updateStreamingMailDraft(mailDraft)
        }

        if let errorDescription = scriptResult.errorDescription {
            activeStreamingMailDraftState = nil
            return PaceActionExecutionObservation(
                toolName: "mail",
                summary: "Failed to stream mail draft: \(errorDescription)"
            )
        }

        let now = Date()
        activeStreamingMailDraftState = PaceStreamingMailDraftState(
            lastWrittenSnapshot: snapshot,
            pendingSnapshot: nil,
            lastWriteDate: now
        )

        guard isFinalWrite else {
            return nil
        }

        let unresolvedRecipientSuffix: String = {
            guard !recipientResolution.unresolvedNames.isEmpty else { return "" }
            return " Unresolved contacts used as-is: \(recipientResolution.unresolvedNames.joined(separator: ", "))."
        }()
        return PaceActionExecutionObservation(
            toolName: "mail",
            summary: "Created streaming mail draft: \(mailDraft.subject).\(unresolvedRecipientSuffix)"
        )
    }

    func createMailDraftViaMailtoAndAccessibility(
        _ mailDraft: PaceMailDraft,
        resolvedRecipients: [String]
    ) async -> (output: String?, errorDescription: String?) {
        guard let mailtoURL = Self.mailtoDraftURL(
            subject: mailDraft.subject,
            resolvedRecipients: resolvedRecipients
        ) else {
            return createStreamingMailDraftViaAppleScript(
                mailDraft,
                resolvedRecipients: resolvedRecipients
            )
        }

        guard NSWorkspace.shared.open(mailtoURL) else {
            return createStreamingMailDraftViaAppleScript(
                mailDraft,
                resolvedRecipients: resolvedRecipients
            )
        }

        let composeWindow = await waitForVisibleOutgoingMailDraft(
            matchingSubject: mailDraft.subject
        )
        let updateResult = await updateStreamingMailDraft(
            mailDraft,
            composeWindow: composeWindow
        )
        if updateResult.errorDescription == nil {
            return updateResult
        }

        return createStreamingMailDraftViaAppleScript(
            mailDraft,
            resolvedRecipients: resolvedRecipients
        )
    }

    static func mailtoDraftURL(
        subject: String,
        resolvedRecipients: [String]
    ) -> URL? {
        var mailtoComponents = URLComponents()
        mailtoComponents.scheme = "mailto"
        mailtoComponents.path = resolvedRecipients.joined(separator: ",")
        if !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mailtoComponents.queryItems = [
                URLQueryItem(name: "subject", value: subject)
            ]
        }
        return mailtoComponents.url
    }

    func waitForVisibleOutgoingMailDraft(
        matchingSubject subject: String,
        timeoutInSeconds: TimeInterval = 1.0
    ) async -> AXUIElement? {
        let deadline = Date(timeIntervalSinceNow: timeoutInSeconds)
        while Date() < deadline {
            if let composeWindow = currentMailComposeWindow(matchingSubject: subject) {
                return composeWindow
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    func createStreamingMailDraftViaAppleScript(
        _ mailDraft: PaceMailDraft,
        resolvedRecipients: [String]
    ) -> (output: String?, errorDescription: String?) {
        let recipientLines = resolvedRecipients.map { recipient in
            "make new to recipient at end of to recipients with properties {address:\"\(Self.appleScriptEscaped(recipient))\"}"
        }
        .joined(separator: "\n            ")

        return runAppleScript(source: """
        tell application "Mail"
            activate
            set targetMessage to make new outgoing message with properties {subject:"\(Self.appleScriptEscaped(mailDraft.subject))", content:"\(Self.appleScriptEscaped(mailDraft.body))", visible:true}
            tell targetMessage
                \(recipientLines)
            end tell
        end tell
        """)
    }

    func updateStreamingMailDraft(
        _ mailDraft: PaceMailDraft,
        composeWindow: AXUIElement? = nil
    ) async -> (output: String?, errorDescription: String?) {
        if mailDraft.body.isEmpty {
            return (nil, nil)
        }

        if await writeMailDraftBodyViaAccessibility(
            mailDraft.body,
            composeWindow: composeWindow ?? currentMailComposeWindow(matchingSubject: mailDraft.subject)
        ) {
            return (nil, nil)
        }

        return runAppleScript(source: """
        tell application "Mail"
            activate
            set visibleOutgoingMessages to outgoing messages whose visible is true
            if (count of visibleOutgoingMessages) is 0 then
                set targetMessage to make new outgoing message with properties {subject:"\(Self.appleScriptEscaped(mailDraft.subject))", content:"\(Self.appleScriptEscaped(mailDraft.body))", visible:true}
            else
                set targetMessage to item 1 of visibleOutgoingMessages
                set subject of targetMessage to "\(Self.appleScriptEscaped(mailDraft.subject))"
                set content of targetMessage to "\(Self.appleScriptEscaped(mailDraft.body))"
            end if
        end tell
        """)
    }

    func writeMailDraftBodyViaAccessibility(
        _ bodyText: String,
        composeWindow: AXUIElement?
    ) async -> Bool {
        guard let composeWindow,
              let bodyElement = Self.bestMailComposeBodyElement(in: composeWindow) else {
            return false
        }

        let setValueResult = AXUIElementSetAttributeValue(
            bodyElement,
            kAXValueAttribute as CFString,
            bodyText as CFString
        )
        if setValueResult == .success {
            return true
        }

        return await replaceMailBodyViaFocusedTyping(
            bodyText,
            bodyElement: bodyElement
        )
    }

    func replaceMailBodyViaFocusedTyping(
        _ bodyText: String,
        bodyElement: AXUIElement
    ) async -> Bool {
        let focusResult = AXUIElementPerformAction(bodyElement, kAXPressAction as CFString)
        guard focusResult == .success else {
            return false
        }

        await pressKey(named: "a", withModifiers: [.command])
        try? await Task.sleep(nanoseconds: 25_000_000)
        await typeText(bodyText)
        return true
    }

    func currentMailComposeWindow(matchingSubject subject: String) -> AXUIElement? {
        guard let mailApplicationElement = mailApplicationElement() else {
            return nil
        }

        let normalizedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let focusedWindow = focusedWindowElement(in: mailApplicationElement)
        let windows = ([focusedWindow] + windows(of: mailApplicationElement))
            .compactMap { $0 }

        let windowsWithBodyCandidates = windows.filter {
            Self.bestMailComposeBodyElement(in: $0) != nil
        }
        guard !windowsWithBodyCandidates.isEmpty else {
            return nil
        }

        if !normalizedSubject.isEmpty,
           let subjectWindow = windowsWithBodyCandidates.first(where: { windowElement in
               Self.concatenatedTextAttributes(in: windowElement)
                   .lowercased()
                   .contains(normalizedSubject)
           }) {
            return subjectWindow
        }

        return windowsWithBodyCandidates.first
    }

    func mailApplicationElement() -> AXUIElement? {
        guard let mailApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.mail")
            .first else {
            return nil
        }
        return AXUIElementCreateApplication(mailApplication.processIdentifier)
    }

    func focusedWindowElement(in applicationElement: AXUIElement) -> AXUIElement? {
        var focusedWindowValue: CFTypeRef?
        let focusedWindowResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )
        guard focusedWindowResult == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return (focusedWindowValue as! AXUIElement)
    }

    func windows(of applicationElement: AXUIElement) -> [AXUIElement] {
        var windowsValue: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        guard windowsResult == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return []
        }
        return windows
    }

    static func bestMailComposeBodyElement(in rootElement: AXUIElement) -> AXUIElement? {
        var bestCandidate: (element: AXUIElement, score: Double)?
        var queue: [AXUIElement] = [rootElement]
        var visitedCount = 0

        while let element = queue.first, visitedCount < 500 {
            queue.removeFirst()
            visitedCount += 1

            let metadata = PaceMailComposeBodyCandidateMetadata(
                role: stringAttribute(kAXRoleAttribute as CFString, of: element),
                title: stringAttribute(kAXTitleAttribute as CFString, of: element),
                description: stringAttribute(kAXDescriptionAttribute as CFString, of: element),
                help: stringAttribute(kAXHelpAttribute as CFString, of: element),
                value: stringAttribute(kAXValueAttribute as CFString, of: element),
                placeholder: stringAttribute("AXPlaceholderValue" as CFString, of: element),
                frame: axFrameMetadata(of: element)
            )

            if metadata.score > 0,
               bestCandidate == nil || metadata.score > (bestCandidate?.score ?? 0) {
                bestCandidate = (element, metadata.score)
            }

            queue.append(contentsOf: children(of: element))
        }

        return bestCandidate?.element
    }

    static func concatenatedTextAttributes(in rootElement: AXUIElement) -> String {
        var values: [String] = []
        var queue: [AXUIElement] = [rootElement]
        var visitedCount = 0

        while let element = queue.first, visitedCount < 300 {
            queue.removeFirst()
            visitedCount += 1
            values.append(contentsOf: [
                stringAttribute(kAXTitleAttribute as CFString, of: element),
                stringAttribute(kAXDescriptionAttribute as CFString, of: element),
                stringAttribute(kAXValueAttribute as CFString, of: element)
            ].compactMap { $0 })
            queue.append(contentsOf: children(of: element))
        }

        return values.joined(separator: " ")
    }

    static func axFrameMetadata(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        )
        var sizeValue: CFTypeRef?
        let sizeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        )
        guard positionResult == .success,
              sizeResult == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    static func stringAttribute(_ attributeName: CFString, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attributeName, &value)
        guard result == .success, let value else { return nil }
        return value as? String
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        )
        guard result == .success,
              let childrenValue,
              let children = childrenValue as? [AXUIElement] else {
            return []
        }
        return children
    }

    struct MailRecipientResolution {
        let recipients: [String]
        let unresolvedNames: [String]
    }

    func resolveMailRecipients(_ rawRecipients: [String]) async -> MailRecipientResolution {
        let trimmedRecipients = rawRecipients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let contactNamesToResolve = trimmedRecipients
            .filter { !Self.looksLikeEmailAddress($0) }
            .map(Self.contactNameToResolve)

        guard !contactNamesToResolve.isEmpty else {
            return MailRecipientResolution(
                recipients: trimmedRecipients,
                unresolvedNames: []
            )
        }

        guard await requestContactsAccessIfNeeded() else {
            return MailRecipientResolution(
                recipients: trimmedRecipients,
                unresolvedNames: contactNamesToResolve
            )
        }

        var resolvedRecipients: [String] = []
        var unresolvedNames: [String] = []

        for rawRecipient in trimmedRecipients {
            guard !Self.looksLikeEmailAddress(rawRecipient) else {
                resolvedRecipients.append(rawRecipient)
                continue
            }

            let contactName = Self.contactNameToResolve(rawRecipient)
            if let emailAddress = emailAddressForContact(named: contactName) {
                resolvedRecipients.append(emailAddress)
            } else {
                resolvedRecipients.append(rawRecipient)
                unresolvedNames.append(contactName)
            }
        }

        return MailRecipientResolution(
            recipients: resolvedRecipients,
            unresolvedNames: unresolvedNames
        )
    }

    func requestContactsAccessIfNeeded() async -> Bool {
        // Never trigger a mid-action TCC prompt — fail with an error
        // observation if the user hasn't granted access yet. They grant
        // once from System Settings on their own time, not while a
        // dictation turn is in progress.
        let authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        switch authorizationStatus {
        case .authorized, .limited:
            return true
        default:
            return false
        }
    }

    func emailAddressForContact(named contactName: String) -> String? {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        let predicate = CNContact.predicateForContacts(matchingName: contactName)

        do {
            let matchingContacts = try contactStore.unifiedContacts(
                matching: predicate,
                keysToFetch: keysToFetch
            )
            return matchingContacts
                .flatMap(\.emailAddresses)
                .map { String($0.value) }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        } catch {
            print("⚠️ PaceActionExecutor: contact lookup failed for \(contactName): \(error.localizedDescription)")
            return nil
        }
    }

    static func looksLikeEmailAddress(_ recipient: String) -> Bool {
        let trimmedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedRecipient.contains("@") && trimmedRecipient.contains(".")
    }

    static func contactNameToResolve(_ rawRecipient: String) -> String {
        rawRecipient
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "__resolve:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func createThingsToDo(_ request: PaceThingsToDoRequest) async -> PaceActionExecutionObservation {
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

    func runShortcut(named shortcutName: String) async -> PaceActionExecutionObservation {
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

        let shortcutListResult = runShortcutsCommand(arguments: ["list"])
        guard shortcutListResult.terminationStatus == 0 else {
            return PaceActionExecutionObservation(
                toolName: "shortcuts",
                summary: "Failed to list shortcuts: \(shortcutListResult.failureSummary)"
            )
        }

        let installedShortcutNames = Self.installedShortcutNames(
            fromListOutput: shortcutListResult.output
        )
        guard Self.shortcutList(
            installedShortcutNames,
            containsShortcutNamed: trimmedShortcutName
        ) else {
            return PaceActionExecutionObservation(
                toolName: "shortcuts",
                summary: "I don't see a shortcut called \(trimmedShortcutName)."
            )
        }

        let shortcutRunResult = runShortcutsCommand(arguments: ["run", trimmedShortcutName])
        guard shortcutRunResult.terminationStatus == 0 else {
            return PaceActionExecutionObservation(
                toolName: "shortcuts",
                summary: "Failed to run shortcut: \(shortcutRunResult.failureSummary)"
            )
        }

        return PaceActionExecutionObservation(
            toolName: "shortcuts",
            summary: "Ran shortcut: \(trimmedShortcutName)"
        )
    }

    static func installedShortcutNames(fromListOutput listOutput: String) -> [String] {
        listOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func shortcutList(
        _ installedShortcutNames: [String],
        containsShortcutNamed requestedShortcutName: String
    ) -> Bool {
        let normalizedRequestedShortcutName = normalizeShortcutName(requestedShortcutName)
        return installedShortcutNames.contains { installedShortcutName in
            normalizeShortcutName(installedShortcutName) == normalizedRequestedShortcutName
        }
    }

    static func normalizeShortcutName(_ shortcutName: String) -> String {
        shortcutName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

}
