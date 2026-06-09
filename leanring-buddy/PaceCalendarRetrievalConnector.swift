//
//  PaceCalendarRetrievalConnector.swift
//  leanring-buddy
//
//  Permission-aware read-only Calendar source for local retrieval.
//

import EventKit
import Foundation

struct PaceCalendarRetrievalEventSnapshot: Equatable {
    let stableIdentifier: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String?
    let location: String?
    let notes: String?

    init(
        stableIdentifier: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        calendarTitle: String? = nil,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.stableIdentifier = stableIdentifier
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled event"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
        self.location = location
        self.notes = notes
    }

    init(event: EKEvent) {
        let fallbackIdentifier = Self.fallbackIdentifier(
            title: event.title,
            startDate: event.startDate ?? Date()
        )
        self.init(
            stableIdentifier: event.eventIdentifier ?? fallbackIdentifier,
            title: event.title ?? "Untitled event",
            startDate: event.startDate ?? Date(),
            endDate: event.endDate ?? event.startDate ?? Date(),
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar?.title,
            location: event.location,
            notes: event.notes
        )
    }

    private static func fallbackIdentifier(title: String?, startDate: Date) -> String {
        let safeTitle = (title ?? "untitled")
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(8)
            .joined(separator: "-")
        return "\(Int(startDate.timeIntervalSince1970))-\(safeTitle.isEmpty ? "event" : safeTitle)"
    }
}

struct PaceCalendarRetrievalConnector {
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
        lookbackDays: Int = 14,
        lookaheadDays: Int = 90,
        maximumEventCount: Int = 200
    ) -> (documents: [PaceRetrievalDocument], status: PaceRetrievalSourceStatus) {
        let authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard Self.canReadCalendarEvents(authorizationStatus) else {
            return ([], Self.skippedStatus(for: authorizationStatus))
        }

        let now = nowProvider()
        let calendar = Calendar.current
        let startDate = calendar.date(byAdding: .day, value: -max(0, lookbackDays), to: now) ?? now
        let endDate = calendar.date(byAdding: .day, value: max(1, lookaheadDays), to: now) ?? now
        let eventPredicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil
        )
        let eventSnapshots = eventStore
            .events(matching: eventPredicate)
            .sorted { firstEvent, secondEvent in
                (firstEvent.startDate ?? .distantFuture) < (secondEvent.startDate ?? .distantFuture)
            }
            .prefix(max(0, maximumEventCount))
            .map(PaceCalendarRetrievalEventSnapshot.init(event:))
        let documents = eventSnapshots.map(Self.document(from:))

        return (
            documents,
            .enabled(
                source: .calendar,
                displayName: PaceRetrievalSource.calendar.displayName,
                documentCount: documents.count
            )
        )
    }

    static func document(from eventSnapshot: PaceCalendarRetrievalEventSnapshot) -> PaceRetrievalDocument {
        var lines = [
            "Title: \(eventSnapshot.title)",
            "When: \(formattedDateRange(for: eventSnapshot))",
        ]

        if let calendarTitle = compactText(eventSnapshot.calendarTitle, maximumCharacters: 120) {
            lines.append("Calendar: \(calendarTitle)")
        }
        if let location = compactText(eventSnapshot.location, maximumCharacters: 180) {
            lines.append("Location: \(location)")
        }
        if let notes = compactText(eventSnapshot.notes, maximumCharacters: 360) {
            lines.append("Notes: \(notes)")
        }

        return PaceRetrievalDocument(
            id: "calendar-\(eventSnapshot.stableIdentifier)",
            source: .calendar,
            title: eventSnapshot.title,
            text: lines.joined(separator: "\n"),
            modifiedAt: eventSnapshot.startDate,
            permissionScope: "eventkit-calendar"
        )
    }

    static func skippedStatus(for authorizationStatus: EKAuthorizationStatus) -> PaceRetrievalSourceStatus {
        let reason: String
        switch authorizationStatus {
        case .notDetermined:
            reason = "Calendar permission has not been granted."
        case .denied:
            reason = "Calendar permission was denied."
        case .restricted:
            reason = "Calendar access is restricted on this Mac."
        case .writeOnly:
            reason = "Calendar permission is write-only; retrieval needs full access."
        case .authorized, .fullAccess:
            reason = "Calendar retrieval is available."
        @unknown default:
            reason = "Calendar permission status is unknown."
        }

        return .skipped(
            source: .calendar,
            displayName: PaceRetrievalSource.calendar.displayName,
            reason: reason
        )
    }

    static func canReadCalendarEvents(_ authorizationStatus: EKAuthorizationStatus) -> Bool {
        switch authorizationStatus {
        case .authorized, .fullAccess:
            return true
        case .notDetermined, .restricted, .denied, .writeOnly:
            return false
        @unknown default:
            return false
        }
    }

    private static func formattedDateRange(for eventSnapshot: PaceCalendarRetrievalEventSnapshot) -> String {
        if eventSnapshot.isAllDay {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .none
            return "\(dateFormatter.string(from: eventSnapshot.startDate)) all day"
        }

        let startFormatter = DateFormatter()
        startFormatter.dateStyle = .medium
        startFormatter.timeStyle = .short

        let endFormatter = DateFormatter()
        endFormatter.dateStyle = Calendar.current.isDate(eventSnapshot.startDate, inSameDayAs: eventSnapshot.endDate)
            ? .none
            : .medium
        endFormatter.timeStyle = .short

        return "\(startFormatter.string(from: eventSnapshot.startDate)) - \(endFormatter.string(from: eventSnapshot.endDate))"
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
