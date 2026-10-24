#!/bin/bash
# Builds DeskKit.app as a universal binary (arm64 + x86_64) that runs on macOS 12 and later,
# signs it, and installs it in /Applications.
#
#   ./build.sh               build and install (restarting DeskKit if it is running)
#   ./build.sh --no-install  only build, into build/DeskKit.app
#
# Signing: with a "Developer ID Application" certificate in your keychain, DeskKit is signed with
# it (hardened runtime, secure timestamp), so macOS keeps its permissions across updates and the
# app can be notarized (see release.sh). Without one it is signed ad hoc, and macOS asks for its
# permissions again after every build. Set DESKKIT_SIGN_IDENTITY to choose a certificate.
set -euo pipefail
cd "$(dirname "$0")"

NAME=DeskKit
BUNDLE_ID=tech.quenneville.DeskKit
VERSION=1.0
BUILD_NUMBER=1
BUILD=build
APP="$BUILD/$NAME.app"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc is missing. Install Apple's command line tools first:  xcode-select --install" >&2
    exit 1
fi

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources -name '*.swift' | sort)

rm -rf "$BUILD"
mkdir -p "$BUILD"

# The Swift 5.6 back-deployment library only matters on macOS 12.0–12.2, and newer toolchains
# (the macOS 27 SDK) ship it without an Intel slice. Skip it for any architecture it lacks.
COMPAT56="$(dirname "$(xcrun --find swiftc)")/../lib/swift/macosx/libswiftCompatibility56.a"

# Without -module-name, swiftc names the module after the output file and fails on "DeskKit-arm64".
# ScreenCaptureKit is weak-linked: it only exists from macOS 12.3.
for ARCH in arm64 x86_64; do
    echo "Compiling for $ARCH…"
    EXTRA=()
    if [[ -f "$COMPAT56" ]] && ! lipo -archs "$COMPAT56" | grep -qw "$ARCH"; then
        EXTRA=(-runtime-compatibility-version none)
    fi
    swiftc -module-name DeskKit -swift-version 5 -O \
        -target "$ARCH-apple-macos12.0" \
        -framework AppKit -framework ServiceManagement \
        -Xlinker -weak_framework -Xlinker ScreenCaptureKit \
        ${EXTRA[@]+"${EXTRA[@]}"} \
        "${SOURCES[@]}" -o "$BUILD/$NAME-$ARCH"
done
lipo -create -output "$BUILD/$NAME" "$BUILD/$NAME-arm64" "$BUILD/$NAME-x86_64"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BUILD/$NAME" "$APP/Contents/MacOS/$NAME"
rm "$BUILD/$NAME-arm64" "$BUILD/$NAME-x86_64"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$NAME</string>
    <key>CFBundleExecutable</key>
    <string>$NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Christopher Quenneville. MIT License.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

IDENTITY="${DESKKIT_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    echo "Signed with $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Signed ad hoc (no Developer ID Application certificate found)"
fi
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/$NAME"))"

if [[ "${1:-}" == "--no-install" ]]; then
    exit 0
fi

WAS_RUNNING=0
if pgrep -xq "$NAME"; then
    WAS_RUNNING=1
    pkill -x "$NAME" || true
    while pgrep -xq "$NAME"; do sleep 0.1; done
fi
rm -rf "/Applications/$NAME.app"
ditto "$APP" "/Applications/$NAME.app"
echo "Installed /Applications/$NAME.app"
if [[ $WAS_RUNNING == 1 ]]; then
    open "/Applications/$NAME.app"
    echo "Restarted $NAME"
else
    echo "Start it with:  open /Applications/$NAME.app"
fi
