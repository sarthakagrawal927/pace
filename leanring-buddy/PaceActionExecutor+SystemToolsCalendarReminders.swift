//
//  PaceActionExecutor+SystemToolsCalendarReminders.swift
//  leanring-buddy
//
//  Extracted from PaceActionExecutor.swift (god-class decomposition Phase B):
//  Calendar and Reminders EventKit tools.
//

import EventKit
import Foundation

@MainActor
extension PaceActionExecutor {

    // MARK: - System tools (calendar & reminders)

    func listCalendarEvents(_ calendarQuery: PaceCalendarQuery) async -> PaceActionExecutionObservation {
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
                summary: "Calendar access not granted. Open System Settings → Privacy & Security → Calendars and toggle Pace on."
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

    func createCalendarEvent(
        _ calendarEventRequest: PaceCalendarEventRequest
    ) async -> PaceActionExecutionObservation {
        print("🧰 Calendar create \"\(calendarEventRequest.title)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "calendar_create",
                summary: "Would create calendar event: \(calendarEventRequest.displaySummary)"
            )
        }

        guard await requestCalendarAccessIfNeeded() else {
            return PaceActionExecutionObservation(
                toolName: "calendar_create",
                summary: "Calendar access not granted. Open System Settings → Privacy & Security → Calendars and toggle Pace on."
            )
        }

        guard let targetCalendar = calendarForNewEvent(matching: calendarEventRequest.calendarTitle) else {
            return PaceActionExecutionObservation(
                toolName: "calendar_create",
                summary: "Could not find a writable calendar."
            )
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = targetCalendar
        event.title = calendarEventRequest.title
        event.startDate = calendarEventRequest.startDate
        event.endDate = calendarEventRequest.endDate
        event.isAllDay = calendarEventRequest.isAllDay
        event.notes = calendarEventRequest.notes
        event.location = calendarEventRequest.location

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return PaceActionExecutionObservation(
                toolName: "calendar_create",
                summary: "Created calendar event: \(calendarEventRequest.displaySummary)"
            )
        } catch {
            return PaceActionExecutionObservation(
                toolName: "calendar_create",
                summary: "Failed to create calendar event: \(error.localizedDescription)"
            )
        }
    }

    func calendarForNewEvent(matching requestedCalendarTitle: String?) -> EKCalendar? {
        guard let requestedCalendarTitle = requestedCalendarTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedCalendarTitle.isEmpty else {
            return eventStore.defaultCalendarForNewEvents
        }

        let matchingCalendar = eventStore
            .calendars(for: .event)
            .first { calendar in
                calendar.allowsContentModifications
                    && calendar.title.compare(
                        requestedCalendarTitle,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) == .orderedSame
            }

        return matchingCalendar ?? eventStore.defaultCalendarForNewEvents
    }

    func createReminder(_ reminderRequest: PaceReminderRequest) async -> PaceActionExecutionObservation {
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
                summary: "Reminders access not granted. Open System Settings → Privacy & Security → Reminders and toggle Pace on."
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

}
