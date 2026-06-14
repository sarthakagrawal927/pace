//
//  PaceBrowserURLReader.swift
//  leanring-buddy
//
//  Reads the frontmost browser's active-tab URL via AppleScript, for the
//  "remember this site" feature. Returns nil for non-browsers or browsers
//  without a scriptable URL (e.g. Firefox), so the caller can ask the user
//  instead of guessing. The first read of a given browser triggers a
//  one-time macOS Automation permission prompt for that browser.
//
//  Captures ONLY the current URL, ONLY on an explicit "remember this"
//  command — no passive browsing capture.
//

import AppKit
import Foundation

@MainActor
enum PaceBrowserURLReader {
    struct CapturedTab: Equatable {
        let url: String
        let browserName: String
    }

    /// Chromium-family browsers expose "active tab of front window"; Safari
    /// uses "current tab". Keyed by bundle id so we target the exact frontmost
    /// app rather than guessing by name.
    private static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "company.thebrowser.Browser" // Arc
    ]
    private static let safariBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview"
    ]

    static func currentTab() -> CapturedTab? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else {
            return nil
        }
        let browserName = frontApp.localizedName ?? "your browser"

        let scriptSource: String
        if safariBundleIDs.contains(bundleID) {
            scriptSource = "tell application id \"\(bundleID)\" to return URL of current tab of front window"
        } else if chromiumBundleIDs.contains(bundleID) {
            scriptSource = "tell application id \"\(bundleID)\" to return URL of active tab of front window"
        } else {
            // Not a scriptable browser in front (Firefox, a non-browser app, etc.)
            return nil
        }

        guard let script = NSAppleScript(source: scriptSource) else { return nil }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil,
              let url = descriptor.stringValue,
              url.hasPrefix("http") else {
            return nil
        }
        return CapturedTab(url: url, browserName: browserName)
    }

    /// A friendly default name derived from a URL host when the user didn't
    /// give one ("dash.cloudflare.com" → "Cloudflare"). Strips "www." and the
    /// TLD, capitalizes the main label.
    static func defaultName(forURL urlString: String) -> String {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return "this page" }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let labels = normalizedHost.split(separator: ".")
        guard labels.count >= 2 else { return normalizedHost }
        // For "dash.cloudflare.com" the registrable label is the second-to-last.
        let mainLabel = String(labels[labels.count - 2])
        return mainLabel.prefix(1).uppercased() + mainLabel.dropFirst()
    }
}
