# Pace Roadmap

This is the current local roadmap. Pace has local tools today; it does not yet
ship MCP integrations.

## Priority 1: Approval And Safety

Status: implemented; Xcode suite passing, manual runtime verification still needed.

- Ask before executing local tool calls.
- Keep approval default-on.
- Add clearer risk labels for actions: read-only, app/system mutation,
  input injection, and destructive.
- Keep `EnableActions` as the hard kill switch.

## Priority 2: Typed Tool Registry

Status: implemented.

- Move tools out of prompt text and parser switch cases into a typed registry.
- Each tool should define name, schema, description, risk level, executor, and
  observation formatter.
- Generate planner prompt tool docs from the registry.
- Use the registry as the bridge point for future MCP-backed tools.

## Priority 3: Apple App Integrations

Status: implemented for first local tool pass; needs runtime verification per app.

- Calendar and Reminders exist as local EventKit tools.
- Things, Notes, Mail drafts, Finder, Shortcuts, and Messages opening are
  registered as local tools.
- Prefer local macOS APIs or AppleScript only when the app does not expose a
  better native API.

## Priority 4: Watch Mode

Status: implemented with panel and explicit voice triggers.

- `PaceScreenImageDiffer` exists as the screen-change primitive.
- `PaceScreenWatchModeController` samples the screen and emits events only when
  the image diff crosses a meaningful threshold.
- The first watch mode is explicit through the `Watch Mode` panel toggle. Pace
  reports meaningful screen changes while it is on.
- Voice commands such as "watch my screen" and "stop watching" toggle watch
  mode before the planner/VLM pipeline.

## Priority 5: Local Intent Classifier

Status: implemented as a rule-based scaffold.

- Add a tiny local classifier for routing turns into:
  - answer directly
  - read screen
  - execute tool
  - phone large model
- Pure-knowledge turns now use a text-only planner path to avoid unnecessary
  screen capture/VLM work.
- Phone-large-model is classified and logged, but there is intentionally no
  cloud model transport wired yet.

## Priority 6: Tests

Status: implemented for unit/build coverage; manual runtime smoke coverage still needed.

- Keep parser and image-diff tests current.
- Parser tests cover registry aliases and Apple app tool parsing.
- Image-diff tests cover watch-mode change throttling.
- Intent tests cover the route mapping.
- Watch-mode command tests cover explicit start/stop routing.
- Latest Xcode test run passed 112 tests after local test-target signing cleanup.
- Still needed: physical smoke tests for approval prompts and action cancellation.
