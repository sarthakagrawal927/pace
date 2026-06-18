//
//  PaceIDEContextDetectorTests.swift
//  leanring-buddyTests
//
//  Window-title parsing is brittle by nature — each IDE's format
//  changes across versions and configurations. These tests pin
//  current-version expectations so a regression shows up at build
//  time, not when a user asks "what file am I looking at" and
//  Pace can't answer.
//

import Foundation
import Testing
@testable import Pace

struct PaceIDEContextDetectorTests {

    // MARK: - bundle id → IDE kind

    @Test func xcodeBundleIdentifierIsRecognised() async throws {
        #expect(PaceIDEContextDetector.detectIDEKind(forBundleIdentifier: "com.apple.dt.Xcode") == .xcode)
    }

    @Test func vscodeBundleIdentifierIsRecognised() async throws {
        #expect(PaceIDEContextDetector.detectIDEKind(forBundleIdentifier: "com.microsoft.VSCode") == .vsCode)
    }

    @Test func cursorBundleIdentifiersAreRecognised() async throws {
        // Cursor ships under two bundle ids depending on signing.
        #expect(PaceIDEContextDetector.detectIDEKind(forBundleIdentifier: "com.cursor.cursor") == .cursor)
        #expect(PaceIDEContextDetector.detectIDEKind(forBundleIdentifier: "com.todesktop.230313mzl4w4u92") == .cursor)
    }

    @Test func intellijFamilyBundleIdentifiersAreRecognised() async throws {
        let kinds = [
            "com.jetbrains.intellij",
            "com.jetbrains.pycharm",
            "com.jetbrains.WebStorm",
            "com.jetbrains.GoLand",
        ].map { PaceIDEContextDetector.detectIDEKind(forBundleIdentifier: $0) }
        #expect(kinds.allSatisfy { $0 == .intellijFamily })
    }

    @Test func nonIDEBundleIdentifiersReturnNil() async throws {
        #expect(PaceIDEContextDetector.detectIDEKind(forBundleIdentifier: "com.apple.Safari") == nil)
        #expect(PaceIDEContextDetector.detectIDEKind(forBundleIdentifier: "com.apple.Notes") == nil)
        #expect(PaceIDEContextDetector.detectIDEKind(forBundleIdentifier: nil) == nil)
    }

    // MARK: - file-name heuristic

    @Test func filenameHeuristicAcceptsCommonExtensions() async throws {
        let positives = ["main.swift", "utils.ts", "App.tsx", "page.astro", "Cargo.toml", "README.md"]
        for filename in positives {
            #expect(PaceIDEContextDetector.looksLikeFileName(filename) == true, "Expected \(filename) to look like a filename")
        }
    }

    @Test func filenameHeuristicRejectsNonFileLikeStrings() async throws {
        let negatives = [
            "Untitled",                          // no extension
            "Project Name",                      // whitespace
            "src/main",                          // no extension
            "trailing.dot.",                     // empty extension
            "file.SUPERLONGEXTNAME",             // extension > 7 chars
            "",                                  // empty
        ]
        for nonFile in negatives {
            #expect(PaceIDEContextDetector.looksLikeFileName(nonFile) == false, "Expected \(nonFile) NOT to look like a filename")
        }
    }

    // MARK: - per-IDE window title parsing

    @Test func xcodeTitleWithProjectAndFileExtractsFileName() async throws {
        let context = PaceIDEContextDetector.detect(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            frontmostWindowTitle: "leanring-buddy — CompanionManager.swift — Edited"
        )
        #expect(context?.focusedFileName == "CompanionManager.swift")
        #expect(context?.ideKind == .xcode)
        #expect(context?.ideDisplayName == "Xcode")
    }

    @Test func vscodeTitleWithUnsavedMarkerStripsTheBullet() async throws {
        let context = PaceIDEContextDetector.detect(
            frontmostBundleIdentifier: "com.microsoft.VSCode",
            frontmostWindowTitle: "● CompanionManager.swift — Pace"
        )
        #expect(context?.focusedFileName == "CompanionManager.swift")
        #expect(context?.ideKind == .vsCode)
    }

    @Test func sublimeTitleWithAbsolutePathExtractsBothFilenameAndPath() async throws {
        let context = PaceIDEContextDetector.detect(
            frontmostBundleIdentifier: "com.sublimetext.4",
            frontmostWindowTitle: "/Users/me/repo/app.py — repo"
        )
        #expect(context?.focusedFileName == "app.py")
        #expect(context?.focusedFileAbsolutePath == "/Users/me/repo/app.py")
    }

    @Test func intellijTitleWithPathSegmentExtractsFilename() async throws {
        let context = PaceIDEContextDetector.detect(
            frontmostBundleIdentifier: "com.jetbrains.intellij",
            frontmostWindowTitle: "MyProject – src/main/java/com/example/Service.kt"
        )
        #expect(context?.focusedFileName == "Service.kt")
    }

    @Test func zedTitleParsesAsFilenameDashProject() async throws {
        let context = PaceIDEContextDetector.detect(
            frontmostBundleIdentifier: "dev.zed.Zed",
            frontmostWindowTitle: "lib.rs — my-crate"
        )
        #expect(context?.focusedFileName == "lib.rs")
        #expect(context?.ideKind == .zed)
    }

    @Test func nonIDEAppReturnsNilContext() async throws {
        let context = PaceIDEContextDetector.detect(
            frontmostBundleIdentifier: "com.apple.Safari",
            frontmostWindowTitle: "Hacker News"
        )
        #expect(context == nil)
    }

    @Test func unparseableTitleReturnsNilEvenForKnownIDE() async throws {
        // Empty title, no file information to extract — we should
        // return nil rather than fabricate a fake filename.
        let context = PaceIDEContextDetector.detect(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            frontmostWindowTitle: ""
        )
        #expect(context == nil)
    }

    // MARK: - planner prompt rendering

    @Test func plannerPromptRenderIncludesIDEAndFileName() async throws {
        let context = PaceIDEContext(
            ideKind: .xcode,
            ideDisplayName: "Xcode",
            focusedFileName: "CompanionManager.swift",
            focusedFileAbsolutePath: nil
        )
        let rendered = PaceIDEContextDetector.renderForPlannerPrompt(context)
        #expect(rendered.contains("Xcode"))
        #expect(rendered.contains("CompanionManager.swift"))
        #expect(!rendered.contains("focused path:"))
    }

    @Test func plannerPromptIncludesAbsolutePathWhenAvailable() async throws {
        let context = PaceIDEContext(
            ideKind: .sublimeText,
            ideDisplayName: "Sublime Text",
            focusedFileName: "app.py",
            focusedFileAbsolutePath: "/Users/me/repo/app.py"
        )
        let rendered = PaceIDEContextDetector.renderForPlannerPrompt(context)
        #expect(rendered.contains("/Users/me/repo/app.py"))
    }
}
