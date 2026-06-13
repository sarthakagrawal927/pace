# Local VLM runtime port

Status: partial (model-blocked). The screen-analysis provider abstraction,
configurable runtime selection, in-process placeholder, and LM Studio fallback
are wired. Screen-context cache entries are invalidated by analyzer identity and
display geometry. Missing VLM descriptions are synthesized from element labels
and included in planner prompt sections. The real CoreML/MLX in-process VLM
runtime remains queued.

Unblocks when: a CoreML- or MLX-bundled UI-Venus / Qwen3-VL artifact passes the
eval gate and ships with the app bundle. Until then `ScreenAnalysisProvider`
selections (`inProcess` / `coreML` / `mlx`) all fall back to LM Studio HTTP.

## Goal

Pace should understand the current screen without a model server:

- Capture screen locally.
- Run a bundled or user-installed local VLM in-process.
- Merge VLM elements with Apple Vision OCR.
- Return structured screen context to the planner.
- Keep all bytes on the Mac.

## Current State

`LocalVLMClient` sends a screenshot to an OpenAI-compatible endpoint, usually
LM Studio on `localhost:1234`. `PaceVisionOCRClient` already provides local OCR,
and `PaceScreenContextMerger` enriches VLM elements with OCR text.

This is acceptable for development, but production Pace should not depend on an
external HTTP server for the screen-understanding hot path.

Implementation note, 2026-06-09: `ScreenAnalysisProvider` in Info.plist selects
`lmStudio` by default. `inProcess` / `coreML` / `mlx` are accepted by
`PaceScreenAnalysisClientFactory`; until a real runtime bridge is available,
they fall back to the LM Studio HTTP client. `CompanionManager` now uses the
`PaceScreenAnalysisClient` abstraction at both in-loop and prewarmed screen
analysis call sites. `LocalVLMScreenAnalysis` preserves model-provided
descriptions when present, but synthesizes a compact deterministic description
from element text/labels when the 2B VLM omits or nulls the field. Prompt
formatting now includes that summary above the compact element map.

## Scope

In scope:

- New in-process VLM client behind the existing screen-analysis abstraction.
- Model readiness and load status in settings.
- Same `LocalVLMScreenAnalysis` output shape as the current HTTP client.
- OCR merge retained.
- Screen-context cache retained.

Out of scope:

- Training the VLM.
- Cloud VLM fallback.
- Broad UI automation changes.
- Replacing ScreenCaptureKit.
- Shipping multiple large vision models by default.

## Runtime Options

Preferred order:

1. CoreML/ANE port when the selected model can run there.
2. MLX-Swift local runtime when CoreML is not viable.
3. LM Studio HTTP as development fallback only.

The production default should not require the user to run LM Studio.

## Output Contract

Keep the current structured shape:

```json
{
  "description": "A Mail compose window...",
  "elements": [
    {
      "id": "send-button",
      "role": "button",
      "label": "Send",
      "text": "Send",
      "boundingBox": {"x": 10, "y": 20, "width": 44, "height": 22}
    }
  ]
}
```

Coordinates stay in screenshot pixel space until Pace maps them to display
coordinates.

## Model Requirements

The selected VLM must:

- Identify buttons, text fields, menus, and list rows.
- Return bounding boxes stable enough for click/point planning.
- Defer verbatim text to OCR when unsure.
- Avoid hallucinating invisible elements.
- Run warm without evicting the planner model.

## Latency Targets

| Operation | Target |
|---|---|
| Model warm load | Background at app launch. |
| Single-frame analyze, common screen | <= 200 ms target, <= 500 ms acceptable v1. |
| OCR merge | <= 100 ms. |
| Cache hit after trivial screen change | <= 20 ms. |

## Cache And Skip Rules

Retain current behavior:

- Skip VLM for pure Q&A turns.
- Reuse cached screen context when `PaceScreenImageDiffer` says the screen has
  not meaningfully changed.
- Allow a debug override to force VLM every turn.

Add:

- Runtime model version in cache keys. Implemented via active analyzer display
  name, which includes provider/runtime and model identifier.
- Screen scale and display id in cache keys. Partial: screenshot dimensions,
  display point dimensions, and display frame are included in cache identity.
- Clear fallback status when the in-process model fails and dev fallback is
  used.

## Permission And Privacy

- Requires Screen Recording / Screen Content permissions.
- Screenshots are never persisted by default.
- Debug image dumps must require explicit opt-in and a local path.
- No analytics event may include screenshot, OCR text, or element labels.

## Tests

Unit tests:

- Decoder compatibility with current `LocalVLMScreenAnalysis` fixtures.
- OCR merge still enriches overlapping boxes.
- Cache invalidates on model version change. Implemented for the manager cache
  identity used by synchronous and prewarm paths.
- Pure-Q&A heuristic skips VLM.
- Missing/null description compatibility and synthesized-description fallback.
  Implemented in `LocalVLMScreenAnalysisDecoderTests`.

Manual tests:

- Mail compose screen.
- Browser form with repeated labels.
- Cursor/Xcode editor with sidebar and tabs.
- Unknown creative app where OCR is strong but semantic roles are weak.

## Done When

- Pace can run screen analysis without LM Studio for at least one qualified VLM.
- Output shape is compatible with current planner prompt injection.
- OCR merge, description fallback, and cache tests pass.
- Settings reports model installed/loading/ready/error states.
- Dev-only LM Studio fallback is clearly labelled and not required for normal
  setup.

Current partial status: the fallback is clearly selectable and labelled, but
LM Studio remains required for VLM-backed screen analysis until the in-process
runtime bridge is implemented.

## References

- `leanring-buddy/LocalVLMClient.swift`
- `leanring-buddy/PaceVisionOCRClient.swift`
- `leanring-buddy/PaceScreenImageDiffer.swift`
- `leanring-buddy/CompanionManager.swift`
- `docs/architecture.md`
