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
BUILD_DIR=".build/$CONFIG"
OUTPUT="${1:-build/$APP_NAME.app}"

if [ ! -x "$BUILD_DIR/$APP_NAME" ]; then
  echo "No $CONFIG binary. Run: swift build -c $CONFIG"
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
  <key>CFBundleShortVersionString</key>      <string>$VERSION</string>
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
