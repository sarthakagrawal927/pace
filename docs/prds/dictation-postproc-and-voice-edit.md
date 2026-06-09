# Dictation post-processing and voice edit

Status: partial (2026-06-09). A rule-backed dictation post-processing scaffold
is wired for `intent:"dictate"` and a deterministic selected-text voice-edit
scaffold is wired for common edit commands; the trained dictation and
voice-edit specialists remain queued.

## Goal

Make Pace useful as a fast writing companion:

- Clean up raw dictation into correctly punctuated text.
- Preserve code symbols and product names.
- Rewrite selected text on command.
- Apply edits through AX without using the pasteboard.
- Keep first visible text update under the interaction latency targets in
  `docs/architecture.md`.

## Why This Exists

Raw ASR is not enough for writing. Users need:

- "Make that shorter."
- "Rewrite this more formal."
- "Delete the last sentence."
- "Dictate: the function is called parse action payload."
- "Change this paragraph to say we ship locally only."

These are not generic chat turns. They are local text transformations with a
focused target and a reversible mutation.

## Scope

In scope:

- Dictation post-processing model path.
- Voice-edit model path for selected or focused text.
- AX selected-text read and write.
- Undo metadata for AX text mutations.
- Code-mode vocabulary and punctuation handling.

Implementation note, 2026-06-09: `PaceDictationPostProcessor` now runs on the
existing v10 `intent:"dictate"` parser path. It handles common spoken
punctuation, basic prose capitalization, and a first code-mode cleanup for
function-call phrases such as "parse action payload open paren args close
paren" -> `parseActionPayload(args)`. `PaceVoiceEditProcessor` now handles
common selected-text edits without a model call: shorten, make direct, fix
grammar, replace X with Y, delete last sentence, and turn into bullets. The
executor reads selected text through AX, writes the replacement through the
existing AX set-value path, and records undo metadata. Richer edit modeling and
dictation cleanup are still queued.

Out of scope:

- Cloud editing models.
- Collaborative docs integrations.
- Secure text fields.
- Rich text formatting beyond plain text v1.
- Full document understanding beyond selected/focused text plus local RAG
  snippets.

## Intents

| Intent | Input | Output | Target |
|---|---|---|---|
| `dictate` | ASR transcript | Clean text | Focused text field |
| `edit` | Selected/focused text + command | Replacement text | Selection or focused field |
| `answer` | Question | Spoken answer | No text mutation |
| `action` | Command | Tool payload | Executor |

The planner v10 contract may initially carry these intents. A smaller local
intent classifier can take over once it is accurate enough.

## AX Text Rules

Primary write path:

1. Read focused element.
2. Read `AXSelectedTextRange` and selected text when available.
3. Generate replacement.
4. Set selected range.
5. Set selected text or value through AX.
6. Record old value/range for undo.

Fallback:

- `CGEventKeyboardSetUnicodeString` typewriter mode for non-AX fields.

Banned:

- NSPasteboard plus command-V.

## Dictation Post-Processor

Inputs:

- Stable ASR transcript.
- Contextual vocabulary.
- Optional app mode: prose, code, chat, email.

Outputs:

- Clean text.
- Confidence.
- Optional no-op when raw ASR should be inserted unchanged.

Examples:

| Raw | Clean |
|---|---|
| `lets ship local only comma no cloud fallback` | `Let's ship local-only, no cloud fallback.` |
| `parse action payload open paren args close paren` | `parseActionPayload(args)` in code mode. |

## Voice Edit Specialist

Inputs:

- User command.
- Selected text or focused text excerpt.
- Optional local RAG snippets.

Outputs:

- Replacement text.
- Short spoken confirmation or empty string.
- Refusal when no editable target exists.

Examples:

- "Make this more direct."
- "Turn this into bullets."
- "Fix grammar only."
- "Replace Sarthak with team."

## Latency Targets

| Path | Target Visible Feedback |
|---|---|
| Plain dictation first char | < 100 ms after stable partial. |
| Dictation final cleanup | < 150 ms after final transcript. |
| Short selected-text edit | < 500 ms full replacement. |
| Long rewrite | < 200 ms first replacement feedback, stream if possible. |

## Safety

- Refuse secure text fields.
- Keep mutations local.
- Record undo for every successful AX text replacement.
- Do not send selected text to analytics.
- Ask before replacing unusually large selections unless the command is
  explicit.

## Tests

Unit tests:

- AX selection replacement builds correct old/new mutation.
- Secure text fields are refused.
- Code-mode phrase normalization preserves symbols.
- Edit intent refuses when no target text exists.
- Undo restores previous AX value in a dry-run executor.

Current coverage: `PaceVoiceEditProcessorTests` covers command parsing and
deterministic transforms. `PaceActionTagParserTests` covers v10 command-based
edit payloads and fast local selected-text edit commands.

Eval fixtures:

- Punctuation cleanup.
- Code symbol repair.
- Formality rewrite.
- Shortening rewrite.
- Delete/replace instruction.
- No-op when user asks a question about text instead of editing it.

## Done When

- Dictation and edit intents have separate code paths from generic answer.
- AX setValue path is primary and pasteboard remains unused.
- At least one local post-processing model or rule-backed scaffold is wired.
- Selected-text edit works in a standard text field and a web/Electron field
  fallback. Partial: the AX selected-text set-value path is wired; real app
  smoke remains queued.
- Undo works for AX value replacement.

## References

- `docs/architecture.md`
- `docs/prds/pace-planner-v10-parameterized-actions.md`
- `leanring-buddy/PaceActionExecutor.swift`
- `leanring-buddy/PaceVoiceEditProcessor.swift`
- `leanring-buddy/PaceAXTargeter.swift`
- `leanring-buddy/PacePushToTalkManager.swift`
