//
//  CompanionManager+MorningTriage.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition):
//  morning triage daily brief + watch-mode toggle methods. Stored
//  `@Published` settings and `morningTriageScheduler` remain in the
//  main file.
//

import AppKit
import Foundation

@MainActor
extension CompanionManager {

    // MARK: - Morning triage (daily brief)

    func setMorningTriageEnabled(_ enabled: Bool) {
        isMorningTriageEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .isMorningTriageEnabled)
        if enabled {
            morningTriageScheduler.start()
        } else {
            morningTriageScheduler.stop()
        }
    }
    func setMorningTriageHourOfDay(_ hourOfDay: Int) {
        let clampedHourOfDay = min(max(hourOfDay, 0), 23)
        morningTriageHourOfDay = clampedHourOfDay
        PaceUserPreferencesStore.setInt(clampedHourOfDay, for: .morningTriageHourOfDay)
        morningTriageScheduler.setFireTime(
            hourOfDay: clampedHourOfDay,
            minuteOfHour: morningTriageMinuteOfHour
        )
    }
    func setMorningTriageMinuteOfHour(_ minuteOfHour: Int) {
        let clampedMinuteOfHour = min(max(minuteOfHour, 0), 59)
        morningTriageMinuteOfHour = clampedMinuteOfHour
        PaceUserPreferencesStore.setInt(clampedMinuteOfHour, for: .morningTriageMinuteOfHour)
        morningTriageScheduler.setFireTime(
            hourOfDay: morningTriageHourOfDay,
            minuteOfHour: clampedMinuteOfHour
        )
    }
    /// Pulls compact typed inputs from currently-indexed retrieval
    /// documents. Calendar / mail / reminders / app-usage all come
    /// from the same retriever the rest of the app uses, so the brief
    /// degrades gracefully to whatever is enabled without crashing.
    func buildMorningBriefInputs(forNow now: Date) -> PaceMorningBriefInputs {
        let calendarBriefEvents = todaysCalendarBriefEvents(forNow: now)
        let (unreadMailCount, topMailSender, topMailSubject) = morningMailSummary()
        let (openRemindersDueToday, topReminderTitle, topReminderDueText) = morningRemindersSummary(forNow: now)
        let (yesterdayTopApp, yesterdayTopAppMinutes) = yesterdayAppUsageSummary(forNow: now)
        let yesterdayWatchHighlight = yesterdayWatchHighlightSummary(forNow: now)

        return PaceMorningBriefInputs(
            now: now,
            userFirstName: nil,
            todaysEvents: calendarBriefEvents,
            unreadMailCount: unreadMailCount,
            topMailSender: topMailSender,
            topMailSubject: topMailSubject,
            openRemindersDueToday: openRemindersDueToday,
            topReminderTitle: topReminderTitle,
            topReminderDueText: topReminderDueText,
            yesterdayTopApp: yesterdayTopApp,
            yesterdayTopAppMinutes: yesterdayTopAppMinutes,
            yesterdayWatchHighlight: yesterdayWatchHighlight
        )
    }

    /// Lightweight today-only view of indexed calendar events. We don't
    /// hit EventKit here — the retriever already mirrors calendar state
    /// through its per-source refresh, and the brief only needs title +
    /// start time to compose the spoken paragraph.
    func todaysCalendarBriefEvents(forNow now: Date) -> [CalendarBriefEvent] {
        guard localRetriever.isSourceEnabled(.calendar) else { return [] }
        // The connector keeps the start date on the document's
        // `modifiedAt` field, so we filter by same-day there to find
        // today's events without re-parsing the indexed text body.
        let calendarUserCalendar = Calendar.current
        let documentsWithStartDate: [(document: PaceRetrievalDocument, startDate: Date)] = localRetriever
            .documents(forSource: .calendar)
            .compactMap { document in
                guard let documentModifiedAt = document.modifiedAt else { return nil }
                return (document, documentModifiedAt)
            }
            .filter { calendarUserCalendar.isDate($0.startDate, inSameDayAs: now) }
            .sorted { $0.startDate < $1.startDate }
        return documentsWithStartDate
            .prefix(2)
            .map { documentAndStartDate in
                CalendarBriefEvent(
                    title: documentAndStartDate.document.title,
                    startDate: documentAndStartDate.startDate,
                    isAllDay: false
                )
            }
    }

    /// Best-effort unread-mail summary. v1: counts indexed mail
    /// documents touched in the last 18 hours. A v2 connector could
    /// expose a richer typed snapshot.
    func morningMailSummary() -> (count: Int, topSender: String?, topSubject: String?) {
        guard localRetriever.isSourceEnabled(.mail) else { return (0, nil, nil) }
        let recentMailDocuments = localRetriever
            .documents(forSource: .mail)
            .sorted { firstDocument, secondDocument in
                let firstModifiedAt = firstDocument.modifiedAt ?? .distantPast
                let secondModifiedAt = secondDocument.modifiedAt ?? .distantPast
                return firstModifiedAt > secondModifiedAt
            }
            .prefix(20)
        let topDocument = recentMailDocuments.first
        return (recentMailDocuments.count, nil, topDocument?.title)
    }

    /// Best-effort reminders summary. v1: counts indexed reminder
    /// documents whose modifiedAt sits today.
    func morningRemindersSummary(forNow now: Date) -> (count: Int, topTitle: String?, topDueText: String?) {
        guard localRetriever.isSourceEnabled(.reminders) else { return (0, nil, nil) }
        let calendarUserCalendar = Calendar.current
        let documentsWithDueDate: [(document: PaceRetrievalDocument, dueDate: Date)] = localRetriever
            .documents(forSource: .reminders)
            .compactMap { document in
                guard let documentModifiedAt = document.modifiedAt else { return nil }
                return (document, documentModifiedAt)
            }
            .filter { calendarUserCalendar.isDate($0.dueDate, inSameDayAs: now) }
            .sorted { $0.dueDate < $1.dueDate }
        let topPair = documentsWithDueDate.first
        let topDueText: String?
        if let topPairDueDate = topPair?.dueDate {
            let dueDateFormatter = DateFormatter()
            dueDateFormatter.dateStyle = .none
            dueDateFormatter.timeStyle = .short
            dueDateFormatter.locale = Locale(identifier: "en_US_POSIX")
            topDueText = "due at \(dueDateFormatter.string(from: topPairDueDate).lowercased())"
        } else {
            topDueText = nil
        }
        return (documentsWithDueDate.count, topPair?.document.title, topDueText)
    }

    /// Best-effort yesterday app-usage summary. We let the journal
    /// formatter render its own line; the brief only needs the top
    /// app name + minutes, so we parse the first usage line.
    func yesterdayAppUsageSummary(forNow now: Date) -> (topApp: String?, minutes: Int?) {
        guard localRetriever.isSourceEnabled(.appUsageHistory) else { return (nil, nil) }
        let calendarUserCalendar = Calendar.current
        guard let yesterday = calendarUserCalendar.date(byAdding: .day, value: -1, to: now) else {
            return (nil, nil)
        }
        let yesterdayUsageDocument = localRetriever
            .documents(forSource: .appUsageHistory)
            .first { document in
                guard let documentModifiedAt = document.modifiedAt else { return false }
                return calendarUserCalendar.isDate(documentModifiedAt, inSameDayAs: yesterday)
            }
        guard let yesterdayUsageDocumentText = yesterdayUsageDocument?.text else {
            return (nil, nil)
        }
        return parseYesterdayTopAppUsageLine(yesterdayUsageDocumentText)
    }

    /// Pulls the top-app + minutes from the first usage line written
    /// by `PaceAppUsageJournal`. Done as a tiny pure parser so it
    /// can be unit-checked separately if the journal format changes.
    func parseYesterdayTopAppUsageLine(_ usageDocumentText: String) -> (topApp: String?, minutes: Int?) {
        // The journal lines look like: "Xcode — 240 min · 14 switches".
        // We only need the first meaningful line; the doc may include
        // a date header on line 0.
        let candidateLines = usageDocumentText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for candidateLine in candidateLines {
            guard candidateLine.contains("min") else { continue }
            let separatorRange = candidateLine.range(of: " — ")
                ?? candidateLine.range(of: " - ")
                ?? candidateLine.range(of: ":")
            guard let separatorRange else { continue }
            let topAppName = String(candidateLine[..<separatorRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let remainderText = candidateLine[separatorRange.upperBound...]
            guard let digitsStartIndex = remainderText.firstIndex(where: { $0.isNumber }) else {
                continue
            }
            let digitsRemainder = remainderText[digitsStartIndex...]
            let digitsEndIndex = digitsRemainder.firstIndex(where: { !$0.isNumber }) ?? digitsRemainder.endIndex
            guard let parsedMinutes = Int(digitsRemainder[..<digitsEndIndex]) else { continue }
            return (topAppName.isEmpty ? nil : topAppName, parsedMinutes)
        }
        return (nil, nil)
    }

    /// Best-effort yesterday watch-mode highlight. v1: returns the first
    /// non-empty line from yesterday's watch-journal document.
    func yesterdayWatchHighlightSummary(forNow now: Date) -> String? {
        guard localRetriever.isSourceEnabled(.screenWatchHistory) else { return nil }
        let calendarUserCalendar = Calendar.current
        guard let yesterday = calendarUserCalendar.date(byAdding: .day, value: -1, to: now) else {
            return nil
        }
        let yesterdayWatchDocument = localRetriever
            .documents(forSource: .screenWatchHistory)
            .first { document in
                guard let documentModifiedAt = document.modifiedAt else { return false }
                return calendarUserCalendar.isDate(documentModifiedAt, inSameDayAs: yesterday)
            }
        return yesterdayWatchDocument?.title
    }

    /// Plays the queued morning-brief card aloud and clears it.
    /// Wired to the small play button on the brief card so users who
    /// missed the spoken brief can hear it on demand.
    func playPendingMorningBrief() {
        guard let pendingMorningBriefText = morningTriageScheduler.pendingMorningBriefCard else { return }
        Task { @MainActor in
            try? await self.ttsClient.speakText(pendingMorningBriefText)
            self.morningTriageScheduler.dismissPendingCard()
        }
    }

    /// User-initiated preview entry point used by Settings → "Send it now".
    /// Wraps `morningTriageScheduler.deliverNowForTesting()` so the
    /// SwiftUI button can call a synchronous-looking API.
    func deliverMorningBriefPreviewNow() {
        Task { @MainActor in
            await self.morningTriageScheduler.deliverNowForTesting()
        }
    }

    /// Builds the gate context for a morning-brief fire. Uses
    /// conservative defaults — the gate's main job for this source
    /// is the active-call check.
    func buildMorningTriageRestraintContext(forNow now: Date) -> PaceRestraintContext {
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: userInputActivityMonitor.lastUserInputAt,
            frontmostAppBundleIdentifier: frontmostBundleIdentifier,
            isOnActiveCall: activeCallDetector.isOnActiveCall,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .morningTriage,
            profile: proactivityProfile,
            isInUserFocusMode: focusModeMonitor.isCurrentlyInUserFocus
        )
    }

    func setWatchModeEnabled(_ enabled: Bool) {
        guard enabled != isWatchModeEnabled else { return }
        isWatchModeEnabled = enabled

        if enabled {
            latestWatchModeSummary = "Watching for screen changes"
            screenWatchModeController.startWatching { [weak self] event in
                await self?.handleWatchModeEvent(event)
            }
        } else {
            screenWatchModeController.stopWatching()
            latestWatchModeSummary = nil
        }
    }
}
