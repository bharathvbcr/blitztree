#!/bin/zsh
# Time Cleanup.find and count git/lsof spawns on a disposable home with N linked
# git worktrees. Production sources, real git, real engine, fixtures in mktemp.
#   benchmarks/run-worktree.sh [--worktrees N] [--rounds R]
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f target/release/libblitztree.a ]] || cargo build --locked --release --lib
WORKTREE_BENCH_TMP=$(mktemp -d /tmp/blitztree-worktree-bench-build.XXXXXX)
trap 'rm -rf "$WORKTREE_BENCH_TMP"' EXIT
# Every app source but the entry point (and its Sparkle import), as the
# regression checks build them, so a new file can't leave this behind.
SOURCES=(app/*.swift)
SOURCES=(${SOURCES:#app/Main.swift})
swiftc "${SOURCES[@]}" tests/GitFixture.swift benchmarks/WorktreeRefresh.swift \
  -import-objc-header app/bz.h -L target/release -lblitztree \
  -O -parse-as-library -swift-version 6 -default-isolation MainActor \
  -target arm64-apple-macos14.0 -Xcc -include -Xcc removefile.h \
  -framework AppKit -framework SwiftUI -o "$WORKTREE_BENCH_TMP/worktree-refresh"
"$WORKTREE_BENCH_TMP/worktree-refresh" "$@"
