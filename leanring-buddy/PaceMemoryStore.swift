//
//  PaceMemoryStore.swift
//  leanring-buddy
//
//  On-device persistence for the unified memory index (see
//  docs/prds/unified-memory.md, Phase 1). The whole entry list — including
//  per-entry `[Float]` embeddings — is persisted as one atomic JSON file at
//  `~/Library/Application Support/Pace/memory-index.json`.
//
//  Mirrors `PaceThreadMemoryStore`: this is the ONLY thing that touches disk
//  for the memory index. `PaceMemoryIndex` stays I/O-free. Writes are atomic
//  (`Data.write(.atomic)` does temp-file + rename on the same volume) so a
//  crash mid-write can never leave a half-written index behind. A corrupt or
//  missing file loads as an empty list rather than throwing — memory must
//  never block launch.
//
//  Privacy: the file stays on this Mac and is removed by `clear()` on an
//  explicit reset — same on-device posture as the rest of Pace.
//

import Foundation

@MainActor
final class PaceMemoryStore {
    private let fileURL: URL?

    init() {
        let applicationSupportRootURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        fileURL = applicationSupportRootURL?
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("memory-index.json", isDirectory: false)
    }

    /// Load the persisted entries, or an empty list when nothing has been
    /// saved yet / the file is unreadable. A decode failure returns `[]`
    /// (start fresh) rather than throwing — a corrupt file must never block
    /// launch.
    func load() -> [PaceMemoryEntry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PaceMemoryEntry].self, from: data)) ?? []
    }

    /// Persist the current entry list. Best-effort: any failure is swallowed
    /// so a memory write never blocks or fails a user-facing turn. Creates
    /// the `Pace` support directory on first write.
    func save(_ entries: [PaceMemoryEntry]) {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }

        let directoryURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Remove the persisted memory index. Called on an explicit reset so
    /// "reset all memory" actually clears the on-disk copy too.
    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
