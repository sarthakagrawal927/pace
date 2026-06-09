# Pace planner v10 - parameterized actions

Status: partial (2026-06-09). Counterpart to the Pace executor surface PRD and the
TinyGPT-side v10 action registry. Pace now documents and parses the typed v10
envelope, validates the bundled registry artifact at app startup, keeps legacy
tags working, routes `Mail.draft` plus the broader v1 local action set through
typed payloads, and streams `Mail.draft` body text before final JSON closes.
The JSON planner-response envelope is schema-checked before action parsing, and
the typed `{name,args}` path plus `<tool_calls>` path reject malformed local
actions before execution when required fields or enum-like values are
missing/invalid. Runtime default switch remains gated on local evals/manual
smokes.

## Goal

Move Pace from label/action tags to a typed planner response:

```json
{
  "spokenText": "Drafting that now.",
  "intent": "action",
  "payload": {
    "name": "Mail.draft",
    "args": {
      "to": ["john"],
      "subject": "Project status",
      "body": "Quick update..."
    }
  }
}
```

The model decides intent and parameters. Pace validates the payload, dispatches
through local handlers, and never executes unknown action names.

## Why Now

The current tag dialect works for pointing, simple clicks, typing, and local
tools, but it is too stringly typed for fast compose/edit flows. v9 adds body
streaming for Mail. v10 generalizes that shape so all high-value actions have
structured args, grammar-constrained decoding, and one executor dispatch path.

## Non-Goals

- No cloud model fallback.
- No multi-turn ReAct loop in the hot path.
- No marketplace or user-defined action SDK.
- No pasteboard-based text injection.
- No broad app automation beyond the v1 action registry.

## Response Contract

Top-level fields:

| Field | Type | Required | Notes |
|---|---|---|---|
| `spokenText` | string | yes | Short user-facing response. Empty is allowed for routine actions where the action is the feedback. |
| `intent` | enum | yes | One of `action`, `answer`, `dictate`, `edit`. |
| `payload` | object | yes | Shape depends on `intent`. |

Intent payloads:

| Intent | Payload |
|---|---|
| `action` | `{ "name": string, "args": object }` |
| `answer` | `{ "answer": string }` or `{}` when `spokenText` carries the answer |
| `dictate` | `{ "text": string, "target": "focused" }` |
| `edit` | `{ "operation": string, "replacement": string?, "target": "selection" \| "focused" }` |

The planner may later emit `{ "calls": [{ "name": string, "args": object }] }`
for parallel actions. v1 Pace accepts the schema but executes only a single
action call unless the executor PRD explicitly enables grouped dispatch.

## v1 Action Registry

The canonical action names and schemas live in TinyGPT's v10 registry. Pace
must bundle a copy and validate every planner action against it at boot.

Minimum v1 actions:

| Action | Purpose |
|---|---|
| `AX.press` | Press a visible accessible element by label or element id. |
| `AX.setValue` | Set focused or labelled text field value without using pasteboard. |
| `AX.scroll` | Scroll focused or frontmost region. |
| `App.launch` | Launch or activate a local app. |
| `Mail.draft` | Open Mail compose with recipient, subject, and streamed body. |
| `Calendar.createEvent` | Create a local calendar event through EventKit. |
| `Reminders.add` | Add a local reminder through EventKit. |
| `Notes.create` | Create a local Apple Notes note. |
| `Shortcut.run` | Run an installed local Shortcut. |
| `Window.snap` | Move/resize the focused window. |
| `Clipboard.read` | Read clipboard text only when the user explicitly asks. |
| `Finder.reveal` | Reveal a local path or search result in Finder. |

## Prompt Requirements

The v10 system prompt must:

- Prefer `action` only when the user requests a concrete local change.
- Prefer `answer` for knowledge or explanation turns.
- Prefer `dictate` for raw text insertion.
- Prefer `edit` when the user refers to selected or focused text.
- Keep `spokenText` short.
- Emit no action for sensitive or unsupported requests.
- Never invent apps, contacts, file paths, or configured MCP servers.

## Streaming Requirements

For compose and edit actions, the planner should stream the largest text field
as early as possible:

- `Mail.draft.args.body`
- `AX.setValue.args.value`
- `dictate.payload.text`
- `edit.payload.replacement`

Pace should consume these through `PartialJSONStream` when possible. The final
JSON object is still authoritative for validation and logging.

## Safety Requirements

- All action names must validate against the bundled registry.
- All args must validate against the action schema before dispatch.
- Destructive or externally visible actions require approval unless the user
has explicitly changed the policy.
- Unknown action names are refusal/no-op, not best-effort execution.
- Secure text fields are out of scope.

## Evaluation

Add or reuse fixtures that cover:

- Answer-only turns that do not call tools.
- Click/open actions with precise target names.
- Mail draft with recipient, subject, and body.
- Dictation into a focused field.
- Editing selected text.
- Refusal for unsupported or sensitive actions.
- Ambiguous actions where the planner asks a short clarification instead of
guessing.

Minimum gate before runtime switch:

| Eval Set | Required |
|---|---|
| Existing fm fixtures | No regression from current planner baseline. |
| Compose fixtures | Body present and appropriate in at least 90 percent of cases. |
| Action schema fixtures | 100 percent schema-valid output under grammar-constrained decode. Deterministic parser/schema fixtures are wired and pass via `scripts/eval-v10-schema-fixtures.py`; model-output grammar gate remains queued. |
| Holdout app fixtures | No more than one unsafe or unsupported action emission. |

## Implementation Slice

1. Bundle the v10 registry and schema into the app resources. Implemented for the action registry artifact and planner response schema artifact.
2. Add a v10 planner response decoder beside the existing tag parser. Implemented inside `PaceActionTagParser` while keeping the legacy parser surface.
3. Keep legacy tags working while v10 rolls out. Implemented.
4. Route one action, `Mail.draft`, through the new payload path. Implemented with streaming detection/finalization.
5. Expand to the rest of the v1 registry after the executor surface lands. Partial: v1 local actions parse to existing executor actions; the v10 JSON envelope is schema-checked; typed `{name,args}` payloads and `<tool_calls>` now have pre-dispatch required-field/enum validation; deterministic v10 schema fixtures are wired and passing; grammar-constrained model eval gates remain queued.

## Done When

- v10 schema is documented, bundled, and validated at app boot. Partial: the action registry and planner response schema artifacts are bundled and checked at startup, the final JSON planner-response envelope is checked before parsing, local planner-output action arguments are checked before dispatch, and deterministic schema fixtures pass; grammar-constrained model schema eval gates remain queued.
- Planner streaming can expose body/value chunks before final JSON closes. Partial: `Mail.draft` body streaming is wired; generic value/edit/dictate streaming remains queued.
- Legacy tag parsing still passes current tests. Implemented in targeted parser coverage.
- `Mail.draft` works through the typed payload path in a stubbed planner test. Implemented.
- The runtime default is switched only after the eval gates pass locally. Still queued.

## References

- `docs/architecture.md`
- `docs/prds/pace-v9-body-streaming-wiring.md`
- `docs/prds/pace-executor-surface.md`
- `leanring-buddy/PartialJSONStream.swift`
- `leanring-buddy/PaceActionExecutor.swift`
- `leanring-buddy/PaceToolRegistry.swift`
- `leanring-buddy/Resources/v10-actions/pace-fm-response-v10.schema.json`
- `scripts/eval-v10-schema-fixtures.py`
- `evals/v10-schema-fixtures/*.json`
