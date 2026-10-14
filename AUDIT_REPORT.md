# BlitzTree audit — 2026-10-13

Read-only audit of `/Users/bharath/Code/devtools/Blitztree` at `97aa8c5` (`main`, 141 commits ahead of `origin/main`, measured with `git rev-list --count origin/main..HEAD`, no fetch). No source, config, or dependency was changed. The board writes and this file are the only writes.

`spawn_subagent` has no model parameter. The four slice audits were prompt-assigned the Sonnet role. Verification of cited lines and the grouping pass were done in this session (Grok 4.7), in the Opus and Fable roles. No Fable/Opus disagreement changed scope.

Tests, `cargo`, `./build.sh`, `tests/run-cleanup.sh`, and `tests/check-l10n.sh` were not executed. A criterion is marked `[MET — verified in source]` only where the criterion text was checked against current source. A green run is still required before any card moves to done, and done was not set. No card was deleted or merged. No `in_progress` card existed.

## Situation

GitPulse Insights (all facets ok, and the auditors saw the same picture): one worktree, this checkout, `main`, clean. Overlapping dirty files: 0. One idle Claude Desktop session, pid 50886. No contended files, so nothing was flagged in-flight from another lane.

DevMap 0.2.4, store `.devcouncil/codeintel/devmap.sqlite`, generation 291, schema 27. `devmap status`: `query_ready` and `reader_ready` true, `is_fresh` false, `source_freshness` false (delta includes `RELEASE_REPORT.md`). Analyzer freshness disagreed between the CLI (`true`) and GitPulse codeintel (`stored extraction payload is obsolete`). The index was not rebuilt. `walk_incomplete` was set on dead-symbols and on several explores. Empty graph answers are unknown. Swift name resolution was about 268 per mille and Rust about 655. Dead-symbol rows: 12, all confidence 0.4 (unconfirmed). Clones output was truncated. The subsystem dump was not printed (a shell heredoc was refused). Partial parses included `app/Agent.swift`, `app/Manvi.swift`, `app/Settings.swift`, `app/Treemap.swift`, parts of `src/bin/blitztree/main.rs`, `src/cleanup.rs` (one region), and several benchmark and test scripts.

The archive (`archived: true`) has 16 done cards. None covers the three new concerns below. The open board was 20 cards at the start of filing and is 23 now.

## Severity × dimension

Counts are confirmed open residuals from this audit. Historical card severity was kept, and two cards were raised (none → low). Nothing was lowered.

| Dimension | Critical | High | Medium | Low |
| --- | --- | --- | --- | --- |
| Security and trust-boundary validation | 0 | 1 (`ft-656786` residuals) | 3 (`ft-99ac` userinfo, `ft-01ce6a`, `ft-9bfa21`) | 0 |
| Correctness (macOS; Windows/Linux are out of this app's scope) | 0 | 0 new (the FFI card stays high for its older criteria) | 2 (`ft-f3fead`, lossy scan root on `ft-994960`) | 1 (`ft-8a7cd` counters) |
| Async and error boundaries | 0 | 0 | 0 open (`ft-5eb6` is met in source) | 1 (`ft-79d331` cancel waits on `sync_all`) |
| Release correctness | 0 | 0 | 1 (`ft-bc6f` tag and CHANGELOG) | 0 |
| Strict typing | 0 | 0 | 0 | 1 (`ft-7fcdb9`: lock is in source; `./build.sh` was not re-run) |
| Performance and benchmarks | 0 | 0 | 0 | 0 new |
| Modular architecture | 0 new | 0 | 0 | 0 new (`ft-05c4` stays as filed) |
| Deterministic testability | 0 new | 0 | 0 | 0 new (`ft-5c064e` stays as filed) |

No performance finding lacked a benchmark, so no benchmark-baseline card was filed. Search already has `BENCHMARKS.md` and `benchmarks/results/2026-10-12-search-topk/`. The search card carries "do not regress that bench" as a criterion.

## Top 10 risks

1. **`ft-656786` (priority 0, severity high).** Clean Up still offers or fails open on user data. Nested `UUID/workflows/memory` and `tool-results/memory` are outside `only_transcripts` (`src/cleanup.rs` 675-697). A symlink project folder under the sessions root is not lstat'd (`app/AgentSessions.swift` 50-52). An unlistable scratchpad becomes `.ended` (284-292). Unreadable mtimes are treated as not recent (`app/CleanupGuard.swift` 64-91). `cacheTokenPolicy` sees only a direct child (`app/CleanupSafety.swift` 553-564). `.venv` is emitted without a regular `pyvenv.cfg` (`src/cleanup.rs` 835). `__pycache__` and the other Python cache markers are `FolderMarker.none` (`app/GitWorktree.swift` 511-514, 529-530). The allowlist question (arbitrary `.cache` children, Apple container caches, `.gradle` without a top-level config, any `.npm`, `.tox` contents, Codex year and archive folders) is one owner decision on this card.
2. **`ft-994960` (priority 1, severity high).** The walk path is `OsStr`. The stored root name is `root.to_string_lossy()` (`src/lib.rs` 1346-1351) while `app/bz.h` 12-14 says the root keeps the name it was given. On APFS this is a display and CSV mismatch; the card stays high because the older FFI criteria were not all re-closed.
3. **`ft-99ac` (priority 1, severity medium).** A custom provider URL may carry a user, password, or query. `problem()` checks scheme, host, and loopback http (`app/ModelProvider.swift` 83-90) and `save()` / `persist()` writes that URL into UserDefaults (236-254).
4. **`ft-01ce6a` (priority 2, severity medium).** Trash and delete re-check the inode, then act on the path (`app/CleanupOperations.swift` 105-121 and 172-198). The path can change between the check and the call.
5. **`ft-9bfa21` (priority 2, severity medium).** `child_path` (`src/lib.rs` 911-919) does not reject `.`, `..`, or `/`. Directory hard links are descended once per name (391-394, 824, 1002-1010). Local APFS usually hides `.` and `..`; a hostile SMB or FUSE server, or a directory hard link, is the failure.
6. **`ft-f3fead` (priority 2, severity medium).** Search lowercases with `char::to_lowercase` only (`src/search.rs` 85-88). No NFC/NFD and no full Unicode casefold, so APFS-normalized names miss.
7. **`ft-955f38` (priority 2, severity medium).** Worktree receipts live only in memory (`app/Cleanup.swift` 114-120). A missing or unreadable admin directory is reported as "changed" (`app/GitWorktree.swift` 283-306). Deleting the admin entry under `.git` after Trash is emptied is implemented and still needs the person's approval.
8. **`ft-bc6f` (priority 1, severity medium).** A second `./release.sh` for an existing `v$V` uploads and edits and does not move the tag (`release.sh` 140-151). CHANGELOG 0.7.0 says a cancelled scan is displayed and names the CLI as a verifier caller. The partial tree is dropped (`src/ffi.rs` 121-130, `app/Model.swift` 812-832). The CLI does not delete (`src/bin/blitztree/main.rs` 20).
9. **`ft-8a7cd` (priority 2, severity low, raised from none).** `clone_ids_unavailable_directories` counts symlinks and sockets (`src/lib.rs` 833, 1015-1018 versus `app/bz.h` 76). `workers_degraded` is also a query-pool failure (`src/pool.rs` 130-131 versus `app/bz.h` 78).
10. **`ft-79d331` (priority 3, severity low, raised from none).** Export calls `sync_all` before the cancel check (`src/export.rs` 487-492). `bz_export_free` joins that worker (`src/ffi.rs` 645-649).

## New cards

| item_id | task_id | Title | Priority | Severity | Status |
| --- | --- | --- | --- | --- | --- |
| `ft-f3feadedd1a6eb1f5769acaeb674d774` | `bt-audit-2026-10-13-search-unicode` | Search misses APFS-normalized names and full Unicode casefold | 2 | medium | backlog |
| `ft-01ce6a8be77399f32d4a4e42cdd9dce2` | `bt-audit-2026-10-13-trash-inode` | Trash and delete re-check the inode, then act on the path | 2 | medium | backlog |
| `ft-9bfa2100d7b952daf21084bc619ae99b` | `bt-audit-2026-10-13-scan-walk` | Scan walk trusts directory entry names and re-walks directory hard links | 2 | medium | backlog |

`ft-9bfa21` was refused twice as related work. The listed cards were read and judged separate: panic/FFI (`ft-994960`), cancel/coverage (`ft-8a7cd`), QoS (`ft-df6882`), and search matching (`ft-f3fead`). The successful call passed `reviewed_related` for all four. `related_check` compared 22 open tasks.

`ft-01ce6a` was refused once against `ft-656786` and filed with that id in `reviewed_related`. The race is the inode/path gap. The rules card owns what may be offered.

## Folded cards

Each overwrite sent the existing title, description, and criteria, plus an Audit 2026-10-13 section and the new criteria. Labels gained `audit-2026-10-13`. Status stayed `review`. Priority was not lowered. Severity was raised only where noted.

| item_id | Revision | What was added | Severity |
| --- | --- | --- | --- |
| `ft-65678665ff3783b3a7972a7997b3c1c6` | 3 | Seven residuals (nested session memory, symlink project folder, scratchpad and mtimes, post-scan nested token, Python cache markers, `.venv` / `pyvenv.cfg`, one allowlist decision). Criteria 2, 3, 4, 5, 7, 8, 9, 10, 11, 12 marked met in source. | high (unchanged), priority 0 |
| `ft-99ac894f06c08e427a4dbfe8af676c6b` | 3 | Reject user, password, and query on provider URLs. Criterion 7 (manual Move to Trash) marked met. | medium (unchanged) |
| `ft-bc6f81a2ef6dd4df1478679dac6349c4` | 4 | Re-release must fail or move the tag. CHANGELOG 0.7.0 scan and verifier bullets. Criteria 1, 3, 4, 5, 6, 7 marked met in source. Criterion 2 stays open. | medium (unchanged) |
| `ft-955f38c8cbbdaab92cf1f6b654c58f4a` | 3 | Receipts across quit, and the "changed" string for a missing admin directory. Criterion 1 marked met. | medium (unchanged) |
| `ft-9949602b8d0ba41fc88c863b683e06be` | 3 | Stored root `name_blob` must equal the input bytes. Criteria 1 and 2 marked met. Criterion 4 stays open. | high (unchanged) |
| `ft-8a7cd14baf45458f7469e29a5f751d52` | 3 | The two coverage-counter criteria. `src/pool.rs` added to planned files. Criterion 1 marked met. | low (raised from none) |
| `ft-79d331a11a7df7783c0ab8a1b02d48b9` | 3 | Cancel must not wait out `sync_all`. Original CSV criteria left unmarked. | low (raised from none) |
| `ft-5eb6885b248237a3d1d3d666cc0304d8` | 3 | Verification section. All six criteria marked met in source. | medium (unchanged) |
| `ft-7fcdb9d19ef55607de5de1fddeb50d18` | 3 | Verification section only. `OSAllocatedUnfairLock` is at `app/Agent.swift` 131-146. Criteria were not prefixed, because `./build.sh` was not run and launch timing was not measured. | unchanged (none) |

## Verified in source, still in review

These stay in `review`. Done needs a Manvi verification this audit did not run.

- **`ft-5eb6`.** All six criteria. `signal(SIGPIPE, SIG_IGN)` at `app/Main.swift` 17. `F_SETNOSIGPIPE` in `app/Subprocess.swift`. The only `Process()` in `app/` is line 179. `runCommand` is `app/Agent.swift` 1130-1154. `readDataToEndOfFile` does not appear under `app/`. Sign-in uses `onBackgroundThread` at lines 245 and 261. `AgentLogin.swift` 82 calls `Subprocess.run`. EIO is end-of-stream at `app/Subprocess.swift` 87-100, and the wait is bounded at 148-151. `tests/SubprocessChecks.swift` 99-129 was read and not executed.
- **`ft-656786`.** Direct `memory/` refusal, foreign `.cache` not emitted whole, submodule versus worktree, manifest requirement for `.tox` / `.nox`, verifier at the trash boundary, no default `verify`, ignored non-rebuildable files, bounded `cwd` and an unlistable sessions directory, and mounts inside `recent_activity`. Criterion 6 (real Codex install) was not repeated. Criterion 1 (person approves) and criterion 13 (quoted test output) stay open.
- **`ft-994960`.** Failed scan is stored (`src/ffi.rs` 175-181) and Swift shows `scanFailed` (`app/Model.swift` 833-835). Poisoned locks use `into_inner` (`src/ffi.rs` 88-89). The log line that still asks to merge `hardening` onto `main` is stale at `97aa8c5`.
- **`ft-bc6f`.** Version and changelog gate, `ALLOW_UNNOTARIZED`, keychain unlock via `security -i` (`build.sh` 116-130; `ps` was not observed during a signing build), trap and pinned Sparkle tool, `deploy.sh` pipefail and verify-before-swap, and `icon-partial.plist` is used (`build.sh` 95-100).
- **`ft-99ac` criterion 7.** Manual Move to Trash stays Finder-style. The alert names what Clean Up would refuse (`app/TreemapView.swift` 856-894, `README.md` 64).
- **`ft-8a7cd` criterion 1.** A cancelled scan is not presented as a complete tree (`src/ffi.rs` 129-130, `src/lib.rs` 927-929, `app/Model.swift` 812-832).
- **`ft-7fcdb9`.** The lock replaced the captured vars. The build criterion stays open until `./build.sh` is run.

## Cards left unchanged

| item_id | Why it was left |
| --- | --- |
| `ft-13d404` | The engine auditor said `Tree::without` is met. This session did not re-read that function body, so nothing was marked met. Directory hard links are `ft-9bfa21`, a different hole. |
| `ft-32287b` | Top-K order was not fully re-verified. Unicode search is `ft-f3fead`, not a reopening of this card. |
| `ft-df6882` | Read while separating the scan-walk card. No new performance finding. QoS claims were not re-marked. |
| `ft-a38171` | The l10n script is wired from `tests/run-cleanup.sh`. The script was not executed. Native review stays with the owner. |
| `ft-f42ed2` | A failed CSV export showing an English engine string was not re-read (`app/Export.swift` 92-99). No new card. |
| `ft-aff09` | `.github/workflows/ci.yml` was not re-read (a workspace search of that file returned no matches even though the file is present). Push and a green GitHub run stay with the owner. Ahead-of-origin is 141, not the older 58 or 63. |
| `ft-48cd` | The panel total is still the naive sum. Already the whole card. No new evidence. |
| `ft-9b93` | Still open. CHANGELOG sentences were added only on `ft-bc6f`. `.auth-repro` was not deleted. |
| `ft-42242a` | Still open. Treemap and the outline handle ⌘⌫. Sunburst does not. No Quick Look panel and no sibling arrow keys. Not re-filed. |
| `ft-05c4` | Still open. The `CGImage` force unwraps remain, and the caller clamps the bitmap to at least 1 pixel, so this is not a new empty-scan crash. |
| `ft-5c064e` | Still open. The cloud-only / `SF_DATALESS` case was not turned into a "deletes the cloud copy" card. |

## Build waves

Waves are disjoint in the files that wave still has to edit. A later wave may reuse a file. `ft-5eb6` is verification-only (run `tests/SubprocessChecks.swift`) and is not a code wave. `ft-aff09` (push and a green CI run) is outside the waves.

**Wave 1**

1. `ft-656786` — `src/cleanup.rs`, `app/CleanupSafety.swift`, `app/AgentSessions.swift`, `app/CleanupGuard.swift`, `app/GitWorktree.swift`, `app/CleanupVerify.swift`, and the matching tests. Leave `app/CleanupOperations.swift` for wave 2.
2. `ft-99ac` userinfo criterion — `app/ModelProvider.swift`, `app/Settings.swift`.
3. `ft-bc6f` — `release.sh`, `build.sh`, `deploy.sh`, `CHANGELOG.md`.
4. `ft-f3fead` — `src/search.rs`.

**Wave 2** (after wave 1 releases `GitWorktree.swift`)

1. `ft-955f38` — `app/GitWorktree.swift`, `app/Cleanup.swift`.
2. `ft-01ce6a` — `app/CleanupOperations.swift`, `tests/CleanupIntegrationChecks.swift`.
3. `ft-9bfa21` — `src/lib.rs`.
4. `ft-9b93` — docs and `.gitignore`. Leave `CHANGELOG.md` on `ft-bc6f`.

**Wave 3** (after wave 2 releases `src/lib.rs`)

1. `ft-79d331` — `src/export.rs`, `src/ffi.rs`.
2. `ft-42242a` — `app/SunburstView.swift`, `app/TreemapView.swift`, `app/ContentView.swift`.
3. `ft-7fcdb9` — run `./build.sh` and confirm `app/Agent.swift` is clean. The lock is already in source.
4. `ft-a38171` — run `tests/check-l10n.sh`. Native review stays with the owner.

**Wave 4** (after wave 2 releases `Cleanup.swift` and wave 3 releases `src/ffi.rs`)

1. `ft-48cd` — `app/Cleanup.swift`, `src/ffi.rs`, `app/bz.h`, `app/Model.swift`.

**Wave 5** (after wave 2 releases `src/lib.rs` and wave 4 releases `app/bz.h`)

1. `ft-8a7cd` counters — `src/lib.rs`, `src/pool.rs`, the counter comments in `app/bz.h`.

**Wave 6** (after wave 5 releases `src/lib.rs` and `app/bz.h`)

1. `ft-994960` stored root name — `src/lib.rs`, `app/bz.h`. The older unmarked FFI criteria stay on this card and share these files, so they are the same wave.

**Wave 7** (after wave 3 releases the views and wave 4 releases `app/Model.swift`)

1. `ft-05c4` — `app/Agent.swift`, `app/ContentView.swift`, `app/Treemap.swift`, `app/TreemapView.swift`, `app/SunburstView.swift`, `benchmarks/run-agent.sh`.

`ft-df6882` and `ft-5c064e` stay where they are. This audit did not re-open them, so they are not given a wave slot.

## Rejected or not filed

- **Dataless directories as a delete-the-cloud-copy bug.** The walk does not descend dataless directories. `find()` does not check `SF_DATALESS`. Whether allocated size can reach 50 MB was not shown. No card says Clean Up deletes the cloud copy.
- **`contained_in` past `--limit`.** The cleanup auditor refuted it from sort order (parents sort first). `src/bin/blitztree/report.rs` 51-61 was not re-read here, so the report records the auditor's refutation and does not file a bug.
- **Manual Move to Trash as a new hole.** The decision is already recorded. `ft-99ac` criterion 7 is met in source.
- **`CGImage` force unwrap as a new crash.** The caller clamps both sides. It stays on `ft-05c4`.
- **Dead symbols at confidence 0.4.** Unconfirmed. Not filed.
- **Re-filing an October item whose criterion is already met in source.**
- **A second card for the Clean Up allowlist.** Folded into `ft-656786`.
- **CLI missing the verifier, treated as a delete path.** The CLI does not delete. The overclaim is a CHANGELOG criterion on `ft-bc6f`.
- **A benchmark-baseline card.** No performance finding lacked a bench.
- **Deduping `ReferenceAgentStreamReader`, or deleting `Tree.cleanupKindID` / section / group helpers.** Left on `ft-05c4` as already scoped. Not deleted.

## Decisions made without asking

- Roles were assigned by prompt because the subagent tool cannot select Sonnet, Opus, or Fable.
- The DevMap index was not rebuilt. Gaps above are recorded rather than treated as "none".
- Findings were grouped one card per concern. Cleanup-rule and fail-open residuals all fold into `ft-656786`. Coverage counters fold into `ft-8a7cd`. The lossy root name folds into `ft-994960`. Changelog sentences fold only into `ft-bc6f`.
- Auditor priorities were lowered only on new residuals: search, scan-walk, and the inode race are priority 2; export cancel stays priority 3. Existing card priority and severity were not lowered. `ft-79d331` and `ft-8a7cd` were raised from none to low.
- `ft-7fcdb9` was not given `[MET]` prefixes, because the criterion text is a clean `./build.sh`.
- `ft-5eb6` was marked met in source and left in review.
- Scan-walk was kept separate from the four related cards the board named. The inode race was kept separate from `ft-656786`.
- Archived tasks were listed before the scan-walk retry. None matched.
- No card was moved to done. No card was deleted or merged.
- `.auth-repro` was not deleted.

## Owner decisions before building

- Approve a security-impact statement before any Clean Up narrowing ships (`ft-656786` criterion 1, `ft-99ac` criterion 1). The allowlist question on `ft-656786` is that approval. Tests that lock today's emit stay until then.
- Approve, or refuse, deleting a worktree admin entry under `.git` after the Trash is emptied (`ft-955f38`). Persisting receipts across quit is part of that decision. The code path is already implemented.
- Manual Move to Trash stays Finder-style. That decision is recorded. It does not need to be reopened.
- How 0.6.x / 0.7.0 ships, whether `ALLOW_UNNOTARIZED` is used, pushing `main` (141 commits ahead), and closing GitHub issues #7, #8, #9, and #11 (`ft-bc6f`, `ft-aff09`).
- Whether `.auth-repro` is disposable (`ft-9b93`). It was not deleted.
- Native review of the seven `Localizable.strings` tables (`ft-a38171`).
- Whether to port `benchmarks/*.py` (`ft-05c4` asks for a written proposal only).
- A real Codex install check for `ft-656786` criterion 6. The code path was read. The install was not re-checked.

Building waits for a go-ahead.
