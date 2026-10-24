#!/bin/sh
# Copies a demo library into the app on a booted simulator, for UI tests and
# README screenshots. Usage: scripts/seed-simulator.sh <device> <demo-folder>
# where <demo-folder> holds library.json, Audio/ and Covers/.
set -eu
DEVICE="$1"
DEMO="$2"
DATA=$(xcrun simctl get_app_container "$DEVICE" com.levvlasov.OfflineMusic data)
TARGET="$DATA/Library/Application Support/OfflineMusic"
xcrun simctl terminate "$DEVICE" com.levvlasov.OfflineMusic 2>/dev/null || true
rm -rf "$TARGET"
mkdir -p "$TARGET"
cp -R "$DEMO/." "$TARGET/"
echo "Seeded $TARGET"
