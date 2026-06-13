//
//  PaceNotesRetrievalConnector.swift
//  leanring-buddy
//
//  Read-only Apple Notes source for local retrieval.
//

import Foundation

struct PaceNoteRetrievalSnapshot: Equatable {
    let stableIdentifier: String
    let title: String
    let body: String

    init(
        stableIdentifier: String,
        title: String,
        body: String
    ) {
        self.stableIdentifier = stableIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.fallbackIdentifier(title: title, body: body)
            : stableIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled note"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.body = body
    }

    private static func fallbackIdentifier(title: String, body: String) -> String {
        let seed = "\(title)-\(body.prefix(120))"
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(12)
            .joined(separator: "-")
        return seed.isEmpty ? "untitled" : seed
    }
}

struct PaceNotesRetrievalConnector {
    func loadDocuments(
        maximumNoteCount: Int = 200
    ) -> (documents: [PaceRetrievalDocument], status: PaceRetrievalSourceStatus) {
        guard maximumNoteCount > 0 else {
            return (
                [],
                .enabled(
                    source: .notes,
                    displayName: PaceRetrievalSource.notes.displayName,
                    documentCount: 0
                )
            )
        }

        let scriptResult = runReadOnlyNotesScript(maximumNoteCount: maximumNoteCount)
        if let errorDescription = scriptResult.errorDescription {
            return (
                [],
                .skipped(
                    source: .notes,
                    displayName: PaceRetrievalSource.notes.displayName,
                    reason: "Notes read failed or Automation is not approved: \(errorDescription)"
                )
            )
        }

        let snapshots = Self.snapshots(fromAppleScriptOutput: scriptResult.output ?? "")
        let documents = snapshots.map(Self.document(from:))
        return (
            documents,
            .enabled(
                source: .notes,
                displayName: PaceRetrievalSource.notes.displayName,
                documentCount: documents.count
            )
        )
    }

    nonisolated static func document(from noteSnapshot: PaceNoteRetrievalSnapshot) -> PaceRetrievalDocument {
        let compactBody = compactText(
            plainText(fromNotesBody: noteSnapshot.body),
            maximumCharacters: 2_000
        )
        let text = [
            "Title: \(noteSnapshot.title)",
            compactBody.map { "Body: \($0)" }
        ]
            .compactMap { $0 }
            .joined(separator: "\n")

        return PaceRetrievalDocument(
            id: "note-\(noteSnapshot.stableIdentifier)",
            source: .notes,
            title: noteSnapshot.title,
            text: text,
            permissionScope: "apple-events-notes-read"
        )
    }

    static func snapshots(fromAppleScriptOutput output: String) -> [PaceNoteRetrievalSnapshot] {
        let recordSeparator = String(Self.recordSeparator)
        let fieldSeparator = String(Self.fieldSeparator)

        return output
            .components(separatedBy: recordSeparator)
            .compactMap { rawRecord -> PaceNoteRetrievalSnapshot? in
                let fields = rawRecord.components(separatedBy: fieldSeparator)
                guard fields.count >= 3 else { return nil }
                let stableIdentifier = fields[0]
                let title = fields[1]
                let body = fields.dropFirst(2).joined(separator: fieldSeparator)
                guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return PaceNoteRetrievalSnapshot(
                    stableIdentifier: stableIdentifier,
                    title: title,
                    body: body
                )
            }
    }

    private func runReadOnlyNotesScript(
        maximumNoteCount: Int
    ) -> (output: String?, errorDescription: String?) {
        let safeMaximumNoteCount = max(0, maximumNoteCount)
        let scriptSource = """
        set fieldDelimiter to ASCII character 31
        set recordDelimiter to ASCII character 30
        set noteRecords to {}
        tell application "Notes"
            set allNotes to notes
            repeat with candidateNote in allNotes
                set candidateId to id of candidateNote as text
                set candidateName to name of candidateNote as text
                set candidateBody to body of candidateNote as text
                copy candidateId & fieldDelimiter & candidateName & fieldDelimiter & candidateBody to end of noteRecords
                if (count of noteRecords) is greater than or equal to \(safeMaximumNoteCount) then exit repeat
            end repeat
        end tell
        set AppleScript's text item delimiters to recordDelimiter
        set outputText to noteRecords as text
        set AppleScript's text item delimiters to ""
        return outputText
        """

        guard let script = NSAppleScript(source: scriptSource) else {
            return (nil, "Could not build Notes AppleScript.")
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

    nonisolated private static func plainText(fromNotesBody body: String) -> String {
        let withoutTags = body.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        return withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    nonisolated private static func compactText(_ text: String, maximumCharacters: Int) -> String? {
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
