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

# Ask SwiftPM where it put the products rather than guessing. .build/release is
# only a convenience symlink, and it is not always there: a fresh checkout built
# by a different toolchain, or a build driven through the XCBuild path, can leave
# the real output in .build/out/Products/Release with no symlink at all, which
# made this script fail on CI with "No release binary" right after a build that
# had actually succeeded.
BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path 2>/dev/null | tail -1 || true)"
if [ -z "$BUILD_DIR" ] || [ ! -d "$BUILD_DIR" ]; then
  BUILD_DIR=".build/$CONFIG"
fi

if [ ! -x "$BUILD_DIR/$APP_NAME" ]; then
  echo "No $CONFIG binary in $BUILD_DIR. Run: swift build -c $CONFIG" >&2
  # Print the build directory contents: a wrong path here is otherwise very
  # hard to diagnose from CI logs, where the build itself has already succeeded.
  ls -la "$BUILD_DIR" 2>&1 | head -20 >&2 || true
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
