#!/bin/bash
# Builds Buddy.app and the buddy-hook binary into build/.
#   ./build.sh            build
#   ./build.sh test       build and run the logic tests (in a throwaway home folder)
#   ./build.sh demo       render the README/website images into design/demo
#   ./build.sh --release  notarized, stapled build/Buddy.zip for a GitHub release
#   ./build.sh --install  build, copy to /Applications, update the installed hook, relaunch
#
# Signing follows the other Purplelink apps: the Developer ID Application identity from the
# keychain (override with BUDDY_SIGN_ID), else Apple Development, else ad hoc. A fixed
# identity matters here: macOS keys the Accessibility permission to it, so it survives
# rebuilds (an ad hoc signature changes with every build).
set -euo pipefail
cd "$(dirname "$0")"
FLAGS=(-O -swift-version 5 -target arm64-apple-macos14.0)
APP=build/Buddy.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

# App icon: every size macOS asks for, from the 1024 px master (see design/).
mkdir -p "$APP/Contents/Resources" build/Buddy.iconset
for size in 16 32 128 256 512; do
  sips -z $size $size design/icon-1024.png --out "build/Buddy.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) design/icon-1024.png --out "build/Buddy.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/Buddy.iconset -o "$APP/Contents/Resources/Buddy.icns"
swiftc "${FLAGS[@]}" -o "$APP/Contents/MacOS/Buddy" Sources/*.swift
swiftc "${FLAGS[@]}" -o build/buddy-hook Hook/main.swift

SIGN_ID="${BUDDY_SIGN_ID:-}"
[ -n "$SIGN_ID" ] || SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/.*"([^"]+)".*/\1/' || true)"
[ -n "$SIGN_ID" ] || SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"([^"]+)".*/\1/' || true)"
[ -n "$SIGN_ID" ] || SIGN_ID="-"
[ "$SIGN_ID" = "-" ] && echo "warning: signing ad hoc; Accessibility will need re-granting after each build" >&2
echo "Signing identity: $SIGN_ID"

# External and exFAT volumes accumulate resource forks that codesign rejects.
dot_clean -m "$APP" 2>/dev/null || true
find build -name '._*' -delete 2>/dev/null || true
xattr -cr "$APP" build/buddy-hook 2>/dev/null || true

TS="--timestamp"; [ "$SIGN_ID" = "-" ] && TS="--timestamp=none"
OPTS=(--force --options runtime); [ "$SIGN_ID" = "-" ] && OPTS=(--force)
codesign "${OPTS[@]}" $TS --identifier llc.purplelink.buddy-hook --sign "$SIGN_ID" build/buddy-hook
# The app ships the hook (Contents/MacOS) so it can connect itself to Claude Code.
cp build/buddy-hook "$APP/Contents/MacOS/buddy-hook"
codesign "${OPTS[@]}" $TS --entitlements Buddy.entitlements --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign --verify --strict build/buddy-hook
echo "built $APP and build/buddy-hook"

case "${1:-}" in
  test)
    swiftc "${FLAGS[@]}" -o build/tests Tests/main.swift Sources/Model.swift Sources/Jump.swift Sources/Inbox.swift Sources/HookSetup.swift
    sandbox=$(mktemp -d "${TMPDIR:-/tmp}/buddy-tests.XXXXXX")
    HOME="$sandbox" CFFIXED_USER_HOME="$sandbox" BUDDY_HOOK="$PWD/build/buddy-hook" build/tests
    rm -rf "${sandbox:?}"
    ;;
  demo)
    # README/website images from the real views with made-up sessions (design/demo/).
    mkdir -p build/demo-src && cp Tools/render_demo.swift build/demo-src/main.swift  # top-level code needs main.swift
    swiftc "${FLAGS[@]}" -o build/render_demo build/demo-src/main.swift $(ls Sources/*.swift | grep -v main.swift)
    sandbox=$(mktemp -d "${TMPDIR:-/tmp}/buddy-demo.XXXXXX")
    HOME="$sandbox" CFFIXED_USER_HOME="$sandbox" build/render_demo design/demo
    rm -rf "${sandbox:?}"
    ;;
  --release)
    # Notarized, stapled build/Buddy.zip for a GitHub release. Needs the Developer ID
    # identity and a notarytool keychain profile named in BUDDY_NOTARY_PROFILE
    # (create one with: xcrun notarytool store-credentials).
    [ "$SIGN_ID" != "-" ] || { echo "a release needs a Developer ID identity" >&2; exit 1; }
    ZIP=build/Buddy.zip
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "${BUDDY_NOTARY_PROFILE:?set BUDDY_NOTARY_PROFILE to your notarytool keychain profile}" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    spctl -a -vv -t exec "$APP"
    shasum -a 256 "$ZIP"
    ;;
  --install)
    osascript -e 'tell application id "llc.purplelink.Buddy" to quit' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Buddy.app
    ditto "$APP" /Applications/Buddy.app
    # Update the hook in place only if it is installed; scripts/hooks.py wires up settings.
    if [[ -e "$HOME/.claude/hooks/buddy-hook" ]]; then
      cp build/buddy-hook "$HOME/.claude/hooks/buddy-hook.new"
      mv "$HOME/.claude/hooks/buddy-hook.new" "$HOME/.claude/hooks/buddy-hook"
    fi
    open /Applications/Buddy.app
    echo "installed /Applications/Buddy.app"
    ;;
esac
