//
//  PaceUserPreferencesStore.swift
//  leanring-buddy
//
//  Typed key namespace + load/save helpers for user-toggleable
//  preferences. Replaces three hand-rolled `UserDefaults
//  .object(forKey:) == nil ? default : bool(forKey:)` patterns scattered
//  across `CompanionManager` — each with its own stringly-typed key.
//
//  The `@Published` properties stay on `CompanionManager` so the
//  existing SwiftUI bindings keep working. This store owns only the
//  storage-layer concern: key strings, defaults, and (for one
//  preference) the Info.plist seed on first launch.
//
//  Adding a new boolean preference is two lines: add a case to
//  `PaceUserPreferenceKey`, and decide its default by calling either
//  `bool(_:default:)` or `boolWithInfoPlistSeed(_:infoPlistKey:)`.
//

import Foundation

enum PaceUserPreferenceKey: String {
    case useLocalVLMForScreenContext
    case isWalkingAvatarEnabled
    case isPaceCursorEnabled
    case areCursorAnnotationsEnabled
    case requiresActionApproval
    case isPostureWatchEnabled
}

enum PaceUserPreferencesStore {
    /// Read a boolean preference. Returns `defaultValue` if the key has
    /// never been written.
    static func bool(_ key: PaceUserPreferenceKey, default defaultValue: Bool) -> Bool {
        guard let stored = UserDefaults.standard.object(forKey: key.rawValue) as? Bool else {
            return defaultValue
        }
        return stored
    }

    /// Read a boolean preference, falling back to an Info.plist string
    /// value if the user has never touched the toggle. Used for one-off
    /// "seed from build config on first launch" cases.
    static func boolWithInfoPlistSeed(
        _ key: PaceUserPreferenceKey,
        infoPlistKey: String
    ) -> Bool {
        if let stored = UserDefaults.standard.object(forKey: key.rawValue) as? Bool {
            return stored
        }
        let infoPlistRawValue = AppBundleConfiguration
            .stringValue(forKey: infoPlistKey)?
            .lowercased()
        return infoPlistRawValue == "true"
            || infoPlistRawValue == "1"
            || infoPlistRawValue == "yes"
    }

    static func setBool(_ value: Bool, for key: PaceUserPreferenceKey) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }
}
