//
//  CompanionManager+LocalMemoryCommands.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition):
//  voice-command handlers for remember-site, local memory, recipes, and MCP prompt augmentation.
//

import AppKit
import Foundation

@MainActor
extension CompanionManager {

    // MARK: - Local memory & fast-path commands

    func handleRememberSiteCommand(
        _ command: PaceRememberSiteCommand,
        transcript: String
    ) {
        let spokenText: String
        switch command {
        case .forget(let name):
            let didForget = PaceNamedDestinationStore.shared.forget(displayName: name)
            spokenText = didForget
                ? "forgotten."
                : "i don't have a saved site called \(name)."
        case .remember(let requestedName):
            if let captured = PaceBrowserURLReader.currentTab() {
                let displayName = requestedName
                    ?? PaceBrowserURLReader.defaultName(forURL: captured.url)
                PaceNamedDestinationStore.shared.save(
                    displayName: displayName,
                    url: captured.url
                )
                spokenText = "got it — i'll remember \(displayName)."
            } else {
                // Frontmost app isn't a scriptable browser, or the read failed.
                spokenText = "i couldn't read this page's address — make sure the site is open in your browser and try again."
            }
        }

        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(spokenText)
        recordConversationTurn(userTranscript: transcript, assistantResponse: spokenText)
        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
            currentTurnHUDState = .done("done")
        }
    }

    func handleLocalMemoryCommand(_ command: PaceLocalMemoryCommand) {
        let spokenText: String
        switch command {
        case .set(let key, let value):
            PaceLocalMemoryStore.setString(value, for: key)
            spokenText = "remembered \(value)."
        case .forget(let key):
            PaceLocalMemoryStore.setString(nil, for: key)
            spokenText = "forgot that preference."
        }

        localMemorySummary = PaceLocalMemoryStore.summaryText
        localRetriever.refreshPreferenceDocuments()
        refreshLocalRetrievalPublishedState()
        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(spokenText)
        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
        }
    }

    func handleAlwaysListeningCommand(_ command: PaceAlwaysListeningCommand, transcript: String) {
        let spokenText: String
        switch command {
        case .start:
            setAlwaysListeningEnabled(true)
            spokenText = "always listening is on."
        case .stop:
            setAlwaysListeningEnabled(false)
            spokenText = "always listening is off."
        }
        handleImmediateLocalModeResponse(transcript: transcript, spokenText: spokenText)
    }


    func handleRecipeCommand(_ command: PaceRecipeCommand, transcript: String) {
        let flowStore = PaceFlowStore()
        let bundledRecipes = PaceRecipeLibrary.loadBundledRecipes()
        let spokenText: String

        switch command {
        case .install(let displayName):
            guard let matchedRecipe = matchBundledRecipe(displayName: displayName, in: bundledRecipes) else {
                spokenText = "i don't have a recipe called \(displayName)."
                break
            }
            do {
                try PaceRecipeLibrary.install(matchedRecipe, into: flowStore)
                spokenText = "installed \(matchedRecipe.name)."
            } catch PaceRecipeInstallError.missingRequiredPreference(let requiredPreferenceKey) {
                spokenText = "i need \(requiredPreferenceKey) set first."
            } catch PaceRecipeInstallError.alreadyInstalled {
                spokenText = "\(matchedRecipe.name) is already installed."
            } catch {
                spokenText = "i couldn't install that recipe."
            }
        case .uninstall(let displayName):
            guard let matchedRecipe = matchBundledRecipe(displayName: displayName, in: bundledRecipes) else {
                spokenText = "i don't have a recipe called \(displayName)."
                break
            }
            if !PaceRecipeLibrary.isInstalled(matchedRecipe, in: flowStore) {
                spokenText = "\(matchedRecipe.name) isn't installed."
                break
            }
            PaceRecipeLibrary.uninstall(slug: matchedRecipe.slug, from: flowStore)
            spokenText = "removed \(matchedRecipe.name)."
        case .list:
            if bundledRecipes.isEmpty {
                spokenText = "i don't have any recipes bundled."
            } else {
                let displayNames = bundledRecipes.map { $0.name }.joined(separator: ", ")
                spokenText = "available recipes: \(displayNames)."
            }
        }

        handleImmediateLocalModeResponse(transcript: transcript, spokenText: spokenText)
    }

    /// Case-insensitive lookup of a bundled recipe by display name OR
    /// slug. Lets the user say "morning standup setup" or
    /// "morning-standup-setup" and get the same recipe.
    func matchBundledRecipe(
        displayName: String,
        in bundledRecipes: [PaceBundledRecipe]
    ) -> PaceBundledRecipe? {
        let normalizedDisplayName = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return bundledRecipes.first(where: { recipe in
            recipe.name.lowercased() == normalizedDisplayName
                || recipe.slug.lowercased() == normalizedDisplayName
        })
    }

    func handleImmediateLocalModeResponse(transcript: String, spokenText: String) {
        currentTurnHUDState = .done(spokenText)
        recordConversationTurn(userTranscript: transcript, assistantResponse: spokenText)
        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(spokenText)
        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
        }
    }

    func currentToolPreflightEnvironment() -> PaceToolPreflightEnvironment {
        PaceToolPreflightEnvironment(
            actionsAreEnabled: actionExecutor.actionsAreEnabled,
            hasAccessibilityPermission: hasAccessibilityPermission,
            hasCalendarPermission: hasCalendarPermission,
            hasRemindersPermission: hasRemindersPermission,
            configuredMCPServerNames: Set(PaceMCPServerRegistry.loadConfiguredServers().keys)
        )
    }

    func appendConfiguredMCPContext(to userPrompt: String) -> String {
        let configuredServerNames = PaceMCPServerRegistry
            .loadConfiguredServers()
            .keys
            .sorted()

        guard !configuredServerNames.isEmpty else {
            return userPrompt
        }

        return """
        \(userPrompt)

        Configured MCP servers:
        \(configuredServerNames.map { "- \($0)" }.joined(separator: "\n"))

        Use MCP only when a task is better handled by one of these configured external servers.
        """
    }
}
