//
//  PaceBackgroundAgentRunnerTests.swift
//  leanring-buddyTests
//
//  Tests for the background agent runner. Verifies task lifecycle,
//  concurrency limits, cancellation, and callback wiring.
//

import Foundation
import Testing
@testable import Pace

@MainActor
@Suite(.serialized)
struct PaceBackgroundAgentRunnerTests {

    // MARK: - Task lifecycle

    /// Enqueuing a task adds it to the task list.
    @Test
    func enqueueAddsTaskToList() {
        let runner = PaceBackgroundAgentRunner.shared
        let initialCount = runner.tasks.count

        let id = runner.enqueue(prompt: "test prompt", displayName: "Test Task")

        #expect(runner.tasks.count == initialCount + 1)
        #expect(runner.tasks.contains(where: { $0.id == id }))

        // Cleanup.
        runner.cancel(taskId: id)
    }

    /// A task that completes successfully reports .completed state.
    @Test
    func taskCompletesSuccessfully() async {
        let runner = PaceBackgroundAgentRunner.shared

        runner.executePlannerTurn = { prompt in
            return "Done: \(prompt)"
        }
        defer { runner.executePlannerTurn = nil }

        let id = runner.enqueue(prompt: "do something", displayName: "Success Task")

        // Wait for the background task to complete. Background priority
        // tasks may take a while to schedule.
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(200))
            if let task = runner.tasks.first(where: { $0.id == id }),
               task.state == .completed || task.state == .failed("") {
                break
            }
        }

        let task = runner.tasks.first(where: { $0.id == id })
        #expect(task != nil)
        #expect(task?.state == .completed)
        #expect(task?.resultSummary?.contains("Done: do something") == true)

        // Cleanup.
        runner.cancel(taskId: id)
    }

    /// Cancelling a running task sets state to .cancelled.
    @Test
    func cancelRunningTaskSetsCancelledState() async {
        let runner = PaceBackgroundAgentRunner.shared

        // Make the planner turn take a while so we can cancel it.
        runner.executePlannerTurn = { _ in
            try? await Task.sleep(for: .seconds(10))
            return "should not reach"
        }
        defer { runner.executePlannerTurn = nil }

        let id = runner.enqueue(prompt: "long task", displayName: "Long Task")

        // Give it a moment to start.
        try? await Task.sleep(for: .milliseconds(500))

        runner.cancel(taskId: id)

        try? await Task.sleep(for: .milliseconds(200))

        let task = runner.tasks.first(where: { $0.id == id })
        #expect(task?.state == .cancelled)
    }

    /// A task with no planner callback fails gracefully.
    @Test
    func taskWithoutCallbackFailsGracefully() async {
        let runner = PaceBackgroundAgentRunner.shared
        runner.executePlannerTurn = nil

        let id = runner.enqueue(prompt: "no callback", displayName: "No Callback")

        // Wait for the background task to process.
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(200))
            if let task = runner.tasks.first(where: { $0.id == id }),
               case .failed = task.state {
                break
            }
        }

        let task = runner.tasks.first(where: { $0.id == id })
        if case .failed(let message) = task?.state {
            #expect(message.contains("No planner callback"))
        } else {
            #expect(Bool(false), "Task should be in failed state")
        }

        // Cleanup.
        runner.cancel(taskId: id)
    }

    // MARK: - State tracking

    /// hasRunningTasks is true when a task is running.
    @Test
    func hasRunningTasksReflectsState() async {
        let runner = PaceBackgroundAgentRunner.shared

        runner.executePlannerTurn = { _ in
            try? await Task.sleep(for: .seconds(2))
            return "done"
        }
        defer { runner.executePlannerTurn = nil }

        let id = runner.enqueue(prompt: "running test", displayName: "Running Test")

        // Wait for the task to start running.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(runner.hasRunningTasks == true)

        // Wait for completion.
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(300))
            if !runner.hasRunningTasks { break }
        }
        #expect(runner.hasRunningTasks == false)

        // Cleanup.
        runner.cancel(taskId: id)
    }

    /// clearCompleted removes completed/cancelled/failed tasks.
    @Test
    func clearCompletedRemovesFinishedTasks() async {
        let runner = PaceBackgroundAgentRunner.shared

        runner.executePlannerTurn = { _ in "done" }
        defer { runner.executePlannerTurn = nil }

        let id = runner.enqueue(prompt: "clear test", displayName: "Clear Test")

        try? await Task.sleep(for: .seconds(1))

        let countBeforeClear = runner.tasks.count
        runner.clearCompleted()
        let countAfterClear = runner.tasks.count

        #expect(countAfterClear < countBeforeClear)
    }
}
