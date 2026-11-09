#!/bin/bash
# Build Card Rename.app with the Command Line Tools (no Xcode needed).
#   ./build.sh           build into build/
#   ./build.sh test      run the naming rule tests
#   ./build.sh install   build, copy to /Applications and open it
#   ./build.sh icon      redraw Resources/AppIcon.icns from Tools/make_icon.swift
#   ./build.sh dmg       build, then build/CardRename.dmg (app + Applications shortcut) for a GitHub release
#   ./build.sh screens   build, then the README screenshots in docs/screenshots
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "test" ]; then
  mkdir -p build
  swiftc -swift-version 5 Sources/CardScan.swift Sources/Labroll.swift Sources/NameScheme.swift Sources/XXHash64.swift Sources/Updater.swift Tests/main.swift -o build/tests
  ./build/tests
  exit
fi

if [ "${1:-}" = "icon" ]; then
  mkdir -p build Resources
  swiftc -swift-version 5 Tools/make_icon.swift -o build/make_icon
  ./build/make_icon build/icon_1024.png
  /bin/rm -rf build/AppIcon.iconset
  mkdir build/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
  echo "Wrote Resources/AppIcon.icns"
  exit
fi

APP="build/Card Rename.app"
/bin/rm -rf "build/Card Rename.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14 \
  Sources/*.swift -o "$APP/Contents/MacOS/CardRename"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/OzColor-*.png LICENSE "$APP/Contents/Resources/"
# Signing identity: SIGN_ID if set, else a Developer ID Application certificate (needed for other
# Macs, with notarization), else an Apple Development one (stable identity: macOS keeps the app's
# permissions across builds), else ad hoc.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)}"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)}"
case "$SIGN_ID" in
  "Developer ID Application:"*) codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP" ;;
  "")                           codesign --force --sign - "$APP" ;;
  *)                            codesign --force --options runtime --sign "$SIGN_ID" "$APP" ;;
esac
echo "Built $APP, signed: ${SIGN_ID:-ad hoc}"

if [ "${1:-}" = "install" ]; then
  /usr/bin/osascript -e 'tell application id "local.cardrename" to quit' 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x CardRename >/dev/null || break; sleep 0.5; done
  /bin/rm -rf "/Applications/Card Rename.app"
  /usr/bin/ditto "$APP" "/Applications/Card Rename.app"
  open "/Applications/Card Rename.app"
  echo "Installed in /Applications"
fi

if [ "${1:-}" = "dmg" ]; then
  /bin/rm -rf build/dmg build/CardRename.dmg
  mkdir build/dmg
  /usr/bin/ditto "$APP" "build/dmg/Card Rename.app"
  ln -s /Applications build/dmg/Applications
  hdiutil create -quiet -volname "Card Rename" -srcfolder build/dmg -fs HFS+ -format UDZO build/CardRename.dmg
  /bin/rm -rf build/dmg
  # Notarized when signed with Developer ID and the notarytool login is saved under NOTARY_PROFILE
  # (once: xcrun notarytool store-credentials oz-color-notary --apple-id ... --team-id ...).
  NOTARY_PROFILE="${NOTARY_PROFILE:-oz-color-notary}"
  case "$SIGN_ID" in
    "Developer ID Application:"*)
      if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        codesign --force --timestamp --sign "$SIGN_ID" build/CardRename.dmg
        xcrun notarytool submit build/CardRename.dmg --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple build/CardRename.dmg
        spctl -a -t open --context context:primary-signature -v build/CardRename.dmg
      else
        echo "Not notarized: no notarytool login saved as \"$NOTARY_PROFILE\"."
      fi ;;
    *) echo "Not notarized: needs a Developer ID Application certificate." ;;
  esac
  echo "Built build/CardRename.dmg (v$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist))"
fi

if [ "${1:-}" = "screens" ]; then
  # The app's views with demo data (Tools/screenshots.swift), in a copy of the bundle for its resources.
  SHOT="build/Screenshots.app"
  /bin/rm -rf "build/Screenshots.app"
  /usr/bin/ditto "$APP" "$SHOT"
  swiftc -O -swift-version 5 -parse-as-library -D SNAPSHOTS -target arm64-apple-macos14 \
    Sources/*.swift Tools/screenshots.swift -o "$SHOT/Contents/MacOS/CardRename"
  codesign --force --sign - "$SHOT"
  mkdir -p docs/screenshots
  "$SHOT/Contents/MacOS/CardRename" docs/screenshots
fi
