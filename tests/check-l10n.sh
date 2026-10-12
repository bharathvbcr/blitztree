#!/bin/zsh
# String tables: every app/*.lproj/Localizable.strings lints, has the keys and
# format specifiers of en, and covers every literal app/ passes to the
# localization helper. Offline and fast; also run by tests/run-cleanup.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d /tmp/blitztree-l10n.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
plutil -lint app/*.lproj/Localizable.strings
swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos14.0 tests/L10nChecks.swift -o "$TMP/l10n"
"$TMP/l10n" "$PWD"
