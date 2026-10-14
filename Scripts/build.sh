#!/bin/bash
# Builds FlowLite (Release), signs it with the local identity and installs it to ~/Applications.
# Usage: Scripts/build.sh [--run]
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="FlowLite Local Signing"
APP="build/Build/Products/Release/FlowLite.app"
DEST="$HOME/Applications/FlowLite.app"

xcodegen generate --quiet
xcodebuild -project FlowLite.xcodeproj -scheme FlowLite -configuration Release \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -quiet build

if security find-identity -p codesigning | grep -qF "$IDENTITY"; then
  SIGN="$IDENTITY"
else
  echo "warning: '$IDENTITY' not found; ad-hoc signing (permissions reset after every build)"
  SIGN="-"
fi
# Sign nested code first (inside-out), then the app itself.
if [[ -d "$APP/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' nested; do
    codesign --force --sign "$SIGN" "$nested"
  done < <(find "$APP/Contents/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' \) -print0)
fi
codesign --force --sign "$SIGN" --entitlements App/FlowLite.entitlements "$APP"

pkill -x FlowLite || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "Installed $DEST"

if [[ "${1:-}" == "--run" ]]; then
  open "$DEST"
fi
