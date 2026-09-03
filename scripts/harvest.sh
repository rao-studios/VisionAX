#!/bin/bash
# WHAT: Build + stable-sign + run the harvester.
# OUT:  sign-binary.sh, then exec .build/$CONFIG/VisionAXHarvest
# PIN:  Its own script and its own bundle id, so the Accessibility and Screen Recording
#       grants belong to the data collector alone — granting the harvester never grants
#       the bench, and revoking one leaves the other alone. Same reasoning as Mary's
#       scripts/sand.sh. Signing matters here and not for the bench, because only this
#       target asks for TCC permissions.
#
#   ./scripts/harvest.sh                                  # prints the usage
#   ./scripts/harvest.sh --web-synthetic 300 --out Dataset --quit-when-done
#   ./scripts/harvest.sh --web-urls Seeds/urls.txt --out Dataset --quit-when-done
#   ./scripts/harvest.sh --app com.apple.Safari --record --interval 3 --out Dataset
#   CONFIG=release ./scripts/harvest.sh ...
#
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
cd "$REPO_ROOT"

echo "▸ swift build --product VisionAXHarvest ($CONFIG)"
if [ "$CONFIG" = "release" ]; then
    swift build -c release --product VisionAXHarvest
else
    swift build --product VisionAXHarvest
fi

BIN="$REPO_ROOT/.build/$CONFIG/VisionAXHarvest"
"$REPO_ROOT/scripts/sign-binary.sh" "$BIN"

exec "$BIN" "$@"
