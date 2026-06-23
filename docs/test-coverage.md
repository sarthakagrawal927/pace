# Test Coverage — EXEMPLARY Tier

Pace holds itself to an **EXEMPLARY** testing standard. The project ships
818 Swift tests across 103 files, and coverage is measured on every CI
run and available locally with a single flag. This document is the
canonical home for coverage goals, per-component targets, how to measure
coverage locally, and how CI enforces it.

## Tier goals

| Scope | Target | Rationale |
| --- | --- | --- |
| **Core logic** (non-UI, deterministic) | **> 80%** line coverage | Parser, executor, memory, planner clients — these are the trust surface. A missed branch here is a silent regression in what Pace *does*. |
| **UI** (SwiftUI views, overlays, panels) | **> 70%** line coverage | Views are partially exercised by SwiftUI previews and integration paths; the bar is lower because visual correctness is verified by humans, not just lines. |

These are floors, not ceilings. New core-logic code is expected to land
with tests that exercise its branches; PRs that drop a component below
its target are flagged for follow-up.

## Per-component targets

The targets below are derived from each component's blast radius — the
wider the consequences of a bug, the higher the bar.

| Component | Target | Key files |
| --- | --- | --- |
| **Tag parser** (`[CLICK:…]`, `[POINT:…]`, `<tool_calls>`) | **> 85%** | `PaceTagParsers`, `PaceActionTagParser`, `PaceToolCallParser` |
| **Action executor** (clicks, typing, scroll, AX fallback) | **> 85%** | `PaceActionExecutor`, `PaceAXTargeter`, `PaceActionApproval` |
| **Memory** (thread memory, summarizer, durable store) | **> 80%** | `PaceThreadMemory`, `PaceThreadSummarizer`, `PaceThreadMemoryStore` |
| **Planner clients** (local, Apple FM, cloud bridge, direct API) | **> 80%** | `LocalPlannerClient`, `AppleFoundationModelsPlannerClient`, `BuddyPlannerClientFactory` |
| **TTS** (Kokoro sidecar + AVSpeechSynthesizer fallback) | **> 75%** | `LocalServerTTSClient`, `LocalTTSClient`, `BuddyTTSClient` |
| **MCP integration** (stdio bridge, catalog installer) | **> 75%** | `PaceMCPClient`, `PaceMCPCatalogInstaller`, `PaceToolPreflight` |
| **Screen capture / watch mode** | **> 70%** | `PaceScreenCaptureService`, `PaceScreenWatchModeController`, `PaceScreenImageDiffer` |
| **UI / overlays / panels** | **> 70%** | `PaceMenuBarOverlay`, `PaceMainWindow`, `PacePrivacyDashboardView`, `PaceUndoBanner` |
| **Recipe library / flows** | **> 75%** | `PaceRecipeLibrary`, `PaceRecipeCommandParser`, `PaceFlowStore` |
| **Failure narration / restraint gate** | **> 80%** | `PaceFailureNarrator`, `PaceRestraintGate` |

A component is considered "on target" when its line coverage in the most
recent CI run meets or exceeds the value in the **Target** column.

## Running coverage locally

The test runner script accepts a `--coverage` flag that enables
`CLANG_ENABLE_CODE_COVERAGE=YES` on the `xcodebuild` invocation and
prints a per-target line-coverage summary after the suite finishes:

```bash
./scripts/test-pace.sh --coverage
```

You can combine the flag with a test filter:

```bash
./scripts/test-pace.sh --coverage PaceTagParsersTests
```

The script builds into an **isolated** DerivedData path
(`/tmp/pace-test-derived-data`) so it never touches the interactive
`Pace.app` you launch from Xcode (and therefore never invalidates TCC
grants). After the run, the full JSON coverage report is written to:

```
/tmp/pace-test-derived-data/coverage-report.json
```

### Reading the raw report

`xcrun xccov` is the supported tool for inspecting `.xcresult` coverage
data. To get a per-file breakdown for a single target:

```bash
xcrun xccov view --file-for-target Pace \
    /tmp/pace-test-derived-data/pace-tests.xcresult
```

To export the full report as JSON (what the script does internally):

```bash
xcrun xccov view --report --json \
    /tmp/pace-test-derived-data/pace-tests.xcresult > coverage-report.json
```

## CI coverage enforcement

Coverage is collected on every push and pull request by the `macos` job
in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml):

1. **Build for testing** with `CLANG_ENABLE_CODE_COVERAGE=YES` so the
   compiler emits coverage instrumentation into the test binary.
2. **Test without building** with the same flag so the run records
   coverage data into the `.xcresult` bundle.
3. **Extract coverage** — the `Extract coverage` step locates the
   `.xcresult` bundle under `~/Library/Developer/Xcode/DerivedData`,
   runs `xcrun xccov view --report --json` against it, and prints a
   per-target line-coverage summary to the job log. Both the `xccov`
   call and the Python summary parser are wrapped in `|| true` so a
   tooling hiccup never fails an otherwise-green build.
4. **Upload coverage** — the `coverage-report.json` artifact is uploaded
   via `actions/upload-artifact@v4` with `if: always()` so it is
   available even when tests fail, for post-hoc analysis.

### What CI does *not* do (yet)

The current pipeline **collects and reports** coverage; it does not
**gate** on it. Hard-failing a build when a component drops below its
target is the next step toward EXEMPLARY — it requires a stable
per-component mapping from `xccov` target/file names to the component
table above. Until that mapping lands, coverage is a published signal,
not a gate. The artifact + log summary make regressions visible in
every PR.
