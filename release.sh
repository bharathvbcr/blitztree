#!/bin/zsh
# Build, notarize, package as dmg, and publish a GitHub release.
# Usage: ./release.sh 0.1.0 [notes.md]
#
# Refuses (before anything is published) unless:
#   - $1 equals the Cargo.toml version, which build.sh writes into Info.plist,
#     and CHANGELOG.md has a `## $1` section;
#   - the git tree is clean, so the bundle is exactly what HEAD contains;
#   - cargo test and tests/run-cleanup.sh pass;
#   - the app carries a Developer ID signature (ALLOW_UNNOTARIZED=1 ships an
#     unnotarized build on purpose);
#   - HEAD is on a pushed branch, because the release tag is created at HEAD.
# DRY_RUN=1 runs all of that, then stops before notarizing or publishing.
set -euo pipefail
cd "$(dirname "$0")"
V="${1:?version, e.g. 0.1.0}"
NOTES_FILE="${2:-}"

die() { print -u2 -- "release.sh: $*"; exit 1; }

# One scratch directory for every temporary file; the trap runs on success,
# failure and interrupt alike.
WORK=$(mktemp -d /tmp/blitztree-release.XXXXXX)
trap 'rm -rf "$WORK"; rm -f SHA256SUMS.txt appcast.xml' EXIT

CARGO_VERSION=$(awk -F'"' '/^version/{print $2; exit}' Cargo.toml)
[[ -n "$CARGO_VERSION" ]] || die "could not read the version from Cargo.toml"
[[ "$V" == "$CARGO_VERSION" ]] ||
    die "version $V does not match Cargo.toml ($CARGO_VERSION); build.sh would ship a $CARGO_VERSION bundle tagged v$V. Bump Cargo.toml (and Cargo.lock) first."
awk -v v="$V" '$0 == "## " v || index($0, "## " v " ") == 1 {found = 1} END {exit !found}' CHANGELOG.md ||
    die "CHANGELOG.md has no \"## $V\" section"

[[ -z "$(git status --porcelain)" ]] ||
    die "the working tree is not clean; commit or remove these first:
$(git status --short)"
HEAD_SHA=$(git rev-parse HEAD)

echo "==> Tests"
cargo test --locked --release
tests/run-cleanup.sh

./build.sh

# Tests and the build must leave the tree as they found it.
[[ -z "$(git status --porcelain)" && "$(git rev-parse HEAD)" == "$HEAD_SHA" ]] ||
    die "the tests or the build changed the working tree or HEAD"

# Notarize when the app carries a Developer ID signature and notary
# credentials are stored (one-time: `xcrun notarytool store-credentials
# blitztree-notary --key <AuthKey.p8> --key-id <id> --issuer <uuid>`).
# The app is stapled before packaging so it opens offline once copied out
# of the dmg; the dmg is then signed, notarized and stapled itself.
# (-dvv: plain -dv never prints the Authority lines.)
codesign --verify --deep --strict build/BlitzTree.app
DEVID=$(codesign -dvv build/BlitzTree.app 2>&1 | awk -F= '/^Authority=Developer ID Application/ && !n++ {print $2}')
NOTARIZE=0
if [[ -n "$DEVID" ]]; then
    NOTARIZE=1
elif [[ "${ALLOW_UNNOTARIZED:-}" != 1 ]]; then
    die "build/BlitzTree.app has no Developer ID signature, so it cannot be notarized (README promises a notarized app). Install the Developer ID identity, or set ALLOW_UNNOTARIZED=1 to ship an unnotarized build."
fi

# The tag is created at HEAD (--target below); GitHub must have that commit.
if [[ "${DRY_RUN:-}" != 1 && "${ALLOW_UNPUSHED:-}" != 1 ]]; then
    [[ -n "$(git for-each-ref --contains "$HEAD_SHA" refs/remotes/origin)" ]] ||
        die "HEAD $HEAD_SHA is not on any origin branch; push it first so the release tag points at a commit GitHub has."
fi

# Sparkle's signing tool, from the version build.sh pins (never a glob).
SPARKLE_VERSION=$(awk -F= '/^SPARKLE_VERSION=/{print $2; exit}' build.sh)
[[ -n "$SPARKLE_VERSION" ]] || die "could not read SPARKLE_VERSION from build.sh"
SIGN_UPDATE=".cache/sparkle-$SPARKLE_VERSION/bin/sign_update"
[[ -x "$SIGN_UPDATE" ]] || die "$SIGN_UPDATE is missing; run ./build.sh to fetch Sparkle $SPARKLE_VERSION"

if [[ "${DRY_RUN:-}" == 1 ]]; then
    echo "==> DRY_RUN: every check passed for v$V at $HEAD_SHA (notarize=$NOTARIZE); nothing notarized or published"
    exit 0
fi

if (( NOTARIZE )); then
    echo "==> Notarizing app"
    ZIP="$WORK/BlitzTree.zip"
    ditto -c -k --keepParent build/BlitzTree.app "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile blitztree-notary --wait
    xcrun stapler staple build/BlitzTree.app
fi

STAGE="$WORK/stage"
mkdir "$STAGE"
cp -R build/BlitzTree.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "BlitzTree.dmg"
hdiutil create -volname BlitzTree -srcfolder "$STAGE" -ov -format UDZO -quiet BlitzTree.dmg

if (( NOTARIZE )); then
    echo "==> Notarizing dmg"
    codesign --force --timestamp --sign "$DEVID" BlitzTree.dmg
    xcrun notarytool submit BlitzTree.dmg --keychain-profile blitztree-notary --wait
    xcrun stapler staple BlitzTree.dmg
    spctl --assess --type open --context context:primary-signature -v BlitzTree.dmg
    NOTES="Download BlitzTree.dmg and drag it to Applications, then grant Full Disk Access when asked and relaunch."
else
    NOTES="Download BlitzTree.dmg, drag to Applications. First launch: System Settings → Privacy & Security → Open Anyway (unnotarized build), then grant Full Disk Access and relaunch."
fi
[[ -n "$NOTES_FILE" ]] && NOTES=$(<"$NOTES_FILE")

# Sparkle appcast: installed apps read it from the latest release
# (SUFeedURL in build.sh). The dmg is EdDSA-signed with the key from
# `generate_keys --account blitztree` (backed up in ~/.config/blitztree-signing).
SPARKLE_KEY="$HOME/.config/blitztree-signing/sparkle-ed25519.key"
if [[ -f "$SPARKLE_KEY" ]]; then
    ED=$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY" BlitzTree.dmg)
else
    ED=$("$SIGN_UPDATE" --account blitztree BlitzTree.dmg)
fi
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" build/BlitzTree.app/Contents/Info.plist)
# The update window shows the notes above the install section, as HTML.
CHANGES_HTML=$(gh api markdown -f text="${NOTES%%'### Install'*}")
cat > appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
<title>BlitzTree</title>
<item>
    <title>BlitzTree $V</title>
    <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
    <sparkle:version>$V</sparkle:version>
    <sparkle:shortVersionString>$V</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
    <sparkle:fullReleaseNotesLink>https://github.com/ahmedkhaleel2004/blitztree/releases/tag/v$V</sparkle:fullReleaseNotesLink>
    <description><![CDATA[$CHANGES_HTML]]></description>
    <enclosure url="https://github.com/ahmedkhaleel2004/blitztree/releases/download/v$V/BlitzTree.dmg" $ED type="application/octet-stream"/>
</item>
</channel>
</rss>
EOF
xmllint --noout appcast.xml

shasum -a 256 BlitzTree.dmg > SHA256SUMS.txt
if gh release view "v$V" >/dev/null 2>&1; then
    # Uploading again would attach this build to the existing tag, which may
    # name an older commit. This script does not move a published tag.
    die "release v$V already exists. Refusing to upload files onto it or to move tag v$V. Delete the release and the tag, then run this again so v$V is created at the tested commit $HEAD_SHA."
else
    # --target pins the tag to the commit that was tested and built.
    gh release create "v$V" BlitzTree.dmg SHA256SUMS.txt appcast.xml \
        --target "$HEAD_SHA" \
        --title "BlitzTree $V" \
        --notes "$NOTES" \
        --latest
fi
echo "==> released v$V"
