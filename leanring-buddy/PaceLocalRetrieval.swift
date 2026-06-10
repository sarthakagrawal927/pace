//
//  PaceLocalRetrieval.swift
//  leanring-buddy
//
//  Local-only retrieval scaffold. This is the lexical fallback and data
//  contract for Pace's future embedding-backed RAG layer.
//

import Foundation

enum PaceRetrievalSource: String, CaseIterable, Codable, Equatable {
    case file
    case mail
    case notes
    case calendar
    case reminders
    case contacts
    case competitiveResearch
    case paceHistory
    case screenWatchHistory
    case appUsageHistory
    case localPreference

    var displayName: String {
        switch self {
        case .file:
            return "File"
        case .mail:
            return "Mail"
        case .notes:
            return "Notes"
        case .calendar:
            return "Calendar"
        case .reminders:
            return "Reminders"
        case .contacts:
            return "Contacts"
        case .competitiveResearch:
            return "Competitive research"
        case .paceHistory:
            return "Pace history"
        case .screenWatchHistory:
            return "Screen watch journal"
        case .appUsageHistory:
            return "App usage journal"
        case .localPreference:
            return "Preference"
        }
    }
}

struct PaceRetrievalDocument: Codable, Equatable {
    let id: String
    let source: PaceRetrievalSource
    let title: String
    let text: String
    let localURL: URL?
    let modifiedAt: Date?
    let permissionScope: String?

    init(
        id: String,
        source: PaceRetrievalSource,
        title: String,
        text: String,
        localURL: URL? = nil,
        modifiedAt: Date? = nil,
        permissionScope: String? = nil
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.text = text
        self.localURL = localURL
        self.modifiedAt = modifiedAt
        self.permissionScope = permissionScope
    }
}

struct PaceRetrievalQuery: Equatable {
    let text: String
    let maximumResultCount: Int
    let maximumSnippetCharacters: Int

    init(
        text: String,
        maximumResultCount: Int = 4,
        maximumSnippetCharacters: Int = 220
    ) {
        self.text = text
        self.maximumResultCount = maximumResultCount
        self.maximumSnippetCharacters = maximumSnippetCharacters
    }
}

struct PaceRetrievalMatch: Equatable {
    let documentId: String
    let chunkId: String
    let source: PaceRetrievalSource
    let title: String
    let excerpt: String
    let localURL: URL?
    let modifiedAt: Date?
    let score: Double
}

struct PaceRetrievalSourceStatus: Equatable {
    let source: PaceRetrievalSource
    let displayName: String
    let isEnabled: Bool
    let documentCount: Int
    let lastError: String?

    static func enabled(
        source: PaceRetrievalSource,
        displayName: String,
        documentCount: Int
    ) -> PaceRetrievalSourceStatus {
        PaceRetrievalSourceStatus(
            source: source,
            displayName: displayName,
            isEnabled: true,
            documentCount: documentCount,
            lastError: nil
        )
    }

    static func skipped(
        source: PaceRetrievalSource,
        displayName: String,
        reason: String
    ) -> PaceRetrievalSourceStatus {
        PaceRetrievalSourceStatus(
            source: source,
            displayName: displayName,
            isEnabled: false,
            documentCount: 0,
            lastError: reason
        )
    }
}

protocol PaceRetrievalStore: AnyObject {
    func reset()
    func upsertDocuments(_ documents: [PaceRetrievalDocument])
    func documents(withSource source: PaceRetrievalSource) -> [PaceRetrievalDocument]
    func removeDocuments(withSource source: PaceRetrievalSource)
    func updateSourceStatus(_ status: PaceRetrievalSourceStatus)
    func setSourceEnabled(_ isEnabled: Bool, for source: PaceRetrievalSource)
    func isSourceEnabled(_ source: PaceRetrievalSource) -> Bool
    func search(_ query: PaceRetrievalQuery) -> [PaceRetrievalMatch]
    var sourceStatuses: [PaceRetrievalSourceStatus] { get }
}

protocol PaceRetriever: AnyObject {
    func localContextBlock(for query: PaceRetrievalQuery) -> String?
}

enum PaceRetrievalSourcePreferences {
    private static let keyPrefix = "PaceRetrievalSourceEnabled."

    static func isEnabled(_ source: PaceRetrievalSource) -> Bool {
        let key = key(for: source)
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setEnabled(_ isEnabled: Bool, for source: PaceRetrievalSource) {
        UserDefaults.standard.set(isEnabled, forKey: key(for: source))
    }

    private static func key(for source: PaceRetrievalSource) -> String {
        keyPrefix + source.rawValue
    }
}

enum PaceLocalRetrievalFileRootPreferences {
    static let userDefaultsKey = "PaceLocalRetrievalFileRootPaths"
    static let infoPlistKey = "LocalRetrievalFileRootPaths"

    static func userSelectedRootURLs(userDefaults: UserDefaults = .standard) -> [URL] {
        normalizedRootURLs(
            from: userDefaults.stringArray(forKey: userDefaultsKey) ?? []
        )
    }

    static func configuredRootURLs(
        userDefaults: UserDefaults = .standard,
        infoPlistConfigurationString: String? = AppBundleConfiguration.stringValue(forKey: infoPlistKey)
    ) -> [URL] {
        normalizedRootURLs(
            from: rootPaths(for: userSelectedRootURLs(userDefaults: userDefaults))
                + fileRootPaths(fromConfigurationString: infoPlistConfigurationString ?? "")
        )
    }

    static func saveUserSelectedRootURLs(
        _ rootURLs: [URL],
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(rootPaths(for: rootURLs), forKey: userDefaultsKey)
    }

    static func mergedRootURLs(
        existingRootURLs: [URL],
        addingRootURLs newRootURLs: [URL]
    ) -> [URL] {
        normalizedRootURLs(from: rootPaths(for: existingRootURLs + newRootURLs))
    }

    static func rootPaths(for rootURLs: [URL]) -> [String] {
        normalizedRootURLs(from: rootURLs.map(\.path)).map(\.path)
    }

    static func fileRootPaths(fromConfigurationString configurationString: String) -> [String] {
        configurationString
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedRootURLs(from rootPaths: [String]) -> [URL] {
        var seenPaths = Set<String>()
        return rootPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { NSString(string: $0).expandingTildeInPath }
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .filter { rootURL in
                seenPaths.insert(rootURL.path).inserted
            }
    }
}

enum PaceSecretPathExclusionPolicy {
    private static let excludedFileNames: Set<String> = [
        ".env",
        ".env.local",
        ".env.production",
        ".netrc",
        "id_rsa",
        "id_dsa",
        "id_ecdsa",
        "id_ed25519",
        "known_hosts",
        "credentials",
        "credentials.json",
        "kubeconfig",
        "config"
    ]

    private static let excludedPathComponents: Set<String> = [
        ".aws",
        ".azure",
        ".config/gcloud",
        ".gnupg",
        ".kube",
        ".ssh",
        "secrets",
        "private",
        "credentials",
        "node_modules",
        ".git",
        "DerivedData"
    ]

    private static let excludedExtensions: Set<String> = [
        "key",
        "pem",
        "p12",
        "pfx",
        "mobileprovision"
    ]

    static func shouldExclude(localURL: URL) -> Bool {
        shouldExclude(path: localURL.path)
    }

    static func shouldExclude(path: String) -> Bool {
        let standardizedPath = NSString(string: path).standardizingPath
        let pathComponents = standardizedPath
            .split(separator: "/")
            .map { String($0).lowercased() }
        let lowercasePath = standardizedPath.lowercased()
        let fileName = pathComponents.last ?? ""
        let fileExtension = (fileName as NSString).pathExtension.lowercased()

        if excludedFileNames.contains(fileName) {
            return true
        }
        if excludedExtensions.contains(fileExtension) {
            return true
        }
        if pathComponents.contains(where: { excludedPathComponents.contains($0) }) {
            return true
        }
        if lowercasePath.contains("/.config/gcloud/") {
            return true
        }
        if lowercasePath.contains("secret") || lowercasePath.contains("credential") {
            return true
        }

        return false
    }
}

enum PaceRetrievalContextPolicy {
    private static let localSourceTerms: [String] = [
        "calendar", "contact", "contacts", "deck", "document", "documents",
        "email", "emails", "event", "events", "file", "files", "folder",
        "folders", "mail", "meeting", "meetings", "message", "messages",
        "note", "notes", "reminder", "reminders"
    ]

    private static let offscreenReferencePhrases: [String] = [
        "according to my", "based on my", "from earlier", "from my",
        "from that", "from the latest", "from yesterday", "i edited",
        "i was editing", "latest", "last email", "last message", "last note",
        "previous", "recent", "said about", "that email", "that note",
        "did i use", "earlier today", "my time", "this morning", "using my",
        "we discussed", "what apps", "what did", "what have i been",
        "what was", "where is", "which apps", "yesterday"
    ]

    private static let localPreferencePhrases: [String] = [
        "default reminder list", "preferred browser", "preferred notes",
        "use my browser", "use my default", "use my preferred"
    ]

    static func shouldQueryLocalContext(
        forTranscript transcript: String,
        route: PaceIntentRoute
    ) -> Bool {
        let normalizedTranscript = normalize(transcript)
        guard !normalizedTranscript.isEmpty else { return false }

        switch route {
        case .chitchatFastPath, .phoneLargeModel:
            return false
        case .answerDirectly, .executeTool, .fullPipeline:
            return containsOffscreenContextReference(normalizedTranscript)
        case .readScreen:
            return containsExplicitComparisonToLocalContext(normalizedTranscript)
        }
    }

    private static func containsOffscreenContextReference(_ normalizedTranscript: String) -> Bool {
        if localPreferencePhrases.contains(where: { normalizedTranscript.contains($0) }) {
            return true
        }
        if offscreenReferencePhrases.contains(where: { normalizedTranscript.contains($0) }) {
            return true
        }
        return localSourceTerms.contains { sourceTerm in
            normalizedTranscript.contains("my \(sourceTerm)")
                || normalizedTranscript.contains("the \(sourceTerm)")
                || normalizedTranscript.contains("latest \(sourceTerm)")
                || normalizedTranscript.contains("recent \(sourceTerm)")
                || normalizedTranscript.contains("search \(sourceTerm)")
                || normalizedTranscript.contains("search my \(sourceTerm)")
        }
    }

    private static func containsExplicitComparisonToLocalContext(_ normalizedTranscript: String) -> Bool {
        normalizedTranscript.contains("compared to my")
            || normalizedTranscript.contains("compare this to")
            || normalizedTranscript.contains("according to my")
            || normalizedTranscript.contains("against my")
    }

    private static func normalize(_ transcript: String) -> String {
        transcript
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class PaceInMemoryRetrievalStore: PaceRetrievalStore {
    private struct PersistedState: Codable {
        let schemaVersion: Int
        let documents: [PaceRetrievalDocument]
    }

    private struct StoredChunk {
        let id: String
        let document: PaceRetrievalDocument
        let text: String
        let tokenSet: Set<String>
        let tokenCounts: [String: Int]
        let tokenCount: Int
    }

    private var documentsById: [String: PaceRetrievalDocument] = [:]
    private var chunksByDocumentId: [String: [StoredChunk]] = [:]
    private var statusesBySource: [PaceRetrievalSource: PaceRetrievalSourceStatus] = [:]
    private var disabledSources: Set<PaceRetrievalSource> = []
    private let persistenceURL: URL?

    init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        loadPersistedDocumentsIfAvailable()
    }

    var sourceStatuses: [PaceRetrievalSourceStatus] {
        statusesBySource.values.sorted { $0.source.rawValue < $1.source.rawValue }
    }

    func reset() {
        documentsById.removeAll()
        chunksByDocumentId.removeAll()
        statusesBySource.removeAll()
        for disabledSource in disabledSources {
            statusesBySource[disabledSource] = Self.disabledStatus(for: disabledSource)
        }
        persistDocuments()
    }

    func upsertDocuments(_ documents: [PaceRetrievalDocument]) {
        let safeDocuments = documents.filter { document in
            guard let localURL = document.localURL else { return true }
            return !PaceSecretPathExclusionPolicy.shouldExclude(localURL: localURL)
        }

        for document in safeDocuments {
            documentsById[document.id] = document
            chunksByDocumentId[document.id] = Self.makeChunks(for: document)
        }

        refreshSourceStatuses()
        persistDocuments()
    }

    func documents(withSource source: PaceRetrievalSource) -> [PaceRetrievalDocument] {
        documentsById.values.filter { $0.source == source }
    }

    func removeDocuments(withSource source: PaceRetrievalSource) {
        let documentIdsForSource = documentsById.values
            .filter { $0.source == source }
            .map(\.id)

        for documentId in documentIdsForSource {
            documentsById.removeValue(forKey: documentId)
            chunksByDocumentId.removeValue(forKey: documentId)
        }

        refreshSourceStatuses()
        persistDocuments()
    }

    func updateSourceStatus(_ status: PaceRetrievalSourceStatus) {
        guard !disabledSources.contains(status.source) else {
            statusesBySource[status.source] = Self.disabledStatus(for: status.source)
            return
        }
        statusesBySource[status.source] = status
    }

    func setSourceEnabled(_ isEnabled: Bool, for source: PaceRetrievalSource) {
        if isEnabled {
            disabledSources.remove(source)
        } else {
            disabledSources.insert(source)
        }
        refreshSourceStatuses()
        if !isEnabled {
            let documentCount = documentsById.values.filter { $0.source == source }.count
            statusesBySource[source] = Self.disabledStatus(
                for: source,
                documentCount: documentCount
            )
        }
    }

    func isSourceEnabled(_ source: PaceRetrievalSource) -> Bool {
        !disabledSources.contains(source)
    }

    func search(_ query: PaceRetrievalQuery) -> [PaceRetrievalMatch] {
        let queryTokens = Self.tokenize(query.text)
        guard !queryTokens.isEmpty else { return [] }

        let queryTokenSet = Set(queryTokens)
        let normalizedQuery = queryTokens.joined(separator: " ")
        let allChunks = chunksByDocumentId.values
            .flatMap { $0 }
            .filter { !disabledSources.contains($0.document.source) }
        let documentFrequencyByToken = Self.documentFrequencyByToken(
            for: allChunks,
            queryTokens: queryTokenSet
        )
        let averageChunkTokenCount = Self.averageChunkTokenCount(for: allChunks)

        let scoredMatches = allChunks.compactMap { chunk -> PaceRetrievalMatch? in
            let sharedTokens = queryTokenSet.intersection(chunk.tokenSet)
            guard !sharedTokens.isEmpty else { return nil }

            var score = 0.0
            for token in sharedTokens {
                score += Self.bm25Score(
                    termFrequency: chunk.tokenCounts[token] ?? 0,
                    chunkTokenCount: chunk.tokenCount,
                    averageChunkTokenCount: averageChunkTokenCount,
                    totalChunkCount: allChunks.count,
                    documentFrequency: documentFrequencyByToken[token] ?? 0
                )
                if Self.tokenize(chunk.document.title).contains(token) {
                    score += 3.0
                }
            }

            let normalizedChunkText = Self.tokenize(chunk.text).joined(separator: " ")
            if !normalizedQuery.isEmpty, normalizedChunkText.contains(normalizedQuery) {
                score += 6.0
            }

            guard score > 0 else { return nil }
            return PaceRetrievalMatch(
                documentId: chunk.document.id,
                chunkId: chunk.id,
                source: chunk.document.source,
                title: chunk.document.title,
                excerpt: Self.snippet(
                    from: chunk.text,
                    queryTokens: queryTokens,
                    maximumCharacters: query.maximumSnippetCharacters
                ),
                localURL: chunk.document.localURL,
                modifiedAt: chunk.document.modifiedAt,
                score: score
            )
        }

        return scoredMatches
            .sorted {
                if $0.score == $1.score {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return $0.score > $1.score
            }
            .prefix(max(1, query.maximumResultCount))
            .map { $0 }
    }

    static func makeDocumentChunksForTesting(_ document: PaceRetrievalDocument) -> [String] {
        makeChunks(for: document).map(\.text)
    }

    private static func makeChunks(for document: PaceRetrievalDocument) -> [StoredChunk] {
        let normalizedText = document.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return [] }

        let maximumChunkCharacters = 900
        let overlapCharacters = 120
        var chunks: [StoredChunk] = []
        var chunkStartIndex = normalizedText.startIndex
        var chunkNumber = 0

        while chunkStartIndex < normalizedText.endIndex {
            let preferredEndIndex = normalizedText.index(
                chunkStartIndex,
                offsetBy: maximumChunkCharacters,
                limitedBy: normalizedText.endIndex
            ) ?? normalizedText.endIndex
            let chunkEndIndex = nearestWordBoundary(
                in: normalizedText,
                from: preferredEndIndex,
                lowerBound: chunkStartIndex
            )
            let chunkText = String(normalizedText[chunkStartIndex..<chunkEndIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !chunkText.isEmpty {
                let tokens = tokenize(chunkText + " " + document.title)
                chunks.append(
                    StoredChunk(
                        id: "\(document.id)#\(chunkNumber)",
                        document: document,
                        text: chunkText,
                        tokenSet: Set(tokens),
                        tokenCounts: Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +),
                        tokenCount: tokens.count
                    )
                )
                chunkNumber += 1
            }

            guard chunkEndIndex < normalizedText.endIndex else { break }
            let nextStartIndex = normalizedText.index(
                chunkEndIndex,
                offsetBy: -overlapCharacters,
                limitedBy: normalizedText.startIndex
            ) ?? chunkEndIndex
            chunkStartIndex = nearestWordBoundary(
                in: normalizedText,
                from: nextStartIndex,
                lowerBound: normalizedText.startIndex
            )
            if chunkStartIndex <= normalizedText.startIndex, chunkNumber > 0 {
                chunkStartIndex = chunkEndIndex
            }
        }

        return chunks
    }

    private static func nearestWordBoundary(
        in text: String,
        from proposedIndex: String.Index,
        lowerBound: String.Index
    ) -> String.Index {
        guard proposedIndex < text.endIndex else { return text.endIndex }
        var candidateIndex = proposedIndex
        while candidateIndex > lowerBound {
            if text[candidateIndex].isWhitespace || text[candidateIndex].isNewline {
                return candidateIndex
            }
            candidateIndex = text.index(before: candidateIndex)
        }
        return proposedIndex
    }

    private static func documentFrequencyByToken(
        for chunks: [StoredChunk],
        queryTokens: Set<String>
    ) -> [String: Int] {
        var documentFrequencyByToken: [String: Int] = [:]
        for chunk in chunks {
            for token in queryTokens where chunk.tokenSet.contains(token) {
                documentFrequencyByToken[token, default: 0] += 1
            }
        }
        return documentFrequencyByToken
    }

    private static func averageChunkTokenCount(for chunks: [StoredChunk]) -> Double {
        guard !chunks.isEmpty else { return 1 }
        let totalTokenCount = chunks.reduce(0) { partialResult, chunk in
            partialResult + chunk.tokenCount
        }
        return max(1, Double(totalTokenCount) / Double(chunks.count))
    }

    private static func bm25Score(
        termFrequency: Int,
        chunkTokenCount: Int,
        averageChunkTokenCount: Double,
        totalChunkCount: Int,
        documentFrequency: Int
    ) -> Double {
        guard termFrequency > 0, totalChunkCount > 0, documentFrequency > 0 else {
            return 0
        }

        let k1 = 1.2
        let b = 0.75
        let inverseDocumentFrequency = log(
            1 + (Double(totalChunkCount - documentFrequency) + 0.5) / (Double(documentFrequency) + 0.5)
        )
        let normalizedChunkLength = Double(chunkTokenCount) / max(1, averageChunkTokenCount)
        let saturationDenominator = Double(termFrequency) + k1 * (1 - b + b * normalizedChunkLength)

        return inverseDocumentFrequency * (Double(termFrequency) * (k1 + 1)) / saturationDenominator
    }

    private static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in
                token.count >= 2 && !stopWords.contains(token)
            }
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from",
        "how", "i", "in", "is", "it", "me", "my", "of", "on", "or", "the",
        "this", "to", "what", "when", "where", "with", "you"
    ]

    private static func snippet(
        from text: String,
        queryTokens: [String],
        maximumCharacters: Int
    ) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.count > maximumCharacters else { return trimmedText }

        let firstMatchRange = queryTokens.compactMap { token in
            trimmedText.range(of: token, options: [.caseInsensitive, .diacriticInsensitive])
        }.min { firstRange, secondRange in
            firstRange.lowerBound < secondRange.lowerBound
        }

        let matchStartIndex = firstMatchRange?.lowerBound ?? trimmedText.startIndex
        let halfWindow = max(20, maximumCharacters / 2)
        let snippetStartIndex = trimmedText.index(
            matchStartIndex,
            offsetBy: -halfWindow,
            limitedBy: trimmedText.startIndex
        ) ?? trimmedText.startIndex
        let snippetEndIndex = trimmedText.index(
            snippetStartIndex,
            offsetBy: maximumCharacters,
            limitedBy: trimmedText.endIndex
        ) ?? trimmedText.endIndex

        var snippetText = String(trimmedText[snippetStartIndex..<snippetEndIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if snippetStartIndex > trimmedText.startIndex {
            snippetText = "..." + snippetText
        }
        if snippetEndIndex < trimmedText.endIndex {
            snippetText += "..."
        }
        return snippetText
    }

    private func refreshSourceStatuses() {
        let documentCountsBySource = Dictionary(
            grouping: documentsById.values,
            by: \.source
        ).mapValues(\.count)

        for (source, documentCount) in documentCountsBySource {
            if disabledSources.contains(source) {
                statusesBySource[source] = Self.disabledStatus(
                    for: source,
                    documentCount: documentCount
                )
                continue
            }
            statusesBySource[source] = .enabled(
                source: source,
                displayName: source.displayName,
                documentCount: documentCount
            )
        }

        for source in statusesBySource.keys where documentCountsBySource[source] == nil {
            if disabledSources.contains(source) {
                statusesBySource[source] = Self.disabledStatus(for: source)
                continue
            }
            if statusesBySource[source]?.isEnabled == false {
                continue
            }
            statusesBySource[source] = .enabled(
                source: source,
                displayName: source.displayName,
                documentCount: 0
            )
        }
    }

    private static func disabledStatus(
        for source: PaceRetrievalSource,
        documentCount: Int = 0
    ) -> PaceRetrievalSourceStatus {
        PaceRetrievalSourceStatus(
            source: source,
            displayName: source.displayName,
            isEnabled: false,
            documentCount: documentCount,
            lastError: "Disabled by user."
        )
    }

    private func loadPersistedDocumentsIfAvailable() {
        guard let persistenceURL,
              let data = try? Data(contentsOf: persistenceURL),
              let persistedState = try? JSONDecoder().decode(PersistedState.self, from: data),
              persistedState.schemaVersion == 1 else {
            return
        }

        let safeDocuments = persistedState.documents.filter { document in
            guard let localURL = document.localURL else { return true }
            return !PaceSecretPathExclusionPolicy.shouldExclude(localURL: localURL)
        }

        for document in safeDocuments {
            documentsById[document.id] = document
            chunksByDocumentId[document.id] = Self.makeChunks(for: document)
        }
        refreshSourceStatuses()
    }

    private func persistDocuments() {
        guard let persistenceURL else { return }

        do {
            let directoryURL = persistenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let persistedState = PersistedState(
                schemaVersion: 1,
                documents: documentsById.values.sorted { firstDocument, secondDocument in
                    firstDocument.id < secondDocument.id
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(persistedState)
            try data.write(to: persistenceURL, options: [.atomic])
        } catch {
            print("⚠️ Local retrieval persistence failed: \(error.localizedDescription)")
        }
    }
}

final class PaceLocalRetriever: PaceRetriever {
    private let store: PaceRetrievalStore
    private let maximumContextCharacters: Int
    private let embeddingClient: PaceTextEmbedding
    private(set) var lastQueryDurationMilliseconds: Int?
    private var screenWatchJournal: PaceScreenWatchJournal?

    init(
        store: PaceRetrievalStore? = nil,
        maximumContextCharacters: Int = 900,
        appliesPersistedSourcePreferences: Bool = true,
        embeddingClient: PaceTextEmbedding? = nil
    ) {
        self.store = store ?? PaceInMemoryRetrievalStore(
            persistenceURL: Self.defaultPersistenceURL()
        )
        self.maximumContextCharacters = maximumContextCharacters
        // Short timeout: re-ranking sits on the turn path, so a cold or
        // missing embedding model must degrade to lexical order quickly.
        self.embeddingClient = embeddingClient
            ?? LMStudioEmbeddingClient(requestTimeoutInSeconds: 2)
        if appliesPersistedSourcePreferences {
            applyPersistedSourcePreferences()
        }
        refreshPreferenceDocuments()
        refreshCompetitiveResearchDocuments()
    }

    var sourceStatuses: [PaceRetrievalSourceStatus] {
        store.sourceStatuses
    }

    func upsertDocuments(_ documents: [PaceRetrievalDocument]) {
        store.upsertDocuments(documents)
    }

    func setSourceEnabled(_ isEnabled: Bool, for source: PaceRetrievalSource) {
        PaceRetrievalSourcePreferences.setEnabled(isEnabled, for: source)
        store.setSourceEnabled(isEnabled, for: source)
    }

    func isSourceEnabled(_ source: PaceRetrievalSource) -> Bool {
        store.isSourceEnabled(source)
    }

    func replaceDocuments(
        _ documents: [PaceRetrievalDocument],
        forSource source: PaceRetrievalSource,
        status: PaceRetrievalSourceStatus? = nil
    ) {
        store.removeDocuments(withSource: source)
        store.upsertDocuments(documents)
        if let status {
            store.updateSourceStatus(status)
        }
    }

    func clearDocuments(forSource source: PaceRetrievalSource) {
        store.removeDocuments(withSource: source)
        lastQueryDurationMilliseconds = nil
    }

    func resetIndex(preservePreferences: Bool = true) {
        store.reset()
        applyPersistedSourcePreferences()
        if preservePreferences {
            refreshPreferenceDocuments()
            refreshCompetitiveResearchDocuments()
        }
        lastQueryDurationMilliseconds = nil
    }

    func refreshPreferenceDocuments() {
        store.removeDocuments(withSource: .localPreference)
        store.upsertDocuments(Self.preferenceDocuments())
    }

    func refreshCompetitiveResearchDocuments() {
        store.removeDocuments(withSource: .competitiveResearch)
        store.upsertDocuments(PaceCompetitiveResearchSeeds.documents)
    }

    /// Journals a watch-mode screen event so "what did I do today?" style
    /// questions can be answered from local history. Recording is free of
    /// model calls — the screen description, when present, comes from the
    /// caller's already-cached analysis.
    func recordScreenWatchObservation(
        screenLabel: String,
        categoryDisplayName: String,
        frontmostApplicationName: String?,
        screenDescription: String?,
        now: Date = Date()
    ) {
        guard isSourceEnabled(.screenWatchHistory) else { return }
        var journal = screenWatchJournal ?? rehydratedScreenWatchJournal(now: now)
        let changedDocument = journal.record(PaceScreenWatchJournalEntry(
            recordedAt: now,
            screenLabel: screenLabel,
            categoryDisplayName: categoryDisplayName,
            frontmostApplicationName: frontmostApplicationName,
            screenDescription: screenDescription
        ))
        screenWatchJournal = journal
        if let changedDocument {
            store.upsertDocuments([changedDocument])
        }
    }

    /// Rebuilds the in-memory journal from persisted documents on the first
    /// event after launch — without this, the first post-restart event would
    /// upsert a same-id day bucket and clobber the earlier history. Also the
    /// single point where the retention window is enforced.
    private func rehydratedScreenWatchJournal(now: Date) -> PaceScreenWatchJournal {
        var journal = PaceScreenWatchJournal(
            rehydratingFrom: store.documents(withSource: .screenWatchHistory),
            now: now
        )
        replaceDocuments(journal.allDocuments(now: now), forSource: .screenWatchHistory)
        return journal
    }

    /// Rebuilds the app-usage journal from persisted documents and enforces
    /// its retention window. Called once when the tracker starts.
    func rehydratedAppUsageJournal(now: Date = Date()) -> PaceAppUsageJournal {
        var journal = PaceAppUsageJournal(
            rehydratingFrom: store.documents(withSource: .appUsageHistory),
            now: now
        )
        replaceDocuments(journal.allDocuments(now: now), forSource: .appUsageHistory)
        return journal
    }

    func recordAppUsageDocument(_ document: PaceRetrievalDocument) {
        guard isSourceEnabled(.appUsageHistory) else { return }
        store.upsertDocuments([document])
    }

    func recordPaceHistory(
        userTranscript: String,
        assistantResponse: String,
        now: Date = Date()
    ) {
        let trimmedTranscript = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResponse = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty, !trimmedResponse.isEmpty else { return }

        let document = PaceRetrievalDocument(
            id: "pace-history-\(Int(now.timeIntervalSince1970))-\(abs(trimmedTranscript.hashValue))",
            source: .paceHistory,
            title: "Recent Pace turn",
            text: "User: \(trimmedTranscript)\nPace: \(trimmedResponse)",
            modifiedAt: now,
            permissionScope: "pace-history"
        )
        store.upsertDocuments([document])
    }

    func localContextBlock(for query: PaceRetrievalQuery) -> String? {
        let retrievalStartedAt = Date()
        let matches = selectMatches(
            from: lexicalCandidateMatches(for: query),
            limit: query.maximumResultCount
        )
        return composeContextBlock(from: matches, startedAt: retrievalStartedAt)
    }

    /// Async variant that re-ranks the lexical candidate pool by embedding
    /// similarity (local /v1/embeddings) before source-diverse selection.
    /// Best-effort: endpoint down, model missing, or timeout falls back to
    /// the plain lexical order — never worse than `localContextBlock`.
    func rerankedLocalContextBlock(for query: PaceRetrievalQuery) async -> String? {
        let retrievalStartedAt = Date()
        let candidateMatches = lexicalCandidateMatches(for: query)
        guard !candidateMatches.isEmpty else {
            return composeContextBlock(from: [], startedAt: retrievalStartedAt)
        }
        let rerankedMatches = await PaceEmbeddingReranker.rerank(
            queryText: query.text,
            matches: candidateMatches,
            embedder: embeddingClient
        )
        let matches = selectMatches(from: rerankedMatches, limit: query.maximumResultCount)
        return composeContextBlock(from: matches, startedAt: retrievalStartedAt)
    }

    /// Wider-than-requested lexical candidate pool so re-ranking and source
    /// diversity have something to work with.
    private func lexicalCandidateMatches(for query: PaceRetrievalQuery) -> [PaceRetrievalMatch] {
        let candidatePoolQuery = PaceRetrievalQuery(
            text: query.text,
            maximumResultCount: query.maximumResultCount * 3,
            maximumSnippetCharacters: query.maximumSnippetCharacters
        )
        return store.search(candidatePoolQuery)
    }

    /// Source-diverse selection: best match per source first, remaining
    /// slots filled in order. Without this, one chatty source can
    /// monopolize the block — e.g. recent Pace turns that echo the user's
    /// exact question outrank the journal/data documents that actually hold
    /// the answer, and the planner ends up parroting its own previous reply.
    private func selectMatches(
        from candidateMatches: [PaceRetrievalMatch],
        limit: Int
    ) -> [PaceRetrievalMatch] {
        var diverseMatches: [PaceRetrievalMatch] = []
        var overflowMatches: [PaceRetrievalMatch] = []
        var seenSources: Set<PaceRetrievalSource> = []
        for candidateMatch in candidateMatches {
            if seenSources.insert(candidateMatch.source).inserted {
                diverseMatches.append(candidateMatch)
            } else {
                overflowMatches.append(candidateMatch)
            }
        }
        return Array((diverseMatches + overflowMatches).prefix(limit))
    }

    private func composeContextBlock(
        from matches: [PaceRetrievalMatch],
        startedAt retrievalStartedAt: Date
    ) -> String? {
        let retrievalDurationMilliseconds = Int(Date().timeIntervalSince(retrievalStartedAt) * 1000)
        lastQueryDurationMilliseconds = retrievalDurationMilliseconds
        let sourceCount = Set(matches.map(\.source)).count
        PaceTelemetryLog.recordRetrievalLatency(
            milliseconds: retrievalDurationMilliseconds,
            resultCount: matches.count,
            sourceCount: sourceCount
        )
        print("🔎 Local retrieval: \(matches.count) match(es) in \(retrievalDurationMilliseconds)ms")
        guard !matches.isEmpty else { return nil }

        var lines = ["LOCAL CONTEXT"]
        var characterCount = lines[0].count

        for (index, match) in matches.enumerated() {
            let line = "\(index + 1). \(match.source.displayName): \(match.title): \"\(match.excerpt)\""
            guard characterCount + line.count + 1 <= maximumContextCharacters else { break }
            lines.append(line)
            characterCount += line.count + 1
        }

        guard lines.count > 1 else { return nil }
        return lines.joined(separator: "\n")
    }

    private static func preferenceDocuments() -> [PaceRetrievalDocument] {
        let preferencePairs: [(String, String?)] = [
            ("Preferred browser", PaceLocalMemoryStore.string(for: .preferredBrowser)),
            ("Preferred notes app", PaceLocalMemoryStore.string(for: .preferredNotesApp)),
            ("Default reminder list", PaceLocalMemoryStore.string(for: .defaultReminderList)),
        ]

        return preferencePairs.compactMap { title, value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return PaceRetrievalDocument(
                id: "preference-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
                source: .localPreference,
                title: title,
                text: "\(title): \(value)",
                permissionScope: "user-defaults"
            )
        }
    }

    private func applyPersistedSourcePreferences() {
        for source in PaceRetrievalSource.allCases {
            store.setSourceEnabled(
                PaceRetrievalSourcePreferences.isEnabled(source),
                for: source
            )
        }
    }

    private static func defaultPersistenceURL() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("retrieval-index.json")
    }
}

struct PaceFileRetrievalConnector {
    let rootURLs: [URL]
    let fileManager: FileManager
    let allowedPathExtensions: Set<String>

    init(
        rootURLs: [URL],
        fileManager: FileManager = .default,
        allowedPathExtensions: Set<String> = ["txt", "md", "markdown", "json"]
    ) {
        self.rootURLs = rootURLs
        self.fileManager = fileManager
        self.allowedPathExtensions = allowedPathExtensions
    }

    func loadDocuments(
        maximumDocumentCount: Int = 200,
        maximumBytesPerFile: Int = 64_000
    ) -> (documents: [PaceRetrievalDocument], statuses: [PaceRetrievalSourceStatus]) {
        guard !rootURLs.isEmpty else {
            return (
                [],
                [.skipped(source: .file, displayName: PaceRetrievalSource.file.displayName, reason: "No file roots configured.")]
            )
        }

        var documents: [PaceRetrievalDocument] = []
        var statuses: [PaceRetrievalSourceStatus] = []

        for rootURL in rootURLs {
            guard !PaceSecretPathExclusionPolicy.shouldExclude(localURL: rootURL) else {
                statuses.append(.skipped(source: .file, displayName: rootURL.lastPathComponent, reason: "Excluded sensitive path."))
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
                statuses.append(.skipped(source: .file, displayName: rootURL.lastPathComponent, reason: "Path does not exist."))
                continue
            }

            if isDirectory.boolValue {
                documents.append(
                    contentsOf: loadDocumentsInDirectory(
                        rootURL,
                        remainingLimit: max(0, maximumDocumentCount - documents.count),
                        maximumBytesPerFile: maximumBytesPerFile
                    )
                )
            } else if let document = loadSingleFile(rootURL, maximumBytesPerFile: maximumBytesPerFile) {
                documents.append(document)
            }

            statuses.append(.enabled(source: .file, displayName: rootURL.lastPathComponent, documentCount: documents.count))
            if documents.count >= maximumDocumentCount {
                break
            }
        }

        return (Array(documents.prefix(maximumDocumentCount)), statuses)
    }

    private func loadDocumentsInDirectory(
        _ rootURL: URL,
        remainingLimit: Int,
        maximumBytesPerFile: Int
    ) -> [PaceRetrievalDocument] {
        guard remainingLimit > 0 else { return [] }
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return []
        }

        var documents: [PaceRetrievalDocument] = []
        for case let fileURL as URL in enumerator {
            if PaceSecretPathExclusionPolicy.shouldExclude(localURL: fileURL) {
                enumerator.skipDescendants()
                continue
            }
            guard let document = loadSingleFile(fileURL, maximumBytesPerFile: maximumBytesPerFile) else {
                continue
            }
            documents.append(document)
            if documents.count >= remainingLimit {
                break
            }
        }
        return documents
    }

    private func loadSingleFile(
        _ fileURL: URL,
        maximumBytesPerFile: Int
    ) -> PaceRetrievalDocument? {
        guard !PaceSecretPathExclusionPolicy.shouldExclude(localURL: fileURL) else { return nil }
        guard allowedPathExtensions.contains(fileURL.pathExtension.lowercased()) else { return nil }

        let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
        guard resourceValues?.isRegularFile == true else { return nil }
        if let fileSize = resourceValues?.fileSize, fileSize > maximumBytesPerFile {
            return nil
        }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return PaceRetrievalDocument(
            id: "file-\(fileURL.path)",
            source: .file,
            title: fileURL.lastPathComponent,
            text: text,
            localURL: fileURL,
            modifiedAt: resourceValues?.contentModificationDate,
            permissionScope: "file-root"
        )
    }
}
