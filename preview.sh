#!/bin/bash
# Renders the current Formzeit.saver build to screenshots/latest.png (and a
# timestamped copy) so every change has a visual artifact alongside it.
# Usage: ./preview.sh [seconds] [width] [height] [--preview|--config] [--at HH:MM]
#
# --at HH:MM pins the wall clock the render sees (via FORMZEIT_PREVIEW_NOW,
# read by FormzeitView) so night/diel rendering can actually be looked at
# instead of only whatever time it happens to be when you run this.
set -euo pipefail
cd "$(dirname "$0")"

SDK=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p screenshots

if [[ ! -x build/TestHarness ]]; then
  mkdir -p build
  swiftc TestHarness/main.swift -O -o build/TestHarness \
    -target arm64-apple-macosx12.0 -sdk "$SDK" \
    -framework Cocoa -framework ScreenSaver
fi

ARGS=()
AT=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--at" ]]; then
    AT="$2"
    shift 2
    continue
  fi
  ARGS+=("$1")
  shift
done

if [[ -n "$AT" ]]; then
  export FORMZEIT_PREVIEW_NOW=$(date -j -f "%H:%M" "$AT" +%s)
fi

STAMP=$(date +%Y%m%d-%H%M%S)
./build/TestHarness "$(pwd)/Formzeit.saver" "$(pwd)/screenshots/$STAMP.png" "${ARGS[@]}"
cp "screenshots/$STAMP.png" "screenshots/latest.png"
echo "screenshots/$STAMP.png (and screenshots/latest.png)"
