#!/bin/zsh
# Time the Clean Up safety checks on disposable fixtures: production sources,
# real git, the real engine, everything in mktemp directories.
#   benchmarks/run-cleanup-perf.sh refresh [--worktrees N] [--rounds R]   Cleanup.find + git/lsof spawns
#   benchmarks/run-cleanup-perf.sh plan    [--worktrees N] [--cards K]    main-thread stalls while a plan streams in
#   benchmarks/run-cleanup-perf.sh node    [--rounds R]                   Tree.node(at:) on 100k entries
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f target/release/libblitztree.a ]] || cargo build --locked --release --lib
PERF_BENCH_TMP=$(mktemp -d /tmp/blitztree-perf-bench-build.XXXXXX)
trap 'rm -rf "$PERF_BENCH_TMP"' EXIT
# Every app source but the entry point (and its Sparkle import), as the
# regression checks build them, so a new file can't leave this behind.
SOURCES=(app/*.swift)
SOURCES=(${SOURCES:#app/Main.swift})
swiftc "${SOURCES[@]}" tests/GitFixture.swift benchmarks/CleanupPerformance.swift \
  -import-objc-header app/bz.h -L target/release -lblitztree \
  -O -parse-as-library -swift-version 6 -default-isolation MainActor \
  -target arm64-apple-macos14.0 -Xcc -include -Xcc removefile.h \
  -framework AppKit -framework SwiftUI -o "$PERF_BENCH_TMP/cleanup-perf"
"$PERF_BENCH_TMP/cleanup-perf" "$@"
