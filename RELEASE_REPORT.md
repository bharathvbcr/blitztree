# Release Preparation Report: BlitzTree v0.7.0

**Target Version:** `v0.7.0` (`0.7.0`)  
**Push Execution:** `PUSH: no` (Release prepared and verified locally; no commits or tags were pushed to `origin`)  
**Date:** 2026-10-12  
**HEAD Commit:** `514220b` (`main`)  

---

## 1. Executive Summary

BlitzTree `main` has been audited, hardened, and verified for the `v0.7.0` release:
- **Clean Tree:** The working tree is completely clean and verified on committed HEAD (`514220b`).
- **Full CI Verification (`ci:local`):** 100% passing across all 19 build, test, and benchmark verification steps:
  - 149 Rust unit/integration tests passed (`--locked --release`, `--features cli`, `--no-default-features`).
  - 45 Python CLI contract tests passed.
  - All Swift check suites passed (Localization, Safety, Integration, Worktree, Volume, Layout, Export, Cancel, Accessibility).
  - All 4 benchmark regression gates passed (UI, Agent, Rendering, Model Handoff).
  - Dry run release pipeline passed (`DRY_RUN=1 ALLOW_UNNOTARIZED=1 ./release.sh 0.7.0`).
- **Pipeline Hardened:** Resolved critical failure points across `deploy.sh`, `build.sh`, `release.sh`, and `.github/workflows/ci.yml`. Satisfied all `cargo fmt` and `cargo clippy -D warnings` requirements on the Rust engine.
- **Release Notes & Documentation:** Comprehensive release notes added to `CHANGELOG.md` covering all 60+ commits landed since the initial 0.7.0 bump, with clarification on 0.6.1 verifier boundaries.

---

## 2. Phase 1: Orientation & Git State

### GitPulse Insights
- **Worktrees:** 1 active worktree (`/Users/bharath/Code/devtools/Blitztree`).
- **Live Agents:** 1 idle Claude Desktop session; no active concurrent agent modifications.
- **Collisions:** 0 overlapping files across worktrees or sessions.
- **Ledger:** Event logging active (`.devcouncil/ledger.sqlite`).

### Git Branch & Tag Status
- **Current Branch:** `main` (clean working tree).
- **Branch Tracking:** `main` is ahead of `origin/main` by **140 commits**. `origin/main` currently points to `d5a0fc8` (`v0.5.6`).
- **Tag Discrepancy:**
  - Remote tags (`git ls-remote --tags origin`) end at `v0.5.6`.
  - Local tag `v0.6.1` (`6b999ed`) exists locally but **was never pushed to origin**.
  - Local tag `v0.6.0` was **never created in git** (although `CHANGELOG.md` has a `## 0.6.0` entry and release commit `b87f420` exists).
  - `v0.7.0` tag does not yet exist locally or remotely.

### Owner Decision Context
- **Task `ft-bc6f81a2ef6dd4df1478679dac6349c4` (status: review):**
  Identified release script risks and noted that 0.6.0 and 0.6.1 were never published upstream. Settles that the owner must decide whether to publish `v0.6.1` retroactively or roll upstream directly from `v0.5.6` to `v0.7.0`.
- **Task `ft-aff09dadbc1cce48c140a44b3e8271d5` (status: review):**
  Noted that CI had never run on GitHub and was blocked on 159 `rustfmt` hunks and 38 `clippy` errors under `-D warnings`.

---

## 3. Phase 2 & 4: Commits Made in this Session

Four logical Conventional Commits were created on `main`:

| Commit | Type | GitPulse Task | Description |
|---|---|---|---|
| [`80d7194`](file:///Users/bharath/Code/devtools/Blitztree/src/ffi.rs#L10) | `chore(ci)` | `ft-aff09dad` | Format Rust engine and satisfy `cargo clippy -D warnings` (allowed `not_unsafe_ptr_arg_deref` in `src/ffi.rs` for C ABI entry points; allowed `type_complexity` in `src/cleanup.rs` test tables; updated `docs/issues/T1-ci-workflow.md`). |
| [`e908f2f`](file:///Users/bharath/Code/devtools/Blitztree/deploy.sh#L18) | `chore(release)` | `ft-bc6f81a` | Harden deploy, build, and release scripts (`deploy.sh` trap restoration; `build.sh` post-sign codesign verification and Sparkle header cleanup; `release.sh` DRY_RUN without requiring pushed HEAD, OS version formatting, and `--latest` flag). |
| [`48d45bd`](file:///Users/bharath/Code/devtools/Blitztree/.github/workflows/ci.yml#L29) | `ci` | `ft-aff09dad` | Pin GitHub Actions to commit SHAs (`actions/checkout@11bd719`, `actions/setup-python@4237552`) and set `persist-credentials: false` on all 5 checkout jobs. |
| [`514220b`](file:///Users/bharath/Code/devtools/Blitztree/CHANGELOG.md#L3) | `docs` | — | Update `CHANGELOG.md` for 0.7.0 release with complete feature coverage (CSV export, VoiceOver, Trash boundary verifier, thread pools, scan cancel) and clarify 0.6.1 panel verifier scope. |

---

## 4. Phase 3: Verification with `ci:local`

All checks were executed on committed `HEAD` (`514220b`):

| Check / Suite | Command | Result | Metrics / Test Counts |
|---|---|---|---|
| **Rust Formatting** | `cargo fmt --check` | **PASS** | 0 formatting hunks (clean) |
| **Rust Clippy** | `cargo clippy --locked --all-targets --features cli -- -D warnings` | **PASS** | 0 errors, 0 warnings |
| **Rust Engine (Default)** | `cargo test --locked --release` | **PASS** | **149 passed**, 0 failed, 9 ignored |
| **Rust Engine (CLI Feature)** | `cargo test --locked --release --features cli` | **PASS** | **149 passed**, 0 failed, 9 ignored |
| **Rust Engine (No Default)** | `cargo test --locked --release --no-default-features` | **PASS** | **149 passed**, 0 failed, 9 ignored |
| **Rust Engine Binary** | `cargo build --locked --release` | **PASS** | Static lib `libblitztree.a` built in 0.01s |
| **CLI Binary Build** | `cargo build --locked --release --features cli --bin blitztree` | **PASS** | Binary `target/release/blitztree` built |
| **CLI Contract Tests** | `python3 -m unittest discover -s tests -p 'test_*.py' -v` | **PASS** | **45 passed** in 2.881s |
| **Localization Tables** | `tests/check-l10n.sh` | **PASS** | 7 string tables verified with compiler emission parity |
| **Swift Regression Checks** | `tests/run-cleanup.sh` | **PASS** | All checks passed (2 environment-specific skips: cloud-only chflags, fish probe) |
| **Swift App Build** | `./build.sh` | **PASS** | App bundle `build/BlitzTree.app` built |
| **Bundle Assets** | `test -f Assets.car -a -f AppIcon.icns` | **PASS** | Liquid Glass and flat icons present |
| **Code Signature** | `codesign --verify --deep --strict build/BlitzTree.app` | **PASS** | Signature verified with hardened runtime |
| **Benchmark Fixtures** | `benchmarks/check-fixtures.sh` | **PASS** | All 47 `bz.h` functions defined in model & UI fixtures |
| **UI Benchmarks** | `benchmarks/run-ui.sh --check-only` | **PASS** | Outline, cleanup parity, shape invalidation verified |
| **Agent Benchmarks** | `benchmarks/run-agent.sh --check-only` | **PASS** | Parser split, JSONL parity, prompt byte equality verified |
| **Rendering Regression** | `python3 benchmarks/rendering.py --baseline bf3b1fc --check-only` | **PASS** | 28 pixel comparisons, 126 cushion scales, 260k hit checks |
| **Model Handoff** | `python3 benchmarks/model-handoff.py` | **PASS** | Tree-first handoff and stale-volume rejection verified |
| **Release Pipeline Dry Run** | `DRY_RUN=1 ALLOW_UNNOTARIZED=1 ./release.sh 0.7.0` | **PASS** | Full pre-flight passed on committed HEAD |

---

## 5. Phase 4: Release Pipeline Audit Findings

Audit conducted across workflows, build scripts, version files, and update mechanisms:

### A. Fixed in this Session
1. **`deploy.sh` Data Loss Vulnerability (Critical):**
   - *Issue:* If deployment was interrupted between moving the old app and moving the new app, `trap 'rm -rf "$STAGING"' EXIT` wiped the user's installed application without rollback.
   - *Fix:* Replaced with `cleanup()` trap that restores `$STAGING/old.app` to `$DEST` if `$DEST` does not exist before removing staging.
2. **`deploy.sh` Destination Cleanup (Warning):**
   - *Issue:* If a fresh install failed codesign verification, the corrupted bundle was left in `/Applications`.
   - *Fix:* Added explicit `rm -rf "$DEST"` on fresh install failure.
3. **`build.sh` Missing Signature Verification (Warning):**
   - *Issue:* Bundle was signed but never verified before exiting 0.
   - *Fix:* Added `codesign --verify --deep --strict "$APP"` directly to `build.sh`.
4. **`build.sh` Developer Header Leak (Warning):**
   - *Issue:* `Headers/` and `PrivateHeaders/` were copied into `Sparkle.framework` inside the release app bundle.
   - *Fix:* Stripped headers before code signing.
5. **`build.sh` Compiler Probe Error Message (Warning):**
   - *Issue:* Error message cited "Xcode 16.3 or newer", but `.icon` compilation requires Xcode 26.
   - *Fix:* Updated diagnostic message to cite Xcode 26.
6. **`release.sh` Origin Check in Dry Run (Warning):**
   - *Issue:* `release.sh` required HEAD to be on `refs/remotes/origin`, preventing any local dry-run testing before pushing.
   - *Fix:* Exempted `DRY_RUN=1` and `ALLOW_UNPUSHED=1` from requiring a remote tracking ref.
7. **`release.sh` Version Formatting (Warning):**
   - *Issue:* Evaluated `<sparkle:minimumSystemVersion>$MIN_OS.0</sparkle:minimumSystemVersion>` to `14.0.0`.
   - *Fix:* Standardized to `<sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>`.
8. **`release.sh` Latest Release Flag (Warning):**
   - *Issue:* `gh release create` did not pass `--latest`, relying on GitHub automatic heuristics.
   - *Fix:* Added explicit `--latest` flag.
9. **Rust Lint Failures (Critical):**
   - *Issue:* 159 `cargo fmt` formatting hunks and 38 `clippy` errors caused CI failures.
   - *Fix:* Formatted codebase with `cargo fmt` and added targeted `allow` annotations for C ABI raw pointers (`ffi.rs`) and complex test slices (`cleanup.rs`).
10. **CI Workflow Actions Security (Warning):**
    - *Issue:* Actions pinned to mutable tags (`@v4`, `@v5`) and persisted default git tokens in `.git/config`.
    - *Fix:* Pinned `actions/checkout` and `actions/setup-python` to commit SHAs and set `persist-credentials: false` across all jobs.
11. **Changelog Scope & Over-Claim (Warning):**
    - *Issue:* 0.6.1 changelog over-claimed universal Trash boundary checks when they only applied to the panel.
    - *Fix:* Clarified 0.6.1 scope and documented complete 0.7.0 improvements in `CHANGELOG.md`.

### B. Filed / Existing Tasks
- **`ft-aff09dadbc1cce48c140a44b3e8271d5`:** CI setup, clippy/fmt gate, and benchmark runners (now resolved on local `main`).
- **`ft-bc6f81a2ef6dd4df1478679dac6349c4`:** Release script hardening, notarization gate, and unpushed 0.6.x status (script fixes completed in this session; unpushed status pending owner decision).

### C. Needing Owner Decision Before Push
1. **Push & Tag Order for 0.6.x vs 0.7.0:**
   - Origin tag history ends at `v0.5.6`.
   - `v0.6.0` was never tagged in Git (commit `b87f420`).
   - `v0.6.1` is tagged locally (`6b999ed`), but never pushed.
   - **Decision:** Should `b87f420` be back-tagged as `v0.6.0`, and should `v0.6.0` and `v0.6.1` be pushed to `origin` before releasing `v0.7.0`, or should `origin/main` jump directly from `v0.5.6` to `v0.7.0`?
2. **Developer ID Signing & Notarization Credentials:**
   - The current local machine builds using local/ad-hoc identities.
   - A production release published via `./release.sh 0.7.0` requires stored credentials for `blitztree-notary` in the keychain profile and a valid Developer ID certificate unless `ALLOW_UNNOTARIZED=1` is explicitly set.

---

## 6. Phase 5: Final Release Notes for BlitzTree v0.7.0

### Highlights
- **Export to CSV:** Export the current folder or entire disk scan to CSV via `File > Export as CSV...` or the CLI command `blitztree export-csv`. Exports stream atomically and preserve file modes.
- **VoiceOver Accessibility:** Complete VoiceOver support across both Cushion Treemap and Rings views, announcing node hierarchy, relative sizes, and coordinate selection.
- **Dedicated Worker Pools:** Heavy directory scanning and UI queries (search, file-type breakdowns, export) operate on independent `USER_INITIATED` QoS worker pools, preventing UI starvation during active scans.
- **MANVI Clean Up Planner:** Integrate MANVI as a Clean Up planner with automatic fallback from local models (Ollama, LM Studio) to hosted cloud keys (Anthropic, Gemini, xAI).
- **Scan Cancellation:** Instant cancellation of active disk scans with clear visual reporting of partially scanned subtrees.

### Hardening & Data Safety
- **Universal Trash Boundary Verifier:** Worktree cleanliness, `CACHEDIR.TAG` signatures, and session recency rules are enforced unconditionally at the Trash boundary across all callers (Clean Up panel, AI agent plan cards, and CLI).
- **Recursive Trash Inspection:** Clean Up inspects recursively through the entire Trash directory before pruning git worktree admin entries, and strictly refuses worktrees with private refs (`refs/worktree/*`, `refs/bisect/*`).
- **Worktree Untracked & Ignored File Protection:** Worktrees containing non-rebuildable ignored files (`.env`, local SQLite databases) are refused.
- **Subprocess Security:** Unified child process executor with SIGPIPE handling, execution timeouts, and automatic process-tree termination. Provider connections enforce HTTPS and reject cross-origin redirects.
- **Engine FFI Robustness:** Rust engine handles and recovers from panics across scan worker threads, bounds-checks raw pointers, and prevents UI hangs.

### Fixes
- Fixed stale node indices and selection desync after moving items to the Trash.
- Fixed item reappearance when trashing occurred concurrently with an active rescan.
- Claude Code scratchpad build artifacts (`/private/tmp/claude-<uid>/...`) are recognised and safely cleanable once sessions terminate.
- Full localization string parity verified across all 7 supported languages (English, German, Spanish, French, Japanese, Turkish, Simplified Chinese).

### Known Issues & Limitations
- **Clone Byte Attribution:** Hard-linked or APFS-cloned files attribute their storage bytes to the first scanned path. Trashing that path drops the bytes from the active map until the subsequent rescan rather than immediately reattributing them to remaining links.
- **Sparkle Downgrades:** Sparkle does not support automatic rollbacks to an older version. If a published release contains defects, the recovery mechanism is to publish a roll-forward patch (e.g. `0.7.1`).

---

## 7. Next Steps & Exact Commands to Push and Tag

Because `PUSH` was set to `no`, no commits or tags have been pushed to remote. When you are ready to publish, execute the following commands:

### Step 1: Push `main` to Origin
```zsh
git push origin main
```

### Step 2 (Optional): Back-Tag and Push 0.6.x (If Desired)
If you wish to preserve the 0.6.x tag history upstream:
```zsh
# Tag v0.6.0 at its release commit (if desired)
git tag v0.6.0 b87f420b5bfab1e45a169437a95180245af73239
git push origin v0.6.0

# Push existing local v0.6.1 tag
git push origin v0.6.1
```

### Step 3: Run Release Script (Creates Tag & Publishes Release)
```zsh
# On a machine with Developer ID and notary credentials configured:
./release.sh 0.7.0

# OR, to ship an unnotarized release:
ALLOW_UNNOTARIZED=1 ./release.sh 0.7.0
```

### Step 4: Monitor CI and Published Assets
```zsh
# Watch GitHub CI execution
gh run watch

# Verify published assets on GitHub
gh release view v0.7.0
```
