# T1 — CI: tests, lints and the Swift build on every push

**Status:** open. CI has never run on GitHub: `.github/workflows/ci.yml` exists
only in local history, and a green run requires pushing `main`, which is the
person's call.
**Severity:** — (process)
**Source:** project review; the 2026-10-07 tests/CI audit.

## Problem

The project has Rust unit tests (`src/lib.rs`, `src/cleanup.rs`), a Python CLI
contract suite (`tests/test_cli.py`), Swift regression checks
(`tests/run-cleanup.sh`) and a Swift UI. A workflow was written, but it has not
been executed on GitHub, so none of it is known to work there.

## Fix

`.github/workflows/ci.yml`, all on the `macos-26` arm64 runner with Xcode 26.6
selected by `DEVELOPER_DIR` (the `.icon` asset needs Xcode 26; Swift 6.1+ is
needed for `-default-isolation`):

- **Rust engine:** `cargo fmt --check`, `cargo clippy --locked --all-targets
  --features cli -- -D warnings`, `cargo test --locked --release` with no
  features, with `--features cli` and with `--no-default-features`, then
  `cargo build --locked --release`.
- **CLI tests:** build the `cli` binary, then
  `python3 -m unittest discover -s tests -p 'test_*.py' -v` (the one documented
  Python command).
- **Swift checks:** `tests/run-cleanup.sh`.
- **Swift app build:** `./build.sh`, with no `continue-on-error`, then checks
  that the icon assets exist and the bundle's signature verifies.
- **Benchmark runners:** `benchmarks/check-fixtures.sh` (fixtures define every
  `bz_*` in `app/bz.h`), `run-ui.sh --check-only`, `run-agent.sh --check-only`
  and `rendering.py --baseline bf3b1fc --check-only` (output equality, no
  timing).

## Acceptance criteria

- [ ] Workflow runs green on a push to `main` (blocked on the person pushing).
- [x] `cargo test`, `cargo fmt`, `cargo clippy` and the Python tests fail the
      build when they fail.
- [x] No secrets required; push access only.
- [ ] `cargo fmt --check` and `cargo clippy ... -D warnings` pass on `main`
      (they failed at 21c43ac: 159 fmt hunks, 35 `not_unsafe_ptr_arg_deref` and
      2 `type_complexity` clippy errors; a mechanical pass is pending).
