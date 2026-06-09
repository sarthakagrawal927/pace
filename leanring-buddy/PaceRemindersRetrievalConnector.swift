//
//  PaceRemindersRetrievalConnector.swift
//  leanring-buddy
//
//  Permission-aware read-only Reminders source for local retrieval.
//

import EventKit
import Foundation

struct PaceReminderRetrievalSnapshot: Equatable {
    let stableIdentifier: String
    let title: String
    let notes: String?
    let listTitle: String?
    let dueDate: Date?
    let completionDate: Date?
    let priority: Int
    let isCompleted: Bool

    init(
        stableIdentifier: String,
        title: String,
        notes: String? = nil,
        listTitle: String? = nil,
        dueDate: Date? = nil,
        completionDate: Date? = nil,
        priority: Int = 0,
        isCompleted: Bool = false
    ) {
        self.stableIdentifier = stableIdentifier
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled reminder"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = notes
        self.listTitle = listTitle
        self.dueDate = dueDate
        self.completionDate = completionDate
        self.priority = priority
        self.isCompleted = isCompleted
    }

    init(reminder: EKReminder) {
        let dueDate = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        let fallbackIdentifier = Self.fallbackIdentifier(
            title: reminder.title,
            dueDate: dueDate,
            completionDate: reminder.completionDate
        )
        self.init(
            stableIdentifier: reminder.calendarItemIdentifier.isEmpty
                ? fallbackIdentifier
                : reminder.calendarItemIdentifier,
            title: reminder.title ?? "Untitled reminder",
            notes: reminder.notes,
            listTitle: reminder.calendar?.title,
            dueDate: dueDate,
            completionDate: reminder.completionDate,
            priority: reminder.priority,
            isCompleted: reminder.isCompleted
        )
    }

    private static func fallbackIdentifier(
        title: String?,
        dueDate: Date?,
        completionDate: Date?
    ) -> String {
        let safeTitle = (title ?? "untitled")
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(8)
            .joined(separator: "-")
        let timestamp = Int((dueDate ?? completionDate ?? Date()).timeIntervalSince1970)
        return "\(timestamp)-\(safeTitle.isEmpty ? "reminder" : safeTitle)"
    }
}

struct PaceRemindersRetrievalConnector {
    let eventStore: EKEventStore
    let nowProvider: () -> Date

    init(
        eventStore: EKEventStore,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.eventStore = eventStore
        self.nowProvider = nowProvider
    }

    func loadDocuments(
        lookbackDaysForCompleted: Int = 14,
        maximumReminderCount: Int = 200
    ) async -> (documents: [PaceRetrievalDocument], status: PaceRetrievalSourceStatus) {
        let authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        guard Self.canReadReminders(authorizationStatus) else {
            return ([], Self.skippedStatus(for: authorizationStatus))
        }

        let now = nowProvider()
        let calendar = Calendar.current
        let completedStartDate = calendar.date(
            byAdding: .day,
            value: -max(0, lookbackDaysForCompleted),
            to: now
        ) ?? now
        let incompletePredicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let completedPredicate = eventStore.predicateForCompletedReminders(
            withCompletionDateStarting: completedStartDate,
            ending: now,
            calendars: nil
        )

        async let incompleteReminders = fetchReminders(matching: incompletePredicate)
        async let completedReminders = fetchReminders(matching: completedPredicate)

        let reminderSnapshots = await (incompleteReminders + completedReminders)
            .reduce(into: [String: PaceReminderRetrievalSnapshot]()) { snapshotsById, reminder in
                let snapshot = PaceReminderRetrievalSnapshot(reminder: reminder)
                snapshotsById[snapshot.stableIdentifier] = snapshot
            }
            .values
            .sorted(by: Self.shouldSortBefore)
            .prefix(max(0, maximumReminderCount))
            .map { $0 }
        let documents = reminderSnapshots.map(Self.document(from:))

        return (
            documents,
            .enabled(
                source: .reminders,
                displayName: PaceRetrievalSource.reminders.displayName,
                documentCount: documents.count
            )
        )
    }

    static func document(from reminderSnapshot: PaceReminderRetrievalSnapshot) -> PaceRetrievalDocument {
        var lines = [
            "Title: \(reminderSnapshot.title)",
            "Status: \(reminderSnapshot.isCompleted ? "completed" : "open")",
        ]

        if let dueDate = reminderSnapshot.dueDate {
            lines.append("Due: \(formattedDate(dueDate))")
        }
        if let completionDate = reminderSnapshot.completionDate {
            lines.append("Completed: \(formattedDate(completionDate))")
        }
        if let listTitle = compactText(reminderSnapshot.listTitle, maximumCharacters: 120) {
            lines.append("List: \(listTitle)")
        }
        if reminderSnapshot.priority > 0 {
            lines.append("Priority: \(reminderSnapshot.priority)")
        }
        if let notes = compactText(reminderSnapshot.notes, maximumCharacters: 360) {
            lines.append("Notes: \(notes)")
        }

        return PaceRetrievalDocument(
            id: "reminder-\(reminderSnapshot.stableIdentifier)",
            source: .reminders,
            title: reminderSnapshot.title,
            text: lines.joined(separator: "\n"),
            modifiedAt: reminderSnapshot.dueDate ?? reminderSnapshot.completionDate,
            permissionScope: "eventkit-reminders"
        )
    }

    static func skippedStatus(for authorizationStatus: EKAuthorizationStatus) -> PaceRetrievalSourceStatus {
        let reason: String
        switch authorizationStatus {
        case .notDetermined:
            reason = "Reminders permission has not been granted."
        case .denied:
            reason = "Reminders permission was denied."
        case .restricted:
            reason = "Reminders access is restricted on this Mac."
        case .writeOnly:
            reason = "Reminders permission is write-only; retrieval needs full access."
        case .authorized, .fullAccess:
            reason = "Reminders retrieval is available."
        @unknown default:
            reason = "Reminders permission status is unknown."
        }

        return .skipped(
            source: .reminders,
            displayName: PaceRetrievalSource.reminders.displayName,
            reason: reason
        )
    }

    static func canReadReminders(_ authorizationStatus: EKAuthorizationStatus) -> Bool {
        switch authorizationStatus {
        case .authorized, .fullAccess:
            return true
        case .notDetermined, .restricted, .denied, .writeOnly:
            return false
        @unknown default:
            return false
        }
    }

    private func fetchReminders(matching predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private static func shouldSortBefore(
        _ firstSnapshot: PaceReminderRetrievalSnapshot,
        _ secondSnapshot: PaceReminderRetrievalSnapshot
    ) -> Bool {
        if firstSnapshot.isCompleted != secondSnapshot.isCompleted {
            return !firstSnapshot.isCompleted
        }
        let firstDate = firstSnapshot.dueDate ?? firstSnapshot.completionDate ?? .distantFuture
        let secondDate = secondSnapshot.dueDate ?? secondSnapshot.completionDate ?? .distantFuture
        if firstDate != secondDate {
            return firstDate < secondDate
        }
        return firstSnapshot.title.localizedCaseInsensitiveCompare(secondSnapshot.title) == .orderedAscending
    }

    private static func formattedDate(_ date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        return dateFormatter.string(from: date)
    }

    private static func compactText(_ text: String?, maximumCharacters: Int) -> String? {
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
