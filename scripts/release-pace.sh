#!/usr/bin/env bash
#
# release-pace.sh — Ship a new Pace release with auto-update support.
#
# What it does:
#   1. Reads the current version from leanring-buddy/Info.plist (or bumps it).
#   2. Builds Pace.app in Release with the test scheme's signing setup
#      (ad-hoc signed — Sparkle verifies updates via EdDSA, not Apple).
#   3. Zips Pace.app.
#   4. Signs the zip with Sparkle's sign_update (uses the private key
#      stored in your Mac's Keychain — generated once via Sparkle's
#      generate_keys; see SUPublicEDKey in Info.plist for the matching
#      public key).
#   5. Pushes the zip + release notes to a GitHub Release via `gh`.
#   6. Regenerates appcast.xml with the new entry on top.
#   7. Commits + pushes appcast.xml so the SUFeedURL serves it instantly.
#
# Prereqs (one-time):
#   - Xcode with command-line tools (`xcode-select --install`)
#   - `brew install gh`, `gh auth login` (personal GitHub account)
#   - Sparkle EdDSA key already generated (was: ./generate_keys)
#
# Usage:
#   ./scripts/release-pace.sh           # bump patch, e.g. 0.3.0 → 0.3.1
#   ./scripts/release-pace.sh 0.4.0     # exact version
#
# After running, every existing Pace install pings the appcast within
# the next hour (or on next launch) and offers the update.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GITHUB_REPO="sarthakagrawal927/pace"
APP_NAME="Pace"
SCHEME="leanring-buddy"
INFO_PLIST="${PROJECT_DIR}/leanring-buddy/Info.plist"
APPCAST_PATH="${PROJECT_DIR}/appcast.xml"
BUILD_DIR="${PROJECT_DIR}/build/release"
RELEASES_DIR="${PROJECT_DIR}/releases"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# xcodebuild lives in Xcode.app, not the Command Line Tools shim. Many
# Macs default xcode-select to /Library/Developer/CommandLineTools and
# xcodebuild fails with "requires Xcode" in that state. Pin DEVELOPER_DIR
# here so the release works regardless of the user's xcode-select state.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path "*sparkle/Sparkle/bin/sign_update" 2>/dev/null | head -1)
if [ -z "$SPARKLE_BIN" ]; then
    SPARKLE_BIN=$(find /tmp/pace-test-derived-data -path "*sparkle/Sparkle/bin/sign_update" 2>/dev/null | head -1)
fi
if [ -z "$SPARKLE_BIN" ]; then
    echo "❌ Sparkle's sign_update not found. Build Pace once (Xcode or test-pace.sh) so SPM downloads Sparkle." >&2
    exit 1
fi
SPARKLE_BIN_DIR=$(dirname "$SPARKLE_BIN")

# ── Version handling ────────────────────────────────────────────────────────

current_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "0.0.0")
current_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || echo "0")

if [ $# -ge 1 ]; then
    next_version="$1"
else
    major=$(echo "$current_version" | cut -d. -f1)
    minor=$(echo "$current_version" | cut -d. -f2)
    patch=$(echo "$current_version" | cut -d. -f3)
    patch=$((patch + 1))
    next_version="${major}.${minor}.${patch}"
fi

next_build=$((current_build + 1))
tag="v${next_version}"

echo "▶ Pace release ${tag} (build ${next_build}; previous: ${current_version} build ${current_build})"

if gh release view "$tag" --repo "$GITHUB_REPO" &>/dev/null; then
    echo "❌ Release ${tag} already exists on GitHub. Bump the version: ./scripts/release-pace.sh <new-version>" >&2
    exit 1
fi

# Dirty-tree check moved here so we fail BEFORE bumping Info.plist /
# building / publishing. If the tree is dirty, fix it (commit or stash)
# and re-run. release-pace.sh itself is the only file allowed to be in
# the dirty set since the script may be self-modifying across releases.
working_tree_status=$(git status --porcelain | grep -v "^.. scripts/release-pace.sh\$" || true)
if [ -n "$working_tree_status" ]; then
    echo "❌ Working tree has uncommitted changes. Commit or stash first:" >&2
    echo "$working_tree_status" >&2
    exit 1
fi

read -p "Proceed? (y/N) " -n 1 -r
echo
[[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Bump Info.plist before building ────────────────────────────────────────

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $next_version" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next_build" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $next_build" "$INFO_PLIST"

# ── Build Release ──────────────────────────────────────────────────────────

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$RELEASES_DIR"

echo "📦 Building Pace.app (Release)..."
xcodebuild \
    -project "${PROJECT_DIR}/leanring-buddy.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    MARKETING_VERSION="$next_version" \
    CURRENT_PROJECT_VERSION="$next_build" \
    > "$BUILD_DIR/build.log" 2>&1

APP_PATH="$BUILD_DIR/Build/Products/Release/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed. Tail of $BUILD_DIR/build.log:" >&2
    tail -40 "$BUILD_DIR/build.log" >&2
    exit 1
fi
echo "✅ Built ${APP_PATH}"

# ── Bundle TTS launcher script so PaceTTSSidecarLauncher finds it in the
# installed app (otherwise auto-start only works in dev builds where the
# hardcoded repo-path fallback fires). The Resources/ path is the first
# location the launcher probes via Bundle.main.resourceURL.
mkdir -p "${APP_PATH}/Contents/Resources/scripts"
cp "${PROJECT_DIR}/scripts/start-tts-server.sh" "${APP_PATH}/Contents/Resources/scripts/start-tts-server.sh"
chmod +x "${APP_PATH}/Contents/Resources/scripts/start-tts-server.sh"
echo "✅ Bundled start-tts-server.sh into Resources/"

# ── Resign every embedded framework + the app itself with ad-hoc identity
# so Pace launches on machines that don't have our (non-existent) Apple
# Developer Team ID. Without this, dyld refuses to load Sparkle.framework
# because its prebuilt code signature has a different Team ID than the
# ad-hoc-signed Pace binary — the exact crash that hit v0.3.0's first install.
echo "🔐 Resigning embedded frameworks ad-hoc..."
find "${APP_PATH}/Contents/Frameworks" -maxdepth 2 -name "*.framework" -type d 2>/dev/null | while read framework_path; do
    codesign --force --deep --sign - "${framework_path}" 2>&1 | tail -1
done
codesign --force --deep --sign - "${APP_PATH}" 2>&1 | tail -1
codesign --verify --deep "${APP_PATH}" && echo "✅ Codesign verify passed"

# ── Zip + Sparkle-sign ─────────────────────────────────────────────────────

zip_name="Pace-${next_version}.zip"
zip_path="${RELEASES_DIR}/${zip_name}"
rm -f "$zip_path"

echo "🗜  Zipping Pace.app → $zip_name"
(cd "$(dirname "$APP_PATH")" && ditto -ck --sequesterRsrc --keepParent "$(basename "$APP_PATH")" "$zip_path")

echo "🔐 Signing zip with Sparkle EdDSA key..."
signature_line=$("${SPARKLE_BIN_DIR}/sign_update" "$zip_path")
echo "   ${signature_line}"
ed_signature=$(echo "$signature_line" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
zip_size=$(echo "$signature_line" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
if [ -z "$ed_signature" ] || [ -z "$zip_size" ]; then
    echo "❌ Could not parse sign_update output." >&2
    exit 1
fi

# ── Publish GitHub Release ─────────────────────────────────────────────────

echo "🏷  Publishing GitHub Release $tag..."
gh release create "$tag" "$zip_path" \
    --repo "$GITHUB_REPO" \
    --title "Pace ${next_version}" \
    --notes "Pace ${next_version} (build ${next_build}) — auto-update enabled." \
    --latest

download_url="https://github.com/${GITHUB_REPO}/releases/download/${tag}/${zip_name}"

# ── Update appcast.xml ─────────────────────────────────────────────────────

pub_date=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")
new_item=$(cat <<EOF
        <item>
            <title>Pace ${next_version}</title>
            <pubDate>${pub_date}</pubDate>
            <sparkle:version>${next_build}</sparkle:version>
            <sparkle:shortVersionString>${next_version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="${download_url}" length="${zip_size}" type="application/octet-stream" sparkle:edSignature="${ed_signature}"/>
        </item>
EOF
)

python3 - "$APPCAST_PATH" "$new_item" <<'PY'
import sys, pathlib, re
path, new_item = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text() if path.exists() else None
if not text or "<channel>" not in text:
    text = """<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Pace</title>
        <description>Auto-update feed for Pace, the local-only macOS voice companion.</description>
        <language>en</language>
    </channel>
</rss>
"""
text = re.sub(r"(<channel>\n(?:[^<]*<(?:title|description|language)>[^<]*</(?:title|description|language)>\n)*)", r"\1" + new_item + "\n", text, count=1)
path.write_text(text)
PY

echo "✅ appcast.xml updated"

# ── Commit appcast + version bump via auto-merged PR ──────────────────────
# main is branch-protected (no direct push), so the appcast update goes
# through a release branch + PR + squash-merge via `gh`. End result is
# identical to a direct push but respects the protection rule.

cd "$PROJECT_DIR"
release_branch="release/${tag}"

current_branch=$(git rev-parse --abbrev-ref HEAD)
git checkout -B "$release_branch"
# Include scripts/release-pace.sh in the release commit if the script
# itself was edited as part of this release (e.g. shipping a fix to the
# release pipeline alongside the bump). The pre-flight dirty-tree check
# at the top of the script already cleared every OTHER file.
git add "$APPCAST_PATH" "$INFO_PLIST" "$0"
git commit -m "Release Pace ${next_version} (build ${next_build}): appcast entry + version bump"
git push -u origin "$release_branch"

pr_url=$(gh pr create \
    --base main \
    --head "$release_branch" \
    --title "Release Pace ${next_version}" \
    --body "Appcast entry + Info.plist bump for the ${tag} GitHub Release. Auto-generated by scripts/release-pace.sh." \
    2>&1 | tail -1)
echo "🔗 PR: $pr_url"

# Squash-merge via gh; --delete-branch cleans up the release branch
# both remotely and locally.
gh pr merge --squash --delete-branch "$pr_url"

# Return to the branch we started on (typically main) and fast-forward.
git checkout "$current_branch" 2>/dev/null || git checkout main
git pull --rebase --autostash

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅ Pace ${next_version} released"
echo "   Download: ${download_url}"
echo "   Appcast:  https://raw.githubusercontent.com/${GITHUB_REPO}/main/appcast.xml"
echo "   Existing installs check the appcast within an hour (or on next launch)."
echo "═══════════════════════════════════════════════════════════════"
