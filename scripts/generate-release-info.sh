#!/usr/bin/env bash
#
# generate-release-info.sh — Parse appcast.xml and write a JSON file
# the website's /download page reads at build time.
#
# This runs as a prebuild step (see website/package.json) so the
# download page always reflects the latest release without anyone
# having to manually update a config file. The JSON is committed to
# the repo so it's present even if this script fails in CI.
#
# Input:  ../appcast.xml (repo root)
# Output: ../website/src/config/release-info.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APPCAST="$PROJECT_DIR/appcast.xml"
OUTPUT="$PROJECT_DIR/website/src/config/release-info.json"

if [ ! -f "$APPCAST" ]; then
  echo "⚠️  appcast.xml not found at $APPCAST — skipping release-info generation"
  exit 0
fi

# Use Python for reliable XML parsing. Available on macOS and CI.
python3 - "$APPCAST" "$OUTPUT" <<'PYEOF'
import json
import sys
import xml.etree.ElementTree as ET
from datetime import datetime

appcast_path, output_path = sys.argv[1], sys.argv[2]

ns = {
    "sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle",
}

tree = ET.parse(appcast_path)
root = tree.getroot()

items = []
for item in root.findall(".//item"):
    title = item.findtext("title", "").strip()
    pub_date = item.findtext("pubDate", "").strip()

    version = item.findtext("sparkle:version", "", ns).strip()
    short_version = item.findtext("sparkle:shortVersionString", "", ns).strip()
    min_system = item.findtext("sparkle:minimumSystemVersion", "", ns).strip()

    enclosure = item.find("enclosure")
    if enclosure is None:
        continue
    download_url = enclosure.get("url", "")
    length = int(enclosure.get("length", "0"))
    ed_signature = enclosure.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature", "")

    # Parse the pubDate into ISO format for sorting/display
    try:
        parsed_date = datetime.strptime(pub_date, "%a, %d %b %Y %H:%M:%S %z")
        iso_date = parsed_date.isoformat()
        display_date = parsed_date.strftime("%b %-d, %Y")
    except (ValueError, TypeError):
        iso_date = pub_date
        display_date = pub_date

    items.append({
        "version": short_version,
        "build": version,
        "title": title,
        "pubDate": pub_date,
        "isoDate": iso_date,
        "displayDate": display_date,
        "downloadURL": download_url,
        "length": length,
        "lengthMB": round(length / (1024 * 1024), 1),
        "minimumSystemVersion": min_system,
        "edSignature": ed_signature,
    })

# Sort by build number descending (newest first)
items.sort(key=lambda x: int(x["build"]) if x["build"].isdigit() else 0, reverse=True)

result = {
    "latest": items[0] if items else None,
    "releases": items[:10],  # Keep the 10 most recent for the page
    "releasesPageURL": "https://github.com/sarthakagrawal927/pace/releases",
    "generatedAt": datetime.utcnow().isoformat() + "Z",
}

with open(output_path, "w") as f:
    json.dump(result, f, indent=2)
    f.write("\n")

print(f"✓ release-info.json written ({len(items)} releases found, latest: {result['latest']['version'] if result['latest'] else 'none'})")
PYEOF
