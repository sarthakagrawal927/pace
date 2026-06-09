//
//  PaceSpotlightRetrievalConnector.swift
//  leanring-buddy
//
//  Spotlight-backed file discovery for local retrieval. It is intentionally
//  scoped to explicit user-approved roots; Pace never starts a broad home-disk
//  crawl from this connector.
//

import Foundation

struct PaceSpotlightRetrievalRequest {
    let rootURLs: [URL]
    let allowedPathExtensions: Set<String>
    let maximumCandidateCount: Int
    let timeoutSeconds: TimeInterval
}

struct PaceSpotlightRetrievalConnector {
    let rootURLs: [URL]
    let fileManager: FileManager
    let allowedPathExtensions: Set<String>
    let candidateURLProvider: ((PaceSpotlightRetrievalRequest) -> [URL])?

    init(
        rootURLs: [URL],
        fileManager: FileManager = .default,
        allowedPathExtensions: Set<String> = ["txt", "md", "markdown", "json"],
        candidateURLProvider: ((PaceSpotlightRetrievalRequest) -> [URL])? = nil
    ) {
        self.rootURLs = rootURLs
        self.fileManager = fileManager
        self.allowedPathExtensions = allowedPathExtensions
        self.candidateURLProvider = candidateURLProvider
    }

    func loadDocuments(
        maximumDocumentCount: Int = 200,
        maximumBytesPerFile: Int = 64_000,
        timeoutSeconds: TimeInterval = 1.0
    ) -> (documents: [PaceRetrievalDocument], status: PaceRetrievalSourceStatus) {
        let safeRootURLs = rootURLs.filter { rootURL in
            guard !PaceSecretPathExclusionPolicy.shouldExclude(localURL: rootURL) else {
                return false
            }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }

        guard !safeRootURLs.isEmpty else {
            return (
                [],
                .skipped(
                    source: .file,
                    displayName: PaceRetrievalSource.file.displayName,
                    reason: "No safe Spotlight roots configured."
                )
            )
        }

        let candidateURLs = uniqueFileURLs(
            (candidateURLProvider ?? Self.discoverCandidateURLs)(
                PaceSpotlightRetrievalRequest(
                    rootURLs: safeRootURLs,
                    allowedPathExtensions: allowedPathExtensions,
                    maximumCandidateCount: maximumDocumentCount * 4,
                    timeoutSeconds: timeoutSeconds
                )
            )
        )
        .filter { candidateURL in
            isCandidateURL(candidateURL, insideAnyRoot: safeRootURLs)
        }

        let documents = loadDocuments(
            fromCandidateURLs: candidateURLs,
            maximumDocumentCount: maximumDocumentCount,
            maximumBytesPerFile: maximumBytesPerFile
        )

        return (
            documents,
            .enabled(
                source: .file,
                displayName: PaceRetrievalSource.file.displayName,
                documentCount: documents.count
            )
        )
    }

    static func fileNamePredicate(allowedPathExtensions: Set<String>) -> NSPredicate {
        let sortedExtensions = allowedPathExtensions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
        guard !sortedExtensions.isEmpty else {
            return NSPredicate(value: false)
        }

        let extensionPredicates = sortedExtensions.map { pathExtension in
            NSPredicate(
                format: "%K LIKE[cd] %@",
                NSMetadataItemFSNameKey,
                "*.\(pathExtension)"
            )
        }
        return NSCompoundPredicate(orPredicateWithSubpredicates: extensionPredicates)
    }

    private static func discoverCandidateURLs(
        request: PaceSpotlightRetrievalRequest
    ) -> [URL] {
        let query = NSMetadataQuery()
        query.searchScopes = request.rootURLs
        query.predicate = fileNamePredicate(
            allowedPathExtensions: request.allowedPathExtensions
        )

        let semaphore = DispatchSemaphore(value: 0)
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: nil
        ) { _ in
            query.disableUpdates()
            query.stop()
            semaphore.signal()
        }

        guard query.start() else {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            return []
        }

        _ = semaphore.wait(timeout: .now() + request.timeoutSeconds)
        query.disableUpdates()
        query.stop()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }

        return query.results
            .prefix(request.maximumCandidateCount)
            .compactMap { result in
                guard let metadataItem = result as? NSMetadataItem,
                      let path = metadataItem.value(forAttribute: NSMetadataItemPathKey) as? String else {
                    return nil
                }
                return URL(fileURLWithPath: path)
            }
    }

    private func loadDocuments(
        fromCandidateURLs candidateURLs: [URL],
        maximumDocumentCount: Int,
        maximumBytesPerFile: Int
    ) -> [PaceRetrievalDocument] {
        var documents: [PaceRetrievalDocument] = []
        for candidateURL in candidateURLs {
            guard documents.count < maximumDocumentCount else { break }
            let connector = PaceFileRetrievalConnector(
                rootURLs: [candidateURL],
                fileManager: fileManager,
                allowedPathExtensions: allowedPathExtensions
            )
            let result = connector.loadDocuments(
                maximumDocumentCount: 1,
                maximumBytesPerFile: maximumBytesPerFile
            )
            documents.append(contentsOf: result.documents)
        }
        return documents
    }

    private func uniqueFileURLs(_ fileURLs: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        var uniqueURLs: [URL] = []
        for fileURL in fileURLs {
            let standardizedPath = fileURL.standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else { continue }
            uniqueURLs.append(fileURL.standardizedFileURL)
        }
        return uniqueURLs
    }

    private func isCandidateURL(_ candidateURL: URL, insideAnyRoot rootURLs: [URL]) -> Bool {
        guard !PaceSecretPathExclusionPolicy.shouldExclude(localURL: candidateURL),
              allowedPathExtensions.contains(candidateURL.pathExtension.lowercased()) else {
            return false
        }

        let candidatePath = candidateURL.standardizedFileURL.path
        return rootURLs.contains { rootURL in
            let rootPath = rootURL.standardizedFileURL.path
            return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
        }
    }
}
