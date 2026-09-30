# Issue Ledger

In-repo tracker for work derived from the v0.5.1 security review
([security-review-v0.5.1.md](security-review-v0.5.1.md)). Each file is
one issue with acceptance criteria; status mirrors the checklist below.

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| [S1](issues/S1-library-blocklist-gaps.md) | `~/Library` blocklist gaps (`LaunchAgents` & peers) | Medium | resolved |
| [S2](issues/S2-revalidate-at-action-time.md) | Re-validate guards at trash/command time (TOCTOU) | Medium | resolved |
| [S3](issues/S3-resolve-symlinks-in-guards.md) | Resolve symlinks before guard checks | Low | resolved |
| [S4](issues/S4-document-fda-inheritance.md) | Document FDA inheritance to child processes | Low | resolved (docs) |
| [S5](issues/S5-codex-installer-checksum.md) | Pin checksum for Codex installer | Low | resolved |
| [S6](issues/S6-command-exact-match.md) | Exact-match commands that take no argument | Low | resolved |
| [T1](issues/T1-ci-workflow.md) | CI: cargo test + Swift build on every push | — | resolved |
| [F1](issues/F1-custom-providers-and-l10n.md) | Custom model providers + multilingual UI | feature | resolved |

## Where the fixes live after merging with main (v0.5.6)

S1–S3 and S6 were first fixed inside `CleanupGuard` in `app/Agent.swift`.
Main meanwhile moved the cleanup policy into `app/CleanupSafety.swift`,
`app/CleanupCommand.swift` and `app/CleanupOperations.swift`, and the
merge keeps those owners:

- **S1**: `CleanupPathSafety.neverCleanRelative` blocks those folders
  recursively (checked in `tests/CleanupSafetyChecks.swift`).
- **S2**: `CleanupOperations.trash` calls `CleanupTarget.validate()` and
  removal calls `CleanupReceipt.validate()` right before acting;
  `CleanupCommand.parse` runs again before a command is started.
- **S3**: `CleanupPathSafety.inspect` walks each path with `lstat` and
  refuses any symlink along it, rather than resolving links first.
- **S6**: `CleanupCommand.parse` is an exact argv allowlist, and the tool
  is run directly, without a shell.

The write-ups in `issues/` and `security-review-v0.5.1.md` still show the
original `CleanupGuard` code.
