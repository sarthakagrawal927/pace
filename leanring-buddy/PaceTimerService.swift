//
//  PaceTimerService.swift
//  leanring-buddy
//
//  Lightweight timer skill: the planner can call start_timer to schedule
//  a spoken nudge after a duration. Survives app quit/relaunch by
//  persisting active timers to disk and rehydrating on start; past-due
//  timers fire immediately on rehydration with a "this just went off"
//  fallback line so a crashed Pace doesn't silently swallow a 5-minute
//  egg timer.
//
//  Two pieces:
//
//  - `PaceTimerStore` — pure JSON-backed persistence. No timers, no
//    TTS, no main actor. Unit-testable with file URLs only.
//  - `PaceTimerScheduler` — MainActor service that owns the live
//    `Timer` objects, fires the spoken callback, and pushes state into
//    the store. CompanionManager creates one instance and the executor
//    talks to it.
//
//  Stays intentionally small. Cancel-by-name is a phase 2 if the
//  planner ever needs to cancel timers it just set.
//

import Foundation

nonisolated struct PaceScheduledTimer: Codable, Equatable {
    let identifier: String
    let label: String
    let fireDate: Date
    let createdAt: Date

    var spokenReminderText: String {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLabel.isEmpty {
            return "your timer just went off."
        }
        return "timer for \(trimmedLabel) just went off."
    }
}

/// Pure store. Reads/writes a JSON array of `PaceScheduledTimer` to a
/// caller-provided file URL — no global state, no TTS. The scheduler
/// owns one instance pointing at the default Application Support path
/// and tests can point at a temp file.
nonisolated struct PaceTimerStore {
    static var defaultFileURL: URL {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let paceDirectoryURL = appSupportURL.appendingPathComponent("Pace", isDirectory: true)
        try? FileManager.default.createDirectory(at: paceDirectoryURL, withIntermediateDirectories: true)
        return paceDirectoryURL.appendingPathComponent("active-timers.json")
    }

    let fileURL: URL

    init(fileURL: URL = PaceTimerStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() -> [PaceScheduledTimer] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PaceScheduledTimer].self, from: data)) ?? []
    }

    func save(_ timers: [PaceScheduledTimer]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(timers)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Split a set of timers by whether they've already passed `now`.
    /// Returned tuple is `(pastDue, stillScheduled)` — the scheduler
    /// fires the first list immediately and arms `Timer` objects for
    /// the second.
    static func partition(
        _ timers: [PaceScheduledTimer],
        relativeTo now: Date
    ) -> (pastDue: [PaceScheduledTimer], stillScheduled: [PaceScheduledTimer]) {
        var pastDueTimers: [PaceScheduledTimer] = []
        var stillScheduledTimers: [PaceScheduledTimer] = []
        for timer in timers {
            if timer.fireDate <= now {
                pastDueTimers.append(timer)
            } else {
                stillScheduledTimers.append(timer)
            }
        }
        return (pastDueTimers, stillScheduledTimers)
    }
}

/// MainActor-owned scheduler. Holds active `Timer` objects and calls
/// `onFire` when each fires. `onFire` is what wires the spoken nudge —
/// `CompanionManager` passes a closure that speaks through the active
/// `BuddyTTSClient`.
@MainActor
final class PaceTimerScheduler {
    private let store: PaceTimerStore
    private var liveTimers: [String: Timer] = [:]
    private(set) var scheduledTimers: [PaceScheduledTimer] = []

    /// Invoked on the main actor when a timer fires. Receives the
    /// timer's spokenReminderText. Wire this to TTS in CompanionManager.
    var onFire: ((String) -> Void)?

    init(store: PaceTimerStore = PaceTimerStore()) {
        self.store = store
    }

    /// Rehydrates persisted timers on app start. Past-due timers fire
    /// their spoken nudge immediately (one shot, on next runloop tick
    /// so the listener is wired); future timers get armed.
    func rehydrate(now: Date = Date()) {
        let persistedTimers = store.load()
        let (pastDueTimers, stillScheduledTimers) = PaceTimerStore.partition(persistedTimers, relativeTo: now)
        scheduledTimers = stillScheduledTimers
        persist()
        for stillScheduledTimer in stillScheduledTimers {
            armLiveTimer(for: stillScheduledTimer)
        }
        for pastDueTimer in pastDueTimers {
            DispatchQueue.main.async { [weak self] in
                self?.onFire?(pastDueTimer.spokenReminderText)
            }
        }
    }

    @discardableResult
    func schedule(label: String, durationInSeconds: TimeInterval, now: Date = Date()) -> PaceScheduledTimer {
        let scheduledTimer = PaceScheduledTimer(
            identifier: UUID().uuidString,
            label: label,
            fireDate: now.addingTimeInterval(durationInSeconds),
            createdAt: now
        )
        scheduledTimers.append(scheduledTimer)
        armLiveTimer(for: scheduledTimer)
        persist()
        return scheduledTimer
    }

    private func armLiveTimer(for scheduledTimer: PaceScheduledTimer) {
        let timeInterval = max(0.001, scheduledTimer.fireDate.timeIntervalSinceNow)
        let liveTimer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fire(scheduledTimer.identifier)
            }
        }
        liveTimers[scheduledTimer.identifier] = liveTimer
    }

    private func fire(_ identifier: String) {
        guard let scheduledTimer = scheduledTimers.first(where: { $0.identifier == identifier }) else {
            return
        }
        scheduledTimers.removeAll(where: { $0.identifier == identifier })
        liveTimers.removeValue(forKey: identifier)
        persist()
        onFire?(scheduledTimer.spokenReminderText)
    }

    private func persist() {
        do {
            try store.save(scheduledTimers)
        } catch {
            // Best-effort: a missing scratch dir or read-only disk
            // shouldn't crash the app — the live Timer still fires
            // until the app quits.
            print("⚠️ PaceTimerScheduler: failed to persist active timers: \(error)")
        }
    }
}

// MARK: - Phrase parsing

/// Pure helper turning a planner-supplied human duration into seconds.
/// Accepts simple shapes: "3 minutes", "30s", "2 hours", "90 seconds".
/// Returns nil for anything ambiguous so the executor can surface a
/// validation error instead of guessing.
nonisolated enum PaceTimerDurationParser {
    static func seconds(from rawDurationText: String) -> TimeInterval? {
        let trimmedText = rawDurationText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmedText.isEmpty else { return nil }

        // First: plain integer/float is interpreted as seconds.
        if let directSeconds = Double(trimmedText), directSeconds > 0 {
            return directSeconds
        }

        // Otherwise: pull the leading numeric run, then look at what
        // follows for a unit. Accepts "3 min", "3min", "3 minutes".
        var numericPrefix = ""
        var unitSuffix = ""
        var hasSeenNonDigit = false
        for character in trimmedText {
            if !hasSeenNonDigit, character.isNumber || character == "." {
                numericPrefix.append(character)
            } else if character.isWhitespace, numericPrefix.isEmpty {
                continue
            } else {
                hasSeenNonDigit = true
                unitSuffix.append(character)
            }
        }
        guard let numericValue = Double(numericPrefix), numericValue > 0 else {
            return nil
        }
        let trimmedUnit = unitSuffix.trimmingCharacters(in: .whitespaces)

        let unitMultiplier: Double
        switch true {
        case trimmedUnit.isEmpty,
             trimmedUnit.hasPrefix("s"):
            unitMultiplier = 1
        case trimmedUnit.hasPrefix("m") && !trimmedUnit.hasPrefix("mo"):
            unitMultiplier = 60
        case trimmedUnit.hasPrefix("h"):
            unitMultiplier = 3600
        default:
            return nil
        }
        return numericValue * unitMultiplier
    }
}
