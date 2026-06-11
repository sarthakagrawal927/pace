//
//  PaceDeepLinkParser.swift
//  leanring-buddy
//
//  Pure parser for the pace:// URL scheme — the external entry surface
//  that gives Raycast, Shortcuts, and other local apps a way to trigger
//  Pace. Kept isolation-free so every parse rule is unit-testable
//  without the AppKit delegate machinery.
//
//  Supported commands:
//    pace://listen                       start a push-to-talk session
//    pace://chat?text=<percent-encoded>  send text straight into the planner pipeline
//    pace://watch?enabled=true|false     toggle watch mode
//    pace://panel                        show the companion panel
//

import Foundation

nonisolated enum PaceDeepLinkCommand: Equatable {
    case startListening
    case sendChatMessage(text: String)
    case setWatchMode(enabled: Bool)
    case showPanel
}

nonisolated enum PaceDeepLinkParser {
    /// Deeplinks are an external input surface — any local app can open a
    /// pace:// URL — so chat text is hard-capped before it reaches the
    /// planner. Over-cap text is rejected rather than truncated, because
    /// truncation could silently change the meaning of a command.
    static let maximumChatTextCharacterCount = 500

    static func parse(_ url: URL) -> PaceDeepLinkCommand? {
        guard url.scheme?.lowercased() == "pace" else { return nil }
        guard let host = url.host?.lowercased() else { return nil }

        // Reject extra path segments so pace://listen/something doesn't
        // silently behave like pace://listen.
        let path = url.path
        guard path.isEmpty || path == "/" else { return nil }

        switch host {
        case "listen":
            return .startListening
        case "panel":
            return .showPanel
        case "chat":
            // URLComponents.queryItems values are already percent-decoded —
            // do not decode a second time.
            guard let chatText = queryItemValue(named: "text", in: url)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !chatText.isEmpty,
                  chatText.count <= maximumChatTextCharacterCount else {
                return nil
            }
            return .sendChatMessage(text: chatText)
        case "watch":
            switch queryItemValue(named: "enabled", in: url)?.lowercased() {
            case "true":
                return .setWatchMode(enabled: true)
            case "false":
                return .setWatchMode(enabled: false)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func queryItemValue(named name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}
