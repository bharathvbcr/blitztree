#!/bin/zsh
# Deploy: rebuild and update the FDA-granted /Applications copy in place.
# The new bundle is copied next to the destination, verified (signature and
# version), and only then swapped in, so a failed copy or a bad signature never
# leaves /Applications without a working app.
# Overrides, for testing against a scratch folder: DEST=/path/BlitzTree.app,
# SKIP_BUILD=1 (deploy the existing build/BlitzTree.app).
set -euo pipefail
cd "$(dirname "$0")"
DEST="${DEST:-/Applications/BlitzTree.app}"
SOURCE=build/BlitzTree.app
[[ "${SKIP_BUILD:-}" == 1 ]] || ./build.sh
[[ -d "$SOURCE" ]] || { print -u2 "deploy.sh: $SOURCE does not exist; run ./build.sh"; exit 1; }

DEST_DIR=${DEST:h}
[[ -d "$DEST_DIR" && -w "$DEST_DIR" ]] || { print -u2 "deploy.sh: cannot write to $DEST_DIR"; exit 1; }
# Same directory as DEST, so the final moves are renames on one filesystem.
STAGING=$(mktemp -d "$DEST_DIR/.BlitzTree-deploy.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

# Clean replace: a ditto-merge over an old bundle can corrupt the signature,
# and an invalid signature makes TCC silently ignore the FDA grant. So the new
# bundle is copied whole into an empty folder, never over the old one.
ditto "$SOURCE" "$STAGING/new.app"
codesign --verify --deep --strict "$STAGING/new.app"
WANT=$(awk -F'"' '/^version/{print $2; exit}' Cargo.toml)
HAVE=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$STAGING/new.app/Contents/Info.plist")
[[ -n "$WANT" && "$HAVE" == "$WANT" ]] ||
    { print -u2 "deploy.sh: the bundle is version '$HAVE' but Cargo.toml says '$WANT'; not deploying"; exit 1; }

if [[ -e "$DEST" ]]; then
    mv "$DEST" "$STAGING/old.app"
    if ! mv "$STAGING/new.app" "$DEST"; then
        mv "$STAGING/old.app" "$DEST"
        print -u2 "deploy.sh: could not move the new bundle into place; the old one is restored"
        exit 1
    fi
else
    mv "$STAGING/new.app" "$DEST"
fi
if ! codesign --verify --deep --strict "$DEST"; then
    if [[ -e "$STAGING/old.app" ]]; then
        mv "$DEST" "$STAGING/rejected.app"
        mv "$STAGING/old.app" "$DEST"
        print -u2 "deploy.sh: the deployed bundle failed verification; the old one is restored"
    fi
    exit 1
fi
echo "==> Deployed $HAVE to $DEST (signature verified)"
