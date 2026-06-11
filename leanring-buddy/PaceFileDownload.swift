//
//  PaceFileDownload.swift
//  leanring-buddy
//
//  Request type and pure helpers for the download_file tool — Pace's one
//  intentional network touch. Downloads are user-commanded, fetch only the
//  user-named URL into ~/Downloads, and send nothing; everything else in
//  the product stays loopback-only.
//

import Foundation

nonisolated struct PaceFileDownloadRequest: Equatable {
    let url: URL
    let suggestedFilename: String?
}

nonisolated enum PaceFileDownloadURLValidator {
    /// Only plain http(s) URLs with a real remote host are downloadable.
    /// Credentials in the URL are refused — they are a phishing-shaped
    /// pattern a planner should never need.
    static func validatedDownloadURL(from rawURLString: String) -> URL? {
        let trimmedURLString = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURLString.isEmpty, let url = URL(string: trimmedURLString) else { return nil }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        guard url.user == nil, url.password == nil else { return nil }
        return url
    }
}

nonisolated enum PaceDownloadFilenameSanitizer {
    static let fallbackFilename = "pace-download"

    /// Produces a safe bare filename for ~/Downloads: path separators and
    /// traversal sequences are stripped so a hostile suggested name can
    /// never escape the downloads folder.
    static func sanitizedFilename(
        suggestedFilename: String?,
        downloadURL: URL
    ) -> String {
        let candidates = [
            suggestedFilename,
            downloadURL.lastPathComponent.isEmpty ? nil : downloadURL.lastPathComponent
        ]
        for candidate in candidates {
            guard let candidate else { continue }
            let sanitized = sanitize(candidate)
            if !sanitized.isEmpty {
                return sanitized
            }
        }
        return fallbackFilename
    }

    /// Appends " 2", " 3", … before the extension until the name does not
    /// collide with an existing file, mirroring Finder's behavior.
    static func collisionFreeFilename(
        _ filename: String,
        existingFilenames: Set<String>
    ) -> String {
        guard existingFilenames.contains(filename) else { return filename }
        let filenameAsURL = URL(fileURLWithPath: filename)
        let fileExtension = filenameAsURL.pathExtension
        let baseName = filenameAsURL.deletingPathExtension().lastPathComponent
        var suffixNumber = 2
        while true {
            let candidate = fileExtension.isEmpty
                ? "\(baseName) \(suffixNumber)"
                : "\(baseName) \(suffixNumber).\(fileExtension)"
            if !existingFilenames.contains(candidate) {
                return candidate
            }
            suffixNumber += 1
        }
    }

    private static func sanitize(_ rawFilename: String) -> String {
        // A suggested name that looks like a path reduces to its final
        // component, so traversal segments can never reach the filesystem.
        let finalPathComponent = URL(fileURLWithPath: rawFilename).lastPathComponent
        var sanitized = finalPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while sanitized.contains("..") {
            sanitized = sanitized.replacingOccurrences(of: "..", with: ".")
        }
        while sanitized.hasPrefix(".") {
            sanitized.removeFirst()
        }
        if sanitized.count > 255 {
            sanitized = String(sanitized.prefix(255))
        }
        return sanitized
    }
}
