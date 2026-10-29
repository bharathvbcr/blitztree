#!/bin/zsh
# Build BlitzTree.app: Rust engine + Swift UI, assembled into a bundle.
set -euo pipefail
cd "$(dirname "$0")"
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
VERSION=$(awk -F'"' '/^version/{print $2; exit}' Cargo.toml)
# Last three macOS releases. Newer-only UI (Liquid Glass) is gated with
# #available, so the compiler enforces that nothing newer slips in unguarded.
MIN_MACOS=14.0
export MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS

echo "==> Rust engine"
cargo build --locked --release

# Sparkle (auto-updates), pinned by checksum and cached outside git.
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPARKLE=.cache/sparkle-$SPARKLE_VERSION
if [[ ! -d "$SPARKLE/Sparkle.framework" ]]; then
    echo "==> Sparkle $SPARKLE_VERSION"
    mkdir -p "$SPARKLE"
    curl -fsSL -o "$SPARKLE.tar.xz" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    echo "$SPARKLE_SHA256  $SPARKLE.tar.xz" | shasum -a 256 -c --quiet
    tar -xf "$SPARKLE.tar.xz" -C "$SPARKLE" Sparkle.framework bin
    rm "$SPARKLE.tar.xz"
fi

APP=build/BlitzTree.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

echo "==> Swift UI"
# -default-isolation needs Swift 6.1 (Xcode 16.3+). Probe it.
if ! echo 'func bzProbe() {}' | swiftc -swift-version 6 -default-isolation MainActor -typecheck - >/dev/null 2>&1; then
    echo "error: the installed Swift predates 6.1 and cannot build the UI;" >&2
    echo "       default-MainActor isolation and .icon asset compilation need Xcode 26 or newer." >&2
    exit 1
fi
swiftc app/*.swift \
    -import-objc-header app/bz.h \
    -O -parse-as-library -swift-version 6 -default-isolation MainActor \
    -target arm64-apple-macos$MIN_MACOS \
    -L target/release -lblitztree \
    -framework AppKit -framework SwiftUI \
    -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$APP/Contents/MacOS/BlitzTree"
# The XPC services only serve sandboxed apps; BlitzTree isn't sandboxed.
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Headers" \
       "$APP/Contents/Frameworks/Sparkle.framework/Headers" \
       "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/PrivateHeaders" \
       "$APP/Contents/Frameworks/Sparkle.framework/PrivateHeaders"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>BlitzTree</string>
    <key>CFBundleDisplayName</key><string>BlitzTree</string>
    <key>CFBundleIdentifier</key><string>dev.ahmed.blitztree</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>BlitzTree</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Ahmed Khaleel</string>
    <key>SUFeedURL</key><string>https://github.com/ahmedkhaleel2004/blitztree/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>WtmMufGnr61vIAeONfQ4650BqnlBZ1uuD1gmngkX+os=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
</dict>
</plist>
EOF
echo -n 'APPL????' > "$APP/Contents/PkgInfo"
# Icon Composer source → Assets.car (Liquid Glass, macOS 26+) plus a flat
# AppIcon.icns that older systems use. Regenerate the source with
# `python3 assets/gen_icon.py`.
# actool refuses to compile an app icon unless it is told where to write the
# partial Info.plist ("Compiling app icons requires passing
# --output-partial-info-plist"), so it gets a scratch file. The bundle's own
# Info.plist already carries the same keys; they are compared below.
ICON_TMP=$(mktemp -d)
trap 'rm -rf "$ICON_TMP"' EXIT
xcrun actool "$PWD/assets/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" \
    --platform macosx --target-device mac --minimum-deployment-target $MIN_MACOS \
    --app-icon AppIcon --output-partial-info-plist "$ICON_TMP/icon-partial.plist" >/dev/null
for ICON_FILE in Assets.car AppIcon.icns; do
    [[ -f "$APP/Contents/Resources/$ICON_FILE" ]] || { echo "error: actool did not produce $ICON_FILE" >&2; exit 1; }
done
for KEY in CFBundleIconFile CFBundleIconName; do
    [[ "$(plutil -extract $KEY raw "$ICON_TMP/icon-partial.plist")" == "$(plutil -extract $KEY raw "$APP/Contents/Info.plist")" ]] ||
        { echo "error: actool's $KEY disagrees with Info.plist" >&2; exit 1; }
done

# Classic .lproj Localizable.strings tables (swiftc, no Xcode build system).
for LPROJ in app/*.lproj; do
    cp -R "$LPROJ" "$APP/Contents/Resources/"
done

# The GUI executable stays linked to the library built without `cli`.
# This second invocation compiles only the JSON engine. The Swift front
# passes that engine's stdout through and finds it beside itself.
echo "==> Agent CLI"
cargo build --locked --release --features cli --bin blitztree
# Not `blitztree`. The default APFS volume is case-insensitive, so that name
# is the GUI executable `BlitzTree` and the copy would replace the app.
cp -f target/release/blitztree "$APP/Contents/MacOS/blitztree-engine"
swiftc cli/Harness.swift cli/main.swift app/Subprocess.swift \
    -O -parse-as-library -swift-version 6 -default-isolation MainActor \
    -target arm64-apple-macos$MIN_MACOS \
    -o "$APP/Contents/MacOS/cli-anything-blitztree"
cp skills/cli-anything-blitztree/SKILL.md "$APP/Contents/Resources/cli-anything-blitztree-SKILL.md"
[[ "$(stat -f '%i' "$APP/Contents/MacOS/BlitzTree")" != "$(stat -f '%i' "$APP/Contents/MacOS/blitztree-engine")" ]] || {
    echo "error: blitztree-engine and BlitzTree are the same file" >&2
    exit 1
}

# Prefer a real identity: stable code requirement -> TCC/FDA grants survive
# rebuilds. Developer ID (paid program) with the hardened runtime and a secure
# timestamp is what notarization needs; Apple Development is the fallback.
# The Developer ID key lives in its own keychain so codesign never prompts;
# unlock it if this machine has one.
SIGN_KC="$HOME/Library/Keychains/blitztree-signing.keychain-db"
SIGN_PASS="$HOME/.config/blitztree-signing/keychain.pass"
if [[ -f "$SIGN_KC" && -f "$SIGN_PASS" ]]; then
    # `unlock-keychain -p` would put the password in the argv of a process any
    # local user can list with ps. `security -i` reads its commands from stdin
    # instead ("security will enter interactive mode and allow the user to
    # enter multiple commands on stdin", man security), and `print` is a shell
    # builtin, so no process ever carries the password in its arguments.
    # Interactive mode splits the line itself, so refuse anything that would
    # need quoting rather than guess how it parses.
    KC_PASS=$(<"$SIGN_PASS")
    if [[ -z "$KC_PASS" || ! "$KC_PASS" =~ '^[A-Za-z0-9+/=._@%:-]+$' || "$SIGN_KC" == *[\'\\]* ]]; then
        echo "error: $SIGN_PASS must hold one password of letters, digits and + / = . _ @ % : -," >&2
        echo "       and the keychain path must not contain quotes or backslashes." >&2
        exit 1
    fi
    print -r -- "unlock-keychain -p '$KC_PASS' '$SIGN_KC'" | security -i
    unset KC_PASS
fi
IDS=$(security find-identity -v -p codesigning 2>/dev/null)
IDENTITY=$(awk -F'"' '/Developer ID Application/{print $2; exit}' <<<"$IDS")
# Sparkle's helpers are signed inside out before the app (never --deep).
SPARKLE_IN_APP="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -n "$IDENTITY" ]]; then
    SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
else
    IDENTITY=$(awk -F'"' '/Apple Development/{print $2; exit}' <<<"$IDS")
    SIGN=(codesign --force --sign "${IDENTITY:--}")
fi
"${SIGN[@]}" "$SPARKLE_IN_APP/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE_IN_APP/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE_IN_APP"
"${SIGN[@]}" "$APP/Contents/MacOS/blitztree-engine"
"${SIGN[@]}" "$APP/Contents/MacOS/cli-anything-blitztree"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "==> Built and verified $APP"
