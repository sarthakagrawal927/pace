# Pace executor surface — generic parameterized-action dispatcher

Status: partial (2026-06-09). The Pace-side counterpart of v10 (`tinygpt/docs/prds/pace-v10-parameterized-actions.md`). Typed v10 payload parsing, the bundled registry artifact, startup registry validation, local planner-output envelope/action rejection before execution, the local executor dispatch surface, destructive-only approval policy, `Mail.draft` streaming, `mailto:` first-draft setup, AX-first Mail body writing with local fallbacks, AX set-value mutation/undo, and first-pass local handlers are wired. Real-app AX/performance smokes remain queued.

## Goal

Build a Pace-side action handler that takes `{name, args}` from the planner stream and dispatches it. AX-first; first-party APIs (EventKit, MessageUI, NSWorkspace, MapKit) as the typed fallback; `shortcuts run` CLI as last mile. NEVER pasteboard.

## Contract (consumed from tinygpt)

The planner emits v10 schema:
```json
{
  "spokenText": "...",
  "intent": "action" | "answer" | "dictate" | "edit",
  "payload": { ... }
}
```

For `intent="action"`, payload is one of:
- `{name: string, args: object}` — single action call
- `{calls: [{name, args}, ...]}` — parallel multi-call (defer; v1 supports only single)

The 12 v1 actions and their args schemas are canonical in `tinygpt/grammars/v10-actions/registry.json`. **Bundle that file into `pace/Resources/v10-actions/registry.json`** and read it at boot — single source of truth.

## Public Swift API

```swift
public protocol PaceActionHandler {
    var name: String { get }  // e.g. "Mail.draft"
    func execute(args: [String: Any], context: ExecutionContext) async throws -> ActionResult
}

public struct ExecutionContext {
    let frontmostApp: NSRunningApplication?
    let focusedElement: AXUIElement?
    let selectionRange: CFRange?  // populated by AXSelectedTextRange when relevant
    let userIntent: String   // raw transcript, for logging/eval
    let confirmationPolicy: ConfirmationPolicy  // .always | .destructiveOnly | .never
}

public struct ActionResult {
    let success: Bool
    let spokenFeedback: String?  // optional override of planner's spokenText
    let mutation: Mutation?      // for undo support
}

public final class Executor {
    public init(registry: ActionRegistry)
    public func register(_ handler: PaceActionHandler)
    public func dispatch(name: String, args: [String: Any]) async throws -> ActionResult
}
```

Each action gets its own handler class. Executor owns the registry + dispatch table.

## The 12 v1 handlers

### AXPressHandler
```swift
final class AXPressHandler: PaceActionHandler {
    var name = "AX.press"
    func execute(args: [String: Any], context: ExecutionContext) async throws -> ActionResult {
        guard let target = args["target"] as? String else { throw ExecError.missingArg("target") }
        // Walk the AX tree of the frontmost app, find element by label match
        let el = try findElement(byLabel: target, in: context.frontmostApp)
        AXUIElementPerformAction(el, kAXPressAction as CFString)
        return ActionResult(success: true, spokenFeedback: nil, mutation: nil)
    }
}
```

### AXSetValueHandler
```swift
final class AXSetValueHandler: PaceActionHandler {
    var name = "AX.setValue"
    func execute(args: [String: Any], context: ExecutionContext) async throws -> ActionResult {
        guard let target = args["target"] as? String,
              let value = args["value"] as? String else { throw ExecError.missingArgs }
        let el: AXUIElement
        if target == "focused" {
            el = context.focusedElement ?? (try findFocused())
        } else {
            el = try findElement(byLabel: target, in: context.frontmostApp)
        }
        // Capture old value for undo
        var oldVal: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &oldVal)
        // Optional range: write into AXSelectedTextRange
        if let r = args["range"] as? [String: Int],
           let loc = r["location"], let len = r["length"] {
            let cfRange = CFRange(location: loc, length: len)
            let axRange = AXValue.createCFRange(cfRange)
            AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axRange)
            AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, value as CFString)
        } else {
            AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFString)
        }
        return ActionResult(success: true, ..., mutation: .axValue(el, oldVal as? String))
    }
}
```

### AXScrollHandler
CGEvent scroll wheel events at the focused element's location. Direction → dy/dx; amount → tick count.

### AppLaunchHandler / AppActivateHandler
```swift
final class AppLaunchHandler: PaceActionHandler {
    var name = "App.launch"
    func execute(args: [String: Any], context: ExecutionContext) async throws -> ActionResult {
        guard let name = args["name"] as? String else { throw ExecError.missingArg("name") }
        let resolved = resolveAppPath(name) // try bundle ID, then display name, then fuzzy
        NSWorkspace.shared.open(URL(fileURLWithPath: resolved))
        return ActionResult(success: true, ..., mutation: nil)
    }
}
```

### MailDraftHandler
```swift
final class MailDraftHandler: PaceActionHandler {
    var name = "Mail.draft"
    func execute(args: [String: Any], context: ExecutionContext) async throws -> ActionResult {
        let to = (args["to"] as? [String]) ?? []
        let subject = (args["subject"] as? String) ?? ""
        let body = (args["body"] as? String) ?? ""

        // Resolve __resolve:<name> tokens via Contacts
        let resolvedTo = to.map(resolveRecipient)

        // 1. Launch mailto: URL — fast (159ms measured) — gets To: + subject
        var components = URLComponents(string: "mailto:")!
        components.path = resolvedTo.joined(separator: ",")
        components.queryItems = subject.isEmpty ? nil : [URLQueryItem(name: "subject", value: subject)]
        NSWorkspace.shared.open(components.url!)

        // 2. Wait for compose window via AX polling (typically ~150ms)
        let composeWindow = try await awaitMailComposeWindow(timeout: 2.0)

        // 3. Stream body via AX setValue if available
        if !body.isEmpty {
            let bodyArea = try findBodyTextArea(in: composeWindow)
            AXUIElementSetAttributeValue(bodyArea, kAXValueAttribute as CFString, body as CFString)
            // NOTE: for chunk-by-chunk streaming, see streaming hook below
        }
        return ActionResult(success: true, ..., mutation: nil)
    }
}
```

**Critical**: if the planner emits `body` as part of a STREAMING SSE response, the handler must write incrementally. See "Streaming body" section.

### CalEventHandler / RemindersAddHandler
EventKit. Request access (one-time). Parse natural-language times via `Date.init(naturalLanguage:)` (or NSDataDetector for dates) — defer hard cases to the model or to the user.

### NotesCreateHandler
Notes.app has no first-party API. Use AppleScript (already in scope per doctrine — Notes is an Apple-shipped app). Pre-baked AppleScript template inline:
```applescript
tell application "Notes"
    set newNote to make new note with properties {name:"%title%", body:"%body%"}
end tell
```

### ShortcutRunHandler
```swift
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
task.arguments = ["run", name] + (input.map { ["--input-path", "-"] } ?? [])
// stdin: input
try task.run()
task.waitUntilExit()
```

Implementation note, 2026-06-09: `Shortcut.run` now uses `/usr/bin/shortcuts`.
Before running, Pace lists installed shortcuts and refuses with "I don't see a
shortcut called X" when the requested name is absent. Dry-run mode remains
non-mutating.

### WindowSnapHandler
Read screen size, compute target frame, AX setValue on `kAXPositionAttribute` + `kAXSizeAttribute` of the focused window.

### ClipboardReadHandler
`NSPasteboard.general.string(forType: .string)` — return in `spokenFeedback`.

## Streaming body — the hot path

For `Mail.draft` (and analogous compose actions later), the planner emits `body` as STREAMING tokens via the SSE stream. The executor must:

1. Pre-launch mailto: as soon as it sees `intent="action", name="Mail.draft"` (don't wait for body).
2. Open compose window via AX polling (~150 ms).
3. As each `payload.args.body` chunk arrives via `PartialJSONStream.swift`'s `onChunk("body", text)`, append to the body field via AX setValue (idempotent, write the running buffer).

Existing `pace/leanring-buddy/PartialJSONStream.swift` already supports this — wire `onChunk("body", text)` into a `MailComposeWriter` that owns the compose window AX reference. The writer batches AX setValue calls if chunks arrive faster than 30 Hz (no perceptible benefit above that).

Counterpart code: `pace/docs/prds/pace-v9-body-streaming-wiring.md`.

## Confirmation policy

`.always`: every action prompts ("send to Aman, yes?") — voice confirmation only, no UI.
`.destructiveOnly`: only confirm Mail.draft (send), Notes.create, Reminders.add, Shortcut.run that may be destructive. Read-only and AX.press/scroll/snap auto-execute.
`.never`: dispatch immediately.

**Default for v1: `.destructiveOnly`.** Beat Raycast's "confidently wrong action" failure mode without making the product feel reluctant.

## Permission requests at onboarding

All Pace permissions surfaced at first launch with clear copy:
- Accessibility (AX read + dispatch) — required, refuses to start without
- Input Monitoring (CGEventKeyboardSetUnicodeString fallback) — required
- Microphone (ASR) — required
- Speech Recognition (Apple Speech bridge) — required
- Contacts (recipient resolution) — required for Mail.draft
- Calendar + Reminders (EventKit) — required for Cal.event / Reminders.add
- Automation (AppleScript control of Notes) — required for Notes.create
- Screen Recording (OCR + vision pillar) — required for vision-pillar features

Don't lazy-request. Bombarding the user later breaks the JARVIS feel.

## Failure handling

| Failure | Behavior |
|---|---|
| Element not found by label | Speak: "i can't see X on this screen" — emit no-op |
| AX setValue fails (secure-text-entry) | Speak: "that field doesn't accept input from me — type it manually" — emit no-op |
| Recipient unresolved (Contacts no match) | Speak: "i couldn't find X in contacts — saying it as-is" — proceed with raw token in To: |
| App.launch — app not installed | Speak: "X isn't installed" |
| Shortcut.run — shortcut name not in user's shortcut list | Speak: "i don't see a shortcut called X" |
| AX dispatch hangs | 5-sec timeout, abort, speak: "that action didn't go through" |

## Mutation log + undo

Every successful action that modifies state records a `Mutation` in a session-local log. Stack supports voice undo: "undo that" → pop top, replay reverse. For v1: AX.setValue mutations are undoable (restore old value). Mail.draft / Cal.event / Reminders.add / Notes.create are non-undoable (no API in the responding app to retract). Speak: "i can't undo that one" for non-undoable.

## Testing

For each action handler, a unit test that:
1. Sets up a synthetic AX context (Mail compose, Safari, Notes — open windows programmatically)
2. Calls the handler with sample args
3. Verifies the AX state changed
4. Verifies mutation was logged

End-to-end: a single integration test that does "draft mail to john about X" via stubbed planner stream, confirms compose window opens with To: + body filled, no clipboard pollution, no leftover Mail processes.

## Performance targets

| Operation | Target |
|---|---|
| AX.press (target known, AX hot) | < 30 ms |
| AX.setValue (single write) | < 50 ms |
| App.launch (warm activate) | < 100 ms |
| App.launch (cold) | < 1500 ms (Mail measured at 1354 ms) |
| Mail.draft from intent → compose visible | < 200 ms (159 ms mailto: measured + ~40 ms AX poll) |
| Mail.draft body first char in compose | < 250 ms after intent |
| Cal.event from intent → EKEvent saved | < 100 ms |
| Window.snap | < 50 ms |
| Shortcut.run cold start | varies — limited by macOS shortcuts CLI overhead |

## Done when

- All 12 handlers implemented
- All 12 handlers implemented. Partial: the current executor implements the v1 surface plus additional local actions, but some handlers are grouped in `PaceActionExecutor` rather than split into one class each.
- AX read + dispatch flow tested on Mail, Safari, Notes, Slack, VSCode, Cursor. Queued for real-app smoke.
- Streaming body wiring confirmed end-to-end against a stubbed tinygpt serve emitting v10 schema. Partial: parser/unit coverage, runtime stream hook, and AX-first Mail body writer are wired; live Mail latency smoke remains queued.
- Mutation log + voice undo works for AX.setValue. Partial: dry-run/unit coverage exists; broad real-app verification remains queued.
- All permissions onboarding screen passes Apple's review patterns. Partial: permission rows/preflight exist; App Review-style walkthrough remains queued.
- Performance targets met for AX.press, AX.setValue, Mail.draft latency. Queued for manual/runtime measurement.

## References

- `tinygpt/grammars/v10-actions/registry.json` — canonical action schemas (bundle this into Pace.app)
- `leanring-buddy/Resources/v10-actions/pace-fm-response-v10.schema.json` — bundled planner output schema artifact
- `tinygpt/grammars/pace-system-prompt-v10-actions.txt` — system prompt v10 uses (for reference; Pace's planner uses this baked in)
- `pace/docs/architecture.md` — 5-pillar overview
- `pace/docs/prds/pace-v9-body-streaming-wiring.md` — streaming body details (subsumed by this PRD for v10)
- `pace/leanring-buddy/PartialJSONStream.swift` — streaming parser, already implemented
