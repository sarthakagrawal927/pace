//
//  PaceLocalRetrievalTests.swift
//  leanring-buddyTests
//

import Foundation
import EventKit
import Contacts
import Testing
@testable import Pace

struct PaceLocalRetrievalTests {
    @Test func secretPathExclusionCoversCredentialsAndKeys() async throws {
        #expect(PaceSecretPathExclusionPolicy.shouldExclude(path: "/Users/sarthak/.ssh/id_ed25519"))
        #expect(PaceSecretPathExclusionPolicy.shouldExclude(path: "/Users/sarthak/project/.env"))
        #expect(PaceSecretPathExclusionPolicy.shouldExclude(path: "/Users/sarthak/.kube/config"))
        #expect(PaceSecretPathExclusionPolicy.shouldExclude(path: "/Users/sarthak/app/secrets/api.txt"))
        #expect(!PaceSecretPathExclusionPolicy.shouldExclude(path: "/Users/sarthak/Documents/roadmap.md"))
    }

    @Test func chunkingIsStableAndOverlapping() async throws {
        let repeatedWords = (0..<260)
            .map { "launch-note-\($0)" }
            .joined(separator: " ")
        let document = PaceRetrievalDocument(
            id: "doc-1",
            source: .notes,
            title: "Launch notes",
            text: repeatedWords
        )

        let firstChunks = PaceInMemoryRetrievalStore.makeDocumentChunksForTesting(document)
        let secondChunks = PaceInMemoryRetrievalStore.makeDocumentChunksForTesting(document)

        #expect(firstChunks == secondChunks)
        #expect(firstChunks.count > 1)
        #expect(firstChunks.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    @Test func lexicalRetrievalReturnsExpectedSnippet() async throws {
        let store = PaceInMemoryRetrievalStore()
        store.upsertDocuments([
            PaceRetrievalDocument(
                id: "launch",
                source: .notes,
                title: "Launch notes",
                text: "Priya said the launch date moved to Friday and the privacy line must stay local only."
            ),
            PaceRetrievalDocument(
                id: "recipe",
                source: .notes,
                title: "Dinner",
                text: "Pasta sauce and grocery list."
            ),
        ])

        let matches = store.search(PaceRetrievalQuery(text: "what did Priya say about launch privacy"))

        #expect(matches.first?.documentId == "launch")
        #expect(matches.first?.excerpt.contains("Priya") == true)
        #expect(matches.first?.source == .notes)
    }

    @Test func lexicalRetrievalUsesRareTermsInsteadOfRepeatedGenericTerms() async throws {
        let store = PaceInMemoryRetrievalStore()
        store.upsertDocuments([
            PaceRetrievalDocument(
                id: "generic-launch-repeat",
                source: .notes,
                title: "Launch scratchpad",
                text: Array(repeating: "launch", count: 80).joined(separator: " ")
            ),
            PaceRetrievalDocument(
                id: "focused-privacy-note",
                source: .notes,
                title: "Launch privacy decision",
                text: "Priya said the launch privacy line must say local by architecture."
            )
        ])

        let matches = store.search(PaceRetrievalQuery(text: "launch privacy"))

        #expect(matches.first?.documentId == "focused-privacy-note")
        #expect((matches.first?.score ?? 0) > (matches.last?.score ?? 0))
    }

    @Test func disabledRetrievalSourceIsFilteredWithoutDeletingDocuments() async throws {
        let store = PaceInMemoryRetrievalStore()
        store.upsertDocuments([
            PaceRetrievalDocument(
                id: "calendar-launch",
                source: .calendar,
                title: "Launch review",
                text: "Priya design launch review on Friday."
            )
        ])

        #expect(store.search(PaceRetrievalQuery(text: "Priya launch")).first?.source == .calendar)

        store.setSourceEnabled(false, for: .calendar)
        #expect(store.search(PaceRetrievalQuery(text: "Priya launch")).isEmpty)
        #expect(store.sourceStatuses.first { $0.source == .calendar }?.lastError == "Disabled by user.")
        #expect(store.sourceStatuses.first { $0.source == .calendar }?.documentCount == 1)

        store.setSourceEnabled(true, for: .calendar)
        #expect(store.search(PaceRetrievalQuery(text: "Priya launch")).first?.source == .calendar)
    }

    @Test func persistentRetrievalStoreRoundTripsAndResetClearsDocuments() async throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-retrieval-persistence-\(UUID().uuidString)", isDirectory: true)
        let persistenceURL = temporaryRoot.appendingPathComponent("retrieval-index.json")
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let firstStore = PaceInMemoryRetrievalStore(persistenceURL: persistenceURL)
        firstStore.upsertDocuments([
            PaceRetrievalDocument(
                id: "history-launch",
                source: .paceHistory,
                title: "Recent launch turn",
                text: "Priya asked whether the launch privacy line stayed local."
            )
        ])

        let secondStore = PaceInMemoryRetrievalStore(persistenceURL: persistenceURL)
        #expect(secondStore.search(PaceRetrievalQuery(text: "Priya launch privacy")).first?.documentId == "history-launch")

        secondStore.reset()
        let thirdStore = PaceInMemoryRetrievalStore(persistenceURL: persistenceURL)
        #expect(thirdStore.search(PaceRetrievalQuery(text: "Priya launch privacy")).isEmpty)
    }

    @Test func clearingOneRetrievalSourcePersistsWithoutTouchingOtherSources() async throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-retrieval-source-clear-\(UUID().uuidString)", isDirectory: true)
        let persistenceURL = temporaryRoot.appendingPathComponent("retrieval-index.json")
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let store = PaceInMemoryRetrievalStore(persistenceURL: persistenceURL)
        let retriever = PaceLocalRetriever(
            store: store,
            appliesPersistedSourcePreferences: false
        )
        retriever.upsertDocuments([
            PaceRetrievalDocument(
                id: "calendar-launch",
                source: .calendar,
                title: "Launch review",
                text: "Priya launch review on Friday."
            ),
            PaceRetrievalDocument(
                id: "notes-launch",
                source: .notes,
                title: "Launch notes",
                text: "Priya launch notes say privacy must stay local."
            )
        ])

        retriever.clearDocuments(forSource: .calendar)

        let reloadedStore = PaceInMemoryRetrievalStore(persistenceURL: persistenceURL)
        #expect(reloadedStore.search(PaceRetrievalQuery(text: "Friday")).isEmpty)
        #expect(reloadedStore.search(PaceRetrievalQuery(text: "privacy local")).first?.source == .notes)
    }

    @Test func localContextBlockCapsItemsAndCharacters() async throws {
        let store = PaceInMemoryRetrievalStore()
        store.upsertDocuments([
            PaceRetrievalDocument(id: "one", source: .paceHistory, title: "One", text: "alpha beta launch privacy one"),
            PaceRetrievalDocument(id: "two", source: .paceHistory, title: "Two", text: "alpha beta launch privacy two"),
            PaceRetrievalDocument(id: "three", source: .paceHistory, title: "Three", text: "alpha beta launch privacy three"),
        ])
        let retriever = PaceLocalRetriever(
            store: store,
            maximumContextCharacters: 120,
            appliesPersistedSourcePreferences: false
        )

        let contextBlock = retriever.localContextBlock(
            for: PaceRetrievalQuery(
                text: "launch privacy",
                maximumResultCount: 3,
                maximumSnippetCharacters: 80
            )
        )

        #expect(contextBlock?.hasPrefix("LOCAL CONTEXT") == true)
        #expect((contextBlock?.count ?? 0) <= 120)
        #expect(contextBlock?.contains("1.") == true)
    }

    @Test func retrieverTracksQueryLatencyAndCanResetIndex() async throws {
        let store = PaceInMemoryRetrievalStore()
        let retriever = PaceLocalRetriever(
            store: store,
            appliesPersistedSourcePreferences: false
        )
        retriever.upsertDocuments([
            PaceRetrievalDocument(
                id: "history",
                source: .paceHistory,
                title: "Recent Pace turn",
                text: "User asked about launch privacy. Pace answered that the local-only line should stay."
            )
        ])

        let contextBlock = retriever.localContextBlock(
            for: PaceRetrievalQuery(text: "launch privacy")
        )

        #expect(contextBlock?.contains("LOCAL CONTEXT") == true)
        #expect(retriever.lastQueryDurationMilliseconds != nil)

        retriever.resetIndex(preservePreferences: false)
        #expect(retriever.sourceStatuses.allSatisfy { $0.documentCount == 0 })
        #expect(retriever.lastQueryDurationMilliseconds == nil)
        #expect(retriever.localContextBlock(for: PaceRetrievalQuery(text: "launch privacy")) == nil)
    }

    @Test func builtInCompetitiveResearchIncludesProjectMinimi() async throws {
        let retriever = PaceLocalRetriever(
            store: PaceInMemoryRetrievalStore(),
            appliesPersistedSourcePreferences: false
        )

        let contextBlock = retriever.localContextBlock(
            for: PaceRetrievalQuery(
                text: "how does Pace differ from Project Minimi Gemini embeddings Claude ambient memory",
                maximumResultCount: 2,
                maximumSnippetCharacters: 260
            )
        )

        #expect(contextBlock?.contains("Project Minimi") == true)
        #expect(contextBlock?.contains("Gemini") == true)
        #expect(contextBlock?.contains("cloud embeddings") == true)

        retriever.setSourceEnabled(false, for: .competitiveResearch)
        let disabledContextBlock = retriever.localContextBlock(
            for: PaceRetrievalQuery(text: "Project Minimi Gemini embeddings")
        )
        #expect(disabledContextBlock == nil)
    }

    @Test func retrievalContextPolicySkipsGenericAndScreenOnlyTurns() async throws {
        #expect(!PaceRetrievalContextPolicy.shouldQueryLocalContext(
            forTranscript: "explain transformers",
            route: .answerDirectly
        ))
        #expect(!PaceRetrievalContextPolicy.shouldQueryLocalContext(
            forTranscript: "click the save button",
            route: .executeTool
        ))
        #expect(!PaceRetrievalContextPolicy.shouldQueryLocalContext(
            forTranscript: "what's on the screen",
            route: .readScreen
        ))
    }

    @Test func retrievalContextPolicyAllowsOffscreenLocalReferences() async throws {
        #expect(PaceRetrievalContextPolicy.shouldQueryLocalContext(
            forTranscript: "what did Priya say about launch privacy",
            route: .fullPipeline
        ))
        #expect(PaceRetrievalContextPolicy.shouldQueryLocalContext(
            forTranscript: "open the deck I was editing yesterday",
            route: .executeTool
        ))
        #expect(PaceRetrievalContextPolicy.shouldQueryLocalContext(
            forTranscript: "make this more direct using my launch notes",
            route: .fullPipeline
        ))
        #expect(PaceRetrievalContextPolicy.shouldQueryLocalContext(
            forTranscript: "compare this to my latest note",
            route: .readScreen
        ))
    }

    @Test func fileConnectorSkipsSensitiveRootsAndLoadsAllowedTextFiles() async throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-retrieval-tests-\(UUID().uuidString)", isDirectory: true)
        let safeFileURL = temporaryRoot.appendingPathComponent("notes.md")
        let secretDirectoryURL = temporaryRoot.appendingPathComponent(".ssh", isDirectory: true)
        let secretFileURL = secretDirectoryURL.appendingPathComponent("id_ed25519")

        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secretDirectoryURL, withIntermediateDirectories: true)
        try "Roadmap launch notes for local retrieval.".write(to: safeFileURL, atomically: true, encoding: .utf8)
        try "PRIVATE KEY".write(to: secretFileURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let connector = PaceFileRetrievalConnector(rootURLs: [temporaryRoot])
        let result = connector.loadDocuments(maximumDocumentCount: 10)

        #expect(result.documents.count == 1)
        #expect(result.documents.first?.title == "notes.md")
        #expect(result.documents.first?.text.contains("Roadmap launch") == true)
        #expect(result.documents.contains { $0.localURL == secretFileURL } == false)
    }

    @Test func fileRootPreferencesNormalizeMergeAndParseConfiguredRoots() async throws {
        let suiteName = "pace-file-root-preferences-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let firstRootURL = URL(fileURLWithPath: "/tmp/pace-docs", isDirectory: true)
        let duplicateFirstRootURL = URL(fileURLWithPath: "/tmp/pace-docs/../pace-docs", isDirectory: true)
        let secondRootURL = URL(fileURLWithPath: "/tmp/pace-notes", isDirectory: true)

        let mergedRootURLs = PaceLocalRetrievalFileRootPreferences.mergedRootURLs(
            existingRootURLs: [firstRootURL],
            addingRootURLs: [duplicateFirstRootURL, secondRootURL]
        )
        let expectedMergedRootPaths = PaceLocalRetrievalFileRootPreferences.rootPaths(
            for: [firstRootURL, secondRootURL]
        )

        #expect(mergedRootURLs.map(\.path) == expectedMergedRootPaths)

        PaceLocalRetrievalFileRootPreferences.saveUserSelectedRootURLs(
            mergedRootURLs,
            userDefaults: userDefaults
        )
        #expect(
            PaceLocalRetrievalFileRootPreferences
                .userSelectedRootURLs(userDefaults: userDefaults)
                .map(\.path) == expectedMergedRootPaths
        )

        let configuredRootURLs = PaceLocalRetrievalFileRootPreferences.configuredRootURLs(
            userDefaults: userDefaults,
            infoPlistConfigurationString: "/tmp/pace-more,\n/tmp/pace-notes"
        )
        #expect(configuredRootURLs.map(\.path) == PaceLocalRetrievalFileRootPreferences.rootPaths(
            for: [
                firstRootURL,
                secondRootURL,
                URL(fileURLWithPath: "/tmp/pace-more", isDirectory: true)
            ]
        ))
    }

    @Test func spotlightConnectorFiltersInjectedCandidatesToSafeExplicitRoots() async throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-spotlight-tests-\(UUID().uuidString)", isDirectory: true)
        let outsideRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-spotlight-outside-\(UUID().uuidString)", isDirectory: true)
        let safeFileURL = temporaryRoot.appendingPathComponent("launch.md")
        let duplicateSafeFileURL = temporaryRoot.appendingPathComponent("launch.md")
        let unsupportedFileURL = temporaryRoot.appendingPathComponent("image.png")
        let secretDirectoryURL = temporaryRoot.appendingPathComponent(".ssh", isDirectory: true)
        let secretFileURL = secretDirectoryURL.appendingPathComponent("id_ed25519")
        let outsideFileURL = outsideRoot.appendingPathComponent("outside.md")

        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secretDirectoryURL, withIntermediateDirectories: true)
        try "Launch plan from Spotlight.".write(to: safeFileURL, atomically: true, encoding: .utf8)
        try "binary".write(to: unsupportedFileURL, atomically: true, encoding: .utf8)
        try "PRIVATE KEY".write(to: secretFileURL, atomically: true, encoding: .utf8)
        try "Outside document".write(to: outsideFileURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            try? FileManager.default.removeItem(at: outsideRoot)
        }

        let connector = PaceSpotlightRetrievalConnector(
            rootURLs: [temporaryRoot],
            candidateURLProvider: { request in
                #expect(request.rootURLs == [temporaryRoot])
                return [
                    safeFileURL,
                    duplicateSafeFileURL,
                    unsupportedFileURL,
                    secretFileURL,
                    outsideFileURL
                ]
            }
        )

        let result = connector.loadDocuments(maximumDocumentCount: 10)

        #expect(result.documents.count == 1)
        #expect(result.documents.first?.localURL == safeFileURL.standardizedFileURL)
        #expect(result.documents.first?.text.contains("Launch plan") == true)
        #expect(result.status.documentCount == 1)
    }

    @Test func spotlightConnectorRefusesMissingOrSensitiveRoots() async throws {
        let connector = PaceSpotlightRetrievalConnector(
            rootURLs: [
                URL(fileURLWithPath: "/Users/sarthak/.ssh"),
                URL(fileURLWithPath: "/tmp/pace-missing-\(UUID().uuidString)")
            ],
            candidateURLProvider: { _ in
                Issue.record("Spotlight should not run without a safe root")
                return []
            }
        )

        let result = connector.loadDocuments()

        #expect(result.documents.isEmpty)
        #expect(result.status.isEnabled == false)
        #expect(result.status.lastError == "No safe Spotlight roots configured.")
    }

    @Test func calendarSnapshotMapsToCompactRetrievalDocument() async throws {
        let startDate = Date(timeIntervalSince1970: 1_781_000_000)
        let endDate = startDate.addingTimeInterval(45 * 60)
        let eventSnapshot = PaceCalendarRetrievalEventSnapshot(
            stableIdentifier: "event-123",
            title: "Launch review",
            startDate: startDate,
            endDate: endDate,
            calendarTitle: "Work",
            location: "Design room",
            notes: "Discuss local-only launch copy.\nConfirm the privacy line."
        )

        let document = PaceCalendarRetrievalConnector.document(from: eventSnapshot)

        #expect(document.id == "calendar-event-123")
        #expect(document.source == .calendar)
        #expect(document.title == "Launch review")
        #expect(document.text.contains("When:"))
        #expect(document.text.contains("Calendar: Work"))
        #expect(document.text.contains("Location: Design room"))
        #expect(document.text.contains("Discuss local-only launch copy. Confirm the privacy line."))
        #expect(document.permissionScope == "eventkit-calendar")
    }

    @Test func calendarWriteOnlyPermissionIsSkippedForRetrieval() async throws {
        let status = PaceCalendarRetrievalConnector.skippedStatus(for: .writeOnly)

        #expect(!PaceCalendarRetrievalConnector.canReadCalendarEvents(.writeOnly))
        #expect(status.source == .calendar)
        #expect(status.isEnabled == false)
        #expect(status.lastError?.contains("write-only") == true)
    }

    @Test func skippedSourceStatusSurvivesOtherSourceUpserts() async throws {
        let store = PaceInMemoryRetrievalStore()
        store.updateSourceStatus(PaceCalendarRetrievalConnector.skippedStatus(for: .denied))

        store.upsertDocuments([
            PaceRetrievalDocument(
                id: "history",
                source: .paceHistory,
                title: "Recent Pace turn",
                text: "User asked about launch privacy."
            )
        ])

        let calendarStatus = store.sourceStatuses.first { $0.source == .calendar }

        #expect(calendarStatus?.isEnabled == false)
        #expect(calendarStatus?.lastError?.contains("denied") == true)
    }

    @Test func reminderSnapshotMapsToCompactRetrievalDocument() async throws {
        let dueDate = Date(timeIntervalSince1970: 1_781_200_000)
        let reminderSnapshot = PaceReminderRetrievalSnapshot(
            stableIdentifier: "reminder-123",
            title: "Send launch invoice",
            notes: "Use the local-only launch billing note.\nAttach final PDF.",
            listTitle: "Work",
            dueDate: dueDate,
            priority: 5,
            isCompleted: false
        )

        let document = PaceRemindersRetrievalConnector.document(from: reminderSnapshot)

        #expect(document.id == "reminder-reminder-123")
        #expect(document.source == .reminders)
        #expect(document.title == "Send launch invoice")
        #expect(document.text.contains("Status: open"))
        #expect(document.text.contains("Due:"))
        #expect(document.text.contains("List: Work"))
        #expect(document.text.contains("Priority: 5"))
        #expect(document.text.contains("Use the local-only launch billing note. Attach final PDF."))
        #expect(document.permissionScope == "eventkit-reminders")
    }

    @Test func remindersWriteOnlyPermissionIsSkippedForRetrieval() async throws {
        let status = PaceRemindersRetrievalConnector.skippedStatus(for: .writeOnly)

        #expect(!PaceRemindersRetrievalConnector.canReadReminders(.writeOnly))
        #expect(status.source == .reminders)
        #expect(status.isEnabled == false)
        #expect(status.lastError?.contains("write-only") == true)
    }

    @Test func contactSnapshotMapsToCompactRetrievalDocument() async throws {
        let contactSnapshot = PaceContactRetrievalSnapshot(
            stableIdentifier: "contact-123",
            displayName: "Priya Shah",
            nickname: "Pri",
            organizationName: "Pace Labs",
            jobTitle: "Design Lead",
            emailAddresses: ["priya@example.com", "priya.work@example.com", "priya@example.com"]
        )

        let document = PaceContactsRetrievalConnector.document(from: contactSnapshot)

        #expect(document.id == "contact-contact-123")
        #expect(document.source == .contacts)
        #expect(document.title == "Priya Shah")
        #expect(document.text.contains("Name: Priya Shah"))
        #expect(document.text.contains("Nickname: Pri"))
        #expect(document.text.contains("Organization: Pace Labs"))
        #expect(document.text.contains("Title: Design Lead"))
        #expect(document.text.contains("Email: priya@example.com, priya.work@example.com"))
        #expect(document.permissionScope == "contacts")
    }

    @Test func contactsDeniedPermissionIsSkippedForRetrieval() async throws {
        let status = PaceContactsRetrievalConnector.skippedStatus(for: .denied)

        #expect(!PaceContactsRetrievalConnector.canReadContacts(.denied))
        #expect(status.source == .contacts)
        #expect(status.isEnabled == false)
        #expect(status.lastError?.contains("denied") == true)
    }

    @Test func noteSnapshotMapsToCompactRetrievalDocument() async throws {
        let noteSnapshot = PaceNoteRetrievalSnapshot(
            stableIdentifier: "note-123",
            title: "Launch notes",
            body: "<div>Priya said &quot;keep it local&quot;.</div><br><div>No cloud fallback.</div>"
        )

        let document = PaceNotesRetrievalConnector.document(from: noteSnapshot)

        #expect(document.id == "note-note-123")
        #expect(document.source == .notes)
        #expect(document.title == "Launch notes")
        #expect(document.text.contains("Title: Launch notes"))
        #expect(document.text.contains("Priya said \"keep it local\". No cloud fallback."))
        #expect(document.permissionScope == "apple-events-notes-read")
    }

    @Test func notesAppleScriptOutputParsesIntoSnapshots() async throws {
        let fieldSeparator = String(UnicodeScalar(31)!)
        let recordSeparator = String(UnicodeScalar(30)!)
        let output = [
            ["id-1", "Launch notes", "Local-only launch line"].joined(separator: fieldSeparator),
            ["id-2", "Pricing", "Pro tier notes"].joined(separator: fieldSeparator)
        ]
            .joined(separator: recordSeparator)

        let snapshots = PaceNotesRetrievalConnector.snapshots(fromAppleScriptOutput: output)

        #expect(snapshots.count == 2)
        #expect(snapshots[0].stableIdentifier == "id-1")
        #expect(snapshots[0].title == "Launch notes")
        #expect(snapshots[0].body == "Local-only launch line")
        #expect(snapshots[1].stableIdentifier == "id-2")
    }

    @Test func mailSnapshotMapsToCompactRetrievalDocument() async throws {
        let mailSnapshot = PaceMailRetrievalSnapshot(
            stableIdentifier: "message-123",
            subject: "Launch review",
            sender: "Priya Shah <priya@example.com>",
            receivedAtText: "Tuesday, June 9, 2026 at 10:14:00 AM",
            body: "The local-only line is approved.\nNo cloud fallback."
        )

        let document = PaceMailRetrievalConnector.document(from: mailSnapshot)

        #expect(document.id == "mail-message-123")
        #expect(document.source == .mail)
        #expect(document.title == "Launch review")
        #expect(document.text.contains("Subject: Launch review"))
        #expect(document.text.contains("From: Priya Shah <priya@example.com>"))
        #expect(document.text.contains("Received: Tuesday, June 9, 2026"))
        #expect(document.text.contains("The local-only line is approved. No cloud fallback."))
        #expect(document.permissionScope == "apple-events-mail-read")
    }

    @Test func mailAppleScriptOutputParsesIntoSnapshots() async throws {
        let fieldSeparator = String(UnicodeScalar(31)!)
        let recordSeparator = String(UnicodeScalar(30)!)
        let output = [
            ["id-1", "Launch review", "Priya <priya@example.com>", "June 9", "Local-only line"].joined(separator: fieldSeparator),
            ["id-2", "Pricing", "Alex <alex@example.com>", "June 8", "Pro tier notes"].joined(separator: fieldSeparator)
        ]
            .joined(separator: recordSeparator)

        let snapshots = PaceMailRetrievalConnector.snapshots(fromAppleScriptOutput: output)

        #expect(snapshots.count == 2)
        #expect(snapshots[0].stableIdentifier == "id-1")
        #expect(snapshots[0].subject == "Launch review")
        #expect(snapshots[0].sender == "Priya <priya@example.com>")
        #expect(snapshots[0].receivedAtText == "June 9")
        #expect(snapshots[0].body == "Local-only line")
        #expect(snapshots[1].stableIdentifier == "id-2")
    }
}
