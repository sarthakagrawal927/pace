//
//  PaceToolRegistry.swift
//  leanring-buddy
//
//  Typed catalog for local Pace tools. This is intentionally metadata
//  only today: parser, prompt, approval, and executor code can all
//  depend on one shared tool contract without introducing an MCP
//  transport boundary yet.
//

import Foundation

enum PaceToolRiskLevel: String {
    case readOnly
    case appOrSystemMutation
    case inputInjection
    case destructive

    var displayName: String {
        switch self {
        case .readOnly:
            return "read-only"
        case .appOrSystemMutation:
            return "app/system change"
        case .inputInjection:
            return "input injection"
        case .destructive:
            return "destructive"
        }
    }
}

enum PaceLocalToolKind: String {
    case click
    case doubleClick
    case type
    case key
    case scroll
    case openApp
    case openURL
    case music
    case volume
    case brightness
    case calendar
    case reminder
    case finder
    case notes
    case mail
    case things
    case shortcuts
    case messages
}

struct PaceLocalToolDefinition {
    let kind: PaceLocalToolKind
    let canonicalName: String
    let aliases: [String]
    let schemaExample: String
    let description: String
    let riskLevel: PaceToolRiskLevel
    let executionSummary: String
    let observationSummary: String

    var promptLine: String {
        "- \(schemaExample) \(description)"
    }

    var allNames: [String] {
        [canonicalName] + aliases
    }
}

enum PaceToolRegistry {
    static let localTools: [PaceLocalToolDefinition] = [
        PaceLocalToolDefinition(
            kind: .click,
            canonicalName: "click",
            aliases: [],
            schemaExample: #"{"tool":"click","x":400,"y":300,"screen":1}"#,
            description: "click screenshot pixel coordinates.",
            riskLevel: .inputInjection,
            executionSummary: "Posts a click through Accessibility or CGEvent.",
            observationSummary: "No observation unless coordinate conversion fails."
        ),
        PaceLocalToolDefinition(
            kind: .doubleClick,
            canonicalName: "double_click",
            aliases: ["doubleclick"],
            schemaExample: #"{"tool":"double_click","x":400,"y":300,"screen":1}"#,
            description: "double-click screenshot pixel coordinates.",
            riskLevel: .inputInjection,
            executionSummary: "Posts a double-click through CGEvent.",
            observationSummary: "No observation unless coordinate conversion fails."
        ),
        PaceLocalToolDefinition(
            kind: .type,
            canonicalName: "type",
            aliases: [],
            schemaExample: #"{"tool":"type","text":"exact text"}"#,
            description: "type exact text into the focused field.",
            riskLevel: .inputInjection,
            executionSummary: "Types literal text into the focused app.",
            observationSummary: "No observation."
        ),
        PaceLocalToolDefinition(
            kind: .key,
            canonicalName: "key",
            aliases: ["press_key"],
            schemaExample: #"{"tool":"key","key":"cmd+shift+t"}"#,
            description: "press a key or key chord.",
            riskLevel: .inputInjection,
            executionSummary: "Posts a keyboard event with optional modifiers.",
            observationSummary: "No observation unless the key is unknown."
        ),
        PaceLocalToolDefinition(
            kind: .scroll,
            canonicalName: "scroll",
            aliases: [],
            schemaExample: #"{"tool":"scroll","direction":"down","amount":5}"#,
            description: "scroll the focused surface.",
            riskLevel: .inputInjection,
            executionSummary: "Posts a scroll wheel event.",
            observationSummary: "No observation."
        ),
        PaceLocalToolDefinition(
            kind: .openApp,
            canonicalName: "open_app",
            aliases: ["open_application"],
            schemaExample: #"{"tool":"open_app","app":"Safari"}"#,
            description: "open a local Mac app by display name.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Launches or activates an app with NSWorkspace.",
            observationSummary: "No observation unless the app cannot be resolved."
        ),
        PaceLocalToolDefinition(
            kind: .openURL,
            canonicalName: "open_url",
            aliases: ["open_website", "website"],
            schemaExample: #"{"tool":"open_url","url":"https://example.com"}"#,
            description: "open a website or URL.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Opens a URL with NSWorkspace.",
            observationSummary: "Reports invalid URLs and opened URLs."
        ),
        PaceLocalToolDefinition(
            kind: .music,
            canonicalName: "music",
            aliases: [],
            schemaExample: #"{"tool":"music","command":"play"}"#,
            description: "control Music. commands: play, pause, play_pause, next, previous.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Controls Music with AppleScript or media keys.",
            observationSummary: "Reports Music command completion or AppleScript errors."
        ),
        PaceLocalToolDefinition(
            kind: .volume,
            canonicalName: "volume",
            aliases: [],
            schemaExample: #"{"tool":"volume","direction":"down","steps":2}"#,
            description: "adjust system volume.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Posts system volume key events.",
            observationSummary: "No observation."
        ),
        PaceLocalToolDefinition(
            kind: .brightness,
            canonicalName: "brightness",
            aliases: [],
            schemaExample: #"{"tool":"brightness","direction":"up","steps":2}"#,
            description: "adjust display brightness.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Posts display brightness key events.",
            observationSummary: "No observation."
        ),
        PaceLocalToolDefinition(
            kind: .calendar,
            canonicalName: "calendar",
            aliases: [],
            schemaExample: #"{"tool":"calendar","range":"today"}"#,
            description: "read calendar events. ranges: today, tomorrow, week.",
            riskLevel: .readOnly,
            executionSummary: "Reads EventKit calendar events after permission.",
            observationSummary: "Returns event summaries or permission errors."
        ),
        PaceLocalToolDefinition(
            kind: .reminder,
            canonicalName: "reminder",
            aliases: [],
            schemaExample: #"{"tool":"reminder","title":"follow up with Alex"}"#,
            description: "create a reminder.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Creates an EventKit reminder after permission.",
            observationSummary: "Reports reminder creation or permission errors."
        ),
        PaceLocalToolDefinition(
            kind: .finder,
            canonicalName: "finder",
            aliases: ["open_finder", "reveal_file"],
            schemaExample: #"{"tool":"finder","path":"~/Downloads","action":"open"}"#,
            description: "open or reveal a local file/folder in Finder.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Opens or reveals a local path with NSWorkspace.",
            observationSummary: "Reports missing paths and opened/revealed paths."
        ),
        PaceLocalToolDefinition(
            kind: .notes,
            canonicalName: "notes",
            aliases: ["note"],
            schemaExample: #"{"tool":"notes","action":"create","title":"Idea","body":"note text"}"#,
            description: "create, append, or search Apple Notes. actions: create, append, search.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Creates a note in Apple Notes with AppleScript.",
            observationSummary: "Reports note creation or AppleScript errors."
        ),
        PaceLocalToolDefinition(
            kind: .mail,
            canonicalName: "mail",
            aliases: ["compose_email", "email"],
            schemaExample: #"{"tool":"mail","to":"name@example.com","subject":"Hello","body":"draft text"}"#,
            description: "compose a Mail draft; never sends automatically.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Creates and opens an Apple Mail draft.",
            observationSummary: "Reports draft creation or AppleScript errors."
        ),
        PaceLocalToolDefinition(
            kind: .things,
            canonicalName: "things",
            aliases: ["things_todo"],
            schemaExample: #"{"tool":"things","title":"Buy milk","notes":"optional"}"#,
            description: "create a Things to-do if Things is installed.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Creates a Things to-do with AppleScript.",
            observationSummary: "Reports creation or missing-app/errors."
        ),
        PaceLocalToolDefinition(
            kind: .shortcuts,
            canonicalName: "shortcuts",
            aliases: ["run_shortcut", "shortcut"],
            schemaExample: #"{"tool":"shortcuts","name":"My Shortcut"}"#,
            description: "run a named macOS Shortcut.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Runs a named shortcut through the Shortcuts app.",
            observationSummary: "Reports shortcut execution or AppleScript errors."
        ),
        PaceLocalToolDefinition(
            kind: .messages,
            canonicalName: "messages",
            aliases: ["message"],
            schemaExample: #"{"tool":"messages","recipient":"Alex","text":"draft text"}"#,
            description: "open Messages and prepare a conversation; sending must be explicit.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Opens Messages or prepares a message draft.",
            observationSummary: "Reports whether Messages was opened."
        )
    ]

    static func definition(forToolName rawToolName: String) -> PaceLocalToolDefinition? {
        let normalizedToolName = normalizeToolName(rawToolName)
        return localTools.first { definition in
            definition.allNames.contains(normalizedToolName)
        }
    }

    static func kind(forToolName rawToolName: String) -> PaceLocalToolKind? {
        definition(forToolName: rawToolName)?.kind
    }

    static var plannerToolListText: String {
        localTools
            .map(\.promptLine)
            .joined(separator: "\n")
    }

    static func riskDisplayName(for action: PaceParsedAction) -> String {
        definition(for: action)?.riskLevel.displayName ?? "unknown"
    }

    static func definition(for action: PaceParsedAction) -> PaceLocalToolDefinition? {
        switch action {
        case .click:
            return definition(forToolName: "click")
        case .doubleClick:
            return definition(forToolName: "double_click")
        case .type:
            return definition(forToolName: "type")
        case .pressKey:
            return definition(forToolName: "key")
        case .scroll:
            return definition(forToolName: "scroll")
        case .openApplication:
            return definition(forToolName: "open_app")
        case .openURL:
            return definition(forToolName: "open_url")
        case .controlMusic:
            return definition(forToolName: "music")
        case .adjustVolume:
            return definition(forToolName: "volume")
        case .adjustBrightness:
            return definition(forToolName: "brightness")
        case .listCalendarEvents:
            return definition(forToolName: "calendar")
        case .createReminder:
            return definition(forToolName: "reminder")
        case .finder:
            return definition(forToolName: "finder")
        case .createNote, .appendNote, .searchNotes:
            return definition(forToolName: "notes")
        case .composeMail:
            return definition(forToolName: "mail")
        case .createThingsToDo:
            return definition(forToolName: "things")
        case .runShortcut:
            return definition(forToolName: "shortcuts")
        case .openMessages:
            return definition(forToolName: "messages")
        }
    }

    private static func normalizeToolName(_ rawToolName: String) -> String {
        rawToolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }
}
