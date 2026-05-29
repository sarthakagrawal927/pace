#!/usr/bin/env bash
#
# eval-fm.sh — directly exercise Apple Foundation Models with the
# same system prompt + element map shape Pace sends, and print what
# the model emits.
#
# Why this exists
# ---------------
# The existing eval-pace.sh hits LM Studio over HTTP. It can't test
# the FoundationModels framework path because that runs in-process,
# requires macOS 26 + Apple Intelligence on the host, and isn't
# reachable via curl.
#
# Without an FM-direct test loop, every "did this fix actually work?"
# question costs a user rebuild. This script closes that loop:
# compile a tiny Swift program against the Pace source, run it
# through Foundation Models with whichever fixture, print the raw
# response. Lets us verify hallucination fixes, sampling changes,
# and prompt tweaks empirically before asking anyone to Cmd+R.
#
# Usage:
#   ./scripts/eval-fm.sh              # run all fixtures
#   ./scripts/eval-fm.sh click-file   # one fixture by name
#
# Fixtures live in evals/fm-fixtures/<name>.txt — a simple text
# format: lines starting "USER:" set the transcript, "ELEMENT:"
# lines are appended verbatim to the element map.

set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$PROJECT_DIR/evals/fm-fixtures"
SINGLE_FIXTURE_NAME="${1:-}"

if [[ ! -d "$FIXTURES_DIR" ]]; then
    echo "❌ Fixtures directory not found: $FIXTURES_DIR" >&2
    exit 2
fi

EVAL_SOURCE_FILE="$(mktemp -t pace-fm-eval.XXXXXX).swift"
cat > "$EVAL_SOURCE_FILE" <<'SWIFT_EOF'
import Foundation
import FoundationModels

// Typed schema — mirrors PaceFMTurnResponse in the Pace source. The
// whole point of this eval is to verify the typed path's behavior;
// can't reach into the Pace module from a one-shot Swift script so
// the schema is duplicated here intentionally.
@available(macOS 26.0, *)
@Generable
struct EvalFMTurnResponse {
    @Guide(description: "What to say to the user, read aloud by text-to-speech. One or two short casual sentences. Lowercase, no markdown.")
    let spokenText: String

    @Guide(description: "ID of an element from the on-screen list to point the cursor at. Use the integer in brackets from the element list. Use -1 if no element should be pointed at (pure knowledge questions, or target not in list).")
    let pointAtElementId: Int

    @Guide(description: "ID of an element to click. Use the integer in brackets from the element list. Use -1 if no click is requested or if the target is not in the element list. Only emit a non-negative value when the user explicitly asked to click, tap, or press something.")
    let clickElementId: Int
}

// Match the lean system prompt Pace ships today. Kept in sync with
// CompanionSystemPrompt.swift via the README; drift acceptable since
// this is a diagnostic tool, not a regression gate.
let baseVoiceRules = """
you are pace, a voice companion that lives in the user's menu bar. you are NOT siri, NOT apple intelligence, NOT a chatbot. you are pace. if the user asks who you are, who they are talking to, or whether you are siri, you must answer "i'm pace" — never "siri", never "apple intelligence".

the user just spoke to you via push-to-talk and you can see their screen. your reply is read aloud, so write the way you'd actually talk.

rules:
- default to one or two sentences. be direct.
- all lowercase, casual, warm. no emojis.
- write for the ear. no lists, no bullets, no markdown.
- if the question relates to what's on screen, reference what you see. otherwise just answer the question.
"""

let pointingRules = """
on-screen elements are given to you in this format, one per line:
    [N] role|x,y|label|text
where N is the integer element ID. POINT and CLICK fields take ONE of those integer IDs, or -1 for "no target".

- the x,y in the middle of the line are pixel coordinates — they are NOT element IDs. only the integer in brackets at the start of the line is the ID. do not confuse the two.
- spokenText is what's read aloud to the user. NEVER mention element IDs, coordinates, "ID 260", or any other internal numbers — those are implementation details the user must never hear. talk like a person, not a parser.

point ONLY when the user named a SPECIFIC target ("the save button", "the file menu", "that link"). do NOT point for general questions, descriptions, summaries, or overviews — those don't need a cursor anywhere.

decide which case the user's request falls into:

A. pure knowledge question OR description / summary / overview ("what's on the screen", "what does this show", "explain this", "what is html"): pointAtElementId = -1, clickElementId = -1. spokenText answers naturally. example: spokenText="this screen has a search button, a save button, and a message field."

B. user named a target that IS in the element list. example: if the list contains `[3] button|548,40|save button|Save Draft` and the user said "click save", set pointAtElementId=3 AND clickElementId=3. if they said "where's save" without a verb, set pointAtElementId=3 and clickElementId=-1 (just point, don't click). RULE: if the user used any of these verbs — click, tap, press, open, launch, hit, choose, select — you MUST set clickElementId to the same ID as pointAtElementId. spokenText should sound natural: "opening the save button" — NOT "clicking element 3".

C. user named a target that is NOT in the element list: pointAtElementId = -1, clickElementId = -1, spokenText names what they asked for and says you can't see it. example: spokenText="i can't see an elephant button on this screen."

case C is critical. picking a wrong but nearby element from the list is FORBIDDEN. picking arbitrary IDs is FORBIDDEN. the only acceptable response when the target is missing is to refuse cleanly with both IDs set to -1.
"""

let agentRules = """
agent mode — when the user asks you to *do* something, emit inline action tags. tags get stripped before TTS and executed in order.

available tags:
- [CLICK:x,y]               left-click at (x,y).
- [TYPE:exact text]         types into focused field.
- [KEY:Return]              press a named key. modifiers chain with +.
- [SCROLL:up:3]             scroll up 3 lines.

only emit action tags when the user clearly asked you to *do* something.
"""

let systemPrompt = baseVoiceRules + "\n\n" + pointingRules + "\n\n" + agentRules

// CLI args: fixture path + transcript + element map (the latter
// two come from the fixture file, parsed by the shell wrapper and
// passed through env vars to avoid argv length limits).
guard let transcript = ProcessInfo.processInfo.environment["PACE_FIXTURE_TRANSCRIPT"],
      let elementMap = ProcessInfo.processInfo.environment["PACE_FIXTURE_ELEMENT_MAP"] else {
    print("missing PACE_FIXTURE_TRANSCRIPT or PACE_FIXTURE_ELEMENT_MAP env vars")
    exit(2)
}

let userPrompt = """
On-device screen analysis (auto-extracted by a local vision model + native OCR):

=== primary focus ===
\(elementMap)

User said: \(transcript)
"""

// Check FM is actually available — same logic Pace uses to fall back
// gracefully when AI is off.
let modelAvailability = SystemLanguageModel.default.availability
switch modelAvailability {
case .available:
    break
case .unavailable(.appleIntelligenceNotEnabled):
    print("❌ Apple Intelligence is not enabled. Open System Settings → Apple Intelligence & Siri.")
    exit(3)
case .unavailable(.modelNotReady):
    print("⏳ Apple Intelligence model still downloading. Try again in a few minutes.")
    exit(3)
case .unavailable(.deviceNotEligible):
    print("❌ This Mac is not eligible for Apple Intelligence.")
    exit(3)
@unknown default:
    print("❓ Unknown FM availability: \(modelAvailability)")
    exit(3)
}

// Match Pace's planner config exactly so the eval reflects real behavior.
let session = LanguageModelSession(
    model: SystemLanguageModel.default,
    instructions: { systemPrompt }
)
let options = GenerationOptions(
    sampling: .greedy,
    temperature: 0,
    maximumResponseTokens: 400
)

let startedAt = Date()
let typedResponse: LanguageModelSession.Response<EvalFMTurnResponse>
do {
    typedResponse = try await session.respond(
        to: userPrompt,
        generating: EvalFMTurnResponse.self,
        options: options
    )
} catch {
    print("❌ FM error: \(error)")
    exit(4)
}

let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
print("─── PACE FM EVAL ───")
print("user said: \(transcript)")
print("element map:")
for line in elementMap.split(separator: "\n") {
    print("  \(line)")
}
print("───")
print("elapsed: \(elapsedMs)ms")
print("FM typed response:")
print("  spokenText      : \(typedResponse.content.spokenText)")
print("  pointAtElementId: \(typedResponse.content.pointAtElementId)")
print("  clickElementId  : \(typedResponse.content.clickElementId)")
print("─── END ───")
SWIFT_EOF

# Compile once; we'll re-run per fixture so the model warms.
COMPILED_EVAL_BIN="$(mktemp -t pace-fm-eval-bin.XXXXXX)"
xcrun swiftc \
    -target arm64-apple-macos26.0 \
    -O \
    -o "$COMPILED_EVAL_BIN" \
    "$EVAL_SOURCE_FILE"

run_one_fixture() {
    local fixture_path="$1"
    local fixture_name
    fixture_name=$(basename "$fixture_path" .txt)

    # Parse fixture: USER: line is the transcript, ELEMENT: lines
    # are appended (without prefix) to the element map. EXPECT_*
    # lines are scoring metadata and ignored by this script — the
    # Python harness in scripts/eval-planners.py reads them directly.
    # `|| true` is intentional: fixtures with no ELEMENT lines (e.g.
    # empty-screen-refuse) make grep return 1, which under `set -e
    # -o pipefail` would silently abort the whole loop.
    local transcript
    transcript=$({ grep -m1 '^USER: ' "$fixture_path" || true; } | sed 's/^USER: //')
    local element_map
    element_map=$({ grep '^ELEMENT: ' "$fixture_path" || true; } | sed 's/^ELEMENT: //')

    if [[ -z "$transcript" ]]; then
        echo "⚠️  Fixture $fixture_name has no USER: line — skipping"
        return
    fi

    echo
    echo "▶ Fixture: $fixture_name"
    PACE_FIXTURE_TRANSCRIPT="$transcript" \
        PACE_FIXTURE_ELEMENT_MAP="$element_map" \
        "$COMPILED_EVAL_BIN"
}

if [[ -n "$SINGLE_FIXTURE_NAME" ]]; then
    FIXTURE_PATH="$FIXTURES_DIR/$SINGLE_FIXTURE_NAME.txt"
    if [[ ! -f "$FIXTURE_PATH" ]]; then
        echo "❌ Fixture not found: $FIXTURE_PATH"
        exit 2
    fi
    run_one_fixture "$FIXTURE_PATH"
else
    for fixture_path in "$FIXTURES_DIR"/*.txt; do
        [[ -e "$fixture_path" ]] || continue
        run_one_fixture "$fixture_path"
    done
fi

rm -f "$EVAL_SOURCE_FILE" "$COMPILED_EVAL_BIN"
