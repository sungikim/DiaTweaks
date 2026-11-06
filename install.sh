#!/bin/sh
set -eu
cd "$(dirname "$0")"
make -s

support="${DIAPATCH_HOME:-$HOME/Library/Application Support/DiaPatches}"
mkdir -p "$support/bin"
cp -f build/diapatch "$support/bin/diapatch"
cp -f build/DiaPatches.dylib "$support/DiaPatches.dylib"
# A new file, not one written over: macOS kills a binary whose signature it cached before the change.
rm -f "$support/bin/diapatch-mobile"
cp build/diapatch-mobile "$support/bin/diapatch-mobile"
launchctl kickstart -k "gui/$(id -u)/com.diapatches.mobile" 2>/dev/null || true

"$support/bin/diapatch" install --relaunch
