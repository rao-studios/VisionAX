#!/bin/bash
# WHAT: Build + run VisionAXBench — open an image, see the tree over it.
# OUT:  exec .build/$CONFIG/VisionAXBench
# PIN:  Build then exec, the way Mary's scripts/sand.sh does, so the binary is
#       launched directly with its arguments under our control — `swift run`
#       forwards argv through SwiftPM, and a bare path there costs the window
#       (see below). No codesign step: the bench asks for no TCC permission, so
#       an ad-hoc identity that changes every build costs nothing here.
#
#   ./scripts/bench.sh
#   ./scripts/bench.sh ~/Desktop/screenshot.png   # or --image <path>
#   ./scripts/bench.sh shot.png --model Tests/VisionAXTests/Fixtures/tiny-classifier.json
#   ./scripts/bench.sh --url news.ycombinator.com    # render a page and use that
#   CONFIG=release ./scripts/bench.sh
#
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
cd "$REPO_ROOT"

echo "▸ swift build --product VisionAXBench ($CONFIG)"
if [ "$CONFIG" = "release" ]; then
    swift build -c release --product VisionAXBench
else
    swift build --product VisionAXBench
fi

BIN="$REPO_ROOT/.build/$CONFIG/VisionAXBench"

# A BARE PATH WOULD COST YOU THE WINDOW. AppKit reads unflagged argv entries as
# documents to open, and an app with no registered document type answers by
# opening nothing at all — event loop up, zero windows, indistinguishable from a
# hang. Passing it as `--image` keeps it inert in the defaults domain.
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
    IMAGE="$1"
    shift
    exec "$BIN" --image "$IMAGE" "$@"
fi

exec "$BIN" "$@"
