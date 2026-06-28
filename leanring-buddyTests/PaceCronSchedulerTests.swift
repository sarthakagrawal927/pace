//
//  PaceCronSchedulerTests.swift
//  leanring-buddyTests
//
//  Tests for the cron scheduler's voice command parser and
//  task management logic. The actual timer firing is not tested
//  (non-deterministic); instead we test the parsing and state
//  management that the timer triggers.
//

import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceCronSchedulerTests {

    // MARK: - Voice command parsing

    /// "every 30 minutes check my calendar" parses correctly.
    @Test
    func parseEveryNMinutes() {
        let task = PaceCronScheduler.parseVoiceCommand("every 30 minutes check my calendar")

        #expect(task != nil)
        #expect(task?.intervalSeconds == 1800) // 30 * 60
        #expect(task?.taskPrompt == "check my calendar")
        #expect(task?.skipWeekends == false)
    }

    /// "every 2 hours remind me to stand up" parses correctly.
    @Test
    func parseEveryNHours() {
        let task = PaceCronScheduler.parseVoiceCommand("every 2 hours remind me to stand up")

        #expect(task != nil)
        #expect(task?.intervalSeconds == 7200) // 2 * 3600
        #expect(task?.taskPrompt == "remind me to stand up")
    }

    /// "every 15 seconds run a quick check" parses correctly.
    @Test
    func parseEveryNSeconds() {
        let task = PaceCronScheduler.parseVoiceCommand("every 15 seconds run a quick check")

        #expect(task != nil)
        #expect(task?.intervalSeconds == 15)
        #expect(task?.taskPrompt == "run a quick check")
    }

    /// Singular "minute" (not "minutes") also parses.
    @Test
    func parseSingularMinute() {
        let task = PaceCronScheduler.parseVoiceCommand("every 1 minute check email")

        #expect(task != nil)
        #expect(task?.intervalSeconds == 60)
        #expect(task?.taskPrompt == "check email")
    }

    /// Non-matching command returns nil.
    @Test
    func parseNonMatchingCommandReturnsNil() {
        #expect(PaceCronScheduler.parseVoiceCommand("check my email") == nil)
        #expect(PaceCronScheduler.parseVoiceCommand("what time is it") == nil)
        #expect(PaceCronScheduler.parseVoiceCommand("every check") == nil)
    }

    /// Case-insensitive matching works.
    @Test
    func parseCaseInsensitive() {
        let task = PaceCronScheduler.parseVoiceCommand("EVERY 30 MINUTES CHECK CALENDAR")

        #expect(task != nil)
        #expect(task?.intervalSeconds == 1800)
    }

    /// Task ID is unique per command.
    @Test
    func taskIDIsUnique() {
        let task1 = PaceCronScheduler.parseVoiceCommand("every 30 minutes check calendar")
        let task2 = PaceCronScheduler.parseVoiceCommand("every 30 minutes check email")

        #expect(task1?.id != task2?.id)
    }

    // MARK: - Task management

    /// Adding a task increases the task count.
    @Test
    func addTaskIncreasesCount() {
        let scheduler = PaceCronScheduler.shared
        let initialCount = scheduler.tasks.count

        let task = PaceCronTask(
            id: "test-add-\(UUID().uuidString.prefix(8))",
            displayName: "Test Task",
            intervalSeconds: 3600,
            skipWeekends: false,
            taskPrompt: "test"
        )
        scheduler.addTask(task)

        #expect(scheduler.tasks.count == initialCount + 1)

        // Cleanup.
        scheduler.removeTask(id: task.id)
    }

    /// Adding a duplicate task (same ID) does not increase count.
    @Test
    func addDuplicateTaskDoesNotIncrease() {
        let scheduler = PaceCronScheduler.shared
        let initialCount = scheduler.tasks.count

        let task = PaceCronTask(
            id: "test-dup-\(UUID().uuidString.prefix(8))",
            displayName: "Test Dup",
            intervalSeconds: 3600,
            skipWeekends: false,
            taskPrompt: "test"
        )
        scheduler.addTask(task)
        scheduler.addTask(task) // Same ID.

        #expect(scheduler.tasks.count == initialCount + 1)

        // Cleanup.
        scheduler.removeTask(id: task.id)
    }

    /// Removing a task decreases the count.
    @Test
    func removeTaskDecreasesCount() {
        let scheduler = PaceCronScheduler.shared

        let task = PaceCronTask(
            id: "test-remove-\(UUID().uuidString.prefix(8))",
            displayName: "Test Remove",
            intervalSeconds: 3600,
            skipWeekends: false,
            taskPrompt: "test"
        )
        scheduler.addTask(task)
        let countAfterAdd = scheduler.tasks.count

        scheduler.removeTask(id: task.id)

        #expect(scheduler.tasks.count == countAfterAdd - 1)
    }

    // MARK: - Codable conformance

    /// PaceCronTask can be encoded and decoded.
    @Test
    func cronTaskIsCodable() throws {
        let task = PaceCronTask(
            id: "codable-test",
            displayName: "Codable Test",
            intervalSeconds: 1800,
            skipWeekends: true,
            taskPrompt: "test prompt"
        )

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(PaceCronTask.self, from: data)

        #expect(decoded.id == task.id)
        #expect(decoded.displayName == task.displayName)
        #expect(decoded.intervalSeconds == task.intervalSeconds)
        #expect(decoded.skipWeekends == task.skipWeekends)
        #expect(decoded.taskPrompt == task.taskPrompt)
    }
}
