//
//  PaceFlowStore.swift
//  leanring-buddy
//
//  JSON-backed persistence for recorded user flows.
//
//  One file per flow under
//  `~/Library/Application Support/Pace/flows/<slug>.json`. The slug is
//  derived from the flow's display name (lowercase, non-alphanumeric
//  collapsed to `-`, length-capped at 64). Files are written atomically
//  (temp file in the same directory + rename) so a crash mid-write
//  can never leave the user with a half-written flow on disk.
//
//  Schema is byte-identical to the bundled recipe JSON shape under
//  `Resources/recipes/<slug>.json` — `PaceRecipeLibrary` literally
//  installs a recipe by calling `PaceFlowStore.save(_:)` with a
//  `PaceRecordedFlow`. Keeping that surface stable means a recipe
//  install is just "drop the right JSON in the same directory".
//
//  v1 didn't have a persistent flow store — `PaceFlowStore` only
//  shipped as a thin file-backed wrapper inside `PaceFlowReplay.swift`.
//  This file is the Wave 3a split-out; the public symbol name stays
//  `PaceFlowStore` so every production call site (CompanionManager,
//  PaceActionExecutor, PaceRecipeLibrary, PaceSettingsWindow) keeps
//  compiling without touching its own file.
//

import Foundation

/// Errors the store can surface to callers. Kept small — most file
/// failures we just let bubble up as `Error` from FileManager so the
/// caller can decide whether to retry or surface to the user.
nonisolated enum PaceFlowStoreError: Error, Equatable {
    /// `rename(_:to:)` was asked to rename a flow that doesn't exist.
    case sourceFlowNotFound(String)

    /// `rename(_:to:)` was asked to overwrite an existing destination
    /// flow. We refuse rather than silently destroying user data.
    case destinationFlowAlreadyExists(String)
}

nonisolated struct PaceFlowStore {
    /// Default on-disk root for saved flows. Lives under the standard
    /// `Application Support/Pace/flows` directory so it gets backed up
    /// by Time Machine and survives app reinstalls.
    static var defaultDirectoryURL: URL {
        let applicationSupportRootURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.temporaryDirectory
        return applicationSupportRootURL
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("flows", isDirectory: true)
    }

    /// Maximum slug length. 64 keeps filenames inside every macOS file
    /// system's per-component limit (HFS+ 255, APFS 255) with massive
    /// headroom for the `.json` suffix and any reserved suffix prefixes
    /// the OS might add during a rename.
    static let maximumSlugLength: Int = 64

    let directoryURL: URL

    init(directoryURL: URL = PaceFlowStore.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    // MARK: - Public API

    func save(_ flow: PaceRecordedFlow) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let encodedFlowJSON = try Self.jsonEncoder.encode(flow)
        let destinationFileURL = fileURL(for: flow.name)
        try writeAtomically(data: encodedFlowJSON, to: destinationFileURL)
    }

    func load(named name: String) -> PaceRecordedFlow? {
        guard let flowFileData = try? Data(contentsOf: fileURL(for: name)) else {
            return nil
        }
        return try? Self.jsonDecoder.decode(PaceRecordedFlow.self, from: flowFileData)
    }

    func delete(named name: String) throws {
        let targetFileURL = fileURL(for: name)
        if FileManager.default.fileExists(atPath: targetFileURL.path) {
            try FileManager.default.removeItem(at: targetFileURL)
        }
    }

    /// Returns every saved flow that decoded cleanly. Sorted by
    /// `createdAt` descending so the Settings UI naturally shows the
    /// most recent flow first; this matches how a user expects to see
    /// "the thing I just recorded" at the top of the list.
    func listAll() -> [PaceRecordedFlow] {
        guard let directoryEntryURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let decodedFlows = directoryEntryURLs
            .filter { $0.pathExtension == "json" }
            .compactMap { fileURL -> PaceRecordedFlow? in
                guard let fileData = try? Data(contentsOf: fileURL) else {
                    return nil
                }
                return try? Self.jsonDecoder.decode(PaceRecordedFlow.self, from: fileData)
            }
        return decodedFlows.sorted { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }
    }

    /// Rename a saved flow. Implemented as "save new file with the
    /// renamed flow's metadata, delete old file" so the on-disk slug
    /// stays in sync with the user-visible name.
    ///
    /// The rename is atomic in the sense that we only delete the
    /// source file after the destination write has succeeded. A crash
    /// between the two steps leaves both files on disk; the user can
    /// resolve manually (or by re-running rename, which will then
    /// fail with `destinationFlowAlreadyExists` and surface the issue).
    func rename(_ originalName: String, to newName: String) throws {
        guard let originalFlow = load(named: originalName) else {
            throw PaceFlowStoreError.sourceFlowNotFound(originalName)
        }
        let trimmedNewName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceFileURL = fileURL(for: originalName)
        let destinationFileURL = fileURL(for: trimmedNewName)

        if sourceFileURL != destinationFileURL,
           FileManager.default.fileExists(atPath: destinationFileURL.path) {
            throw PaceFlowStoreError.destinationFlowAlreadyExists(trimmedNewName)
        }

        let renamedFlow = PaceRecordedFlow(
            name: trimmedNewName,
            createdAt: originalFlow.createdAt,
            steps: originalFlow.steps
        )
        try save(renamedFlow)

        if sourceFileURL != destinationFileURL {
            try? FileManager.default.removeItem(at: sourceFileURL)
        }
    }

    // MARK: - One-shot migration

    /// Best-effort migration from the legacy UserDefaults-backed flow
    /// snapshot. The early prototype kept flows in `UserDefaults` under
    /// the `pace.flows.snapshot` key as a single JSON blob containing
    /// `[PaceRecordedFlow]`. We read it once, save every entry into
    /// the new on-disk store, and then delete the UserDefaults key so
    /// this runs at most once per user.
    ///
    /// Defensive: missing key, malformed JSON, save failures all degrade
    /// to "no migration" silently. The next time the user records or
    /// installs a flow they'll be using the new store anyway.
    static let legacyUserDefaultsKey: String = "pace.flows.snapshot"

    @discardableResult
    func migrateLegacyUserDefaultsFlowsIfNeeded(
        userDefaults: UserDefaults = .standard
    ) -> Int {
        guard let legacySnapshotData = userDefaults.data(
            forKey: Self.legacyUserDefaultsKey
        ) else {
            return 0
        }
        guard let legacyFlows = try? Self.jsonDecoder.decode(
            [PaceRecordedFlow].self,
            from: legacySnapshotData
        ) else {
            userDefaults.removeObject(forKey: Self.legacyUserDefaultsKey)
            return 0
        }
        var migratedFlowCount = 0
        for legacyFlow in legacyFlows {
            do {
                try save(legacyFlow)
                migratedFlowCount += 1
            } catch {
                // Best-effort — skip this flow and try the next one.
                // The legacy UD key stays present so the next launch
                // can retry, but we still clear it below so we don't
                // loop forever on a single broken flow.
            }
        }
        userDefaults.removeObject(forKey: Self.legacyUserDefaultsKey)
        return migratedFlowCount
    }

    // MARK: - Slug helpers

    /// Map a display name to its on-disk slug. Public so callers (the
    /// Settings UI, the recipe library) can preview the resulting
    /// filename without duplicating the normalization rules.
    static func slug(for name: String) -> String {
        let allowedScalars = CharacterSet.alphanumerics
        let loweredAndTrimmedName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Map every non-alphanumeric scalar to `-`, then collapse runs
        // of `-` into a single `-`, and trim leading/trailing `-`.
        let mappedScalars = loweredAndTrimmedName.unicodeScalars.map { scalar -> Character in
            allowedScalars.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsedSlugComponents = String(mappedScalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")

        // Cap length. Trimming any trailing partial `-` keeps the slug
        // looking clean instead of "...thing-".
        let cappedSlug: String
        if collapsedSlugComponents.count > maximumSlugLength {
            let prefixIndex = collapsedSlugComponents.index(
                collapsedSlugComponents.startIndex,
                offsetBy: maximumSlugLength
            )
            cappedSlug = String(collapsedSlugComponents[..<prefixIndex])
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        } else {
            cappedSlug = collapsedSlugComponents
        }

        return cappedSlug.isEmpty ? "flow" : cappedSlug
    }

    // MARK: - Private helpers

    private func fileURL(for flowName: String) -> URL {
        directoryURL
            .appendingPathComponent(Self.slug(for: flowName))
            .appendingPathExtension("json")
    }

    /// Atomic temp-file + rename write. Mirrors the pattern in
    /// `PaceMCPCatalogInstaller` so the implementation looks the same
    /// to a reviewer who has already read that file.
    private func writeAtomically(data: Data, to destinationFileURL: URL) throws {
        let parentDirectoryURL = destinationFileURL.deletingLastPathComponent()
        let temporaryFileURL = parentDirectoryURL.appendingPathComponent(
            ".\(destinationFileURL.lastPathComponent).pace.tmp.\(UUID().uuidString)"
        )
        try data.write(to: temporaryFileURL, options: [.atomic])
        do {
            if FileManager.default.fileExists(atPath: destinationFileURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    destinationFileURL,
                    withItemAt: temporaryFileURL
                )
            } else {
                try FileManager.default.moveItem(at: temporaryFileURL, to: destinationFileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryFileURL)
            throw error
        }
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
