//
//  PaceIDEContextDetector.swift
//  leanring-buddy
//
//  Recognises when the user is in an IDE — Xcode, VS Code, Cursor,
//  Sublime, IntelliJ family — and extracts whatever code-context
//  signal we can read without LSP: the focused file's name (and
//  path when available), the IDE's display name, and a typed flag
//  so downstream surfaces can route "summarize this file" /
//  "rename this variable" / "what does this function do" turns
//  with the right prompt shape.
//
//  This is intentionally NOT a full LSP integration. Pace already
//  has rich screen context (VLM + OCR + AX). What's missing is the
//  one-line answer to "what file am I in?" — and macOS gives us
//  that via the IDE's window title without any Accessibility
//  Inspector spelunking. A real LSP-backed mode (semantic file
//  tree, type info, refactors) is a larger product surface and
//  belongs in a future "code mode" with its own settings tab.
//
//  Pure value-type helper — no AppKit imports, no AX calls. The
//  caller passes the frontmost bundle id + window title strings;
//  the detector returns a typed result. Easy to unit-test against
//  recorded window-title fixtures.
//

import Foundation

nonisolated enum PaceIDEKind: String, Equatable {
    case xcode
    case vsCode
    case cursor
    case sublimeText
    case intellijFamily
    case zed
    case nova
    case textMate
}

nonisolated struct PaceIDEContext: Equatable {
    let ideKind: PaceIDEKind
    let ideDisplayName: String
    /// The bare file name (e.g. "CompanionManager.swift"). Always set
    /// when the detector returns a context — if we can't read the file
    /// name we return `nil` from `detect`, never a context with an
    /// empty name.
    let focusedFileName: String
    /// The full absolute path when the window title carries enough
    /// signal to reconstruct it. Often `nil` for VS Code (which shows
    /// `filename — Folder` rather than the full path) but typically
    /// available for Xcode (which shows the workspace + file).
    let focusedFileAbsolutePath: String?
}

nonisolated enum PaceIDEContextDetector {

    /// Per-IDE bundle identifier set. The bundle id is the only
    /// stable signal — window-title format changes between versions
    /// but bundle ids don't.
    private static let bundleIdentifierToIDEKind: [String: PaceIDEKind] = [
        "com.apple.dt.Xcode": .xcode,
        "com.microsoft.VSCode": .vsCode,
        "com.visualstudio.code.oss": .vsCode,
        "com.todesktop.230313mzl4w4u92": .cursor, // Cursor (todesktop bundle)
        "com.cursor.cursor": .cursor,
        "com.sublimetext.4": .sublimeText,
        "com.sublimetext.3": .sublimeText,
        "com.jetbrains.intellij": .intellijFamily,
        "com.jetbrains.pycharm": .intellijFamily,
        "com.jetbrains.WebStorm": .intellijFamily,
        "com.jetbrains.GoLand": .intellijFamily,
        "com.jetbrains.AppCode": .intellijFamily,
        "com.jetbrains.CLion": .intellijFamily,
        "com.jetbrains.rider": .intellijFamily,
        "com.jetbrains.PhpStorm": .intellijFamily,
        "com.jetbrains.RubyMine": .intellijFamily,
        "com.jetbrains.intellij.ce": .intellijFamily,
        "dev.zed.Zed": .zed,
        "com.panic.Nova": .nova,
        "com.macromates.TextMate": .textMate,
    ]

    /// IDE display names. Used both for the planner-prompt label
    /// and for any UI surface that wants to render which IDE Pace
    /// detected.
    nonisolated private static func displayName(forKind kind: PaceIDEKind) -> String {
        switch kind {
        case .xcode:          return "Xcode"
        case .vsCode:         return "VS Code"
        case .cursor:         return "Cursor"
        case .sublimeText:    return "Sublime Text"
        case .intellijFamily: return "JetBrains IDE"
        case .zed:            return "Zed"
        case .nova:           return "Nova"
        case .textMate:       return "TextMate"
        }
    }

    /// Match the frontmost app to a known IDE kind. Returns nil for
    /// non-IDE apps so the caller can skip the file-name extraction.
    static func detectIDEKind(forBundleIdentifier bundleIdentifier: String?) -> PaceIDEKind? {
        guard let bundleIdentifier else { return nil }
        return bundleIdentifierToIDEKind[bundleIdentifier]
    }

    /// Full detection pass: bundle id + window title in, typed
    /// context out (or nil for non-IDE apps / unparseable titles).
    static func detect(
        frontmostBundleIdentifier: String?,
        frontmostWindowTitle: String?
    ) -> PaceIDEContext? {
        guard let ideKind = detectIDEKind(forBundleIdentifier: frontmostBundleIdentifier) else {
            return nil
        }
        guard let windowTitle = frontmostWindowTitle,
              let extracted = extractFocusedFile(
                fromWindowTitle: windowTitle,
                ideKind: ideKind
              ) else {
            return nil
        }
        return PaceIDEContext(
            ideKind: ideKind,
            ideDisplayName: displayName(forKind: ideKind),
            focusedFileName: extracted.fileName,
            focusedFileAbsolutePath: extracted.absolutePath
        )
    }

    /// Per-IDE window-title parsing. Returns the bare file name
    /// (always) plus an absolute path (when the title carries it).
    /// Format references gathered from current-version IDEs as of
    /// 2026 — if an IDE rev's title shape changes, only the matching
    /// case here needs updating.
    nonisolated static func extractFocusedFile(
        fromWindowTitle windowTitle: String,
        ideKind: PaceIDEKind
    ) -> (fileName: String, absolutePath: String?)? {
        let trimmedWindowTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWindowTitle.isEmpty else { return nil }

        switch ideKind {
        case .xcode:
            // Xcode title shapes:
            //   "leanring-buddy — CompanionManager.swift — Edited"
            //   "leanring-buddy — CompanionManager.swift"
            //   "CompanionManager.swift"
            // We split on em-dash, take the segment that looks like a
            // filename. Strip the trailing " — Edited" marker.
            let segments = trimmedWindowTitle
                .components(separatedBy: " — ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "Edited" }
            // Prefer the LAST segment with a file extension; Xcode
            // sometimes flips the order between workspace/file.
            if let segmentWithExtension = segments.last(where: { looksLikeFileName($0) }) {
                return (fileName: segmentWithExtension, absolutePath: nil)
            }
            return nil

        case .vsCode, .cursor:
            // VS Code / Cursor title shapes:
            //   "● CompanionManager.swift — Pace [WSL: ubuntu]"
            //   "CompanionManager.swift — Pace"
            //   "Untitled-1 — Visual Studio Code"
            // Leading "●" marks unsaved. Strip it and the IDE name
            // suffix.
            var workingTitle = trimmedWindowTitle
            if workingTitle.hasPrefix("● ") { workingTitle.removeFirst(2) }
            let firstSegment = workingTitle
                .components(separatedBy: " — ")
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard looksLikeFileName(firstSegment) else { return nil }
            return (fileName: firstSegment, absolutePath: nil)

        case .sublimeText:
            // Sublime title: "/abs/path/to/file.py — Project Name"
            //                "file.py (~/proj) - Sublime Text"
            // Try to pull an absolute path if present.
            let firstSegmentBeforeDash = trimmedWindowTitle
                .components(separatedBy: " — ")
                .first?
                .trimmingCharacters(in: .whitespaces) ?? trimmedWindowTitle
            // Absolute path: starts with "/" and ends with a known
            // file-name-shaped tail.
            if firstSegmentBeforeDash.hasPrefix("/") {
                let fileName = (firstSegmentBeforeDash as NSString).lastPathComponent
                guard looksLikeFileName(fileName) else { return nil }
                return (fileName: fileName, absolutePath: firstSegmentBeforeDash)
            }
            if looksLikeFileName(firstSegmentBeforeDash) {
                return (fileName: firstSegmentBeforeDash, absolutePath: nil)
            }
            return nil

        case .intellijFamily:
            // IntelliJ title shapes vary widely between versions.
            // Recent shape: "ProjectName – src/path/to/File.kt"
            // Older shape: "src/path/to/File.kt - ProjectName - IntelliJ IDEA"
            // We try both: find the segment that looks most like a
            // file path or filename.
            let candidates = trimmedWindowTitle
                .components(separatedBy: CharacterSet(charactersIn: " –-"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // Prefer one with a slash (path) and a file extension.
            if let pathCandidate = candidates.first(where: { $0.contains("/") && looksLikeFileName(($0 as NSString).lastPathComponent) }) {
                let fileName = (pathCandidate as NSString).lastPathComponent
                let absolutePath = pathCandidate.hasPrefix("/") ? pathCandidate : nil
                return (fileName: fileName, absolutePath: absolutePath)
            }
            if let fileNameCandidate = candidates.first(where: { looksLikeFileName($0) }) {
                return (fileName: fileNameCandidate, absolutePath: nil)
            }
            return nil

        case .zed:
            // Zed title: "file.rs — Project"
            let firstSegment = trimmedWindowTitle
                .components(separatedBy: " — ")
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard looksLikeFileName(firstSegment) else { return nil }
            return (fileName: firstSegment, absolutePath: nil)

        case .nova:
            // Nova title: "file.swift — Project"
            let firstSegment = trimmedWindowTitle
                .components(separatedBy: " — ")
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard looksLikeFileName(firstSegment) else { return nil }
            return (fileName: firstSegment, absolutePath: nil)

        case .textMate:
            // TextMate title: "file.rb — /abs/path"
            let parts = trimmedWindowTitle.components(separatedBy: " — ")
            guard let fileNamePart = parts.first?.trimmingCharacters(in: .whitespaces),
                  looksLikeFileName(fileNamePart) else { return nil }
            let absolutePath: String?
            if parts.count >= 2, parts[1].hasPrefix("/") {
                absolutePath = parts[1].trimmingCharacters(in: .whitespaces) + "/" + fileNamePart
            } else {
                absolutePath = nil
            }
            return (fileName: fileNamePart, absolutePath: absolutePath)
        }
    }

    /// Heuristic: a "file name" has a recognised extension and no
    /// embedded whitespace. Generous on extensions so a new language
    /// doesn't silently fail to match — anything 1-7 chars of ASCII
    /// letters/digits after the last dot counts.
    nonisolated static func looksLikeFileName(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, !candidate.contains(" ") else { return false }
        guard let lastDotIndex = candidate.lastIndex(of: ".") else { return false }
        let extensionStartIndex = candidate.index(after: lastDotIndex)
        let extensionTail = candidate[extensionStartIndex...]
        guard !extensionTail.isEmpty, extensionTail.count <= 7 else { return false }
        return extensionTail.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Render the detected context into the compact prompt-fragment
    /// the planner consumes. Three lines, intentionally terse —
    /// even on a giant codebase the planner shouldn't have to spend
    /// 100 tokens reading the IDE banner.
    static func renderForPlannerPrompt(_ ideContext: PaceIDEContext) -> String {
        var lines: [String] = [
            "ide: \(ideContext.ideDisplayName)",
            "focused file: \(ideContext.focusedFileName)",
        ]
        if let absolutePath = ideContext.focusedFileAbsolutePath {
            lines.append("focused path: \(absolutePath)")
        }
        return lines.joined(separator: "\n")
    }
}
