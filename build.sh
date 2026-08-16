#!/bin/bash
# Builds Formzeit.saver from source, ad-hoc code signs it, and (with -i)
# installs it into ~/Library/Screen Savers.
set -euo pipefail
cd "$(dirname "$0")"

SDK=$(xcrun --sdk macosx --show-sdk-path)
TARGET="arm64-apple-macosx12.0"
TOOLCHAIN_SWIFT_LIB="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"

rm -rf build Formzeit.saver
mkdir -p build Formzeit.saver/Contents/MacOS Formzeit.saver/Contents/Resources

echo "Compiling..."
swiftc -c Sources/*.swift -O -wmo -module-name Formzeit \
  -emit-module -emit-module-path build/Formzeit.swiftmodule \
  -o build/Formzeit.o \
  -target "$TARGET" -sdk "$SDK" \
  -framework Cocoa -framework ScreenSaver -framework QuartzCore

echo "Linking..."
clang -bundle -o Formzeit.saver/Contents/MacOS/Formzeit build/Formzeit.o \
  -target "$TARGET" -isysroot "$SDK" \
  -framework Cocoa -framework ScreenSaver -framework QuartzCore \
  -L "$SDK/usr/lib/swift" -L "$TOOLCHAIN_SWIFT_LIB" \
  -Xlinker -rpath -Xlinker /usr/lib/swift

cp Info.plist Formzeit.saver/Contents/Info.plist

echo "Code signing (ad-hoc)..."
codesign --force --sign - --timestamp=none Formzeit.saver

echo "Built: $(pwd)/Formzeit.saver"

if [[ "${1:-}" == "-i" ]]; then
  DEST="$HOME/Library/Screen Savers"
  mkdir -p "$DEST"
  rm -rf "$DEST/Formzeit.saver"
  cp -R Formzeit.saver "$DEST/Formzeit.saver"
  xattr -dr com.apple.quarantine "$DEST/Formzeit.saver" 2>/dev/null || true
  echo "Installed to: $DEST/Formzeit.saver"

  # macOS loads a .saver into long-lived legacyScreenSaver host processes and
  # keeps it there, so replacing the bundle on disk alone leaves the old code
  # running and the old preview showing. These hosts relaunch on demand, so
  # ending them is how the new build actually gets picked up. System Settings
  # caches its preview too and has to be reopened.
  pkill -x legacyScreenSaver 2>/dev/null && echo "Reloaded: legacyScreenSaver hosts restarted" || true
  pkill -f "ScreenSaverEngine" 2>/dev/null || true
  if pgrep -x "System Settings" >/dev/null 2>&1; then
    echo "NOTE: quit and reopen System Settings to refresh its cached preview."
  fi
fi
