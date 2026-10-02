#!/bin/bash
# Build CIStatus.app from the SwiftPM release binary.
#
# SwiftPM produces a bare Mach-O executable, which macOS will not treat as an
# app: there is no Info.plist, so LSUIElement cannot hide it from the Dock and
# launching it produces a second icon in the menu bar next to the real one.
# This wraps the binary in a minimal bundle and signs it.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="CIStatus"
BUNDLE_ID="dev.dolivari.ciStatus"
OUTPUT="${1:-build/$APP_NAME.app}"

# Find the release binary. There is no single reliable location, and guessing
# one has broken this script twice on CI, both times immediately after a build
# that had actually succeeded:
#
#   .build/release                    a convenience symlink, not always created
#   .build/out/Products/Release       the local SwiftPM layout
#   .build/apple/Products/Release     the layout the GitHub runner's toolchain
#                                     produces, and it does not create the
#                                     symlink above
#
# `swift build --show-bin-path` is the intended answer, but on the runner it
# reports a path that does not exist, so it is only trusted once the binary is
# actually found under it. A directory search is the backstop.
find_binary() {
  local candidate
  for candidate in \
    "${BIN_DIR:-}" \
    "$(swift build -c "$CONFIG" --show-bin-path 2>/dev/null | tail -1 || true)" \
    ".build/$CONFIG" \
    ".build/out/Products/$CONFIG" \
    ".build/apple/Products/$CONFIG" \
    ".build/*/Products/$CONFIG"
  do
    if [ -n "$candidate" ] && [ -x "$candidate/$APP_NAME" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

BUILD_DIR="$(find_binary || true)"

if [ -z "$BUILD_DIR" ]; then
  echo "No $CONFIG binary for $APP_NAME. Run: swift build -c $CONFIG" >&2
  # Say where it looked. A missing binary is otherwise very hard to diagnose
  # from a CI log, where the build has already reported success.
  echo "Searched:" >&2
  echo "  $(swift build -c "$CONFIG" --show-bin-path 2>/dev/null | tail -1 || echo '(show-bin-path failed)')" >&2
  for candidate in ".build/$CONFIG" ".build/out/Products/$CONFIG" ".build/apple/Products/$CONFIG"; do
    echo "  $candidate ($( [ -d "$candidate" ] && ls "$candidate" 2>/dev/null | tr '\n' ' ' || echo missing ))" >&2
  done
  exit 1
fi

echo "Building $APP_NAME.app ($CONFIG)"
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$OUTPUT/Contents/MacOS/$APP_NAME"

# SwiftPM emits resources as a sibling bundle; the app loads it from Resources.
if [ -d "$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle" ]; then
  cp -R "$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle" "$OUTPUT/Contents/Resources/"
fi

# Read the version from git when available so a build can be traced back.
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo "dev")"

# CFBundleShortVersionString has to be dotted integers or macOS refuses to treat
# the bundle as a real app, and `git describe` hands back things that are not
# that shape: a "v1.2.3" tag, or a bare commit hash when the checkout has no
# tags at all (a shallow CI clone, for instance). Peel the tag prefix and the
# -N-gHASH suffix, then fall back to 0.0.0 rather than emitting a version
# macOS would choke on. The unpeeled value is kept as CFBundleVersion, which is
# allowed to be an arbitrary build identifier, so a shipped app can still be
# traced back to the commit it came from.
SHORT_VERSION="$(printf '%s' "$VERSION" | sed -E 's/^v//; s/-.*$//')"
if ! [[ "$SHORT_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  SHORT_VERSION="0.0.0"
fi

cat > "$OUTPUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>       <string>en</string>
  <key>CFBundleExecutable</key>              <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>              <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>   <string>6.0</string>
  <key>CFBundleName</key>                    <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>             <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>             <string>APPL</string>
  <key>CFBundleShortVersionString</key>      <string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key>                 <string>$VERSION</string>
  <!-- No Dock icon and no app menu: this is a menu bar extra. -->
  <key>LSUIElement</key>                     <true/>
  <key>NSHighResolutionCapable</key>         <true/>
  <!-- Menu bar extras are agents, so they are not a document based app. -->
  <key>NSSupportsAutomaticTermination</key>  <false/>
  <key>NSSupportsSuddenTermination</key>     <false/>
</dict>
</plist>
PLIST

# Ad hoc signing is enough to run locally. Gatekeeper only notarises builds
# distributed to other machines, which is a separate step.
codesign --force --deep --sign - "$OUTPUT" >/dev/null 2>&1 \
  || echo "warning: codesign failed, the app will still run locally"

echo "Built $OUTPUT ($VERSION)"
