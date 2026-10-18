#!/bin/bash
# Renders the images used on the website and in the README, from the app's real widget view.
#
#   ./scripts/make-screenshots.sh [output-folder]      (default: ../docs/images)
#
# The widget view is compiled together with a small program (scripts/screenshots/main.swift) that feeds it hand-made glucose
# curves and draws it offscreen. Nothing here touches the real app, its settings, its login or any window on screen, and
# the images never show the "SIMULATED" label because no simulation is involved. Developer tool only: it is not part of the
# app and is never built into a release.
set -euo pipefail

cd "$(dirname "$0")/.." # the mac/ folder
OUT="${1:-../docs/images}"
mkdir -p "$OUT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# One module: the logic library, and the app's views without its entry point and window plumbing.
cp Sources/LibreMonitorKit/*.swift "$WORK/"
for f in Sources/LibreMonitorMac/*.swift; do
  case "$(basename "$f")" in
    LibreMonitorApp.swift|AppDelegate.swift) continue ;;
  esac
  cp "$f" "$WORK/"
done
sed -i '' '/^import LibreMonitorKit$/d' "$WORK"/*.swift
# The pictures use a fixed clock, so the model's "now" must be settable. Only in this temporary copy, never in the app.
sed -i '' 's/@Published private(set) var now = Date()/@Published var now = Date()/' "$WORK/AppModel.swift"
cp scripts/screenshots/main.swift "$WORK/main.swift"

swiftc -swift-version 5 -D DEBUG -o "$WORK/render" "$WORK"/*.swift 2>&1 | grep -E "error" || true
"$WORK/render" "$OUT"
