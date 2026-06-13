//
//  PaceMailRetrievalConnector.swift
//  leanring-buddy
//
//  Read-only Apple Mail inbox source for local retrieval.
//

import Foundation

struct PaceMailRetrievalSnapshot: Equatable {
    let stableIdentifier: String
    let subject: String
    let sender: String?
    let receivedAtText: String?
    let body: String

    init(
        stableIdentifier: String,
        subject: String,
        sender: String? = nil,
        receivedAtText: String? = nil,
        body: String
    ) {
        self.stableIdentifier = stableIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.fallbackIdentifier(subject: subject, sender: sender, body: body)
            : stableIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subject = subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled message"
            : subject.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sender = Self.compactOptional(sender)
        self.receivedAtText = Self.compactOptional(receivedAtText)
        self.body = body
    }

    private static func fallbackIdentifier(
        subject: String,
        sender: String?,
        body: String
    ) -> String {
        let seed = "\(sender ?? "")-\(subject)-\(body.prefix(120))"
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(12)
            .joined(separator: "-")
        return seed.isEmpty ? "untitled" : seed
    }

    private static func compactOptional(_ value: String?) -> String? {
        let compactedValue = value?
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compactedValue?.isEmpty == false ? compactedValue : nil
    }
}

struct PaceMailRetrievalConnector {
    func loadDocuments(
        maximumMessageCount: Int = 100
    ) -> (documents: [PaceRetrievalDocument], status: PaceRetrievalSourceStatus) {
        guard maximumMessageCount > 0 else {
            return (
                [],
                .enabled(
                    source: .mail,
                    displayName: PaceRetrievalSource.mail.displayName,
                    documentCount: 0
                )
            )
        }

        let scriptResult = runReadOnlyMailScript(maximumMessageCount: maximumMessageCount)
        if let errorDescription = scriptResult.errorDescription {
            return (
                [],
                .skipped(
                    source: .mail,
                    displayName: PaceRetrievalSource.mail.displayName,
                    reason: "Mail read failed or Automation is not approved: \(errorDescription)"
                )
            )
        }

        let snapshots = Self.snapshots(fromAppleScriptOutput: scriptResult.output ?? "")
        let documents = snapshots.map(Self.document(from:))
        return (
            documents,
            .enabled(
                source: .mail,
                displayName: PaceRetrievalSource.mail.displayName,
                documentCount: documents.count
            )
        )
    }

    nonisolated static func document(from mailSnapshot: PaceMailRetrievalSnapshot) -> PaceRetrievalDocument {
        var lines = ["Subject: \(mailSnapshot.subject)"]

        if let sender = compactText(mailSnapshot.sender, maximumCharacters: 240) {
            lines.append("From: \(sender)")
        }
        if let receivedAtText = compactText(mailSnapshot.receivedAtText, maximumCharacters: 120) {
            lines.append("Received: \(receivedAtText)")
        }
        if let body = compactText(mailSnapshot.body, maximumCharacters: 2_000) {
            lines.append("Body: \(body)")
        }

        return PaceRetrievalDocument(
            id: "mail-\(mailSnapshot.stableIdentifier)",
            source: .mail,
            title: mailSnapshot.subject,
            text: lines.joined(separator: "\n"),
            permissionScope: "apple-events-mail-read"
        )
    }

    static func snapshots(fromAppleScriptOutput output: String) -> [PaceMailRetrievalSnapshot] {
        let recordSeparator = String(Self.recordSeparator)
        let fieldSeparator = String(Self.fieldSeparator)

        return output
            .components(separatedBy: recordSeparator)
            .compactMap { rawRecord -> PaceMailRetrievalSnapshot? in
                let fields = rawRecord.components(separatedBy: fieldSeparator)
                guard fields.count >= 5 else { return nil }
                let stableIdentifier = fields[0]
                let subject = fields[1]
                let sender = fields[2]
                let receivedAtText = fields[3]
                let body = fields.dropFirst(4).joined(separator: fieldSeparator)
                guard !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return PaceMailRetrievalSnapshot(
                    stableIdentifier: stableIdentifier,
                    subject: subject,
                    sender: sender,
                    receivedAtText: receivedAtText,
                    body: body
                )
            }
    }

    private func runReadOnlyMailScript(
        maximumMessageCount: Int
    ) -> (output: String?, errorDescription: String?) {
        let safeMaximumMessageCount = max(0, maximumMessageCount)
        let scriptSource = """
        set fieldDelimiter to ASCII character 31
        set recordDelimiter to ASCII character 30
        set messageRecords to {}
        tell application "Mail"
            set inboxMessages to messages of inbox
            repeat with candidateMessage in inboxMessages
                set candidateId to id of candidateMessage as text
                set candidateSubject to subject of candidateMessage as text
                set candidateSender to sender of candidateMessage as text
                set candidateDate to date received of candidateMessage as text
                set candidateBody to content of candidateMessage as text
                copy candidateId & fieldDelimiter & candidateSubject & fieldDelimiter & candidateSender & fieldDelimiter & candidateDate & fieldDelimiter & candidateBody to end of messageRecords
                if (count of messageRecords) is greater than or equal to \(safeMaximumMessageCount) then exit repeat
            end repeat
        end tell
        set AppleScript's text item delimiters to recordDelimiter
        set outputText to messageRecords as text
        set AppleScript's text item delimiters to ""
        return outputText
        """

        guard let script = NSAppleScript(source: scriptSource) else {
            return (nil, "Could not build Mail AppleScript.")
        }

        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "\(errorInfo)"
            return (nil, message)
        }

        return (output.stringValue, nil)
    }

    private static let fieldSeparator = Character(UnicodeScalar(31)!)
    private static let recordSeparator = Character(UnicodeScalar(30)!)

    nonisolated private static func compactText(_ text: String?, maximumCharacters: Int) -> String? {
        guard let text else { return nil }
        let compactedText = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compactedText.isEmpty else { return nil }
        guard compactedText.count > maximumCharacters else { return compactedText }

        let endIndex = compactedText.index(
            compactedText.startIndex,
            offsetBy: maximumCharacters,
            limitedBy: compactedText.endIndex
        ) ?? compactedText.endIndex
        return String(compactedText[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
