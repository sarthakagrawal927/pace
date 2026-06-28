//
//  PaceModelDownloadManager.swift
//  leanring-buddy
//
//  Pausable (cancel + retry) model download state tracker.
//  Inspired by ORB's pausable model downloads — gives users
//  visibility and control over the MLX embedder's first-use
//  HuggingFace download.
//
//  Architecture note: the MLXEmbedders library manages its own
//  HuggingFace download internally, so we can't do byte-level
//  pause/resume. Instead we wrap the load in a cancellable Task:
//    - "Pause" = cancel the Task (stops the download)
//    - "Resume" = start a new Task (library resumes from cache)
//  The library caches partial downloads in ~/.cache/huggingface,
//  so a cancelled + resumed download picks up where it left off
//  in practice, even though we don't control the byte stream.
//

import Combine
import Foundation

/// Download state for a single model.
enum PaceModelDownloadState: Equatable {
    case idle
    case downloading
    case cancelled
    case ready
    case failed(String)
}

/// One entry in the download manager. Tracks a model that Pace
/// may need to download at runtime (currently just the MLX
/// embedder; future models can be added).
struct PaceModelDownloadEntry: Identifiable, Equatable {
    let id: String
    let displayName: String
    let modelIdentifier: String
    var state: PaceModelDownloadState
}

@MainActor
final class PaceModelDownloadManager: ObservableObject {
    static let shared = PaceModelDownloadManager()

    @Published private(set) var entries: [PaceModelDownloadEntry] = []

    /// Active download tasks keyed by entry id. Cancelling the task
    /// triggers the "pause" — the library's partial cache means
    /// resuming is effectively a retry that skips already-downloaded
    /// files.
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    private init() {
        // Register the MLX embedder if the runtime is linked.
        if PaceMLXEmbeddingClient.isRuntimeAvailable {
            let embedderID = PaceBundledModelsSettings.embedderModelIdentifier()
            entries.append(PaceModelDownloadEntry(
                id: "mlx-embedder",
                displayName: "MLX Embedder",
                modelIdentifier: embedderID,
                state: .idle
            ))
        }
    }

    /// Check if a model is already loaded locally. Called on app
    /// start to set the initial state of each entry.
    func refreshStates() {
        for i in entries.indices {
            if isModelReady(entries[i].id) {
                entries[i].state = .ready
            }
        }
    }

    /// Start (or resume) a model download. If the model is already
    /// ready, this is a no-op. If a download is already in progress,
    /// this is also a no-op.
    func startDownload(entryId: String) {
        guard let index = entries.firstIndex(where: { $0.id == entryId }) else { return }
        guard entries[index].state != .downloading else { return }
        guard entries[index].state != .ready else { return }

        entries[index].state = .downloading

        let modelIdentifier = entries[index].modelIdentifier
        downloadTasks[entryId]?.cancel()

        downloadTasks[entryId] = Task { [weak self] in
            await self?.performDownload(entryId: entryId, modelIdentifier: modelIdentifier)
        }
    }

    /// Cancel (pause) an in-progress download. The library's partial
    /// cache means a subsequent `startDownload` will resume from
    /// where it left off.
    func cancelDownload(entryId: String) {
        guard let index = entries.firstIndex(where: { $0.id == entryId }) else { return }
        guard entries[index].state == .downloading else { return }

        downloadTasks[entryId]?.cancel()
        downloadTasks[entryId] = nil
        entries[index].state = .cancelled
    }

    /// Check if a model is already available locally. Currently
    /// only checks the MLX embedder via its cached container.
    private func isModelReady(_ entryId: String) -> Bool {
        switch entryId {
        case "mlx-embedder":
            return PaceMLXEmbeddingClient.isModelCached()
        default:
            return false
        }
    }

    /// Perform the actual model load. On success, marks the entry
    /// as ready. On cancellation, marks as cancelled. On failure,
    /// marks as failed with the error message.
    private func performDownload(entryId: String, modelIdentifier: String) async {
        do {
            switch entryId {
            case "mlx-embedder":
                _ = try await PaceMLXEmbeddingClient.preloadModel(
                    modelIdentifier: modelIdentifier
                )
            default:
                return
            }

            if let index = entries.firstIndex(where: { $0.id == entryId }) {
                entries[index].state = .ready
            }
        } catch is CancellationError {
            if let index = entries.firstIndex(where: { $0.id == entryId }) {
                entries[index].state = .cancelled
            }
        } catch {
            if let index = entries.firstIndex(where: { $0.id == entryId }) {
                entries[index].state = .failed(error.localizedDescription)
            }
        }

        downloadTasks[entryId] = nil
    }
}
