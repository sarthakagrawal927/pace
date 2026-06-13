---
Status: shipped (v0.3.11)
owner: delegated to Sonnet agent
priority: P1 — Poke-style templated automation; multiplier on the just-shipped flow-replay PRD
---

# PRD — Recipe Library (curated, installable Pace flows)

## Goal

Ship a small library of pre-built `PaceFlow` definitions ("recipes")
that the user can install with one command or one click, instead of
having to demonstrate every flow themselves. Maps directly to
Poke's Recipes system. Builds on the just-landed flow-replay
infrastructure.

## Scope (v1)

Five bundled recipes, all installable from Settings → Flows OR via
voice ("install the morning standup recipe"). Each recipe is a
JSON file shipped inside the app bundle under
`Resources/recipes/<slug>.json`, schema-identical to user-recorded
flows so the same `PaceFlowStore` + `PaceFlowReplayer` paths run them.

### The five recipes

| Slug | Display name | What it does |
|---|---|---|
| `morning-standup-setup` | "Morning standup setup" | Activate Slack → press cmd+K → type "standup" → wait → activate Calendar app. |
| `weekly-review-draft` | "Weekly review note" | Activate Notes → create a new note titled "weekly review — <today>" → type a bulleted template (wins, blockers, next week). |
| `email-zero` | "Inbox triage pass" | Activate Mail → cmd+1 (inbox) → say "let me know what's worth opening" — Pace then describes the visible inbox via VLM. |
| `focus-mode-on` | "Focus mode on" | Activate Do Not Disturb (via Shortcut.run "Set Focus") → activate Music → play the user's preferred focus playlist (read from PaceLocalMemoryStore key `preferredFocusPlaylist`). |
| `end-of-day-shutdown` | "End-of-day shutdown" | Activate Calendar → screenshot tomorrow → speak the brief → activate Reminders → cmd+N → type "review tomorrow's calendar" (creates a follow-up reminder). |

Recipes that depend on user state (preferred playlist, etc.) read
from `PaceLocalMemoryStore` at install time and bake the value in
— so a missing preference produces a clear validation error
("install the playlist preference first") instead of a runtime
crash.

Out of scope for v1: user-shareable recipes (export/import),
recipe marketplace, branching/conditional recipes, parameterized
recipes (those become a v2 spec).

## Architecture

### New directory: `leanring-buddy/Resources/recipes/`

Five JSON files, one per recipe. Schema (must match
`PaceFlowStore`'s on-disk shape so installation is a copy):

```json
{
  "name": "morning standup setup",
  "slug": "morning-standup-setup",
  "description": "Opens Slack to your standup channel and pulls today's calendar.",
  "displayCategory": "morning",
  "createdAt": "2026-06-12T00:00:00Z",
  "steps": [
    {"kind": "activateApp", "bundleIdentifier": "com.tinyspeck.slackmacgap"},
    {"kind": "keyShortcut", "key": "cmd+k"},
    {"kind": "typeText", "text": "standup", "secure": false},
    {"kind": "keyShortcut", "key": "return"},
    {"kind": "activateApp", "bundleIdentifier": "com.apple.iCal"}
  ],
  "secureFieldDefaults": {},
  "requiredPreferences": []
}
```

`requiredPreferences` is new — array of `PaceLocalMemoryKey` raw
values the recipe needs to be set before install can succeed.

### New file: `leanring-buddy/PaceRecipeLibrary.swift` (~280 lines)

Pure module that lists bundled recipes, validates them at
startup, and installs them into `PaceFlowStore`.

```swift
struct PaceBundledRecipe: Equatable, Codable {
    let name: String
    let slug: String
    let description: String
    let displayCategory: String  // "morning", "work", "shutdown"
    let steps: [PaceFlowStore.Step]
    let requiredPreferences: [String]
}

enum PaceRecipeLibrary {
    static let bundleResourceDirectory: String = "recipes"

    static func loadBundledRecipes(bundle: Bundle = .main) -> [PaceBundledRecipe]
    static func install(_ recipe: PaceBundledRecipe,
                        into store: PaceFlowStore,
                        memoryStore: PaceLocalMemoryStore.Type = PaceLocalMemoryStore.self) throws
    static func uninstall(slug: String, from store: PaceFlowStore)
    static func validateBundledRecipes(bundle: Bundle) -> [PaceRecipeValidationIssue]
}

enum PaceRecipeInstallError: Error {
    case missingRequiredPreference(String)
    case alreadyInstalled(String)
}
```

`install(...)` checks `requiredPreferences` against
`PaceLocalMemoryStore` — if any are missing/empty, throws
`missingRequiredPreference`. Otherwise it serializes the recipe
to the same JSON shape `PaceFlowStore` already writes and saves
under the recipe's slug.

### New file: `leanring-buddy/PaceRecipeCommandParser.swift` (~80 lines)

Pure parser for voice commands. Recognizes:
- "install the <recipe display name> recipe" / "add the <name> flow"
- "remove the <name> recipe" / "uninstall <name>"
- "list recipes" / "what recipes do you have"

Returns a `PaceRecipeCommand` enum the CompanionManager routes
before the planner.

### Modify: `leanring-buddy/CompanionManager.swift`

- New private function `handleRecipeCommand(_:transcript:)` that
  installs/removes/lists, then synthesizes the spoken response
  through `handleImmediateLocalModeResponse`.
- In the existing transcript intake (before the planner is invoked),
  call `PaceRecipeCommandParser.parse(transcript)`. If it returns
  a command, handle it and short-circuit.

### Modify: `leanring-buddy/PaceSettingsWindow.swift`

In the existing "Flows" tab (added by the flow-replay PRD), add a
new section ABOVE the user-recorded flows list: "Recipe library".
Show each bundled recipe as a row with:
- Display name + 1-line description
- "Install" button (or "Installed ✓ · Uninstall" if already
  present in PaceFlowStore)
- Disabled state with tooltip when `requiredPreferences` aren't met

### Modify: `leanring-buddy/PaceToolRegistry.swift`

Add startup validation: `validateBundledRecipes(bundle:)` is
called from `validateForAppStartup`. Any issue → fail-fast
crash with the issue text, same pattern as the registry's own
drift check. Recipe JSON drift is detected before the user can
interact with them.

### Modify: `leanring-buddy/CompanionSystemPrompt.swift`

In the agent-mode rules block, append a small example showing the
planner can suggest a recipe ("you can install the 'morning
standup setup' recipe for this"). Keep it ≤2 lines of prompt — the
recipes are user-installed, not planner-installed.

## Acceptance criteria

- [ ] Five recipe JSON files present and parse cleanly.
- [ ] `bash scripts/test-pace.sh` green; new
      `PaceRecipeLibraryTests` cover load/install/uninstall,
      missing-preference error, alreadyInstalled error, and
      validateBundledRecipes catches a fixture with bad shape.
- [ ] Voice command "install the morning standup recipe" installs
      the recipe and Pace says "installed."
- [ ] Settings → Flows shows the Recipe library section with
      install/uninstall toggles per recipe.
- [ ] Startup validation catches a corrupted bundled recipe
      (test injects a malformed fixture).
- [ ] After install, the recipe shows up in the user-recorded
      flows list and `run_flow` tool can execute it.

## Implementation order (for the agent)

1. `PaceBundledRecipe` schema + `PaceRecipeLibrary` core (load,
   validate) — write the 5 JSON files alongside.
2. Unit tests for library load + install.
3. `PaceRecipeCommandParser` + tests.
4. `CompanionManager` routing.
5. Settings UI section.
6. Startup validation wiring.
7. System prompt 2-line update.
8. AGENTS.md: Key Files row for `PaceRecipeLibrary.swift`,
   mention in the recipe section.
9. `bash scripts/test-pace.sh` green. Commit. **Don't release.**

## What NOT to do

- Don't add planner-driven recipe execution — recipes run via the
  existing `run_flow` tool by name, no new tool kind.
- Don't add export/share — keep recipes bundled-only in v1.
- Don't make recipes mutable from voice (no "edit the standup
  recipe" command) — they're install/uninstall only. User edits
  happen by uninstalling and re-recording.

Where in code: `leanring-buddy/PaceRecipeLibrary.swift` (loader + install/uninstall
+ `requiredPreferences` gating), `leanring-buddy/PaceRecipeCommandParser.swift`
(install/uninstall/list voice parser). Bundled JSONs under
`leanring-buddy/Resources/recipes/` (morning-standup-setup, weekly-review-draft,
email-zero, focus-mode-on, end-of-day-shutdown).
