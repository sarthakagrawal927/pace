# Pace v9 — body streaming wiring (Pace-side)

Status: partial (model-blocked). Counterpart to `tinygpt/docs/prds/pace-v9-body-streaming.md`. Pace now detects streaming `Mail.draft` planner JSON, opens the first draft through `mailto:` for fast recipient/subject setup, updates the visible Apple Mail draft while `body`/`bodyText` is still streaming through an AX-first body writer with typewriter/AppleScript fallback, finalizes that draft before executing remaining actions, and prewarms Mail at app launch behind `PrewarmMailForDrafts=true`. The manual latency demo remains queued.

Unblocks when: TinyGPT's trained v9 specialist (or any planner with body-token
streaming low enough to deliver the published latency numbers) replaces the
qwen3-30b-a3b MoE. The Pace-side wiring is complete; the demo is the cosmetic
final gate.

## Goal

When the user says "draft a mail to john about the project status", Pace should:
1. ASR → final transcript: ~150 ms
2. Open Mail compose in parallel via `mailto:to@addr?subject=...`: ~159 ms
3. Stream the LLM's `bodyText` field characters into the compose body field as the planner emits them: first body char visible in compose within ~700 ms of user stops talking
4. First spoken word: ~269 ms

Today: Pace can open Mail with `To:` filled but the body is empty (#264).

## Scope

In-scope for this PR:
- Wire streamed `body` / `bodyText` chunks into a Mail draft writer. Implemented through `PaceStreamingMailDraftDetector` plus `PaceActionExecutor.beginOrUpdateStreamingMailDraft`; the first draft opens through `mailto:` and body updates now prefer the Mail compose AX body writer before falling back to focused typing or AppleScript.
- Mail-app pre-warm at Pace startup so we hit the 85 ms warm-activate path, not the 1354 ms cold-launch. Implemented via `PrewarmMailForDrafts=true`, using non-activating `NSWorkspace` launch.
- Detect "compose intent" at the ASR layer (after final transcript) so we can launch `mailto:` URL in parallel with the planner SSE stream. Currently the planner is the sole decision point — by the time it returns intent, Mail has already lost 350+ ms.
- Update planner request to use the v9 system prompt + v9 grammar schema.

Out of scope (separate work):
- Notes / Slack / Messages compose paths (start with Mail; pattern generalizes)
- v9 LoRA quality regressions on existing fixtures — addressed by tinygpt eval matrix
- TTS streaming of `spokenText` partials — already covered by `PartialJSONStream.swift`

## Measured baselines from the tinygpt session 2026-06-08

| Path | Latency | Status |
|---|---|---|
| TTFW (Qwen3-0.6B + v8 LoRA + grammar, warm) | 119 ms | tinygpt fix shipped |
| `mailto:` URL → compose window visible | 159 ms | works, To: + subject populated |
| `mailto:?body=...` | 291 ms | **body silently dropped** by Mail's URL handler |
| AppleScript `make new outgoing message` | 2207 ms | works but 14× slower than mailto: |
| AX `setValue` on body text area | 156 ms | works when path matches Mail's AX tree (fragile across macOS versions) |
| `keystroke` into focused body (after tab+tab) | 202 ms | works, requires focus state |
| Mail.app warm activate | 85 ms | requires Mail already running |
| Mail.app cold launch | 1354 ms | first invocation per Mac session |

Implication: `mailto:` + AX/keystroke body fill is the only viable path. `mailto:?body=` is genuinely broken on this macOS.

## Architecture

### Mail pre-warm at Pace startup

In `pace/` app boot (or first push-to-talk press), eagerly launch Mail in the background if it isn't already running. No window shown — just the daemon. Cost: one-time 1354 ms eaten BEFORE the user issues a compose intent.

```swift
// In AppDelegate.applicationDidFinishLaunching or on first PTT press
NSWorkspace.shared.launchApplication(
    withBundleIdentifier: "com.apple.mail",
    options: [.withoutActivation, .withoutAddingToRecents],
    additionalEventParamDescriptor: nil,
    launchIdentifier: nil
)
```

### Early compose-intent detection (optional optimization)

If the final ASR transcript matches a compose pattern (`/\b(draft|write|compose|send|email|message|reply|note)\b/i`), kick off `mailto:to@addr?subject=...` in parallel with the planner request. The planner still owns the final decision; if it ALSO returns compose intent, we use the already-open window. If it returns non-compose (rare), we close the empty compose window.

To extract the recipient from raw ASR text BEFORE the planner replies, use a simple regex on the transcript:
```swift
// Last-resort heuristic; planner's bodyText/spokenText is the source of truth
let recipientPattern = /\b(?:to|email)\s+(\w+@\w+\.\w+|\w+)/i
```

For unstructured recipients ("draft a mail to john"), the planner will fill its `bodyText` field with the message; the To: field gets filled by Pace using its contacts lookup downstream (separate work; for now, fall back to opening Mail with empty To: and a pre-filled body).

### Body streaming pipeline

Reuse the existing `PartialJSONStream.swift` (already in `pace/leanring-buddy/PartialJSONStream.swift`):

```swift
let parser = PartialJSONStream()
let composeWriter = MailComposeWriter()

parser.onStart = { field in
    if field == "spokenText" {
        // TTS engine already wired
    } else if field == "bodyText" {
        composeWriter.beginBody()  // ensure compose window focused on body
    }
}

parser.onChunk = { field, text in
    if field == "spokenText" {
        tts.append(text)
    } else if field == "bodyText" {
        composeWriter.appendBody(text)  // AX setValue or keystroke
    }
}

parser.onComplete = { field, value in
    if field == "clickLabel" && !value.isEmpty {
        clickExecutor.click(label: value)
    } else if field == "pointAtLabel" && !value.isEmpty {
        hudOverlay.pointAt(label: value)
    }
}

// Feed SSE chunks from tinygpt serve
for chunk in sseStream {
    parser.feed(chunk)
}
```

### MailComposeWriter

Two strategies, AX-first with keystroke fallback:

```swift
final class MailComposeWriter {
    private var composeWindowID: AXUIElement?
    private var bodyTextArea: AXUIElement?
    private var bufferedBody: String = ""

    func beginBody() {
        // Find Mail compose window, locate body text area via AX
        // Try paths (varies across macOS versions):
        //   window > text area 1
        //   window > scroll area 1 > text area 1
        //   window > splitter group 1 > scroll area 1 > text area 1
        bodyTextArea = locateBodyTextArea()
    }

    func appendBody(_ chunk: String) {
        bufferedBody += chunk
        if let area = bodyTextArea {
            // AX setValue with the running buffer (idempotent)
            AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, bufferedBody as CFString)
        } else {
            // Fallback: keystroke the chunk into the focused element
            CGEvent.keyboardType(chunk)
        }
    }
}
```

The AX tree differs across macOS releases. Test on 14, 15, 26. If `locateBodyTextArea` fails, fall back to keystroke (after focusing the body via two tab keystrokes from the freshly-opened compose window).

### v9 schema integration

Pace's request to `tinygpt serve` now uses:
- System prompt: `pace-system-prompt-v9-compose.txt` (in tinygpt/grammars/)
- Grammar: `pace-fm-label-response-v9.schema.json`
- Same model dir: pace-planner-v9 once trained

The response schema becomes `{spokenText, pointAtLabel, clickLabel, bodyText}`. Existing code that consumes the first three fields keeps working unchanged.

## Estimated end-to-end after wiring

T0 = user stops talking. ASR final ~150 ms.

| Milestone | Time after T0 |
|---|---|
| Planner TTFW (first SSE chunk) | T0 + 269 ms |
| `mailto:` launched (early-intent detection) | T0 + 155 ms |
| Mail compose window visible | T0 + 309 ms (warm) |
| First spokenText char streaming to TTS | T0 + 290 ms (heard ~T0 + 400 ms after TTS pipeline latency) |
| First bodyText char written into compose | T0 + 700-800 ms |
| Full short body (~50 chars) | T0 + 1.2 s |
| Full draft (~200-char body) | T0 + 2.0-2.5 s |

## Test plan

Before merging:
1. Manual: voice "draft a mail to john about the project status" with Mail pre-warmed. Expect compose window open with To: filled and body actively typing within 700 ms of stop-talk.
2. Manual: same, but Mail not pre-warmed (cold). Expect 1.5–2 s additional delay (Mail cold launch). Acceptable on first-of-session; pre-warm covers steady-state.
3. Manual: "describe what's on my screen" (non-compose). Expect no compose window opens; bodyText stays empty per v9 grammar; spokenText flows through TTS as today.
4. Regression: existing v8 fixtures (click, knowledge Q&A) must keep passing on v9.

## Risks

- AX path detection differs across macOS versions. Mitigation: body-candidate scoring prefers large compose body elements, then falls back to focused typing and finally AppleScript if AX refuses the write.
- Privacy: AX requires accessibility permission. Pace already requests it; no new prompt.
- Window-focus race: if user clicks away during draft, our AX writes go to wrong window. Mitigation: track our window ID and silently abort if focus moved.
- Planner emits bodyText in non-compose case (regression in v9): wasted compose window. Mitigation: only open compose if spokenText looks like a draft intent AND bodyText non-empty.

## Counterpart in tinygpt

- v9 LoRA training: currently running (kicked off 2026-06-08). ETA depends on DoRA step rate. Will produce `pace-planner-v9.lora` + `baked-hf` dir.
- TTFW serve fix: shipped this session — token-bytes cached at boot, 330 ms → 119 ms warm.

## Done when

- Mail pre-warm wired at Pace boot. Implemented.
- `MailComposeWriter` implemented with AX-first + keystroke fallback. Implemented inside `PaceActionExecutor`: `mailto:` sets recipients/subject, AX writes the body when the compose element is available, focused typing is the local fallback, and AppleScript remains the slow reliability fallback.
- `PartialJSONStream` integrated end-to-end with `MailComposeWriter`. Partial: streamed planner text is detected incrementally by `PaceStreamingMailDraftDetector` and passed into the executor writer; the older flat `PartialJSONStream` helper is not the active nested-v10 parser.
- Fast `mailto:` setup for first draft. Implemented for recipient and subject; body remains out of the URL because Mail drops `mailto:?body=...` on this macOS.
- Pace request switched to v9 schema + v9 system prompt. Superseded by v10 typed `Mail.draft` parsing in the current Pace-side contract.
- Manual demo passes the four test cases above
- Latency measurement run: first-body-char ≤800 ms with Mail warm
