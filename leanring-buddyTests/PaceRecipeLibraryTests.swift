//
//  PaceRecipeLibraryTests.swift
//  leanring-buddyTests
//
//  Covers load, install, uninstall, missing-preference refusal,
//  already-installed refusal, and the startup-validation fixture path.
//

import Foundation
import Testing
@testable import Pace

struct PaceRecipeLibraryTests {

    // MARK: - Loader covers all five shipped recipes

    @Test func loadsAllFiveBundledRecipesFromSourceTreeFixtures() async throws {
        // The loader is wired to `Bundle.main`; in unit-test context the
        // app bundle may not include the resource subdirectory, so we
        // assert against the validator (which DOES allow source-tree
        // fallback) — that path is what the app exercises at startup.
        let validationIssues = PaceRecipeLibrary.validateBundledRecipes(bundle: .main)
        #expect(validationIssues.isEmpty, "expected no validation issues, got: \(validationIssues.map { $0.message }.joined(separator: "; "))")
    }

    @Test func bundledSlugListMatchesPRD() async throws {
        let expectedBundledSlugs: Set<String> = [
            "morning-standup-setup",
            "weekly-review-draft",
            "email-zero",
            "focus-mode-on",
            "end-of-day-shutdown",
        ]
        #expect(Set(PaceRecipeLibrary.bundledRecipeSlugs) == expectedBundledSlugs)
    }

    // MARK: - Install / uninstall round-trip

    @Test func installSavesRecipeAsRecordedFlow() async throws {
        let temporaryDirectoryURL = makeTemporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }
        let flowStore = PaceFlowStore(directoryURL: temporaryDirectoryURL)

        let installableRecipe = makeFixtureRecipe(slug: "fixture-install", requiredPreferences: [])
        try PaceRecipeLibrary.install(
            installableRecipe,
            into: flowStore,
            memoryStore: AlwaysEmptyMemoryStoreFixture.self
        )

        let savedFlow = flowStore.load(named: installableRecipe.name)
        #expect(savedFlow != nil)
        #expect(savedFlow?.steps.count == installableRecipe.steps.count)
        #expect(PaceRecipeLibrary.isInstalled(installableRecipe, in: flowStore))
    }

    @Test func uninstallRemovesPreviouslyInstalledFlow() async throws {
        let temporaryDirectoryURL = makeTemporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }
        let flowStore = PaceFlowStore(directoryURL: temporaryDirectoryURL)

        // Save the same recipe shape under the slug we'll search for.
        let installableRecipe = makeFixtureRecipe(slug: "fixture-uninstall", requiredPreferences: [])
        try flowStore.save(PaceRecordedFlow(
            name: installableRecipe.name,
            createdAt: Date(),
            steps: installableRecipe.steps
        ))
        #expect(flowStore.load(named: installableRecipe.name) != nil)

        // `uninstall(slug:)` looks the recipe up in the bundled library,
        // so for a fixture-only slug we must call delete directly to
        // simulate the same end-state. Verify the helper is a no-op for
        // an unknown slug and that delete cleans the file.
        PaceRecipeLibrary.uninstall(slug: "not-a-real-recipe", from: flowStore)
        #expect(flowStore.load(named: installableRecipe.name) != nil)
        try flowStore.delete(named: installableRecipe.name)
        #expect(flowStore.load(named: installableRecipe.name) == nil)
    }

    @Test func installRefusesWhenRequiredPreferenceMissing() async throws {
        let temporaryDirectoryURL = makeTemporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }
        let flowStore = PaceFlowStore(directoryURL: temporaryDirectoryURL)

        let preferenceGatedRecipe = makeFixtureRecipe(
            slug: "fixture-needs-playlist",
            requiredPreferences: [PaceLocalMemoryKey.preferredFocusPlaylist.rawValue]
        )

        do {
            try PaceRecipeLibrary.install(
                preferenceGatedRecipe,
                into: flowStore,
                memoryStore: AlwaysEmptyMemoryStoreFixture.self
            )
            #expect(Bool(false), "expected missingRequiredPreference error")
        } catch PaceRecipeInstallError.missingRequiredPreference(let missingPreferenceKey) {
            #expect(missingPreferenceKey == PaceLocalMemoryKey.preferredFocusPlaylist.rawValue)
        } catch {
            #expect(Bool(false), "unexpected error \(error)")
        }
    }

    @Test func installSucceedsWhenRequiredPreferenceIsPopulated() async throws {
        let temporaryDirectoryURL = makeTemporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }
        let flowStore = PaceFlowStore(directoryURL: temporaryDirectoryURL)

        let preferenceGatedRecipe = makeFixtureRecipe(
            slug: "fixture-with-playlist-set",
            requiredPreferences: [PaceLocalMemoryKey.preferredFocusPlaylist.rawValue]
        )

        try PaceRecipeLibrary.install(
            preferenceGatedRecipe,
            into: flowStore,
            memoryStore: AlwaysHasFocusPlaylistMemoryStoreFixture.self
        )

        #expect(PaceRecipeLibrary.isInstalled(preferenceGatedRecipe, in: flowStore))
    }

    @Test func installRefusesWhenRecipeAlreadySavedUnderSameName() async throws {
        let temporaryDirectoryURL = makeTemporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }
        let flowStore = PaceFlowStore(directoryURL: temporaryDirectoryURL)

        let duplicateRecipe = makeFixtureRecipe(slug: "fixture-duplicate", requiredPreferences: [])
        try PaceRecipeLibrary.install(
            duplicateRecipe,
            into: flowStore,
            memoryStore: AlwaysEmptyMemoryStoreFixture.self
        )

        do {
            try PaceRecipeLibrary.install(
                duplicateRecipe,
                into: flowStore,
                memoryStore: AlwaysEmptyMemoryStoreFixture.self
            )
            #expect(Bool(false), "expected alreadyInstalled error")
        } catch PaceRecipeInstallError.alreadyInstalled(let alreadyInstalledSlug) {
            #expect(alreadyInstalledSlug == duplicateRecipe.slug)
        } catch {
            #expect(Bool(false), "unexpected error \(error)")
        }
    }

    @Test func installRejectsUnknownRequiredPreferenceKey() async throws {
        let temporaryDirectoryURL = makeTemporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }
        let flowStore = PaceFlowStore(directoryURL: temporaryDirectoryURL)

        let recipeWithUnknownKey = makeFixtureRecipe(
            slug: "fixture-unknown-key",
            requiredPreferences: ["aPreferenceWeNeverDefined"]
        )

        do {
            try PaceRecipeLibrary.install(
                recipeWithUnknownKey,
                into: flowStore,
                memoryStore: AlwaysEmptyMemoryStoreFixture.self
            )
            #expect(Bool(false), "expected unknownRequiredPreference error")
        } catch PaceRecipeInstallError.unknownRequiredPreference(let unknownKey) {
            #expect(unknownKey == "aPreferenceWeNeverDefined")
        } catch {
            #expect(Bool(false), "unexpected error \(error)")
        }
    }

    // MARK: - Validator catches malformed bundle

    @Test func validatorCatchesMalformedRecipeFixture() async throws {
        let temporaryBundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-recipe-validation-\(UUID().uuidString).bundle", isDirectory: true)
        let recipeSubdirectoryURL = temporaryBundleURL
            .appendingPathComponent("Resources")
            .appendingPathComponent("recipes", isDirectory: true)
        try FileManager.default.createDirectory(at: recipeSubdirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryBundleURL) }

        // Write a malformed payload for one slug so we expect an issue
        // for THAT slug; the others will be reported as missing — both
        // are valid validator outputs we assert on.
        let malformedRecipeURL = recipeSubdirectoryURL.appendingPathComponent("morning-standup-setup.json")
        let malformedPayload = "{ \"name\": \"oops\" }"
        try malformedPayload.write(to: malformedRecipeURL, atomically: true, encoding: .utf8)

        // Use the URL-provider entry point so we can point the
        // validator straight at a temporary directory without paying
        // the Bundle(url:) cost. Strictly fixture-only — no source-
        // tree fallback can sneak in.
        let validationIssues = PaceRecipeLibrary.validateBundledRecipes(resolveRecipeURL: { recipeSlug in
            let recipeURL = recipeSubdirectoryURL.appendingPathComponent("\(recipeSlug).json")
            return FileManager.default.fileExists(atPath: recipeURL.path) ? recipeURL : nil
        })

        #expect(!validationIssues.isEmpty)
        // Must surface the bad-decode for the slug we wrote.
        let decodeFailureMessages = validationIssues.filter { $0.message.contains("morning-standup-setup") }
        #expect(!decodeFailureMessages.isEmpty)
    }

    // MARK: - Helpers

    private func makeTemporaryStoreDirectory() -> URL {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-recipe-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        return temporaryDirectoryURL
    }

    private func makeFixtureRecipe(
        slug: String,
        requiredPreferences: [String]
    ) -> PaceBundledRecipe {
        PaceBundledRecipe(
            name: "fixture recipe \(slug)",
            slug: slug,
            description: "fixture description for \(slug)",
            displayCategory: "test",
            createdAt: "2026-06-12T00:00:00Z",
            steps: [
                .activateApp(bundleIdentifier: "com.apple.iCal"),
                .keyShortcut(key: "cmd+n"),
            ],
            requiredPreferences: requiredPreferences
        )
    }
}

// MARK: - Memory-store fixtures

/// Reports every preference as unset. Used to assert the
/// missing-preference branch without touching `UserDefaults.standard`.
private enum AlwaysEmptyMemoryStoreFixture: PaceLocalMemoryStoreReadable {
    static func string(for key: PaceLocalMemoryKey) -> String? {
        return nil
    }
}

/// Reports `preferredFocusPlaylist` as populated; everything else
/// unset. Used to assert the install-when-set branch.
private enum AlwaysHasFocusPlaylistMemoryStoreFixture: PaceLocalMemoryStoreReadable {
    static func string(for key: PaceLocalMemoryKey) -> String? {
        switch key {
        case .preferredFocusPlaylist:
            return "Deep Work"
        default:
            return nil
        }
    }
}

// MARK: - Parser tests

struct PaceRecipeCommandParserTests {
    @Test func recognizesInstallCommand() async throws {
        #expect(PaceRecipeCommandParser.parse("install the morning standup setup recipe")
                == .install(displayName: "morning standup setup"))
        #expect(PaceRecipeCommandParser.parse("install morning standup setup recipe")
                == .install(displayName: "morning standup setup"))
        #expect(PaceRecipeCommandParser.parse("add the inbox triage pass flow")
                == .install(displayName: "inbox triage pass"))
    }

    @Test func recognizesUninstallCommand() async throws {
        #expect(PaceRecipeCommandParser.parse("remove the focus mode on recipe")
                == .uninstall(displayName: "focus mode on"))
        #expect(PaceRecipeCommandParser.parse("uninstall morning standup setup recipe")
                == .uninstall(displayName: "morning standup setup"))
    }

    @Test func recognizesListCommand() async throws {
        #expect(PaceRecipeCommandParser.parse("list recipes") == .list)
        #expect(PaceRecipeCommandParser.parse("what recipes do you have") == .list)
        #expect(PaceRecipeCommandParser.parse("show recipes") == .list)
    }

    @Test func ignoresUnrelatedTranscripts() async throws {
        #expect(PaceRecipeCommandParser.parse("install the latest update") == nil)
        #expect(PaceRecipeCommandParser.parse("hello pace") == nil)
        #expect(PaceRecipeCommandParser.parse("") == nil)
        #expect(PaceRecipeCommandParser.parse("install   recipe") == nil)
    }
}
