#!/usr/bin/env bash
#
# test-pace.sh — run the unit tests without touching the TCC-paired
# Pace.app the user uses interactively.
#
# Why this exists
# ---------------
# CLAUDE.md says: "Do NOT run `xcodebuild` from the terminal — it
# invalidates TCC permissions and the app will need to re-request
# screen recording, accessibility, etc."
#
# That observation applies to `xcodebuild` rebuilding into the default
# DerivedData path (`~/Library/Developer/Xcode/DerivedData/…`), which
# is the same path Xcode's Cmd+R uses. Re-signing the same bundle
# identifier at the same path may cause macOS to re-evaluate TCC.
#
# This script builds + tests into an **isolated DerivedData path**
# (`/tmp/pace-test-derived-data`). The user's interactive Pace.app at
# its usual DerivedData path stays untouched.
#
# Risk caveat
# -----------
# macOS TCC's exact identity-resolution algorithm isn't documented.
# In theory `(bundle_id, code_signing_identity)` is the key, in which
# case re-signing the same bundle ID at any path could still affect
# TCC grants for the interactive Pace.app.
#
# If you run this script and your interactive Pace.app starts
# re-prompting for Accessibility / Screen Recording / Mic permissions
# on next Cmd+R, that hypothesis was wrong; close this script and
# we'll switch to a stand-alone Swift Package approach for tests.
#
# Usage
# -----
#   ./scripts/test-pace.sh                       # run all unit tests
#   ./scripts/test-pace.sh PaceTagParsersTests   # filter
#
# Returns xcodebuild's exit code (0 on green, non-zero on failure).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DERIVED_DATA_PATH="/tmp/pace-test-derived-data"
PROJECT_PATH="$PROJECT_DIR/leanring-buddy.xcodeproj"
# Scheme name kept as `leanring-buddy` (matches the Xcode default
# scheme alongside the legacy folder name). The PRODUCT_NAME is `Pace`,
# but `xcodebuild -list` shows the scheme name, not the product.
SCHEME="leanring-buddy"
TEST_TARGET="leanring-buddyTests"
DESTINATION='platform=macOS,arch=arm64'

# Use the full Xcode.app, not the Command Line Tools — xcodebuild
# only ships with Xcode.app. If `xcode-select` is pointing at
# CommandLineTools (common on fresh dev machines), `xcodebuild` errors
# out before doing anything. Setting `DEVELOPER_DIR` here picks Xcode
# without touching the system-wide setting (no sudo needed).
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    else
        # Fall back to a versioned Xcode beta (e.g. Xcode-27.0.0-Beta.app).
        beta_xcode="$(/usr/bin/find /Applications -maxdepth 1 -name 'Xcode*.app' -type d 2>/dev/null | /usr/bin/sort | /usr/bin/tail -1)"
        if [[ -n "$beta_xcode" && -d "$beta_xcode/Contents/Developer" ]]; then
            export DEVELOPER_DIR="$beta_xcode/Contents/Developer"
        fi
    fi
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "Project not found: $PROJECT_PATH" >&2
    exit 2
fi

ONLY_TESTING_ARGS=()
for filter in "$@"; do
    ONLY_TESTING_ARGS+=("-only-testing:${TEST_TARGET}/${filter}")
done

echo "▶ Pace test runner — isolated DerivedData at $DERIVED_DATA_PATH"
echo "  (will not touch ~/Library/Developer/Xcode/DerivedData/leanring-buddy-*)"
echo

# `xcodebuild test` builds the test bundle + its host app (Pace.app)
# into DERIVED_DATA_PATH, then runs the tests inside that host app.
# Result bundle path is pinned so we can query the structured summary
# afterward via `xcresulttool` instead of scraping the noisy stdout.
#
# Code-signing is disabled for the test build: the keychain identity
# may not be available from a terminal-launched xcodebuild (it is from
# Xcode interactive), and unit tests don't need entitlements to run.
# The user's interactive Pace.app build keeps its real signing.

RESULT_BUNDLE_PATH="$DERIVED_DATA_PATH/pace-tests.xcresult"
rm -rf "$RESULT_BUNDLE_PATH"
BUILD_LOG_FILE="$DERIVED_DATA_PATH/last-build.log"
mkdir -p "$DERIVED_DATA_PATH"

set +e
xcodebuild test \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -resultBundlePath "$RESULT_BUNDLE_PATH" \
    -only-testing:"$TEST_TARGET" \
    "${ONLY_TESTING_ARGS[@]}" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    > "$BUILD_LOG_FILE" 2>&1
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -ne 0 ]]; then
    echo "❌ xcodebuild exited $EXIT_CODE — surfacing the last 60 lines of build output:"
    echo "  (full log: $BUILD_LOG_FILE)"
    echo
    tail -60 "$BUILD_LOG_FILE" | grep -vE '^Resolve Package' || true
    exit $EXIT_CODE
fi

# Pretty-print the result-bundle summary via xcresulttool. Falls back
# to grepping the raw log if xcresulttool isn't found.
if command -v xcrun >/dev/null 2>&1 && [[ -d "$RESULT_BUNDLE_PATH" ]]; then
    xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE_PATH" \
        | python3 -c '
import json, sys
data = json.load(sys.stdin)
total = data.get("totalTestCount", 0)
passed = data.get("passedTests", 0)
failed = data.get("failedTests", 0)
skipped = data.get("skippedTests", 0)
result = data.get("result", "Unknown")
elapsed = (data.get("finishTime", 0) - data.get("startTime", 0))
icon = "✅" if result == "Passed" else "❌"
print(f"{icon} {result} — {passed}/{total} passed, {failed} failed, {skipped} skipped, {elapsed:.1f}s")
for failure in data.get("testFailures", [])[:20]:
    target = failure.get("targetName", "?")
    name = failure.get("testName", "?")
    msg = failure.get("failureText", "")[:200]
    print(f"   ✗ {target}::{name}")
    if msg:
        print(f"     {msg}")
'
else
    grep -E '^\*\* TEST' "$BUILD_LOG_FILE" || true
fi

exit $EXIT_CODE
