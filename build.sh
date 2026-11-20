#!/bin/sh
# Builds "Maben Schema.app" into ./build.
#   ./build.sh            -> build only
#   ./build.sh install    -> build, copy to /Applications and open it
#   ./build.sh demo       -> build a debug copy and open it on the sample diagram
#   ./build.sh xcode      -> make and open an Xcode project (needs xcodegen)
#   ./build.sh check      -> unit tests, then the editing self-test (no window shows, your clipboard isn't touched)
set -e
cd "$(dirname "$0")"

if [ "$1" = "xcode" ]; then
    # The same project release.sh builds from; not kept in git.
    ./build.sh >/dev/null
    cp Info.plist build/Info-release.plist
    xcodegen generate --quiet && open MabenSchema.xcodeproj
    exit 0
fi

if [ "$1" = "check" ]; then
    swift test 2>&1 | grep -E "error:|Executed .* tests" | tail -3
    swift build --product Schema >/dev/null
    "$(swift build --show-bin-path)/Schema" --selftest | grep -v "^ok" 
    exit 0
fi

CONFIG=release
[ "$1" = "demo" ] && CONFIG=debug
swift build -c $CONFIG --product Schema
BIN=$(swift build -c $CONFIG --show-bin-path)/Schema

# App icon: render once, then build the .icns from the 1024px PNG.
if [ ! -f build/AppIcon.icns ] || [ Resources/make-icon.swift -nt build/AppIcon.icns ]; then
    mkdir -p build/AppIcon.iconset
    swift Resources/make-icon.swift build/icon-1024.png >/dev/null
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
        sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
    done
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
# macOS 26 and later: the layered icon (lime in light, lime mark on black in dark, tinted and clear).
# Without it, the Dark icon style turns the flat icon above black. AppIcon.icns stays for macOS 14 and 15.
if [ ! -f build/icon/Assets.car ] || [ -n "$(find Resources/AppIcon.icon -newer build/icon/Assets.car)" ]; then
    rm -rf build/icon && mkdir -p build/icon
    xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/build/icon" --platform macosx --minimum-deployment-target 14.0 \
        --app-icon AppIcon --output-partial-info-plist "$PWD/build/icon/partial.plist" >/dev/null
    rm -f build/icon/AppIcon.icns build/icon/partial.plist
fi

APP="build/Maben Schema.app"
[ "$CONFIG" = "debug" ] && APP="build/demo/Maben Schema.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Schema"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" "$APP/Contents/Info.plist"
cp build/AppIcon.icns build/icon/Assets.car "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

if [ "$1" = "demo" ]; then
    [ -n "$NO_OPEN" ] && exit 0
    open -n "$APP" --args --demo
    exit 0
fi
[ "$1" = "install" ] || exit 0

osascript -e 'quit app "Maben Schema"' >/dev/null 2>&1 || true
sleep 1
rm -rf "/Applications/Maben Schema.app"
cp -R "$APP" /Applications/
echo "Installed /Applications/Maben Schema.app"
open "/Applications/Maben Schema.app"
