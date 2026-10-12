# Benchmarks

The [clone accounting measurements](benchmarks/CLONE_ACCOUNTING.md) cover what
reading APFS clone ids costs a scan, the whole-volume totals before and after,
and the randomized stress runs on APFS, HFS+, exFAT and FAT32 images.

The [path-ordering measurements](benchmarks/PATH_ORDER.md) cover hard-link-heavy
trees and complete JSON CLI latency, including report construction and output.
They distinguish workload-specific gains from unchanged ordinary scan times.

The [September 27 performance audit](PERFORMANCE_AUDIT.md) records the latest
before/after scanner, rendering, pointer lookup, cleanup, and outline results,
with reproducible harnesses and raw samples. The comparisons below are the
earlier v0.5.0 measurements against other tools.

M4 MacBook (10 cores), macOS 27.0, APFS, warm cache, Full Disk Access for
every tool. The machine was in normal use (load average 5–9), so runs
alternate between tools and the table shows the median of five, with the
range in brackets.

Engines are timed with `cargo run --release --bin bench -- bulk <path>` and
disktree's own `disktree_core::scan::scan` with default options. Peak memory
is `/usr/bin/time -l`'s "peak memory footprint".

## Scan engines

| target | BlitzTree | [disktree](https://github.com/tobi/disktree) 0.10.1 | |
|---|---|---|---|
| home folder (3.1M entries, 227.9 GB) | **10.2 s** (9.9–10.4) | 14.7 s (14.4–15.9) | 1.43× |
| whole data volume (4.0M entries, 303.5 GB) | **12.6 s** (12.4–13.0) | 18.2 s (18.1–19.3) | 1.45× |
| peak memory, home folder | **362 MB** | 665 MB | 1.8× less |
| peak memory, whole volume | **454 MB** | 864 MB | 1.9× less |

For reference, on the home folder: a parallel `readdir` + per-file `lstat`
walk takes 14.4 s and `du -skx` takes 65.3 s.

## Apps

Both apps scanning `~/.t3` (720k entries, nothing that needs Full Disk
Access), three launches each, as reported in each app's status bar:

| | BlitzTree | disktree 0.10.1 |
|---|---|---|
| scan time | **1.4–1.5 s** | 3.1–3.2 s |
| memory after the scan | 237–279 MB | 242–272 MB |

The finished apps use about the same memory: both keep the whole tree
loaded for the UI.

BlitzTree scanning the whole data volume in the app takes 13.3–14.0 s when
the machine is quiet and up to 20 s under heavy load. The in-app time is the
engine scan plus about 0.15 s to hand the tree to the UI.

## Accuracy

- Home folder: both engines report 227.89 GB, the same as `du -skx`.
- Whole volume: both report 303.48 GB, and each top-level folder agrees to
  within 2 MB (files being written during the runs).
- `df` shows 318.7 GB used; the 15.2 GB gap is root-only system data
  (Spotlight index, logs and the like, 231 folders) that no unprivileged app
  can read. BlitzTree shows that gap in its status bar.
- BlitzTree counts every name of a hard-linked file in the file count but
  its bytes once; disktree drops the extra names. That is why BlitzTree lists
  about 1% more files for identical totals.

## Findings

- `searchfs(2)`, the closest thing macOS has to reading NTFS's MFT, was 5×
  slower than the parallel walk on an earlier 1.9M-entry volume (38 s vs
  7.1 s): it is one sequential kernel iteration over the catalog and cannot be
  split across cores. The experiment's code (`src/searchfs.rs`) was removed:
  it was bench-only, never faster, and shipped in the app's static library
  with unchecked record parsing; it is in git history before the removal.
- Thread count sweet spot is about the core count. 32+ threads regress ~40%.
- Scan, search and file-type threads (and the scan's coordinator thread) run
  at `QOS_CLASS_USER_INITIATED`, on one shared pool (see the last section). At a GUI app's default
  QoS they land on efficiency cores and the scan takes twice as long.
  `QOS_CLASS_USER_INTERACTIVE` scanned no faster (home folder in the app:
  8.8–9.6 s vs 9.3–9.4 s) but outranked the UI and the compositor, so the
  window skipped frames for ~0.2–0.4 s mid-scan. Leaving cores free instead
  cost speed: 4 workers took 14 s on the home folder, 6 took 11 s.
- Treemap render (1600×1600 px, /Applications): 100–190 ms on one thread
  originally, now ~5 ms layout + ~3 ms paint across 30 row bands, pixel-for-pixel
  the same image.
- The peak memory rows above predate the flat engine, which peaks at about
  half of v0.5.1 (see the audit's third pass).

## Name Search (WizTree parity)

Interactive matching runs in the Rust engine over the flat name arrays, in parallel across Rayon worker threads, with zero heap allocations per node on the hot path. Measured with `cargo run --release --bin bench -- search-synth` on a 3.6M-entry synthetic tree (M4, 10 cores, min of 5 runs):

| Query | Kind | Latency | Matches found (capped at 1,000) | Throughput |
|---|---|---|---|---|
| `'photo'` | Substring (common) | **7.6 ms** | 359,999 matches | 476M entries/s |
| `'entry_0000001'` | Substring (rare) | **5.7 ms** | 1 match | 635M entries/s |
| `'*.png'` | Wildcard extension | **6.4 ms** | 327,272 matches | 566M entries/s |
| `'entry_*_photo.jpg'` | Complex wildcard | **6.0 ms** | 32,727 matches | 597M entries/s |
| `'*münchen*'` | Non-ASCII wildcard | **11.2 ms** | 327,272 matches | 322M entries/s |
| `'東京*'` | Non-ASCII prefix | **8.3 ms** | 0 matches | 433M entries/s |

Every query resolves in under 12 ms, well within a 16.6 ms 60 Hz frame budget, ensuring typing remains responsive during whole-disk scans.

### Deterministic top-K at the size cutoff

`Tree::search` used to keep each Rayon worker's own heap and evict only on a
strictly larger size, so when more than `limit` matches tied at the cutoff,
which of them came back depended on how the work was split. It now selects
with `ranking::top_by_alloc`'s ordering (size, then path, then node index; one
`ranking::TopK` for both callers), so the result is the same on every run.

The same change rewrote the Unicode lowercasing step the non-ASCII queries
use (one pass into a stack buffer, heap only past 256 chars) and made the
matchers generic over the element type.

Before/after: same synthetic 3.6M-entry tree, limit 1,000, one Rayon thread
(`bench search-synth . 1`), so scheduling does not add noise. 9 interleaved
base/new process runs per cell, each the min of 5 in-process runs; the table
shows the min over the 9. The machine was heavily loaded by other work (load
average 80–160 on 18 cores) so absolute times are inflated and noisy; an A/A
control (the base binary against itself, same method) moved −6% to +5%. Base
is 70472bb with only the `BZ_SYNTH_TIES` bench switch added. "varied" is the
default tree (sizes mostly distinct, ascending, the worst case for heap
insertion); "all tied" is `BZ_SYNTH_TIES=1`, every entry the same size, so
every match reaches the path tie-break:

| Query | varied before | varied after | all tied before | all tied after |
|---|---|---|---|---|
| `'photo'` | 81.2 ms | 83.8 ms (+3%) | 68.0 ms | 73.8 ms (+9%) |
| `'entry_0000001'` | 68.2 ms | 64.6 ms (−5%) | 64.1 ms | 63.0 ms (−2%) |
| `'*.png'` | 90.8 ms | 80.2 ms (−12%) | 80.1 ms | 77.2 ms (−4%) |
| `'entry_*_photo.jpg'` | 98.8 ms | 77.2 ms (−22%) | 87.7 ms | 84.3 ms (−4%) |
| `'*münchen*'` | 219.0 ms | 154.8 ms (−29%) | 202.8 ms | 157.9 ms (−22%) |
| `'東京*'` | 182.9 ms | 118.2 ms (−35%) | 178.8 ms | 122.4 ms (−32%) |

Non-ASCII wildcard queries are 22–35% faster. Everything else is within the
A/A noise except `'photo'` on the all-tied tree: 360,000 matches that all tie
and so all go through the path comparison, about +6 ms of 68 ms single
threaded (roughly 16 ns per match). That cost is the price of a deterministic
cutoff. In earlier multi-thread runs on this tree (before the lowercasing
rewrite) the same query was 7.1 vs 7.8 ms. Raw output:
[benchmarks/results/2026-10-12-search-topk](benchmarks/results/2026-10-12-search-topk).

## File-type breakdown (WizTree parity)

The File Types list totals allocated bytes and file counts per extension for
the folder on screen, in the Rust engine, in one pass over that folder's
files (folders with 32k+ files fan out across Rayon threads). It reruns on
every zoom. Measured with `BZ_RUNS=21 cargo run --release --bin bench --
types <path>` on real scans, M5 Pro (18 cores), macOS 27.0.1, warm cache,
load average 12–17 from other work. Each run asserts that the rows add up to
the folder's bytes and file count. Raw output:
[benchmarks/results/2026-10-06](benchmarks/results/2026-10-06).

| folder | files | extensions | min | median of 21 |
|---|---|---|---|---|
| home folder (root) | 4,257,926 | 10,678 | **10.8 ms** | 11.4 ms |
| home folder's largest subfolder | 2,154,585 | 8,021 | **6.1 ms** | 6.5 ms |
| /Applications (root) | 502,516 | 591 | **0.8 ms** | 1.0 ms |
| /Applications' largest subfolder | 136,968 | 244 | **0.4 ms** | 0.5 ms |

These are engine times only; the app copies the rows and redraws the list
after them.

## One shared USER_INITIATED pool, and the arena lock (2026-10-12)

Scan, search and the type breakdown now run on one lazily built pool of
USER_INITIATED workers (`src/pool.rs`); before, only the scan did, on a pool it
built again for every scan, while search and types ran on rayon's global pool
at the app's default QoS. The scan coordinator thread is USER_INITIATED too
(it was USER_INTERACTIVE, the class that made the window skip frames).

Method: M5 Pro, 18 cores, macOS 27, release builds of `4286e7e` (base) and the
change, three arms per round (`base`, `new`, and `base2` = the base binary
again as the A/A control), run interleaved with the starting arm rotated each
round (`benchmarks/ab.sh`), min and median over the rounds. **The machine was
not quiet: the load average was 260–490 (other agents' builds and tests)
throughout, so absolute times are inflated and only same-round comparisons
mean anything.** Raw samples:
[benchmarks/results/2026-10-12-shared-pool](benchmarks/results/2026-10-12-shared-pool).

| measurement (ms unless noted) | base min / median | base2 (A/A) | new |
|---|---|---|---|
| `search-synth` 1M entries, `'photo'` (9 rounds) | 2.73 / 3.27 | 2.74 / 3.28 | 2.91 / 3.32 |
| `'entry_0000001'` | 2.06 / 2.42 | 2.08 / 2.41 | 2.01 / 2.47 |
| `'*.png'` | 2.82 / 3.19 | 2.59 / 3.21 | 2.99 / 3.12 |
| `'entry_*_photo.jpg'` | 2.70 / 3.17 | 2.59 / 3.12 | 2.43 / 3.04 |
| `types` of a 500k-file tree (9 rounds) | 0.39 / 1.53 | 0.78 / 1.13 | 0.45 / 1.06 |
| `scan-repeat`, small folder, 11 scans per process (21 rounds): min of scans | 0.242 | 0.256 | **0.101** |
| the same, median across processes of each process's min | 0.298 | 0.301 | **0.171** |
| the same, first scan in the process | 0.470 | 0.502 | 0.439 |
| `bulk` walk of a 505k-entry tree (9 rounds, seconds) | 1.018 / 1.061 | 1.025 / 1.070 | 1.026 / 1.038 |

What this shows, and what it does not:

- **No measurable change in the CLI for search, types or a large scan.** Every
  `new` figure sits inside the spread between the two identical base arms
  (the `types` base and A/A minimums differ by 2x at this load, so that row
  cannot resolve anything). The workers run at the same speed they ran before;
  the CLI is not where default-QoS threads hurt.
- **A repeated scan no longer builds a pool**: about 0.13 ms less per scan on a
  tiny folder (the cost of starting a thread per core), none on the first scan
  of a process, nothing visible on a scan that takes seconds. This is real but
  small.
- **The benefit the card is after, search and types on the performance cores
  inside the app, was not measured.** The CLI shows no difference and I could
  not drive the app's GUI here, so "search/types were running on efficiency
  cores in the app" stays inferred (from the scan-thread measurement above) and
  the in-app before/after timing is **unverified**. The tests do prove the
  mechanism: work run through the pool executes on `bz-worker-N` threads whose
  QoS reads back as USER_INITIATED, and the coordinator thread reads back
  USER_INITIATED where it read USER_INTERACTIVE.
- **One thing got worse, by design of a single pool.** rayon runs a worker's own
  spawned jobs before work injected from outside, so a search issued while a
  scan is still walking waits until the walk has little left. `bench
  search-during-scan` (a 1M-entry tree searched back to back while a 505k-entry
  scan runs, 7 rounds): on the base, 17–32 searches completed during the scan
  with a median of 29–63 ms and a worst case of 89–249 ms; on the shared pool 1–3
  completed, the worst case was 1.09–1.70 s, about the whole scan. The app does
  not do this (`Model.swift` drops the tree when a scan starts), and the
  library's callers that need it can use their own pool; it is documented in
  `src/pool.rs`. If the app ever searches during a scan, give search and types a
  second pool of the same class instead of sharing the scan's.

### Does the arena lock contend on hard-link-heavy trees?

`walk` takes the arena lock once per directory, and `account_file` (a HashMap
lookup, plus `compare_paths` for a second path to the same data) runs inside
it. `bench hardlink-fixture` builds real hard links in a fresh directory:
200 deep folders of 500 files, every folder after the first linking to the first
one's files (100k entries, 500 data streams); `BZ_HL_PROJECTS=1000` gives a
505k-entry version; `BZ_HL_UNIQUE=1` writes the same shape as independent files.

Instrumented build (the patch is in the results directory): timing the lock
around the directory-append block, summed over the workers.

| fixture | walk | lock held (all workers) | `account_file` loop | note |
|---|---|---|---|---|
| 100k hard links, load ~150 | 45–57 ms | 7–11 ms | 5–8 ms (50–80 ns per linked file) | 1,001 acquisitions |
| 100k independent files (control) | 204–241 ms | 9–23 ms | 0.5–3.5 ms | no stream bookkeeping |
| 505k hard links, load ~150 | 212–279 ms | 43–56 ms | 28–36 ms | 5,001 acquisitions |
| the same at load ~280 | 1.43 s | 420–427 ms | 287–306 ms | cost per file about 10x higher: the load, not the code |

The wait time the instrumentation reports (0.1–8 s summed over 18 workers) is
dominated by the load average: the lock holder is descheduled while it holds the
lock. It is not attributable to the bookkeeping, since the control has the same
waits with almost none of it.

The direct test of "is the bookkeeping the bottleneck": a build where
`account_file` does nothing (wrong totals, timing only) against the real one,
with the A/A control, 25 and 21 interleaved rounds.

| fixture | real (min / median) | bookkeeping free | real again (A/A) |
|---|---|---|---|
| 100k hard links, walk, ms | 34 / 37 | 33 / 36 | 34 / 37 |
| 505k hard links, walk, s | 1.017 / 1.091 | 1.021 / 1.090 | 1.011 / 1.096 |

Removing the bookkeeping entirely changed nothing the A/A control could not.
The most the change could save is therefore below the noise of this fixture,
which is the most hard-link-heavy tree one could build; and since `account_file`
returns the bytes the live progress counter shows, resolving ownership in
`finish` would also make the counter overshoot during the scan. **No locking
change was made.** Re-measure on a quiet machine before revisiting.

