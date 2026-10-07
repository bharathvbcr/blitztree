#!/bin/zsh
# Offline regression checks. All filesystem operations stay in disposable fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."
CLEANUP_TEST_TMP=$(mktemp -d /tmp/blitztree-cleanup-checks.XXXXXX)
trap 'rm -rf "$CLEANUP_TEST_TMP"' EXIT
FLAGS=(-parse-as-library -swift-version 6 -default-isolation MainActor -target arm64-apple-macos14.0)
swiftc app/CleanupCommand.swift tests/CleanupCommandChecks.swift "${FLAGS[@]}" -o "$CLEANUP_TEST_TMP/commands"
"$CLEANUP_TEST_TMP/commands"
# The guard verifies linked git worktrees, so it compiles with GitWorktree and
# the session-log reader it consults; the checks build fixtures with real git.
GUARD=(app/CleanupSafety.swift app/GitWorktree.swift app/AgentSessions.swift tests/GitFixture.swift)
swiftc "${GUARD[@]}" tests/CleanupSafetyChecks.swift "${FLAGS[@]}" -o "$CLEANUP_TEST_TMP/paths"
"$CLEANUP_TEST_TMP/paths"
swiftc "${GUARD[@]}" app/CleanupVerify.swift app/CleanupOperations.swift tests/WorktreeChecks.swift \
  "${FLAGS[@]}" -Xcc -include -Xcc removefile.h -o "$CLEANUP_TEST_TMP/worktrees"
"$CLEANUP_TEST_TMP/worktrees"
cargo build --locked --release --lib
SOURCES=(app/*.swift)
SOURCES=(${SOURCES:#app/Main.swift})
swiftc "${SOURCES[@]}" tests/CleanupIntegrationChecks.swift "${FLAGS[@]}" \
  -import-objc-header app/bz.h -L target/release -lblitztree \
  -framework AppKit -framework SwiftUI -o "$CLEANUP_TEST_TMP/integration"
for LPROJ in app/*.lproj; do
  cp -R "$LPROJ" "$CLEANUP_TEST_TMP/"
done
"$CLEANUP_TEST_TMP/integration"
swiftc "${SOURCES[@]}" tests/SearchIntegrationChecks.swift "${FLAGS[@]}" \
  -import-objc-header app/bz.h -L target/release -lblitztree \
  -framework AppKit -framework SwiftUI -o "$CLEANUP_TEST_TMP/search"
"$CLEANUP_TEST_TMP/search"

