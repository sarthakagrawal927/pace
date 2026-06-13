//
//  PaceContactsRetrievalConnector.swift
//  leanring-buddy
//
//  Permission-aware read-only Contacts source for local retrieval.
//

import Contacts
import Foundation

struct PaceContactRetrievalSnapshot: Equatable {
    let stableIdentifier: String
    let displayName: String
    let nickname: String?
    let organizationName: String?
    let jobTitle: String?
    let emailAddresses: [String]

    init(
        stableIdentifier: String,
        displayName: String,
        nickname: String? = nil,
        organizationName: String? = nil,
        jobTitle: String? = nil,
        emailAddresses: [String] = []
    ) {
        self.stableIdentifier = stableIdentifier
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Unnamed contact"
            : displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.nickname = nickname
        self.organizationName = organizationName
        self.jobTitle = jobTitle
        self.emailAddresses = emailAddresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    init(contact: CNContact) {
        let fullName = CNContactFormatter.string(from: contact, style: .fullName)
        let fallbackName = [
            contact.givenName,
            contact.familyName,
            contact.organizationName,
            contact.nickname
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let displayName = fullName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? fullName!
            : fallbackName

        self.init(
            stableIdentifier: contact.identifier,
            displayName: displayName,
            nickname: contact.nickname,
            organizationName: contact.organizationName,
            jobTitle: contact.jobTitle,
            emailAddresses: contact.emailAddresses.map { String($0.value) }
        )
    }
}

struct PaceContactsRetrievalConnector {
    let contactStore: CNContactStore

    init(contactStore: CNContactStore = CNContactStore()) {
        self.contactStore = contactStore
    }

    func loadDocuments(
        maximumContactCount: Int = 500
    ) -> (documents: [PaceRetrievalDocument], status: PaceRetrievalSourceStatus) {
        let authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        guard Self.canReadContacts(authorizationStatus) else {
            return ([], Self.skippedStatus(for: authorizationStatus))
        }

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        let fetchRequest = CNContactFetchRequest(keysToFetch: keysToFetch)
        fetchRequest.sortOrder = .userDefault

        var snapshots: [PaceContactRetrievalSnapshot] = []
        do {
            try contactStore.enumerateContacts(with: fetchRequest) { contact, shouldStop in
                snapshots.append(PaceContactRetrievalSnapshot(contact: contact))
                if snapshots.count >= max(0, maximumContactCount) {
                    shouldStop.pointee = true
                }
            }
        } catch {
            return (
                [],
                .skipped(
                    source: .contacts,
                    displayName: PaceRetrievalSource.contacts.displayName,
                    reason: "Contacts read failed: \(error.localizedDescription)"
                )
            )
        }

        let documents = snapshots.map(Self.document(from:))
        return (
            documents,
            .enabled(
                source: .contacts,
                displayName: PaceRetrievalSource.contacts.displayName,
                documentCount: documents.count
            )
        )
    }

    nonisolated static func document(from contactSnapshot: PaceContactRetrievalSnapshot) -> PaceRetrievalDocument {
        var lines = ["Name: \(contactSnapshot.displayName)"]

        if let nickname = compactText(contactSnapshot.nickname, maximumCharacters: 120) {
            lines.append("Nickname: \(nickname)")
        }
        if let organizationName = compactText(contactSnapshot.organizationName, maximumCharacters: 160) {
            lines.append("Organization: \(organizationName)")
        }
        if let jobTitle = compactText(contactSnapshot.jobTitle, maximumCharacters: 160) {
            lines.append("Title: \(jobTitle)")
        }
        let uniqueEmailAddresses = Array(NSOrderedSet(array: contactSnapshot.emailAddresses)) as? [String] ?? contactSnapshot.emailAddresses
        if !uniqueEmailAddresses.isEmpty {
            lines.append("Email: \(uniqueEmailAddresses.prefix(3).joined(separator: ", "))")
        }

        return PaceRetrievalDocument(
            id: "contact-\(contactSnapshot.stableIdentifier)",
            source: .contacts,
            title: contactSnapshot.displayName,
            text: lines.joined(separator: "\n"),
            permissionScope: "contacts"
        )
    }

    static func skippedStatus(for authorizationStatus: CNAuthorizationStatus) -> PaceRetrievalSourceStatus {
        let reason: String
        switch authorizationStatus {
        case .notDetermined:
            reason = "Contacts permission has not been granted."
        case .denied:
            reason = "Contacts permission was denied."
        case .restricted:
            reason = "Contacts access is restricted on this Mac."
        case .authorized:
            reason = "Contacts retrieval is available."
        @unknown default:
            reason = "Contacts permission status is unknown."
        }

        return .skipped(
            source: .contacts,
            displayName: PaceRetrievalSource.contacts.displayName,
            reason: reason
        )
    }

    static func canReadContacts(_ authorizationStatus: CNAuthorizationStatus) -> Bool {
        switch authorizationStatus {
        case .authorized:
            return true
        case .notDetermined, .restricted, .denied:
            return false
        @unknown default:
            return false
        }
    }

    nonisolated private static func compactText(_ text: String?, maximumCharacters: Int) -> String? {
        guard let text else { return nil }
        let compactedText = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compactedText.isEmpty else { return nil }
        guard compactedText.count > maximumCharacters else { return compactedText }

        let endIndex = compactedText.index(
            compactedText.startIndex,
            offsetBy: maximumCharacters,
            limitedBy: compactedText.endIndex
        ) ?? compactedText.endIndex
        return String(compactedText[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
