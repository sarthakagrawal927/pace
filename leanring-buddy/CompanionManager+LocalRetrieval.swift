//
//  CompanionManager+LocalRetrieval.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition):
//  local retrieval context assembly, connector refresh, and source management.
//

import Contacts
import EventKit
import Foundation

@MainActor
extension CompanionManager {

    // MARK: - Local retrieval

    func appendLocalRetrievalContext(
        to userPrompt: String,
        query: String,
        route: PaceIntentRoute,
        isFirstPlannerStep: Bool = true
    ) async -> String {
        guard isFirstPlannerStep else { return userPrompt }
        guard PaceRetrievalContextPolicy.shouldQueryLocalContext(
            forTranscript: query,
            route: route
        ) else {
            return userPrompt
        }

        defer {
            // Updates the Settings retrieval status AND debounce-triggers the
            // connector → unified-index resync, so the single recall path below
            // keeps trailing connector changes.
            refreshLocalRetrievalPublishedState()
        }

        // Phase 5 step 3 (docs/prds/unified-memory.md): the unified index is
        // now the SINGLE recall path. It's a superset — conversation turns +
        // durable facts (dual-written) + every connector source (synced in) —
        // and the retriever ranks it semantically when embeddings are loaded,
        // by BM25 keyword otherwise. The legacy parallel lexical-injection path
        // (`rerankedLocalContextBlock`) has been retired; `PaceLocalRetrieval`
        // remains only as the connector ingestion layer the resync reads from.
        // Verbatim-window turns are excluded — they already ship to the planner
        // as conversation history, so re-injecting them would duplicate.
        guard PaceUserPreferencesStore.bool(.useUnifiedMemoryRecall, default: true) else {
            return userPrompt
        }
        let verbatimWindowTurnIds = Set(threadMemory.verbatimWindow().map { $0.turnId })
        guard let memoryContextBlock = await memoryRetriever.assembleContextBlock(
            forQuery: query,
            excludingEntryIds: verbatimWindowTurnIds,
            maxEntries: 8,
            now: Date()
        ) else {
            return userPrompt
        }
        return "\(memoryContextBlock)\n\nUSER REQUEST\n\(userPrompt)"
    }

    func localRetrievalSummaryText(
        from sourceStatuses: [PaceRetrievalSourceStatus],
        lastQueryDurationMilliseconds: Int? = nil
    ) -> String {
        let activeSourceSummaries = sourceStatuses
            .filter { $0.documentCount > 0 }
            .map { "\($0.displayName): \($0.documentCount)" }

        guard !activeSourceSummaries.isEmpty else {
            return "Retrieval: no local context indexed"
        }
        var summary = "Retrieval: " + activeSourceSummaries.joined(separator: " · ")
        if let lastQueryDurationMilliseconds {
            summary += " · Query: \(lastQueryDurationMilliseconds)ms"
        }
        return summary
    }

    func refreshLocalRetrievalPublishedState() {
        let sourceStatuses = localRetriever.sourceStatuses
        localRetrievalSourceStatuses = sourceStatuses
        localRetrievalSummary = localRetrievalSummaryText(
            from: sourceStatuses,
            lastQueryDurationMilliseconds: localRetriever.lastQueryDurationMilliseconds
        )
        // Trail connector changes into the unified index (debounced). This
        // only READS from the retriever, so it can't re-enter this method.
        syncConnectorsIntoUnifiedMemoryIfDue()
    }

    func addLocalRetrievalFileRootURLs(_ rootURLs: [URL]) {
        let safeNewRootURLs = rootURLs
            .map { URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL }
            .filter { !PaceSecretPathExclusionPolicy.shouldExclude(localURL: $0) }

        let existingRootURLs = PaceLocalRetrievalFileRootPreferences.userSelectedRootURLs()
        let mergedRootURLs = PaceLocalRetrievalFileRootPreferences.mergedRootURLs(
            existingRootURLs: existingRootURLs,
            addingRootURLs: safeNewRootURLs
        )
        saveLocalRetrievalUserSelectedFileRootURLs(mergedRootURLs)
    }

    func removeLocalRetrievalFileRootPath(_ rootPath: String) {
        let rootURLToRemove = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let remainingRootURLs = PaceLocalRetrievalFileRootPreferences
            .userSelectedRootURLs()
            .filter { $0.path != rootURLToRemove.path }
        saveLocalRetrievalUserSelectedFileRootURLs(remainingRootURLs)
    }

    func clearLocalRetrievalFileRootPaths() {
        saveLocalRetrievalUserSelectedFileRootURLs([])
    }

    func saveLocalRetrievalUserSelectedFileRootURLs(_ rootURLs: [URL]) {
        PaceLocalRetrievalFileRootPreferences.saveUserSelectedRootURLs(rootURLs)
        localRetrievalFileRootPaths = PaceLocalRetrievalFileRootPreferences.rootPaths(for: rootURLs)
        handleLocalRetrievalFileRootConfigurationChanged()
    }

    func handleLocalRetrievalFileRootConfigurationChanged() {
        fileRetrievalRefreshTask?.cancel()
        fileRetrievalRefreshTask = nil
        lastFileRetrievalRefreshAt = nil
        spotlightRetrievalConnector = PaceSpotlightRetrievalConnector(
            rootURLs: PaceLocalRetrievalFileRootPreferences.configuredRootURLs()
        )
        localRetriever.clearDocuments(forSource: .file)
        refreshFileRetrievalDocumentsIfAllowed(force: true)
        refreshLocalRetrievalPublishedState()
        currentTurnHUDState = .done("file retrieval folders updated")
    }

    func setLocalRetrievalSourceEnabled(_ isEnabled: Bool, for source: PaceRetrievalSource) {
        localRetriever.setSourceEnabled(isEnabled, for: source)
        refreshLocalRetrievalPublishedState()

        if source == .appUsageHistory, !isEnabled {
            appUsageTracker?.stop()
        }
        guard isEnabled else { return }
        switch source {
        case .calendar:
            refreshCalendarRetrievalDocumentsIfAllowed(force: true)
        case .reminders:
            refreshRemindersRetrievalDocumentsIfAllowed(force: true)
        case .contacts:
            refreshContactsRetrievalDocumentsIfAllowed(force: true)
        case .notes:
            refreshNotesRetrievalDocumentsIfAllowed(force: true)
        case .mail:
            refreshMailRetrievalDocumentsIfAllowed(force: true)
        case .localPreference:
            localRetriever.refreshPreferenceDocuments()
            refreshLocalRetrievalPublishedState()
        case .competitiveResearch:
            localRetriever.refreshCompetitiveResearchDocuments()
            refreshLocalRetrievalPublishedState()
        case .file:
            refreshFileRetrievalDocumentsIfAllowed(force: true)
        case .paceHistory, .screenWatchHistory, .episodicMemory:
            // Both are recorded passively as turns/watch events happen —
            // nothing to refresh on re-enable.
            break
        case .appUsageHistory:
            appUsageTracker?.start()
        case .screenTime:
            refreshScreenTimeRetrievalDocumentsIfAllowed(force: true)
        }
    }

    /// Reads macOS's own Screen Time database into the retrieval index.
    /// No prompt is ever shown: without Full Disk Access the read fails and
    /// the source row shows the repair hint instead.
    func refreshScreenTimeRetrievalDocumentsIfAllowed(force: Bool = false) {
        guard localRetriever.isSourceEnabled(.screenTime) else {
            refreshLocalRetrievalPublishedState()
            return
        }
        let connector = screenTimeRetrievalConnector
        Task.detached(priority: .utility) { [weak self] in
            let outcome: Result<[PaceRetrievalDocument], Error> = Result {
                try connector.loadScreenTimeDocuments()
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch outcome {
                case .success(let documents):
                    self.localRetriever.replaceDocuments(
                        documents,
                        forSource: .screenTime,
                        status: .enabled(
                            source: .screenTime,
                            displayName: PaceRetrievalSource.screenTime.displayName,
                            documentCount: documents.count
                        )
                    )
                    print("🔎 Screen Time retrieval: \(documents.count) day(s) indexed")
                case .failure(let error):
                    self.localRetriever.replaceDocuments(
                        [],
                        forSource: .screenTime,
                        status: .skipped(
                            source: .screenTime,
                            displayName: PaceRetrievalSource.screenTime.displayName,
                            reason: (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription
                        )
                    )
                    print("🔎 Screen Time retrieval skipped: \(error.localizedDescription)")
                }
                self.refreshLocalRetrievalPublishedState()
            }
        }
    }

    func isLocalRetrievalSourceEnabled(_ source: PaceRetrievalSource) -> Bool {
        localRetriever.isSourceEnabled(source)
    }

    func clearLocalRetrievalSource(_ source: PaceRetrievalSource) {
        localRetriever.clearDocuments(forSource: source)
        refreshLocalRetrievalPublishedState()
        currentTurnHUDState = .done("\(source.displayName.lowercased()) retrieval cleared")
        print("🔎 Local retrieval source cleared: \(source.displayName)")
    }

    func refreshCalendarRetrievalDocumentsIfAllowed(force: Bool = false) {
        guard localRetriever.isSourceEnabled(.calendar) else {
            refreshLocalRetrievalPublishedState()
            return
        }
        let calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        let authorizationStatusChanged = lastCalendarRetrievalAuthorizationStatus != calendarAuthorizationStatus
        lastCalendarRetrievalAuthorizationStatus = calendarAuthorizationStatus

        guard PaceCalendarRetrievalConnector.canReadCalendarEvents(calendarAuthorizationStatus) else {
            guard force || authorizationStatusChanged else { return }
            localRetriever.replaceDocuments(
                [],
                forSource: .calendar,
                status: PaceCalendarRetrievalConnector.skippedStatus(for: calendarAuthorizationStatus)
            )
            lastCalendarRetrievalRefreshAt = nil
            refreshLocalRetrievalPublishedState()
            return
        }

        let now = Date()
        if !force,
           !authorizationStatusChanged,
           let lastCalendarRetrievalRefreshAt,
           now.timeIntervalSince(lastCalendarRetrievalRefreshAt) < 300 {
            return
        }

        let result = calendarRetrievalConnector.loadDocuments()
        localRetriever.replaceDocuments(
            result.documents,
            forSource: .calendar,
            status: result.status
        )
        lastCalendarRetrievalRefreshAt = now
        refreshLocalRetrievalPublishedState()
        print("🔎 Calendar retrieval refreshed: \(result.documents.count) event(s)")
    }

    func refreshRemindersRetrievalDocumentsIfAllowed(force: Bool = false) {
        guard localRetriever.isSourceEnabled(.reminders) else {
            refreshLocalRetrievalPublishedState()
            return
        }
        let reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        let authorizationStatusChanged = lastRemindersRetrievalAuthorizationStatus != reminderAuthorizationStatus
        lastRemindersRetrievalAuthorizationStatus = reminderAuthorizationStatus

        guard PaceRemindersRetrievalConnector.canReadReminders(reminderAuthorizationStatus) else {
            guard force || authorizationStatusChanged else { return }
            remindersRetrievalRefreshTask?.cancel()
            remindersRetrievalRefreshTask = nil
            localRetriever.replaceDocuments(
                [],
                forSource: .reminders,
                status: PaceRemindersRetrievalConnector.skippedStatus(for: reminderAuthorizationStatus)
            )
            lastRemindersRetrievalRefreshAt = nil
            refreshLocalRetrievalPublishedState()
            return
        }

        let now = Date()
        if !force,
           !authorizationStatusChanged,
           let lastRemindersRetrievalRefreshAt,
           now.timeIntervalSince(lastRemindersRetrievalRefreshAt) < 300 {
            return
        }

        lastRemindersRetrievalRefreshAt = now
        remindersRetrievalRefreshTask?.cancel()
        remindersRetrievalRefreshTask = Task { [weak self] in
            guard let self else { return }
            let result = await remindersRetrievalConnector.loadDocuments()
            guard !Task.isCancelled else { return }

            localRetriever.replaceDocuments(
                result.documents,
                forSource: .reminders,
                status: result.status
            )
            refreshLocalRetrievalPublishedState()
            print("🔎 Reminders retrieval refreshed: \(result.documents.count) reminder(s)")
        }
    }

    func refreshContactsRetrievalDocumentsIfAllowed(force: Bool = false) {
        guard localRetriever.isSourceEnabled(.contacts) else {
            refreshLocalRetrievalPublishedState()
            return
        }
        let contactsAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        let authorizationStatusChanged = lastContactsRetrievalAuthorizationStatus != contactsAuthorizationStatus
        lastContactsRetrievalAuthorizationStatus = contactsAuthorizationStatus

        guard PaceContactsRetrievalConnector.canReadContacts(contactsAuthorizationStatus) else {
            guard force || authorizationStatusChanged else { return }
            contactsRetrievalRefreshTask?.cancel()
            contactsRetrievalRefreshTask = nil
            localRetriever.replaceDocuments(
                [],
                forSource: .contacts,
                status: PaceContactsRetrievalConnector.skippedStatus(for: contactsAuthorizationStatus)
            )
            lastContactsRetrievalRefreshAt = nil
            refreshLocalRetrievalPublishedState()
            return
        }

        let now = Date()
        if !force,
           !authorizationStatusChanged,
           let lastContactsRetrievalRefreshAt,
           now.timeIntervalSince(lastContactsRetrievalRefreshAt) < 300 {
            return
        }

        lastContactsRetrievalRefreshAt = now
        contactsRetrievalRefreshTask?.cancel()
        contactsRetrievalRefreshTask = Task { [weak self] in
            guard let self else { return }
            let result = contactsRetrievalConnector.loadDocuments()
            guard !Task.isCancelled else { return }

            localRetriever.replaceDocuments(
                result.documents,
                forSource: .contacts,
                status: result.status
            )
            refreshLocalRetrievalPublishedState()
            print("🔎 Contacts retrieval refreshed: \(result.documents.count) contact(s)")
        }
    }

    func refreshNotesRetrievalDocumentsIfAllowed(force: Bool = false) {
        guard localRetriever.isSourceEnabled(.notes) else {
            refreshLocalRetrievalPublishedState()
            return
        }

        let now = Date()
        if !force,
           let lastNotesRetrievalRefreshAt,
           now.timeIntervalSince(lastNotesRetrievalRefreshAt) < 300 {
            return
        }

        lastNotesRetrievalRefreshAt = now
        notesRetrievalRefreshTask?.cancel()
        notesRetrievalRefreshTask = Task { [weak self] in
            guard let self else { return }
            let result = notesRetrievalConnector.loadDocuments()
            guard !Task.isCancelled else { return }

            localRetriever.replaceDocuments(
                result.documents,
                forSource: .notes,
                status: result.status
            )
            refreshLocalRetrievalPublishedState()
            print("🔎 Notes retrieval refreshed: \(result.documents.count) note(s)")
        }
    }

    func refreshMailRetrievalDocumentsIfAllowed(force: Bool = false) {
        guard localRetriever.isSourceEnabled(.mail) else {
            refreshLocalRetrievalPublishedState()
            return
        }

        let now = Date()
        if !force,
           let lastMailRetrievalRefreshAt,
           now.timeIntervalSince(lastMailRetrievalRefreshAt) < 300 {
            return
        }

        lastMailRetrievalRefreshAt = now
        mailRetrievalRefreshTask?.cancel()
        mailRetrievalRefreshTask = Task { [weak self] in
            guard let self else { return }
            let result = mailRetrievalConnector.loadDocuments()
            guard !Task.isCancelled else { return }

            localRetriever.replaceDocuments(
                result.documents,
                forSource: .mail,
                status: result.status
            )
            refreshLocalRetrievalPublishedState()
            print("🔎 Mail retrieval refreshed: \(result.documents.count) message(s)")
        }
    }

    func refreshFileRetrievalDocumentsIfAllowed(force: Bool = false) {
        guard localRetriever.isSourceEnabled(.file) else {
            refreshLocalRetrievalPublishedState()
            return
        }

        let now = Date()
        if !force,
           let lastFileRetrievalRefreshAt,
           now.timeIntervalSince(lastFileRetrievalRefreshAt) < 300 {
            return
        }

        lastFileRetrievalRefreshAt = now
        fileRetrievalRefreshTask?.cancel()
        fileRetrievalRefreshTask = Task { [weak self] in
            guard let self else { return }
            let result = spotlightRetrievalConnector.loadDocuments()
            guard !Task.isCancelled else { return }

            localRetriever.replaceDocuments(
                result.documents,
                forSource: .file,
                status: result.status
            )
            refreshLocalRetrievalPublishedState()
            print("🔎 File retrieval refreshed: \(result.documents.count) file(s)")
        }
    }

    func resetLocalRetrievalIndex() {
        localRetriever.resetIndex(preservePreferences: true)
        refreshFileRetrievalDocumentsIfAllowed(force: true)
        refreshCalendarRetrievalDocumentsIfAllowed(force: true)
        refreshRemindersRetrievalDocumentsIfAllowed(force: true)
        refreshContactsRetrievalDocumentsIfAllowed(force: true)
        refreshNotesRetrievalDocumentsIfAllowed(force: true)
        refreshMailRetrievalDocumentsIfAllowed(force: true)
        refreshLocalRetrievalPublishedState()
        currentTurnHUDState = .done("retrieval reset")
        print("🔎 Local retrieval index reset")
    }
}
