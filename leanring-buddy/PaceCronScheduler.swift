//
//  PaceCronScheduler.swift
//  leanring-buddy
//
//  General-purpose cron-like scheduler for recurring Pace tasks.
//  Inspired by OpenFelix's cron jobs + proactive alerts.
//
//  Unlike PaceMorningTriageScheduler (which fires once daily), this
//  scheduler supports arbitrary intervals: "every 30 minutes check
//  my calendar", "every 2 hours remind me to stand up", etc.
//
//  Tasks are defined as closures that produce a spoken utterance.
//  All tasks pass through PaceRestraintGate before speaking, and
//  queue through PaceProactivityPipeline when the user is busy.
//

import Combine
import Foundation

/// A scheduled task with a recurring interval and a generator closure.
struct PaceCronTask: Identifiable, Equatable, Codable {
    let id: String
    let displayName: String
    /// Interval between firings, in seconds.
    let intervalSeconds: TimeInterval
    /// Whether to skip weekends (for work-day-only tasks).
    let skipWeekends: Bool
    /// The prompt to send to the planner when this task fires.
    /// The planner generates the spoken response.
    let taskPrompt: String

    static func == (lhs: PaceCronTask, rhs: PaceCronTask) -> Bool {
        lhs.id == rhs.id
    }
}

/// Manages recurring scheduled tasks. Each task has its own timer.
/// When a task fires, it goes through the restraint gate and
/// proactivity pipeline — same as the morning brief.
@MainActor
final class PaceCronScheduler: ObservableObject {
    static let shared = PaceCronScheduler()

    @Published private(set) var tasks: [PaceCronTask] = []
    @Published var isEnabled: Bool = PaceUserPreferencesStore
        .bool(.isCronSchedulerEnabled, default: false)

    private var timers: [String: Timer] = [:]
    private var lastFireDates: [String: Date] = [:]

    /// Callback to the CompanionManager for executing tasks.
    /// Set during CompanionManager.start().
    var executeTaskCallback: ((PaceCronTask) async -> Void)?

    private init() {
        loadPersistedTasks()
    }

    // MARK: - Task management

    /// Add a recurring task. The timer fires immediately if the
    /// scheduler is enabled and the task hasn't fired today.
    func addTask(_ task: PaceCronTask) {
        guard !tasks.contains(where: { $0.id == task.id }) else { return }
        tasks.append(task)
        persistTasks()
        if isEnabled {
            armTimer(for: task)
        }
    }

    /// Remove a recurring task.
    func removeTask(id: String) {
        tasks.removeAll(where: { $0.id == id })
        timers[id]?.invalidate()
        timers.removeValue(forKey: id)
        lastFireDates.removeValue(forKey: id)
        persistTasks()
    }

    /// Enable/disable the scheduler. When enabled, arms timers for
    /// all tasks. When disabled, invalidates all timers.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .isCronSchedulerEnabled)
        if enabled {
            for task in tasks {
                armTimer(for: task)
            }
        } else {
            for (id, timer) in timers {
                timer.invalidate()
            }
            timers.removeAll()
        }
    }

    // MARK: - Timer management

    private func armTimer(for task: PaceCronTask) {
        timers[task.id]?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: task.intervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fireTask(task)
            }
        }
        timers[task.id] = timer
    }

    private func fireTask(_ task: PaceCronTask) async {
        // Skip weekends if configured.
        if task.skipWeekends {
            let weekday = Calendar.current.component(.weekday, from: Date())
            if weekday == 1 || weekday == 7 { return }
        }

        // Prevent double-fire within the same interval.
        if let lastFire = lastFireDates[task.id],
           Date().timeIntervalSince(lastFire) < task.intervalSeconds * 0.5 {
            return
        }
        lastFireDates[task.id] = Date()

        await executeTaskCallback?(task)
    }

    // MARK: - Persistence

    private static let tasksKey = "pace.cronScheduler.tasks"

    private func loadPersistedTasks() {
        guard let data = UserDefaults.standard.data(forKey: Self.tasksKey),
              let decoded = try? JSONDecoder().decode([PaceCronTask].self, from: data) else {
            return
        }
        tasks = decoded
    }

    private func persistTasks() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        UserDefaults.standard.set(data, forKey: Self.tasksKey)
    }

    // MARK: - Voice command parsing

    /// Parse a voice command like "every 30 minutes check my calendar"
    /// into a PaceCronTask. Returns nil if the command doesn't match.
    nonisolated static func parseVoiceCommand(_ transcript: String) -> PaceCronTask? {
        let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Match "every N minutes/hours <task>"
        let patterns: [(regex: String, interval: (Int) -> TimeInterval)] = [
            (#"every (\d+) minutes? (.+)"#, { Double($0) * 60 }),
            (#"every (\d+) hours? (.+)"#, { Double($0) * 3600 }),
            (#"every (\d+) seconds? (.+)"#, { Double($0) }),
        ]

        for (pattern, intervalFn) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(lower.startIndex..., in: lower)
            if let match = regex.firstMatch(in: lower, options: [], range: range) {
                guard let numberRange = Range(match.range(at: 1), in: lower),
                      let taskRange = Range(match.range(at: 2), in: lower),
                      let number = Int(lower[numberRange]) else { continue }
                let taskDescription = String(lower[taskRange])
                let id = "cron-\(number)-\(taskDescription.hashValue)"
                return PaceCronTask(
                    id: id,
                    displayName: "Every \(number) min: \(taskDescription)",
                    intervalSeconds: intervalFn(number),
                    skipWeekends: false,
                    taskPrompt: taskDescription
                )
            }
        }

        return nil
    }
}
