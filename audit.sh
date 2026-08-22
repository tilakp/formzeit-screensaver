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

# Audit/main.swift constructs a real FormzeitDefaults(), which reads through
# to this machine's actual persisted ScreenSaverDefaults (24-hour toggle,
# accent color, ...) — the same domain you get from clicking through the
# settings panel while testing. Left in a non-factory state, the audit
# silently measures a different rendering than its own math assumes (it
# labels numerals 1-12 regardless of what's actually drawn), which reads as
# a geometry regression that isn't one. Pin known values for the run, then
# put back whatever was there before — this dev tool has no business
# permanently changing your test settings as a side effect.
DOMAIN="com.tilakpatel.formzeit"
BACKUP=$(mktemp -t formzeit-audit-defaults).plist
HAD_DOMAIN=0
if defaults -currentHost export "$DOMAIN" "$BACKUP" 2>/dev/null; then
  HAD_DOMAIN=1
fi
restore_defaults() {
  # `defaults import` overlays onto whatever's already in the domain rather
  # than replacing it outright, so the keys this script writes below would
  # otherwise survive the "restore" — delete first, then re-import the
  # pre-existing content on top of a clean slate.
  defaults -currentHost delete "$DOMAIN" 2>/dev/null || true
  if [[ "$HAD_DOMAIN" == "1" ]]; then
    defaults -currentHost import "$DOMAIN" "$BACKUP" 2>/dev/null || true
  fi
  rm -f "$BACKUP"
}
trap restore_defaults EXIT

defaults -currentHost write "$DOMAIN" accentIndex -int 0
defaults -currentHost write "$DOMAIN" movement -string "mechanical"
defaults -currentHost write "$DOMAIN" use24Hour -bool false
defaults -currentHost write "$DOMAIN" burnInProtection -bool true
defaults -currentHost write "$DOMAIN" nightDimming -bool true
defaults -currentHost write "$DOMAIN" face -string "classic"
defaults -currentHost write "$DOMAIN" world -string "ember"
defaults -currentHost write "$DOMAIN" accent -string "adaptive"

SDK=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p build
# Every v2 face lives across Sources/*.swift now (Palette/Lighting/ClassicFace/
# EclipseFace/StrataFace/FilamentFace/FormzeitRenderer/FormzeitDefaults), so
# the audit tool compiles the same file set build.sh does, plus Audit/main.swift.
# It does not need ConfigureSheetController.swift or FormzeitView.swift (no
# NSPrincipalClass/UI is instantiated here), but those aren't excluded for
# simplicity — they compile standalone with no side effects at audit time.
swiftc Sources/*.swift Audit/main.swift \
  -O -o build/audit -target arm64-apple-macosx12.0 -sdk "$SDK" \
  -framework Cocoa -framework ScreenSaver -framework QuartzCore

./build/audit
