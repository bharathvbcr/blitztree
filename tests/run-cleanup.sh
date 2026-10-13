#!/bin/zsh
# Offline regression checks. All filesystem operations stay in disposable fixtures.
set -euo pipefail
SELF=${0:A}
cd "${SELF:h}/.."
# A check that cannot run here (no Keychain, no hdiutil, no fish ...) prints a
# line starting with SKIP and carries on: a skip is not a failure, so the exit
# code is untouched. But a skipped check must never read as a plain pass, so
# the run is wrapped: everything it prints is kept, and when it ends every SKIP
# line is listed again with a count (and, on GitHub Actions, as a warning
# annotation on the run page).
if [[ -z "${BZ_CLEANUP_INNER:-}" ]]; then
  RUN_LOG=$(mktemp /tmp/blitztree-cleanup-log.XXXXXX)
  set +e
  BZ_CLEANUP_INNER=1 zsh "$SELF" "$@" 2>&1 | tee "$RUN_LOG"
  RUN_STATUS=${pipestatus[1]}
  set -e
  SKIPS=("${(@f)$(grep -E '^SKIP' "$RUN_LOG" || true)}")
  SKIPS=("${(@)SKIPS:#}")
  rm -f "$RUN_LOG"
  if (( ${#SKIPS} == 0 )); then
    echo "no checks skipped"
  else
    echo "${#SKIPS} checks SKIPPED (not failures, but nothing was checked):"
    for line in "${SKIPS[@]}"; do
      echo "  $line"
      [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::warning title=Check skipped::${line//\%/%25}"
    done
  fi
  exit $RUN_STATUS
fi
CLEANUP_TEST_TMP=$(mktemp -d /tmp/blitztree-cleanup-checks.XXXXXX)
PROVIDER_MOCK=""
# Only the mock this script started (by PID) is stopped on the way out.
trap '[[ -n "$PROVIDER_MOCK" ]] && kill "$PROVIDER_MOCK" 2>/dev/null; rm -rf "$CLEANUP_TEST_TMP"' EXIT
FLAGS=(-parse-as-library -swift-version 6 -default-isolation MainActor -target arm64-apple-macos14.0)
swiftc app/CleanupCommand.swift tests/CleanupCommandChecks.swift "${FLAGS[@]}" -o "$CLEANUP_TEST_TMP/commands"
"$CLEANUP_TEST_TMP/commands"
# The guard verifies linked git worktrees and runs each rule's check, so it compiles with GitWorktree, CleanupVerify and
# the session-log reader it consults; the checks build fixtures with real git.
GUARD=(app/CleanupSafety.swift app/CleanupVerify.swift app/GitWorktree.swift app/Subprocess.swift app/AgentSessions.swift tests/GitFixture.swift)
swiftc "${GUARD[@]}" tests/CleanupSafetyChecks.swift "${FLAGS[@]}" -o "$CLEANUP_TEST_TMP/paths"
"$CLEANUP_TEST_TMP/paths"
swiftc "${GUARD[@]}" app/CleanupOperations.swift tests/WorktreeChecks.swift \
  "${FLAGS[@]}" -Xcc -include -Xcc removefile.h -o "$CLEANUP_TEST_TMP/worktrees"
"$CLEANUP_TEST_TMP/worktrees"
# Claude Code scratchpads: path shape, the live-session registry, and the
# policy that refuses a running session's build output at every capture.
swiftc "${GUARD[@]}" tests/ScratchpadChecks.swift \
  "${FLAGS[@]}" -o "$CLEANUP_TEST_TMP/scratchpad"
"$CLEANUP_TEST_TMP/scratchpad"
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
swiftc "${SOURCES[@]}" tests/VolumeChecks.swift "${FLAGS[@]}" \
  -import-objc-header app/bz.h -L target/release -lblitztree \
  -framework AppKit -framework SwiftUI -o "$CLEANUP_TEST_TMP/volumes"
"$CLEANUP_TEST_TMP/volumes"
swiftc "${SOURCES[@]}" tests/PlannerFallbackChecks.swift "${FLAGS[@]}" \
  -import-objc-header app/bz.h -L target/release -lblitztree \
  -framework AppKit -framework SwiftUI -o "$CLEANUP_TEST_TMP/planner"
"$CLEANUP_TEST_TMP/planner"
# MANVI as a planner: its event stream, the strict-posture gate and the
# environment BlitzTree pins. No MANVI binary or model is needed.
swiftc "${SOURCES[@]}" tests/ManviChecks.swift "${FLAGS[@]}" \
  -import-objc-header app/bz.h -L target/release -lblitztree \
  -framework AppKit -framework SwiftUI -o "$CLEANUP_TEST_TMP/manvi"
"$CLEANUP_TEST_TMP/manvi"
swiftc "${SOURCES[@]}" tests/TypesIntegrationChecks.swift "${FLAGS[@]}" \
  -import-objc-header app/bz.h -L target/release -lblitztree \
  -framework AppKit -framework SwiftUI -o "$CLEANUP_TEST_TMP/types"
"$CLEANUP_TEST_TMP/types"
swiftc "${SOURCES[@]}" tests/ListIntegrationChecks.swift "${FLAGS[@]}" \
  -import-objc-header app/bz.h -L target/release -lblitztree \
  -framework AppKit -framework SwiftUI -o "$CLEANUP_TEST_TMP/list"
"$CLEANUP_TEST_TMP/list"
# A scan that ends without a tree reads as failed and a new one is allowed.
swiftc "${SOURCES[@]}" tests/ScanFailureChecks.swift "${FLAGS[@]}" \
  -import-objc-header app/bz.h -L target/release -lblitztree \
  -framework AppKit -framework SwiftUI -o "$CLEANUP_TEST_TMP/scanfail"
"$CLEANUP_TEST_TMP/scanfail"
# Sign-in opens the authorize URL itself. No scan engine and no real browser.
swiftc app/AgentLogin.swift app/Subprocess.swift tests/AgentLoginChecks.swift "${FLAGS[@]}" \
  -framework AppKit -o "$CLEANUP_TEST_TMP/login"
"$CLEANUP_TEST_TMP/login"
# The shared subprocess helper: SIGPIPE, bounded and cancellable waits, no
# leaked reader or descriptor, the install script, many children at once.
swiftc "${SOURCES[@]}" tests/SubprocessChecks.swift "${FLAGS[@]}" \
  -import-objc-header app/bz.h -L target/release -lblitztree \
  -framework AppKit -framework SwiftUI -o "$CLEANUP_TEST_TMP/subprocess"
"$CLEANUP_TEST_TMP/subprocess"
# The custom-provider pipeline against a local mock: stream shapes, errors,
# refused http, and that a redirect never carries the key to another origin.
# The mock picks free loopback ports and reports them in a file.
swiftc -parse-as-library app/PlanParsing.swift app/ModelProvider.swift tests/provider-pipeline/main.swift \
  -o "$CLEANUP_TEST_TMP/provider-pipeline"
python3 tests/provider-pipeline/server.py "$CLEANUP_TEST_TMP/ports.json" &
PROVIDER_MOCK=$!
for _ in {1..100}; do [[ -s "$CLEANUP_TEST_TMP/ports.json" ]] && break; sleep 0.1; done
[[ -s "$CLEANUP_TEST_TMP/ports.json" ]] || { echo "provider mock did not start" >&2; exit 1; }
"$CLEANUP_TEST_TMP/provider-pipeline" "$CLEANUP_TEST_TMP/ports.json"
# The string tables: same keys and format specifiers in all 7 languages, and a
# key for every literal app/ localizes. Offline; also runnable alone.
tests/check-l10n.sh
# The maps' geometry: squarified treemap (areas, overlap, containment, pixel
# coverage), the leaf index and the rings' angles, on random input and a scan.
swiftc "${SOURCES[@]}" tests/LayoutChecks.swift "${FLAGS[@]}" \
  -import-objc-header app/bz.h -L target/release -lblitztree \
  -framework AppKit -framework SwiftUI -o "$CLEANUP_TEST_TMP/layout"
"$CLEANUP_TEST_TMP/layout"
# PartialPlanParser and PlanJSON on recorded stream shapes, in every chunking. No server.
swiftc app/PlanParsing.swift tests/PlanParsingChecks.swift "${FLAGS[@]}" -o "$CLEANUP_TEST_TMP/plan-parsing"
"$CLEANUP_TEST_TMP/plan-parsing"
# The engine on non-APFS volumes (HFS+, ExFAT, FAT32 disk images) and a volume
# mounted inside the scanned tree. Ignored by plain `cargo test`, so they run
# here; without hdiutil they are reported as skipped, never as passed.
if [[ -x /usr/bin/hdiutil ]]; then
  cargo test --locked --release --lib volume_tests -- --ignored --test-threads=1 2>&1 | tee "$CLEANUP_TEST_TMP/volume-tests.log"
  grep -q "test result: ok. 2 passed" "$CLEANUP_TEST_TMP/volume-tests.log"
else
  echo "SKIPPED: engine tests on disk images (no /usr/bin/hdiutil); nothing was checked"
fi
# Stopping a scan, the earlier tree coming back, and the coverage the engine
# reports reaching the app (marks, summary text, strings in every language).
swiftc "${SOURCES[@]}" tests/ScanCancelChecks.swift "${FLAGS[@]}" \
  -import-objc-header app/bz.h -L target/release -lblitztree \
  -framework AppKit -framework SwiftUI -o "$CLEANUP_TEST_TMP/scancancel"
"$CLEANUP_TEST_TMP/scancancel"
# VoiceOver on the treemap and the rings (rows, press, announcements), and error
# text made with String(localized:), its keys in all seven tables. Runs from the
# repository root: it reads app/*.swift and app/*.lproj.
swiftc "${SOURCES[@]}" tests/AccessibilityChecks.swift "${FLAGS[@]}" \
  -import-objc-header app/bz.h -L target/release -lblitztree \
  -framework AppKit -framework SwiftUI -o "$CLEANUP_TEST_TMP/accessibility"
"$CLEANUP_TEST_TMP/accessibility"

