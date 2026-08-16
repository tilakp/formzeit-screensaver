#!/bin/bash
# Geometry audit: renders the real dial code into a bitmap and measures the
# resulting pixels, so numeral placement is checked numerically rather than
# by eye. Run after any change to the dial layout.
#
#   impliedR spread  every numeral should sit on one ring
#   max |tangOff|    every numeral should be centred on its hour ray
#   min gap          closest approach between numeral ink and any tick
set -euo pipefail
cd "$(dirname "$0")"

SDK=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p build
swiftc Sources/Palette.swift Sources/FormzeitDefaults.swift Sources/FormzeitRenderer.swift Audit/main.swift \
  -O -o build/audit -target arm64-apple-macosx12.0 -sdk "$SDK" \
  -framework Cocoa -framework ScreenSaver -framework QuartzCore

./build/audit
