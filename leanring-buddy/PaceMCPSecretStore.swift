//
//  PaceMCPSecretStore.swift
//  leanring-buddy
//
//  Keychain wrapper for MCP-server environment-variable secrets (e.g.,
//  Composio's `COMPOSIO_API_KEY`). Sibling to `PaceKeychainStore`, but
//  scoped to the MCP-server surface area so the two threat models stay
//  cleanly separated:
//
//    - `PaceKeychainStore` holds Pace's PLANNER API keys (Anthropic,
//      OpenAI, OpenRouter, custom). One key authorizes one model.
//    - `PaceMCPSecretStore` holds secrets for spawned MCP-server
//      subprocesses (Composio's API key authorizes hundreds of tools;
//      a Slack token authorizes write access to a workspace; etc.).
//
//  Account naming is composable per `(server-slug, env-key)` so a single
//  server can carry multiple secrets (e.g., a future server that needs
//  both an API key and a workspace ID).
//
//  Storage rules (same as PaceKeychainStore):
//    - `kSecAttrSynchronizable = false` — never syncs via iCloud Keychain.
//    - `kSecAttrAccessible = kSecAttrAccessibleWhenUnlocked` — secrets
//      unavailable while the Mac is locked. MCP servers can't fire then
//      anyway because the user can't be talking to Pace.
//    - Service identifier is Pace-scoped so revoking these secrets
//      never touches the user's other apps.
//    - The returned secret string is held in-process only. Callers must
//      NEVER write it to disk, plist, log, or audit-log entry.
//

import Foundation
import Security

enum PaceMCPSecretStore {

    /// Pace-scoped service identifier. Distinct from
    /// `PaceKeychainStore.serviceIdentifier` so the two stores can be
    /// inspected, revoked, and migrated independently.
    static let serviceIdentifier = "com.pace.app.mcpServerSecrets"

    /// Composable account name: one Keychain entry per
    /// `(server-slug, env-key)` pair. Lets a single server (e.g.,
    /// "slack") have several secrets (e.g., `SLACK_BOT_TOKEN`,
    /// `SLACK_APP_TOKEN`) without collision.
    static func keychainAccountName(server serverSlug: String, key envKey: String) -> String {
        let normalizedServerSlug = serverSlug
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedEnvKey = envKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "mcp.\(normalizedServerSlug).\(normalizedEnvKey)"
    }

    /// Stores `secret` for `(server, key)`. Overwrites in place via
    /// `SecItemUpdate` when an entry already exists, otherwise adds
    /// via `SecItemAdd`. Returns true on success; false on any
    /// Keychain error. Status codes are logged but the secret value
    /// itself is NEVER logged.
    @discardableResult
    static func storeSecret(
        _ secret: String,
        server serverSlug: String,
        key envKey: String
    ) -> Bool {
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecret.isEmpty else { return false }
        guard let secretData = trimmedSecret.data(using: .utf8) else { return false }

        let accountName = keychainAccountName(server: serverSlug, key: envKey)

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: accountName
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: secretData
        ]

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            updateAttributes as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            print("⚠️ PaceMCPSecretStore.storeSecret: SecItemUpdate failed status=\(updateStatus) account=\(accountName)")
            return false
        }

        var addItemAttributes: [String: Any] = baseQuery
        addItemAttributes[kSecValueData as String] = secretData
        addItemAttributes[kSecAttrSynchronizable as String] = kCFBooleanFalse
        addItemAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let addStatus = SecItemAdd(addItemAttributes as CFDictionary, nil)
        if addStatus != errSecSuccess {
            print("⚠️ PaceMCPSecretStore.storeSecret: SecItemAdd failed status=\(addStatus) account=\(accountName)")
            return false
        }
        return true
    }

    /// Returns the stored secret, or nil if none is set. Callers must
    /// keep the returned string in-process only — never write it to
    /// disk, plist, log, or audit-log entry. This function does NOT
    /// log the returned value under any condition.
    static func loadSecret(
        server serverSlug: String,
        key envKey: String
    ) -> String? {
        let accountName = keychainAccountName(server: serverSlug, key: envKey)

        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var retrievedItemReference: AnyObject?
        let lookupStatus = SecItemCopyMatching(lookupQuery as CFDictionary, &retrievedItemReference)

        guard lookupStatus == errSecSuccess else {
            if lookupStatus != errSecItemNotFound {
                print("⚠️ PaceMCPSecretStore.loadSecret: SecItemCopyMatching status=\(lookupStatus) account=\(accountName)")
            }
            return nil
        }

        guard let retrievedSecretData = retrievedItemReference as? Data,
              let recoveredSecret = String(data: retrievedSecretData, encoding: .utf8) else {
            return nil
        }
        return recoveredSecret
    }

    /// Removes the stored secret. Returns true on success OR if no
    /// entry existed (idempotent delete). Returns false only on a
    /// genuine Keychain error.
    @discardableResult
    static func deleteSecret(
        server serverSlug: String,
        key envKey: String
    ) -> Bool {
        let accountName = keychainAccountName(server: serverSlug, key: envKey)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: accountName
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        if deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound {
            return true
        }
        print("⚠️ PaceMCPSecretStore.deleteSecret: SecItemDelete status=\(deleteStatus) account=\(accountName)")
        return false
    }

    /// Returns true when a secret exists for `(server, key)` without
    /// reading the value. Used by Settings UI to render "Key in
    /// Keychain: yes/no" without holding the secret in a SwiftUI
    /// `@State`.
    static func hasSecret(
        server serverSlug: String,
        key envKey: String
    ) -> Bool {
        let accountName = keychainAccountName(server: serverSlug, key: envKey)
        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: accountName,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let lookupStatus = SecItemCopyMatching(lookupQuery as CFDictionary, nil)
        return lookupStatus == errSecSuccess
    }
}
