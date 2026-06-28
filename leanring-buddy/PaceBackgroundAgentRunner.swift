//
//  PaceBackgroundAgentRunner.swift
//  leanring-buddy
//
//  Background agent execution — runs multi-step tasks asynchronously
//  while the user continues working. Inspired by Clicky's background
//  agents and Shiro's parallel sub-agents.
//
//  Unlike the synchronous agent loop (which blocks the UI and TTS
//  pipeline), background agents:
//    - Run on a detached Task with background priority
//    - Report progress via a published state object
//    - Can be cancelled by the user
//    - Speak results only when done (or on failure)
//    - Respect the restraint gate for proactive speech
//
//  Use cases:
//    - "Build a Linear ticket for the bug I just described"
//    - "Draft a Gmail response to the last email"
//    - "Research the top 5 competitors for X"
//

import Combine
import Foundation

/// State of a background agent task.
enum PaceBackgroundAgentState: Equatable {
    case queued
    case running
    case completed
    case cancelled
    case failed(String)
}

/// A background agent task. Created by voice command or cron trigger.
struct PaceBackgroundAgentTask: Identifiable, Equatable {
    let id: String
    let displayName: String
    let prompt: String
    var state: PaceBackgroundAgentState
    var startedAt: Date?
    var completedAt: Date?
    var resultSummary: String?
    var stepCount: Int

    static func == (lhs: PaceBackgroundAgentTask, rhs: PaceBackgroundAgentTask) -> Bool {
        lhs.id == rhs.id
    }
}

/// Manages background agent tasks. Each task runs as a detached Task
/// that calls the planner with the task prompt and executes the
/// resulting tool calls. Progress is published for UI updates.
@MainActor
final class PaceBackgroundAgentRunner: ObservableObject {
    static let shared = PaceBackgroundAgentRunner()

    @Published private(set) var tasks: [PaceBackgroundAgentTask] = []

    /// Callback to execute a planner turn. Set by CompanionManager.
    var executePlannerTurn: ((String) async -> String)?

    /// Callback to speak a result. Set by CompanionManager.
    var speakResult: ((String) async -> Void)?

    /// Maximum concurrent background tasks.
    private let maxConcurrent = 2

    private var runningTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    // MARK: - Task lifecycle

    /// Enqueue a background task. Starts immediately if under the
    /// concurrency limit.
    func enqueue(prompt: String, displayName: String) -> String {
        let id = "bg-\(UUID().uuidString.prefix(8))"
        var task = PaceBackgroundAgentTask(
            id: id,
            displayName: displayName,
            prompt: prompt,
            state: .queued,
            startedAt: nil,
            completedAt: nil,
            resultSummary: nil,
            stepCount: 0
        )
        tasks.append(task)

        if runningTasks.count < maxConcurrent {
            startTask(id)
        }

        return id
    }

    /// Cancel a running or queued task.
    func cancel(taskId: String) {
        runningTasks[taskId]?.cancel()
        runningTasks.removeValue(forKey: taskId)
        updateTask(taskId) { task in
            task.state = .cancelled
            task.completedAt = Date()
        }
    }

    /// Remove completed/cancelled/failed tasks from the list.
    func clearCompleted() {
        tasks.removeAll { task in
            task.state == .completed || task.state == .cancelled || task.state == .failed("")
        }
    }

    // MARK: - Execution

    private func startTask(_ taskId: String) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[taskIndex].state = .running
        tasks[taskIndex].startedAt = Date()

        let prompt = tasks[taskIndex].prompt

        runningTasks[taskId] = Task.detached(priority: .background) { [weak self] in
            await self?.executeTask(taskId: taskId, prompt: prompt)
        }
    }

    private func executeTask(taskId: String, prompt: String) async {
        do {
            guard let executePlannerTurn else {
                await MainActor.run {
                    self.updateTask(taskId) { task in
                        task.state = .failed("No planner callback set")
                        task.completedAt = Date()
                    }
                }
                return
            }

            let result = await executePlannerTurn(prompt)

            // Check for cancellation before speaking.
            try Task.checkCancellation()

            await MainActor.run {
                self.updateTask(taskId) { task in
                    task.state = .completed
                    task.completedAt = Date()
                    task.resultSummary = result
                }
            }

            // Speak the result through the restraint gate.
            if let speakResult, !result.isEmpty {
                await speakResult(result)
            }
        } catch is CancellationError {
            await MainActor.run {
                self.updateTask(taskId) { task in
                    task.state = .cancelled
                    task.completedAt = Date()
                }
            }
        } catch {
            await MainActor.run {
                self.updateTask(taskId) { task in
                    task.state = .failed(error.localizedDescription)
                    task.completedAt = Date()
                }
            }
        }

        await MainActor.run {
            self.runningTasks.removeValue(forKey: taskId)
            // Start next queued task if any.
            if let nextQueued = self.tasks.first(where: { $0.state == .queued }) {
                self.startTask(nextQueued.id)
            }
        }
    }

    private func updateTask(_ taskId: String, _ update: (inout PaceBackgroundAgentTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        update(&tasks[index])
    }

    /// Whether any background tasks are currently running.
    var hasRunningTasks: Bool {
        tasks.contains(where: { $0.state == .running })
    }
}
