#!/bin/bash
# Renders the current Formzeit.saver build to screenshots/latest.png (and a
# timestamped copy) so every change has a visual artifact alongside it.
# Usage: ./preview.sh [seconds] [width] [height] [--preview|--config]
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

STAMP=$(date +%Y%m%d-%H%M%S)
./build/TestHarness "$(pwd)/Formzeit.saver" "$(pwd)/screenshots/$STAMP.png" "$@"
cp "screenshots/$STAMP.png" "screenshots/latest.png"
echo "screenshots/$STAMP.png (and screenshots/latest.png)"
