//
//  PaceThreadMemoryStore.swift
//  leanring-buddy
//
//  On-device persistence for the conversational thread memory so a
//  conversation survives quit/relaunch ("resume always, until reset").
//
//  Single JSON file at `~/Library/Application Support/Pace/thread-memory.json`.
//  `PaceThreadMemory` stays I/O-free — it produces a `PaceThreadMemorySnapshot`
//  via `snapshot(now:)` and rehydrates via `restore(from:)`; this store is the
//  only thing that touches disk. Writes are atomic (`Data.write(.atomic)` does
//  a temp-file + rename on the same volume) so a crash mid-write can never
//  leave a half-written conversation behind.
//
//  Privacy: the file stays on this Mac and is removed by `clear()` on an
//  explicit thread reset (Settings → Memory → Reset thread) or when the user
//  turns thread memory off. Nothing is uploaded anywhere — same on-device
//  posture as the rest of Pace.
//

import Foundation

@MainActor
final class PaceThreadMemoryStore {
    private let fileURL: URL?

    init() {
        let applicationSupportRootURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        fileURL = applicationSupportRootURL?
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("thread-memory.json", isDirectory: false)
    }

    /// Load the persisted snapshot, or nil when no conversation has been
    /// saved yet / the file is unreadable. A decode failure returns nil
    /// (start fresh) rather than throwing — a corrupt file must never
    /// block launch.
    func load() -> PaceThreadMemorySnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PaceThreadMemorySnapshot.self, from: data)
    }

    /// Persist the current snapshot. Best-effort: any failure is swallowed
    /// (the user-facing turn must never block or fail on a thread-memory
    /// write). Creates the `Pace` support directory on first write.
    func save(_ snapshot: PaceThreadMemorySnapshot) {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }

        let directoryURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Remove the persisted conversation. Called on an explicit thread
    /// reset and when thread memory is disabled, so "until I reset"
    /// actually clears the on-disk copy too.
    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
