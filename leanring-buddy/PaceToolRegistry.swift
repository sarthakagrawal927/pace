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

nonisolated enum PaceToolRiskLevel: String {
    case readOnly
    case appOrSystemMutation
    case inputInjection
    case destructive
    case externalIntegration

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
        case .externalIntegration:
            return "external tool"
        }
    }
}

nonisolated enum PaceLocalToolKind: String, CaseIterable {
    case click
    case doubleClick
    case type
    case setValue
    case undo
    case key
    case clipboard
    case window
    case scroll
    case openApp
    case openURL
    case music
    case volume
    case brightness
    case calendar
    case calendarCreate
    case reminder
    case finder
    case notes
    case mail
    case things
    case shortcuts
    case messages
    case downloadFile
    case startTimer
    case recordFlow
    case runFlow
    case drawAnnotation
    case clearAnnotations
}

nonisolated struct PaceLocalToolDefinition {
    let kind: PaceLocalToolKind
    let canonicalName: String
    let aliases: [String]
    let schemaExample: String
    let description: String
    let riskLevel: PaceToolRiskLevel
    let executionSummary: String
    let observationSummary: String
    /// Short user-facing voice/chat phrase that would trigger this tool.
    /// Rendered in the Skills tab of `PaceMainWindow` so the user can
    /// see at a glance how to ask for each capability. Drift-checked at
    /// startup — every tool must have a non-empty utterance.
    let exampleUtterance: String

    var promptLine: String {
        "- \(schemaExample) \(description)"
    }

    var allNames: [String] {
        [canonicalName] + aliases
    }
}

nonisolated struct PaceToolRegistryValidationIssue: Equatable, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

nonisolated enum PaceToolRegistry {
    static let localTools: [PaceLocalToolDefinition] = [
        PaceLocalToolDefinition(
            kind: .click,
            canonicalName: "click",
            aliases: [],
            schemaExample: #"{"tool":"click","x":400,"y":300,"screen":1}"#,
            description: "click screenshot pixel coordinates.",
            riskLevel: .inputInjection,
            executionSummary: "Posts a click through Accessibility or CGEvent.",
            observationSummary: "No observation unless coordinate conversion fails.",
            exampleUtterance: "click the Save button"
        ),
        PaceLocalToolDefinition(
            kind: .doubleClick,
            canonicalName: "double_click",
            aliases: ["doubleclick"],
            schemaExample: #"{"tool":"double_click","x":400,"y":300,"screen":1}"#,
            description: "double-click screenshot pixel coordinates.",
            riskLevel: .inputInjection,
            executionSummary: "Posts a double-click through CGEvent.",
            observationSummary: "No observation unless coordinate conversion fails.",
            exampleUtterance: "double click that icon"
        ),
        PaceLocalToolDefinition(
            kind: .type,
            canonicalName: "type",
            aliases: [],
            schemaExample: #"{"tool":"type","text":"exact text"}"#,
            description: "type exact text into the focused field.",
            riskLevel: .inputInjection,
            executionSummary: "Types literal text into the focused app.",
            observationSummary: "No observation.",
            exampleUtterance: "type hello world"
        ),
        PaceLocalToolDefinition(
            kind: .setValue,
            canonicalName: "set_value",
            aliases: ["ax_set_value"],
            schemaExample: #"{"tool":"set_value","text":"replacement text","action":"selection"}"#,
            description: "set focused text or replace selected text through Accessibility. actions: focused, selection.",
            riskLevel: .inputInjection,
            executionSummary: "Uses AXValue to update focused or selected text.",
            observationSummary: "Reports whether text was updated or no editable target was found.",
            exampleUtterance: "make this selection more concise"
        ),
        PaceLocalToolDefinition(
            kind: .undo,
            canonicalName: "undo_last",
            aliases: ["undo"],
            schemaExample: #"{"tool":"undo_last"}"#,
            description: "undo the last editable text change made by Pace.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Restores the previous AX value from Pace's session mutation log.",
            observationSummary: "Reports whether an undoable mutation was restored.",
            exampleUtterance: "undo that"
        ),
        PaceLocalToolDefinition(
            kind: .key,
            canonicalName: "key",
            aliases: ["press_key"],
            schemaExample: #"{"tool":"key","key":"cmd+shift+t"}"#,
            description: "press a key or key chord.",
            riskLevel: .inputInjection,
            executionSummary: "Posts a keyboard event with optional modifiers.",
            observationSummary: "No observation unless the key is unknown.",
            exampleUtterance: "press command S"
        ),
        PaceLocalToolDefinition(
            kind: .clipboard,
            canonicalName: "clipboard_read",
            aliases: ["clipboard"],
            schemaExample: #"{"tool":"clipboard_read"}"#,
            description: "read current clipboard text only when explicitly requested.",
            riskLevel: .readOnly,
            executionSummary: "Reads text from NSPasteboard without modifying it.",
            observationSummary: "Returns a bounded clipboard text preview or empty-text status.",
            exampleUtterance: "what's on my clipboard?"
        ),
        PaceLocalToolDefinition(
            kind: .window,
            canonicalName: "window_snap",
            aliases: ["window", "snap_window"],
            schemaExample: #"{"tool":"window_snap","position":"left"}"#,
            description: "move/resize the focused window. positions: left, right, top, bottom, maximize, center.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Moves and resizes the focused window with Accessibility.",
            observationSummary: "Reports whether the focused window was snapped.",
            exampleUtterance: "snap this window to the left half"
        ),
        PaceLocalToolDefinition(
            kind: .scroll,
            canonicalName: "scroll",
            aliases: [],
            schemaExample: #"{"tool":"scroll","direction":"down","amount":5}"#,
            description: "scroll the focused surface.",
            riskLevel: .inputInjection,
            executionSummary: "Posts a scroll wheel event.",
            observationSummary: "No observation.",
            exampleUtterance: "scroll down"
        ),
        PaceLocalToolDefinition(
            kind: .openApp,
            canonicalName: "open_app",
            aliases: ["open_application"],
            schemaExample: #"{"tool":"open_app","app":"Safari"}"#,
            description: "open a local Mac app by display name.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Launches or activates an app with NSWorkspace.",
            observationSummary: "No observation unless the app cannot be resolved.",
            exampleUtterance: "open Safari"
        ),
        PaceLocalToolDefinition(
            kind: .openURL,
            canonicalName: "open_url",
            aliases: ["open_website", "website"],
            schemaExample: #"{"tool":"open_url","url":"https://example.com"}"#,
            description: "open a website or URL.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Opens a URL with NSWorkspace.",
            observationSummary: "Reports invalid URLs and opened URLs.",
            exampleUtterance: "open Safari to anthropic.com"
        ),
        PaceLocalToolDefinition(
            kind: .music,
            canonicalName: "music",
            aliases: [],
            schemaExample: #"{"tool":"music","command":"play"}"#,
            description: "control Music. commands: play, pause, play_pause, next, previous.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Controls Music with AppleScript or media keys.",
            observationSummary: "Reports Music command completion or AppleScript errors.",
            exampleUtterance: "play my music"
        ),
        PaceLocalToolDefinition(
            kind: .volume,
            canonicalName: "volume",
            aliases: [],
            schemaExample: #"{"tool":"volume","direction":"down","steps":2}"#,
            description: "adjust system volume.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Posts system volume key events.",
            observationSummary: "No observation.",
            exampleUtterance: "turn the volume down"
        ),
        PaceLocalToolDefinition(
            kind: .brightness,
            canonicalName: "brightness",
            aliases: [],
            schemaExample: #"{"tool":"brightness","direction":"up","steps":2}"#,
            description: "adjust display brightness.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Posts display brightness key events.",
            observationSummary: "No observation.",
            exampleUtterance: "make the screen brighter"
        ),
        PaceLocalToolDefinition(
            kind: .calendar,
            canonicalName: "calendar",
            aliases: [],
            schemaExample: #"{"tool":"calendar","range":"today"}"#,
            description: "read calendar events. ranges: today, tomorrow, week.",
            riskLevel: .readOnly,
            executionSummary: "Reads EventKit calendar events after permission.",
            observationSummary: "Returns event summaries or permission errors.",
            exampleUtterance: "what's on my calendar this week"
        ),
        PaceLocalToolDefinition(
            kind: .calendarCreate,
            canonicalName: "calendar_create",
            aliases: ["calendar_event", "cal_event"],
            schemaExample: #"{"tool":"calendar_create","title":"Design review","start":"2026-06-10T15:00:00-07:00","end":"2026-06-10T16:00:00-07:00"}"#,
            description: "create a local calendar event. start is required; date-only values create all-day events.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Creates an EventKit calendar event after permission.",
            observationSummary: "Reports event creation or permission errors.",
            exampleUtterance: "add a design review to my calendar tomorrow at 3pm"
        ),
        PaceLocalToolDefinition(
            kind: .reminder,
            canonicalName: "reminder",
            aliases: [],
            schemaExample: #"{"tool":"reminder","title":"follow up with Alex"}"#,
            description: "create a reminder.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Creates an EventKit reminder after permission.",
            observationSummary: "Reports reminder creation or permission errors.",
            exampleUtterance: "remind me to follow up with Alex"
        ),
        PaceLocalToolDefinition(
            kind: .finder,
            canonicalName: "finder",
            aliases: ["open_finder", "reveal_file"],
            schemaExample: #"{"tool":"finder","path":"~/Downloads","action":"open"}"#,
            description: "open or reveal a local file/folder in Finder.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Opens or reveals a local path with NSWorkspace.",
            observationSummary: "Reports missing paths and opened/revealed paths.",
            exampleUtterance: "open my Downloads folder"
        ),
        PaceLocalToolDefinition(
            kind: .notes,
            canonicalName: "notes",
            aliases: ["note"],
            schemaExample: #"{"tool":"notes","action":"create","title":"Idea","body":"note text"}"#,
            description: "create, append, or search Apple Notes. actions: create, append, search.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Creates a note in Apple Notes with AppleScript.",
            observationSummary: "Reports note creation or AppleScript errors.",
            exampleUtterance: "take a note: idea for the launch page"
        ),
        PaceLocalToolDefinition(
            kind: .mail,
            canonicalName: "mail",
            aliases: ["compose_email", "email"],
            schemaExample: #"{"tool":"mail","to":"name@example.com","subject":"Hello","body":"draft text"}"#,
            description: "compose a Mail draft; never sends automatically.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Creates and opens an Apple Mail draft.",
            observationSummary: "Reports draft creation or AppleScript errors.",
            exampleUtterance: "draft an email to Alex saying I'll be late"
        ),
        PaceLocalToolDefinition(
            kind: .things,
            canonicalName: "things",
            aliases: ["things_todo"],
            schemaExample: #"{"tool":"things","title":"Buy milk","notes":"optional"}"#,
            description: "create a Things to-do if Things is installed.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Creates a Things to-do with AppleScript.",
            observationSummary: "Reports creation or missing-app/errors.",
            exampleUtterance: "add buy milk to my Things inbox"
        ),
        PaceLocalToolDefinition(
            kind: .shortcuts,
            canonicalName: "shortcuts",
            aliases: ["run_shortcut", "shortcut"],
            schemaExample: #"{"tool":"shortcuts","name":"My Shortcut"}"#,
            description: "run a named macOS Shortcut.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Runs a named shortcut through the Shortcuts app.",
            observationSummary: "Reports shortcut execution or AppleScript errors.",
            exampleUtterance: "run my Morning Routine shortcut"
        ),
        PaceLocalToolDefinition(
            kind: .messages,
            canonicalName: "messages",
            aliases: ["message"],
            schemaExample: #"{"tool":"messages","recipient":"Alex","text":"draft text"}"#,
            description: "open Messages and prepare a conversation; sending must be explicit.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Opens Messages or prepares a message draft.",
            observationSummary: "Reports whether Messages was opened.",
            exampleUtterance: "open Messages with Alex"
        ),
        PaceLocalToolDefinition(
            kind: .downloadFile,
            canonicalName: "download_file",
            aliases: ["download", "save_file"],
            schemaExample: #"{"tool":"download_file","url":"https://example.com/report.pdf","name":"report.pdf"}"#,
            description: "download a user-named http(s) URL into ~/Downloads. The product's only network action; always user-commanded.",
            riskLevel: .externalIntegration,
            executionSummary: "Downloads the URL into ~/Downloads with a sanitized, collision-free filename.",
            observationSummary: "Reports the saved filename and byte count, or the failure reason.",
            exampleUtterance: "download the report at example.com/report.pdf"
        ),
        PaceLocalToolDefinition(
            kind: .startTimer,
            canonicalName: "start_timer",
            aliases: ["timer", "set_timer"],
            schemaExample: #"{"tool":"start_timer","duration":"3 minutes","label":"tea"}"#,
            description: "schedule a spoken nudge after a duration. duration accepts \"3 minutes\", \"30s\", \"2 hours\", or a plain seconds number.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Schedules an in-process Timer that fires a spoken nudge through TTS.",
            observationSummary: "Reports the scheduled fire time, or a validation error if the duration was unparseable.",
            exampleUtterance: "set a 5 minute timer for tea"
        ),
        PaceLocalToolDefinition(
            kind: .recordFlow,
            canonicalName: "record_flow",
            aliases: ["record_this", "remember_flow"],
            schemaExample: #"{"tool":"record_flow","name":"morning standup setup"}"#,
            description: "start recording a user-demonstrated local flow by name. Recording stores AX/key steps, not pixels.",
            riskLevel: .inputInjection,
            executionSummary: "Starts or stops a local demonstration-recording session.",
            observationSummary: "Reports recording state or missing flow name.",
            exampleUtterance: "record this as my standup setup"
        ),
        PaceLocalToolDefinition(
            kind: .runFlow,
            canonicalName: "run_flow",
            aliases: ["play_flow", "do_flow"],
            schemaExample: #"{"tool":"run_flow","name":"morning standup setup"}"#,
            description: "run a previously recorded local flow by name. User approval is required before replay.",
            riskLevel: .inputInjection,
            executionSummary: "Replays saved AX/key steps through the local executor.",
            observationSummary: "Reports replay start or missing flow.",
            exampleUtterance: "run my standup setup flow"
        ),
        PaceLocalToolDefinition(
            kind: .drawAnnotation,
            canonicalName: "draw_annotation",
            aliases: ["annotate", "draw"],
            schemaExample: #"{"tool":"draw_annotation","shapes":[{"kind":"rect","x":100,"y":80,"width":200,"height":60,"color":"red","label":"start here"}],"screen":1}"#,
            description: "draw teaching shapes on the screen overlay. shapes: rect, ellipse, line, arrow, polygon. coords are screenshot pixels (same space as click). optional color (red, blue, green, yellow, orange — default red), label (≤60 chars), strokeWidth (default 3), filled (default false). annotations persist until the next user turn or 30 seconds.",
            riskLevel: .readOnly,
            executionSummary: "Renders annotation shapes on the transparent full-screen overlay.",
            observationSummary: "No observation.",
            exampleUtterance: "draw a circle around the save button and explain it"
        ),
        PaceLocalToolDefinition(
            kind: .clearAnnotations,
            canonicalName: "clear_annotations",
            aliases: ["clear_drawing", "wipe_annotations"],
            schemaExample: #"{"tool":"clear_annotations"}"#,
            description: "remove all annotations currently drawn on the screen overlay.",
            riskLevel: .readOnly,
            executionSummary: "Clears the annotation overlay layer.",
            observationSummary: "No observation.",
            exampleUtterance: "clear the annotations"
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

    static func validateForAppStartup() {
        let validationIssues = validateLocalRegistry()
            + validateBundledRegistryArtifact(
                bundle: .main,
                allowSourceTreeFallback: false
            )
            + validateBundledPlannerResponseSchemaArtifact(
                bundle: .main,
                allowSourceTreeFallback: false
            )
        // Recipe library validation runs alongside the tool registry
        // validation so malformed recipe JSON fails the app at launch
        // — same fail-fast contract the registry uses.
        let recipeValidationIssues = PaceRecipeLibrary
            .validateBundledRecipes(bundle: .main, allowSourceTreeFallback: false)
            .map { PaceToolRegistryValidationIssue(message: "bundled recipe: \($0.message)") }
        let allValidationIssues = validationIssues + recipeValidationIssues
        guard allValidationIssues.isEmpty else {
            let formattedIssues = allValidationIssues
                .map { "- \($0.description)" }
                .joined(separator: "\n")
            fatalError("Pace local tool registry is invalid:\n\(formattedIssues)")
        }
    }

    static func validateSourceRegistryArtifact() -> [PaceToolRegistryValidationIssue] {
        validateBundledRegistryArtifact(
            bundle: .main,
            allowSourceTreeFallback: true
        )
        + validateBundledPlannerResponseSchemaArtifact(
            bundle: .main,
            allowSourceTreeFallback: true
        )
    }

    static func validateLocalRegistry() -> [PaceToolRegistryValidationIssue] {
        var validationIssues: [PaceToolRegistryValidationIssue] = []

        if localTools.isEmpty {
            validationIssues.append(.init(message: "registry must contain at least one local tool"))
        }

        // Hard product invariant: Pace ships NO destructive tools. Every
        // mutation must be undoable, collision-safe, or draft-only. Startup
        // fails if a destructive-risk definition is ever added, so the
        // planner can never gain access to one silently.
        for destructiveDefinition in localTools.filter({ $0.riskLevel == .destructive }) {
            validationIssues.append(.init(
                message: "\(destructiveDefinition.canonicalName) is destructive — Pace does not permit destructive tools"
            ))
        }

        let registeredKinds = Set(localTools.map(\.kind))
        let expectedKinds = Set(PaceLocalToolKind.allCases)
        for missingKind in expectedKinds.subtracting(registeredKinds).sorted(by: { $0.rawValue < $1.rawValue }) {
            validationIssues.append(.init(message: "missing local tool definition for kind \(missingKind.rawValue)"))
        }
        for duplicateKind in duplicateValues(localTools.map(\.kind)) {
            validationIssues.append(.init(message: "duplicate local tool definition for kind \(duplicateKind.rawValue)"))
        }

        var seenToolNames: [String: String] = [:]
        for definition in localTools {
            let trimmedCanonicalName = definition.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCanonicalName.isEmpty {
                validationIssues.append(.init(message: "\(definition.kind.rawValue) has an empty canonical name"))
            }

            if definition.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validationIssues.append(.init(message: "\(definition.canonicalName) has an empty description"))
            }
            if definition.executionSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validationIssues.append(.init(message: "\(definition.canonicalName) has an empty execution summary"))
            }
            if definition.observationSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validationIssues.append(.init(message: "\(definition.canonicalName) has an empty observation summary"))
            }
            if definition.exampleUtterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validationIssues.append(.init(message: "\(definition.canonicalName) has an empty example utterance"))
            }

            for toolName in definition.allNames {
                let normalizedToolName = normalizeToolName(toolName)
                if normalizedToolName.isEmpty {
                    validationIssues.append(.init(message: "\(definition.canonicalName) has an empty name or alias"))
                    continue
                }
                if let existingCanonicalName = seenToolNames[normalizedToolName] {
                    validationIssues.append(.init(
                        message: "\(definition.canonicalName) reuses tool name or alias \(normalizedToolName) from \(existingCanonicalName)"
                    ))
                } else {
                    seenToolNames[normalizedToolName] = definition.canonicalName
                }
            }

            validationIssues.append(contentsOf: validateSchemaExample(definition))
        }

        return validationIssues
    }

    static func riskDisplayName(for action: PaceParsedAction) -> String {
        if case .mcp = action {
            return PaceToolRiskLevel.externalIntegration.displayName
        }
        return definition(for: action)?.riskLevel.displayName ?? "unknown"
    }

    static func definition(for action: PaceParsedAction) -> PaceLocalToolDefinition? {
        switch action {
        case .click, .clickCandidates:
            return definition(forToolName: "click")
        case .doubleClick:
            return definition(forToolName: "double_click")
        case .type:
            return definition(forToolName: "type")
        case .setTextValue, .editSelectedText:
            return definition(forToolName: "set_value")
        case .undoLastMutation:
            return definition(forToolName: "undo_last")
        case .pressKey:
            return definition(forToolName: "key")
        case .readClipboard:
            return definition(forToolName: "clipboard_read")
        case .snapWindow:
            return definition(forToolName: "window_snap")
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
        case .createCalendarEvent:
            return definition(forToolName: "calendar_create")
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
        case .downloadFile:
            return definition(forToolName: "download_file")
        case .startTimer:
            return definition(forToolName: "start_timer")
        case .recordFlow:
            return definition(forToolName: "record_flow")
        case .runFlow:
            return definition(forToolName: "run_flow")
        case .mcp:
            return nil
        case .drawAnnotation:
            return definition(forToolName: "draw_annotation")
        case .clearAnnotations:
            return definition(forToolName: "clear_annotations")
        }
    }

    nonisolated private static func normalizeToolName(_ rawToolName: String) -> String {
        rawToolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func validateSchemaExample(
        _ definition: PaceLocalToolDefinition
    ) -> [PaceToolRegistryValidationIssue] {
        guard let schemaData = definition.schemaExample.data(using: .utf8) else {
            return [.init(message: "\(definition.canonicalName) schema example is not UTF-8")]
        }

        do {
            let decodedExample = try JSONSerialization.jsonObject(with: schemaData)
            guard let exampleObject = decodedExample as? [String: Any] else {
                return [.init(message: "\(definition.canonicalName) schema example must be a JSON object")]
            }
            guard let exampleToolName = exampleObject["tool"] as? String else {
                return [.init(message: "\(definition.canonicalName) schema example must include a string tool field")]
            }
            guard normalizeToolName(exampleToolName) == normalizeToolName(definition.canonicalName) else {
                return [.init(
                    message: "\(definition.canonicalName) schema example tool field is \(exampleToolName)"
                )]
            }
            return []
        } catch {
            return [.init(message: "\(definition.canonicalName) schema example is invalid JSON: \(error.localizedDescription)")]
        }
    }

    private static func validateBundledRegistryArtifact(
        bundle: Bundle,
        allowSourceTreeFallback: Bool
    ) -> [PaceToolRegistryValidationIssue] {
        guard let registryURL = registryArtifactURL(
            bundle: bundle,
            allowSourceTreeFallback: allowSourceTreeFallback
        ) else {
            return [.init(message: "missing v10 action registry artifact at Resources/v10-actions/registry.json")]
        }

        do {
            let registryData = try Data(contentsOf: registryURL)
            let decodedObject = try JSONSerialization.jsonObject(with: registryData)
            guard let registryObject = decodedObject as? [String: Any] else {
                return [.init(message: "v10 action registry artifact must be a JSON object")]
            }
            return validateRegistryArtifactObject(registryObject)
        } catch {
            return [.init(message: "could not read v10 action registry artifact: \(error.localizedDescription)")]
        }
    }

    private static func registryArtifactURL(
        bundle: Bundle,
        allowSourceTreeFallback: Bool
    ) -> URL? {
        let bundleCandidates = [
            bundle.url(
                forResource: "registry",
                withExtension: "json",
                subdirectory: "Resources/v10-actions"
            ),
            bundle.url(
                forResource: "registry",
                withExtension: "json",
                subdirectory: "v10-actions"
            ),
            bundle.url(
                forResource: "registry",
                withExtension: "json"
            )
        ]
        if let bundledURL = bundleCandidates.compactMap({ $0 }).first {
            return bundledURL
        }

        guard allowSourceTreeFallback else { return nil }
        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceTreeURL = currentDirectoryURL
            .appendingPathComponent("leanring-buddy")
            .appendingPathComponent("Resources")
            .appendingPathComponent("v10-actions")
            .appendingPathComponent("registry.json")
        return FileManager.default.fileExists(atPath: sourceTreeURL.path) ? sourceTreeURL : nil
    }

    private static func validateBundledPlannerResponseSchemaArtifact(
        bundle: Bundle,
        allowSourceTreeFallback: Bool
    ) -> [PaceToolRegistryValidationIssue] {
        guard let schemaURL = plannerResponseSchemaArtifactURL(
            bundle: bundle,
            allowSourceTreeFallback: allowSourceTreeFallback
        ) else {
            return [.init(message: "missing v10 planner response schema artifact at Resources/v10-actions/pace-fm-response-v10.schema.json")]
        }

        do {
            let schemaData = try Data(contentsOf: schemaURL)
            let decodedObject = try JSONSerialization.jsonObject(with: schemaData)
            guard let schemaObject = decodedObject as? [String: Any] else {
                return [.init(message: "v10 planner response schema artifact must be a JSON object")]
            }
            return validatePlannerResponseSchemaArtifactObject(schemaObject)
        } catch {
            return [.init(message: "could not read v10 planner response schema artifact: \(error.localizedDescription)")]
        }
    }

    private static func plannerResponseSchemaArtifactURL(
        bundle: Bundle,
        allowSourceTreeFallback: Bool
    ) -> URL? {
        let bundleCandidates = [
            bundle.url(
                forResource: "pace-fm-response-v10.schema",
                withExtension: "json",
                subdirectory: "Resources/v10-actions"
            ),
            bundle.url(
                forResource: "pace-fm-response-v10.schema",
                withExtension: "json",
                subdirectory: "v10-actions"
            ),
            bundle.url(
                forResource: "pace-fm-response-v10.schema",
                withExtension: "json"
            )
        ]
        if let bundledURL = bundleCandidates.compactMap({ $0 }).first {
            return bundledURL
        }

        guard allowSourceTreeFallback else { return nil }
        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceTreeURL = currentDirectoryURL
            .appendingPathComponent("leanring-buddy")
            .appendingPathComponent("Resources")
            .appendingPathComponent("v10-actions")
            .appendingPathComponent("pace-fm-response-v10.schema.json")
        return FileManager.default.fileExists(atPath: sourceTreeURL.path) ? sourceTreeURL : nil
    }

    private static func validatePlannerResponseSchemaArtifactObject(
        _ schemaObject: [String: Any]
    ) -> [PaceToolRegistryValidationIssue] {
        var validationIssues: [PaceToolRegistryValidationIssue] = []

        if schemaObject["title"] as? String != "Pace planner response v10" {
            validationIssues.append(.init(message: "v10 planner response schema title drift"))
        }
        if schemaObject["type"] as? String != "object" {
            validationIssues.append(.init(message: "v10 planner response schema root type must be object"))
        }
        guard let properties = schemaObject["properties"] as? [String: Any] else {
            validationIssues.append(.init(message: "v10 planner response schema must define properties"))
            return validationIssues
        }
        for requiredProperty in ["spokenText", "intent", "payload"] where properties[requiredProperty] == nil {
            validationIssues.append(.init(message: "v10 planner response schema missing property \(requiredProperty)"))
        }

        return validationIssues
    }

    private static func validateRegistryArtifactObject(
        _ registryObject: [String: Any]
    ) -> [PaceToolRegistryValidationIssue] {
        var validationIssues: [PaceToolRegistryValidationIssue] = []

        guard let version = registryObject["version"] as? Int, version == 1 else {
            validationIssues.append(.init(message: "v10 action registry artifact version must be 1"))
            return validationIssues
        }

        guard let actionObjects = registryObject["actions"] as? [[String: Any]] else {
            validationIssues.append(.init(message: "v10 action registry artifact must contain an actions array"))
            return validationIssues
        }

        let definitionsByKind = Dictionary(uniqueKeysWithValues: localTools.map { ($0.kind.rawValue, $0) })
        let artifactKinds = actionObjects.compactMap { $0["kind"] as? String }
        let expectedKinds = Set(PaceLocalToolKind.allCases.map(\.rawValue))
        let actualKinds = Set(artifactKinds)

        for missingKind in expectedKinds.subtracting(actualKinds).sorted() {
            validationIssues.append(.init(message: "v10 action registry artifact missing kind \(missingKind)"))
        }
        for extraKind in actualKinds.subtracting(expectedKinds).sorted() {
            validationIssues.append(.init(message: "v10 action registry artifact has unknown kind \(extraKind)"))
        }
        for duplicateKind in duplicateValues(artifactKinds) {
            validationIssues.append(.init(message: "v10 action registry artifact duplicates kind \(duplicateKind)"))
        }

        for actionObject in actionObjects {
            guard let kindName = actionObject["kind"] as? String,
                  let definition = definitionsByKind[kindName] else {
                continue
            }
            validationIssues.append(contentsOf: validateRegistryArtifactAction(
                actionObject,
                definition: definition
            ))
        }

        return validationIssues
    }

    private static func validateRegistryArtifactAction(
        _ actionObject: [String: Any],
        definition: PaceLocalToolDefinition
    ) -> [PaceToolRegistryValidationIssue] {
        var validationIssues: [PaceToolRegistryValidationIssue] = []

        let artifactToolName = actionObject["tool"] as? String
        if normalizeToolName(artifactToolName ?? "") != normalizeToolName(definition.canonicalName) {
            validationIssues.append(.init(
                message: "v10 artifact kind \(definition.kind.rawValue) has tool \(artifactToolName ?? "<missing>"), expected \(definition.canonicalName)"
            ))
        }

        let artifactAliases = (actionObject["aliases"] as? [String]) ?? []
        if artifactAliases.map(normalizeToolName) != definition.aliases.map(normalizeToolName) {
            validationIssues.append(.init(message: "v10 artifact aliases drift for \(definition.canonicalName)"))
        }

        let artifactRisk = actionObject["risk"] as? String
        if artifactRisk != definition.riskLevel.rawValue {
            validationIssues.append(.init(message: "v10 artifact risk drift for \(definition.canonicalName)"))
        }

        guard let schemaExample = actionObject["schemaExample"] as? [String: Any] else {
            validationIssues.append(.init(message: "v10 artifact schemaExample missing for \(definition.canonicalName)"))
            return validationIssues
        }

        let artifactExampleToolName = schemaExample["tool"] as? String
        if normalizeToolName(artifactExampleToolName ?? "") != normalizeToolName(definition.canonicalName) {
            validationIssues.append(.init(message: "v10 artifact schemaExample tool drift for \(definition.canonicalName)"))
        }

        let artifactExampleUtterance = (actionObject["exampleUtterance"] as? String) ?? ""
        if artifactExampleUtterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationIssues.append(.init(message: "v10 artifact exampleUtterance missing for \(definition.canonicalName)"))
        } else if artifactExampleUtterance != definition.exampleUtterance {
            validationIssues.append(.init(message: "v10 artifact exampleUtterance drift for \(definition.canonicalName)"))
        }

        return validationIssues
    }

    private static func duplicateValues<T: Hashable>(_ values: [T]) -> [T] {
        var seenValues = Set<T>()
        var duplicateValues = Set<T>()
        for value in values {
            if !seenValues.insert(value).inserted {
                duplicateValues.insert(value)
            }
        }
        return Array(duplicateValues)
    }
}
