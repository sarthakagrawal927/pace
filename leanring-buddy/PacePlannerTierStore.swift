//
//  PacePlannerTierStore.swift
//  leanring-buddy
//
//  Pure state module for the user-facing planner tier picker. Mirrors
//  PaceCloudBridgeConsent's shape — UserDefaults under the
//  `pace.planner.tier.` prefix, no keychain access (that lives in
//  PaceKeychainStore), and no network or AppKit imports.
//
//  Default tier on first launch is `.local`, which matches Pace's
//  current LM Studio default. Existing users see zero behavior change.
//
//  See PRD: docs/prds/planner-tier-picker.md
//

import Foundation
import FoundationModels

// MARK: - PacePlannerTier

/// The four user-selectable backend tiers for Pace's main planner.
/// Each tier maps to exactly one BuddyPlannerClient conformer at request
/// time. Persona/system-prompt/tool-dialect are identical across tiers.
nonisolated enum PacePlannerTier: String, Equatable, Codable, CaseIterable {
    /// LM Studio at localhost:1234 — current default. Free, on-device.
    case local
    /// CloudBridgePlannerClient via the sibling local-ai Node bridge.
    /// Free if the user already has Claude Code / Codex / Gemini CLI auth.
    case cliBridge
    /// BYO key against an OpenAI-compatible cloud endpoint.
    /// User pastes their own API key; key lives in Keychain only.
    case directAPI
    /// Apple Foundation Models becomes the sole planner. Free, on-device.
    case appleFoundationModels
}

// MARK: - PaceDirectAPIProvider

/// The set of providers Pace ships as Direct-API presets. Each preset
/// hard-codes the OpenAI-compatible chat-completions endpoint URL and a
/// reasonable default model identifier. `.custom` lets the user paste
/// their own endpoint URL.
nonisolated enum PaceDirectAPIProvider: String, Equatable, Codable, CaseIterable {
    case anthropic
    case openai
    case openrouter
    case custom

    /// Human-readable label shown in Settings → Planner → Direct API picker.
    var displayLabel: String {
        switch self {
        case .anthropic:  return "Anthropic"
        case .openai:     return "OpenAI"
        case .openrouter: return "OpenRouter"
        case .custom:     return "Custom"
        }
    }

    /// OpenAI-compatible chat-completions endpoint URL for this provider.
    /// For `.custom` returns an empty string — the user must paste their own.
    var defaultEndpointURLString: String {
        switch self {
        case .anthropic:  return "https://api.anthropic.com/v1/chat/completions"
        case .openai:     return "https://api.openai.com/v1/chat/completions"
        case .openrouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .custom:     return ""
        }
    }

    /// Sensible default model identifier the user can override.
    var defaultModelIdentifier: String {
        switch self {
        case .anthropic:  return "claude-sonnet-4-5-20251001"
        case .openai:     return "gpt-4o-mini"
        case .openrouter: return "anthropic/claude-sonnet-4"
        case .custom:     return ""
        }
    }

    /// Anthropic uses native `x-api-key` + `anthropic-version`. Every
    /// other provider uses standard `Authorization: Bearer <key>`.
    var usesAnthropicAuthHeader: Bool {
        return self == .anthropic
    }

    /// Whether the provider requires `https://` (rejecting `http://` to
    /// non-loopback hosts). `.custom` opts into the loopback exception so
    /// developers can point at a local OpenAI-compatible proxy.
    var requiresHTTPS: Bool {
        return self != .custom
    }
}

// MARK: - PacePlannerTierConfiguration

/// Immutable snapshot of the tier picker preferences at one point in time.
nonisolated struct PacePlannerTierConfiguration: Equatable {
    let tier: PacePlannerTier
    let directAPIProvider: PaceDirectAPIProvider
    let directAPIModelIdentifier: String
    /// Used only when `directAPIProvider == .custom`. Empty otherwise.
    let directAPICustomEndpointURLString: String
    /// Opt-in: when true, a Direct-API failure (network / 401) silently
    /// retries the same turn against LM Studio. Default is OFF —
    /// failures surface verbatim so users know quota/auth issues happened.
    let fallsBackToLocalOnCloudFailure: Bool
}

// MARK: - UserDefaults keys

private enum PlannerTierUserDefaultsKey: String {
    case selectedTier                       = "pace.planner.tier.selectedTier"
    case directAPIProvider                  = "pace.planner.tier.directAPI.provider"
    case directAPIModelIdentifier           = "pace.planner.tier.directAPI.model"
    case directAPICustomEndpointURLString   = "pace.planner.tier.directAPI.customEndpointURL"
    case fallsBackToLocalOnCloudFailure     = "pace.planner.tier.directAPI.fallsBackToLocalOnFailure"
}

// MARK: - PacePlannerTierStore

enum PacePlannerTierStore {

    // MARK: First-launch detection

    /// True iff NONE of the planner tier UserDefaults keys are set. Used
    /// to decide whether the new Apple-FM-first default applies. Existing
    /// users — anyone who has ever opened Settings → Planner — already
    /// have at least the `selectedTier` key written, so this returns
    /// false and the new default is gated off behind it. Hard requirement
    /// from docs/prds/first-run-experience.md: existing users see zero
    /// behavior change.
    static func hasAnyPlannerTierUserDefaultsState() -> Bool {
        let plannerTierUserDefaultsKeys: [PlannerTierUserDefaultsKey] = [
            .selectedTier,
            .directAPIProvider,
            .directAPIModelIdentifier,
            .directAPICustomEndpointURLString,
            .fallsBackToLocalOnCloudFailure
        ]
        for plannerTierUserDefaultsKey in plannerTierUserDefaultsKeys {
            if UserDefaults.standard.object(forKey: plannerTierUserDefaultsKey.rawValue) != nil {
                return true
            }
        }
        return false
    }

    /// Pure function — given a snapshot of Apple Intelligence availability,
    /// returns the tier a brand-new install should default to. When
    /// Apple Intelligence is available, prefer Apple Foundation Models
    /// because it ships in-process with zero external dependency and the
    /// goal of the first-run experience PRD is "Pace works the moment
    /// you install it, no LM Studio needed". When Apple Intelligence is
    /// not available, fall back to `.local` so the existing Settings →
    /// Planner upgrade path (LM Studio install) is the next step the
    /// user sees.
    static func defaultTierForFirstLaunch(
        appleIntelligenceAvailable: Bool
    ) -> PacePlannerTier {
        return appleIntelligenceAvailable ? .appleFoundationModels : .local
    }

    /// Resolves Apple Intelligence availability via the same
    /// `SystemLanguageModel.default.availability` call
    /// `AppleFoundationModelsPlannerClient` uses. Cached per process so
    /// the answer stays stable across calls within a single Pace launch.
    /// Returns false on older macOS where FoundationModels isn't linked.
    private static var cachedAppleIntelligenceAvailable: Bool?

    static func isAppleIntelligenceAvailableOnThisDevice() -> Bool {
        if let cached = cachedAppleIntelligenceAvailable { return cached }
        let resolvedAvailable: Bool
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                resolvedAvailable = true
            case .unavailable:
                resolvedAvailable = false
            @unknown default:
                resolvedAvailable = false
            }
        } else {
            resolvedAvailable = false
        }
        cachedAppleIntelligenceAvailable = resolvedAvailable
        return resolvedAvailable
    }

    // MARK: Load

    /// Returns the current tier picker configuration. When the user has
    /// EVER touched the picker, the persisted tier wins and behavior
    /// stays byte-identical to today — that's the existing-user safety
    /// guarantee from docs/prds/first-run-experience.md.
    ///
    /// On a clean install (no planner-tier UserDefaults state at all),
    /// the default tier is now derived from Apple Intelligence
    /// availability via `defaultTierForFirstLaunch(...)`. Apple FM is
    /// preferred when available because it works with zero external
    /// install; otherwise the resolver falls back to `.local`.
    static func loadConfiguration() -> PacePlannerTierConfiguration {
        let firstLaunchFallbackTier: PacePlannerTier
        if hasAnyPlannerTierUserDefaultsState() {
            firstLaunchFallbackTier = .local
        } else {
            firstLaunchFallbackTier = defaultTierForFirstLaunch(
                appleIntelligenceAvailable: isAppleIntelligenceAvailableOnThisDevice()
            )
        }

        let rawSelectedTier = UserDefaults.standard.string(
            forKey: PlannerTierUserDefaultsKey.selectedTier.rawValue
        ) ?? firstLaunchFallbackTier.rawValue
        let resolvedTier = PacePlannerTier(rawValue: rawSelectedTier) ?? firstLaunchFallbackTier

        let rawDirectAPIProvider = UserDefaults.standard.string(
            forKey: PlannerTierUserDefaultsKey.directAPIProvider.rawValue
        ) ?? PaceDirectAPIProvider.anthropic.rawValue
        let resolvedDirectAPIProvider = PaceDirectAPIProvider(rawValue: rawDirectAPIProvider) ?? .anthropic

        let resolvedModelIdentifier = UserDefaults.standard.string(
            forKey: PlannerTierUserDefaultsKey.directAPIModelIdentifier.rawValue
        ) ?? resolvedDirectAPIProvider.defaultModelIdentifier

        let resolvedCustomEndpointURLString = UserDefaults.standard.string(
            forKey: PlannerTierUserDefaultsKey.directAPICustomEndpointURLString.rawValue
        ) ?? ""

        let resolvedFallsBackToLocalOnCloudFailure = UserDefaults.standard.bool(
            forKey: PlannerTierUserDefaultsKey.fallsBackToLocalOnCloudFailure.rawValue
        )

        return PacePlannerTierConfiguration(
            tier: resolvedTier,
            directAPIProvider: resolvedDirectAPIProvider,
            directAPIModelIdentifier: resolvedModelIdentifier,
            directAPICustomEndpointURLString: resolvedCustomEndpointURLString,
            fallsBackToLocalOnCloudFailure: resolvedFallsBackToLocalOnCloudFailure
        )
    }

    // MARK: Save

    static func saveTier(_ tier: PacePlannerTier) {
        UserDefaults.standard.set(
            tier.rawValue,
            forKey: PlannerTierUserDefaultsKey.selectedTier.rawValue
        )
    }

    static func saveDirectAPIProvider(_ provider: PaceDirectAPIProvider) {
        UserDefaults.standard.set(
            provider.rawValue,
            forKey: PlannerTierUserDefaultsKey.directAPIProvider.rawValue
        )
    }

    static func saveDirectAPIModelIdentifier(_ modelIdentifier: String) {
        UserDefaults.standard.set(
            modelIdentifier,
            forKey: PlannerTierUserDefaultsKey.directAPIModelIdentifier.rawValue
        )
    }

    static func saveDirectAPICustomEndpointURL(_ customEndpointURLString: String) {
        UserDefaults.standard.set(
            customEndpointURLString,
            forKey: PlannerTierUserDefaultsKey.directAPICustomEndpointURLString.rawValue
        )
    }

    static func saveFallsBackToLocalOnCloudFailure(_ enabled: Bool) {
        UserDefaults.standard.set(
            enabled,
            forKey: PlannerTierUserDefaultsKey.fallsBackToLocalOnCloudFailure.rawValue
        )
    }

    // MARK: Endpoint resolution

    /// Returns the endpoint URL string the Direct-API client should use,
    /// given the active provider and (for `.custom`) the user-pasted URL.
    /// Returns the provider's default for built-in providers — the user
    /// does not edit the URL except for `.custom`.
    static func resolvedDirectAPIEndpointURLString(
        for configuration: PacePlannerTierConfiguration
    ) -> String {
        switch configuration.directAPIProvider {
        case .anthropic, .openai, .openrouter:
            return configuration.directAPIProvider.defaultEndpointURLString
        case .custom:
            return configuration.directAPICustomEndpointURLString
        }
    }
}
