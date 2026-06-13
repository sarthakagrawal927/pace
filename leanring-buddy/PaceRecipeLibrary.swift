//
//  PaceRecipeLibrary.swift
//  leanring-buddy
//
//  Bundled "Poke-style" recipe library. Each recipe is a JSON file
//  shipped at `Resources/recipes/<slug>.json`. Schema-compatible with
//  `PaceFlowStore`'s on-disk shape PLUS a small layer of metadata
//  (slug, description, displayCategory, requiredPreferences) so the
//  Settings UI can describe each recipe and refuse install when a
//  required preference is missing.
//
//  Installation is "save into PaceFlowStore under the recipe name" so
//  the existing replay tool can execute the recipe with no new tool
//  kind. Uninstall is "delete that store entry by slug-derived name".
//
//  Pure module — no UI, no async, no global state.
//

import Foundation

// MARK: - Recipe model

/// One bundled, installable recipe. Decoded directly from
/// `Resources/recipes/<slug>.json`. Codable so the same JSON the test
/// suite asserts against is the JSON the runtime parses.
nonisolated struct PaceBundledRecipe: Equatable, Codable {
    /// Human-readable name. Used as the saved `PaceRecordedFlow.name`
    /// after install, so the `run_flow` tool can match it.
    let name: String

    /// Stable identifier. Used for the resource filename and for
    /// uninstall lookups. Must match `PaceFlowStore.slug(for: name)`
    /// for any name → slug mapping the user sees in Settings.
    let slug: String

    /// 1-line description shown in the Settings UI.
    let description: String

    /// Category bucket ("morning" / "work" / "shutdown") used to
    /// group recipes in the UI. Free-form string for v1.
    let displayCategory: String

    /// ISO8601 string. Baked into the recipe JSON at ship time;
    /// re-used as the saved flow's `createdAt` so the user sees a
    /// sensible date next to the recipe in the existing flows list.
    let createdAt: String

    /// The flow steps. Schema-identical to `PaceRecordedStep` so
    /// `PaceFlowStore` can save the recipe as a regular flow.
    let steps: [PaceRecordedStep]

    /// Optional `requiredPreferences` — `PaceLocalMemoryKey` raw
    /// values that must be set in `PaceLocalMemoryStore` before
    /// install can succeed. Lets recipes depend on user state
    /// (e.g. preferred focus playlist) without baking values into
    /// the bundled JSON itself.
    let requiredPreferences: [String]

    /// Reserved placeholder for v2 secure-field default support.
    /// Always `[:]` in v1; kept in the model so on-disk JSON layout
    /// is stable when v2 lands.
    let secureFieldDefaults: [String: String]

    init(
        name: String,
        slug: String,
        description: String,
        displayCategory: String,
        createdAt: String,
        steps: [PaceRecordedStep],
        requiredPreferences: [String] = [],
        secureFieldDefaults: [String: String] = [:]
    ) {
        self.name = name
        self.slug = slug
        self.description = description
        self.displayCategory = displayCategory
        self.createdAt = createdAt
        self.steps = steps
        self.requiredPreferences = requiredPreferences
        self.secureFieldDefaults = secureFieldDefaults
    }
}

// MARK: - Validation issue type

/// One specific problem the validator surfaced. Mirrors the shape of
/// `PaceToolRegistryValidationIssue` so the startup-validation site can
/// treat both validator outputs uniformly.
nonisolated struct PaceRecipeValidationIssue: Equatable, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

// MARK: - Install error type

enum PaceRecipeInstallError: Error, Equatable {
    /// Recipe declared `requiredPreferences` but at least one of them
    /// is not set in `PaceLocalMemoryStore`. The associated value is
    /// the raw `PaceLocalMemoryKey` name that was missing, so the
    /// caller can render a precise "install <key> first" message.
    case missingRequiredPreference(String)

    /// A flow with the recipe's destination name (or its slug-derived
    /// file) is already present in `PaceFlowStore`. Caller can either
    /// uninstall first or surface a "already installed" message.
    case alreadyInstalled(String)

    /// `requiredPreferences` referenced a string that doesn't map to
    /// any known `PaceLocalMemoryKey`. Should never happen for shipped
    /// recipes because startup validation catches it — but `install`
    /// is defensive so an external caller can't sneak past.
    case unknownRequiredPreference(String)
}

// MARK: - Library

nonisolated enum PaceRecipeLibrary {
    /// Subdirectory inside the bundle where recipe JSON files live.
    /// Mirrors the `Resources/v10-actions` convention used by the tool
    /// registry artifact lookups.
    static let bundleResourceDirectory: String = "recipes"

    /// The five recipe slugs we ship in v1. Used by the loader as the
    /// authoritative list of files to look up so a missing-from-bundle
    /// recipe is detected (rather than silently absent).
    static let bundledRecipeSlugs: [String] = [
        "morning-standup-setup",
        "weekly-review-draft",
        "email-zero",
        "focus-mode-on",
        "end-of-day-shutdown",
    ]

    /// Load all bundled recipes that decode cleanly. Skips and logs any
    /// recipe whose JSON fails to decode — startup validation surfaces
    /// the precise failure separately.
    static func loadBundledRecipes(bundle: Bundle = .main) -> [PaceBundledRecipe] {
        var loadedRecipes: [PaceBundledRecipe] = []
        for slug in bundledRecipeSlugs {
            guard let recipeURL = recipeResourceURL(slug: slug, bundle: bundle, allowSourceTreeFallback: false) else {
                continue
            }
            guard let recipeData = try? Data(contentsOf: recipeURL) else {
                continue
            }
            guard let decodedRecipe = try? decoder.decode(PaceBundledRecipe.self, from: recipeData) else {
                continue
            }
            loadedRecipes.append(decodedRecipe)
        }
        return loadedRecipes
    }

    /// Install a recipe into `PaceFlowStore`. Refuses install if
    /// `requiredPreferences` aren't satisfied or if a flow with the
    /// recipe's name is already saved. The recipe's `createdAt` ISO
    /// string is preserved (parses to a Date for the saved flow; falls
    /// back to "now" if the timestamp is malformed).
    static func install(
        _ recipe: PaceBundledRecipe,
        into store: PaceFlowStore,
        memoryStore: PaceLocalMemoryStoreReadable.Type = PaceLocalMemoryStore.self
    ) throws {
        for requiredPreferenceKey in recipe.requiredPreferences {
            guard let resolvedKey = PaceLocalMemoryKey(rawValue: requiredPreferenceKey) else {
                throw PaceRecipeInstallError.unknownRequiredPreference(requiredPreferenceKey)
            }
            if memoryStore.string(for: resolvedKey) == nil {
                throw PaceRecipeInstallError.missingRequiredPreference(requiredPreferenceKey)
            }
        }

        if store.load(named: recipe.name) != nil {
            throw PaceRecipeInstallError.alreadyInstalled(recipe.slug)
        }

        let installedFlow = PaceRecordedFlow(
            name: recipe.name,
            createdAt: parseCreatedAt(recipe.createdAt),
            steps: recipe.steps
        )
        try store.save(installedFlow)
    }

    /// Uninstall (delete) the saved flow corresponding to the given
    /// recipe slug. No-op if the flow isn't currently saved. Looks up
    /// by the slug-derived filename, mirroring `PaceFlowStore.delete`.
    static func uninstall(slug: String, from store: PaceFlowStore) {
        guard let recipe = loadBundledRecipes().first(where: { $0.slug == slug }) else {
            return
        }
        try? store.delete(named: recipe.name)
    }

    /// Check whether a recipe is currently installed in `PaceFlowStore`.
    /// Used by the Settings UI to switch the row's button between
    /// "Install" and "Installed · Uninstall".
    static func isInstalled(_ recipe: PaceBundledRecipe, in store: PaceFlowStore) -> Bool {
        store.load(named: recipe.name) != nil
    }

    /// Run every recipe JSON through structural checks. Called from
    /// `PaceToolRegistry.validateForAppStartup` so malformed recipe
    /// drift fails the app at launch instead of at first user
    /// interaction.
    ///
    /// `allowSourceTreeFallback` mirrors the tool-registry convention:
    /// at runtime the shipped Pace.app must only see what's in its own
    /// bundle (false), but tests + the source-tree validator pass true
    /// so unit tests can run without a fully-staged resource bundle.
    static func validateBundledRecipes(
        bundle: Bundle = .main,
        allowSourceTreeFallback: Bool = true
    ) -> [PaceRecipeValidationIssue] {
        return validateBundledRecipes(resolveRecipeURL: { slug in
            recipeResourceURL(
                slug: slug,
                bundle: bundle,
                allowSourceTreeFallback: allowSourceTreeFallback
            )
        })
    }

    /// Test-facing entry point: takes an explicit URL provider so unit
    /// tests can validate a fixture directory without constructing a
    /// full `Bundle` (Bundle(url:) requires the Contents/Info.plist
    /// layout, which is heavier than we need for validation).
    static func validateBundledRecipes(
        resolveRecipeURL: (String) -> URL?
    ) -> [PaceRecipeValidationIssue] {
        var validationIssues: [PaceRecipeValidationIssue] = []
        var seenSlugs: Set<String> = []
        var seenNames: Set<String> = []

        for expectedSlug in bundledRecipeSlugs {
            guard let recipeURL = resolveRecipeURL(expectedSlug) else {
                validationIssues.append(
                    PaceRecipeValidationIssue(message: "missing bundled recipe at Resources/recipes/\(expectedSlug).json")
                )
                continue
            }

            let recipeData: Data
            do {
                recipeData = try Data(contentsOf: recipeURL)
            } catch {
                validationIssues.append(
                    PaceRecipeValidationIssue(message: "could not read bundled recipe \(expectedSlug): \(error.localizedDescription)")
                )
                continue
            }

            let decodedRecipe: PaceBundledRecipe
            do {
                decodedRecipe = try decoder.decode(PaceBundledRecipe.self, from: recipeData)
            } catch {
                validationIssues.append(
                    PaceRecipeValidationIssue(message: "bundled recipe \(expectedSlug).json failed to decode: \(error.localizedDescription)")
                )
                continue
            }

            validationIssues.append(contentsOf: validateRecipeShape(decodedRecipe, expectedSlug: expectedSlug))

            if seenSlugs.contains(decodedRecipe.slug) {
                validationIssues.append(
                    PaceRecipeValidationIssue(message: "duplicate recipe slug \(decodedRecipe.slug)")
                )
            } else {
                seenSlugs.insert(decodedRecipe.slug)
            }

            let normalizedName = decodedRecipe.name.lowercased()
            if seenNames.contains(normalizedName) {
                validationIssues.append(
                    PaceRecipeValidationIssue(message: "duplicate recipe name \(decodedRecipe.name)")
                )
            } else {
                seenNames.insert(normalizedName)
            }
        }

        return validationIssues
    }

    // MARK: - Private helpers

    private static func validateRecipeShape(
        _ recipe: PaceBundledRecipe,
        expectedSlug: String
    ) -> [PaceRecipeValidationIssue] {
        var validationIssues: [PaceRecipeValidationIssue] = []

        if recipe.slug != expectedSlug {
            validationIssues.append(
                PaceRecipeValidationIssue(
                    message: "recipe at \(expectedSlug).json declares slug \(recipe.slug); filename and slug must match"
                )
            )
        }

        let trimmedName = recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            validationIssues.append(
                PaceRecipeValidationIssue(message: "recipe \(expectedSlug) has empty name")
            )
        }

        let trimmedDescription = recipe.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDescription.isEmpty {
            validationIssues.append(
                PaceRecipeValidationIssue(message: "recipe \(expectedSlug) has empty description")
            )
        }

        let trimmedDisplayCategory = recipe.displayCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDisplayCategory.isEmpty {
            validationIssues.append(
                PaceRecipeValidationIssue(message: "recipe \(expectedSlug) has empty displayCategory")
            )
        }

        if recipe.steps.isEmpty {
            validationIssues.append(
                PaceRecipeValidationIssue(message: "recipe \(expectedSlug) must declare at least one step")
            )
        }

        for requiredPreferenceKey in recipe.requiredPreferences {
            if PaceLocalMemoryKey(rawValue: requiredPreferenceKey) == nil {
                validationIssues.append(
                    PaceRecipeValidationIssue(
                        message: "recipe \(expectedSlug) requires unknown preference key \(requiredPreferenceKey)"
                    )
                )
            }
        }

        return validationIssues
    }

    /// Bundle resource lookup. Tries the synchronized-group layout
    /// (Resources/recipes/<slug>.json), then the legacy flat layout,
    /// then optionally the source tree (only allowed for the
    /// validation path so the unit test suite can find the JSON when
    /// the test bundle doesn't ship recipes).
    private static func recipeResourceURL(
        slug: String,
        bundle: Bundle,
        allowSourceTreeFallback: Bool
    ) -> URL? {
        let bundleCandidates = [
            bundle.url(
                forResource: slug,
                withExtension: "json",
                subdirectory: "Resources/\(bundleResourceDirectory)"
            ),
            bundle.url(
                forResource: slug,
                withExtension: "json",
                subdirectory: bundleResourceDirectory
            ),
            bundle.url(
                forResource: slug,
                withExtension: "json"
            )
        ]
        if let bundledURL = bundleCandidates.compactMap({ $0 }).first {
            return bundledURL
        }

        guard allowSourceTreeFallback else { return nil }
        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceTreeURL = currentDirectoryURL
            .appendingPathComponent("leanring-buddy")
            .appendingPathComponent("Resources")
            .appendingPathComponent(bundleResourceDirectory)
            .appendingPathComponent("\(slug).json")
        return FileManager.default.fileExists(atPath: sourceTreeURL.path) ? sourceTreeURL : nil
    }

    private static let decoder: JSONDecoder = {
        let jsonDecoder = JSONDecoder()
        return jsonDecoder
    }()

    private static func parseCreatedAt(_ rawTimestamp: String) -> Date {
        let isoFormatter = ISO8601DateFormatter()
        return isoFormatter.date(from: rawTimestamp) ?? Date()
    }
}

// MARK: - Memory-store abstraction for testability

/// Minimal surface of `PaceLocalMemoryStore` that the recipe installer
/// needs. Lets unit tests inject a stub store without depending on
/// `UserDefaults.standard` state.
nonisolated protocol PaceLocalMemoryStoreReadable {
    static func string(for key: PaceLocalMemoryKey) -> String?
}

extension PaceLocalMemoryStore: PaceLocalMemoryStoreReadable {}
