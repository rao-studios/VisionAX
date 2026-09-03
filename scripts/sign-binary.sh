#!/bin/bash
# WHAT: Stable-sign one built binary so TCC grants survive a rebuild.
# IN:   path to a binary — scripts/harvest.sh
# PIN:  SwiftPM signs ad-hoc, and an ad-hoc identity IS the binary's cdhash: it
#       changes on every build, so macOS treats each rebuild as a brand-new app. The
#       Accessibility checkbox stays ticked in System Settings while
#       AXIsProcessTrusted() quietly returns false — the most confusing failure in this
#       whole package, because nothing looks wrong. Signing with a stable certificate
#       makes the designated requirement identifier + certificate instead of a hash, so
#       one grant covers every rebuild. Copied from Mary's scripts/sign-binary.sh.
#
#   ./scripts/sign-binary.sh /path/to/VisionAXHarvest
#
BIN="$1"

if [ ! -f "$BIN" ]; then
    echo "sign-binary: nothing at $BIN — skipping"
    exit 0
fi

# Prefer Apple Development; else a self-made Keychain identity.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|VisionAX Dev Signing/ {print $2; exit}')"

if [ -z "$IDENTITY" ]; then
    echo "sign-binary: WARNING — no stable codesigning identity; leaving ad-hoc."
    echo "  Accessibility and Screen Recording grants will NOT survive the next build."
    echo "  Make one once with Keychain Access ▸ Certificate Assistant ▸ Create a"
    echo "  Certificate… named 'VisionAX Dev Signing', type Code Signing."
    exit 0
fi

codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements "$BIN"
echo "sign-binary: signed $BIN with '$IDENTITY'"
