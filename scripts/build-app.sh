#!/usr/bin/env bash
# Build an ad-hoc signed local macOS app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
version="$(python3 scripts/version.py)"
swift build -c "$configuration" --product kpub
bin="$(swift build -c "$configuration" --show-bin-path)/kpub"
app="build/kpub.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/kpub"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
codesign --force --sign - "$app"
printf 'Built: %s\n' "$app"
if [[ "${1:-}" == "--install" ]]; then
  make install
fi
