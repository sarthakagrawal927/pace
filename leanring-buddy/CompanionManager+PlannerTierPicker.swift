//
//  CompanionManager+PlannerTierPicker.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition Phase A5):
//  planner tier picker setters, Direct-API key management, and off-device tier checks.
//

import Foundation

@MainActor
extension CompanionManager {

    // MARK: - Planner tier picker state

    func setActivePlannerTier(_ newTier: PacePlannerTier) {
        activePlannerTier = newTier
        PacePlannerTierStore.saveTier(newTier)
        // Rebuild planner so the next turn uses the freshly-picked tier
        // without requiring an app restart.
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    func setDirectAPIProvider(_ newProvider: PaceDirectAPIProvider) {
        directAPIProvider = newProvider
        PacePlannerTierStore.saveDirectAPIProvider(newProvider)
        // When the provider changes, also seed the model field with that
        // provider's default — the user can immediately overwrite it but
        // most users want a sensible starting model identifier.
        let savedModelForProvider = PacePlannerTierStore.loadConfiguration().directAPIModelIdentifier
        let modelIdentifierLooksEmptyOrStale = savedModelForProvider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if modelIdentifierLooksEmptyOrStale {
            setDirectAPIModelIdentifier(newProvider.defaultModelIdentifier)
        }
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    func setDirectAPIModelIdentifier(_ newModelIdentifier: String) {
        directAPIModelIdentifier = newModelIdentifier
        PacePlannerTierStore.saveDirectAPIModelIdentifier(newModelIdentifier)
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    func setDirectAPICustomEndpointURLString(_ newCustomEndpointURLString: String) {
        directAPICustomEndpointURLString = newCustomEndpointURLString
        PacePlannerTierStore.saveDirectAPICustomEndpointURL(newCustomEndpointURLString)
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    func setDirectAPIFallsBackToLocalOnCloudFailure(_ enabled: Bool) {
        directAPIFallsBackToLocalOnCloudFailure = enabled
        PacePlannerTierStore.saveFallsBackToLocalOnCloudFailure(enabled)
    }

    /// Whether the active planner tier is one that leaves the Mac.
    /// Cliff-edge gates: cliBridge requires consent AND a non-off mode;
    /// directAPI requires a stored key. Both checks mirror the factory
    /// so the UI flag stays honest.
    var activePlannerTierIsOffDevice: Bool {
        switch activePlannerTier {
        case .local, .appleFoundationModels:
            return false
        case .cliBridge:
            let bridgeConfiguration = PaceCloudBridgeConsent.loadConfiguration()
            return bridgeConfiguration.hasUserAcceptedConsent
                && bridgeConfiguration.mode != .off
        case .directAPI:
            return PaceKeychainStore.loadAPIKey(for: directAPIProvider) != nil
        }
    }

    /// Verifies that the configured Direct-API provider, model, and key
    /// can complete a single round trip. Builds a one-off
    /// `DirectAPIPlannerClient` rather than reusing the active
    /// `plannerClient` so the test does not disturb live state and is
    /// not blocked by the tier choice. Surfaces the upstream error
    /// verbatim on failure — users debugging API issues need to see the
    /// provider's actual error string to find it in provider docs.
    func runDirectAPITestRoundTrip() async -> Result<String, Error> {
        let configurationAtTestTime = PacePlannerTierStore.loadConfiguration()
        let resolvedEndpointURLString = PacePlannerTierStore
            .resolvedDirectAPIEndpointURLString(for: configurationAtTestTime)

        let validatedEndpointURL: URL
        do {
            validatedEndpointURL = try PaceLocalEndpointGuard.validatedDirectAPIURL(
                from: resolvedEndpointURLString
            )
        } catch {
            return .failure(error)
        }

        let testOnlyPlannerClient = DirectAPIPlannerClient(
            provider: configurationAtTestTime.directAPIProvider,
            endpointURL: validatedEndpointURL,
            modelIdentifier: configurationAtTestTime.directAPIModelIdentifier
        )

        do {
            let (responseText, _) = try await testOnlyPlannerClient.generateResponseStreaming(
                images: [],
                systemPrompt: "You are a connectivity-test echo. Respond with the model identifier you are, in exactly one word.",
                conversationHistory: [],
                userPrompt: "hi",
                onTextChunk: { _ in }
            )
            let trimmedResponseText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(String(trimmedResponseText.prefix(60)))
        } catch {
            return .failure(error)
        }
    }

    /// Stores the user-pasted API key for the active Direct-API provider
    /// and rebuilds the planner so the new key is picked up on the next
    /// turn. The key value is passed straight to `PaceKeychainStore` and
    /// is never persisted anywhere else.
    @discardableResult
    func saveDirectAPIKey(_ apiKey: String, for provider: PaceDirectAPIProvider) -> Bool {
        let didStore = PaceKeychainStore.storeAPIKey(apiKey, for: provider)
        if didStore {
            plannerClient = BuddyPlannerClientFactory.makeDefault()
        }
        return didStore
    }

    /// Removes the stored API key for the given provider and rebuilds the
    /// planner so the next turn either falls back to local (when no other
    /// key is present) or picks up a different stored provider.
    @discardableResult
    func deleteDirectAPIKey(for provider: PaceDirectAPIProvider) -> Bool {
        let didDelete = PaceKeychainStore.deleteAPIKey(for: provider)
        if didDelete {
            plannerClient = BuddyPlannerClientFactory.makeDefault()
        }
        return didDelete
    }

    /// Snapshot of which providers currently have an API key in Keychain.
    /// Settings UI calls this to show a green checkmark next to a saved
    /// provider.
    func providersWithStoredDirectAPIKeys() -> Set<PaceDirectAPIProvider> {
        return PaceKeychainStore.providersWithStoredKeys()
    }
}
