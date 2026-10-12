#!/bin/zsh
# String tables: every app/*.lproj/Localizable.strings lints, has the keys and
# format specifiers of en, and has a key for everything app/ asks it for. The
# keys come from the compiler itself (-emit-localized-strings), so every form
# (String(localized:), Text, LocalizedStringKey, .alert, multi-line and raw
# literals, interpolations with their real %lld/%@ types) is covered; only
# Main.swift, which needs Sparkle to compile, is read by a scanner that refuses
# what it cannot read. Offline and fast; also run by tests/run-cleanup.sh.
# Usage: tests/check-l10n.sh [ROOT]   (ROOT: a copy of the repository to check)
set -euo pipefail
HERE="${0:A:h}"
cd "${1:-$HERE/..}"
ROOT=$PWD
TMP=$(mktemp -d /tmp/blitztree-l10n.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
plutil -lint app/*.lproj/Localizable.strings
FLAGS=(-parse-as-library -swift-version 6 -default-isolation MainActor -target arm64-apple-macos14.0)
swiftc "$HERE/L10nChecks.swift" "${FLAGS[@]}" -o "$TMP/l10n"
SOURCES=(app/*.swift)
SOURCES=(${SOURCES:#app/Main.swift})
mkdir "$TMP/emitted"
swiftc "${SOURCES[@]}" "${FLAGS[@]}" -import-objc-header app/bz.h -c -wmo -module-name BlitzTree \
  -o "$TMP/app.o" -emit-localized-strings -emit-localized-strings-path "$TMP/emitted"
"$TMP/l10n" "$ROOT" "$TMP/emitted"
