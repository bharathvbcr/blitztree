# Performance audit — 2026-09-27

Baseline: `74b8fe4f097a819ece484a73e08f5368e64c3001` (v0.5.0 source).
Machine: Apple M4, 10 CPU cores, 16 GB RAM, macOS 27.0, Swift 6.4,
Rust 1.98. Release builds, warm filesystem caches, normal desktop activity.
Team benchmarks ran sequentially; background system activity was not stopped.
These are local measurements, not a claim about every disk or Mac.

Raw measurements are checked in under
[`benchmarks/results/2026-09-27`](benchmarks/results/2026-09-27).

## Changes

### Scanner and C handoff

- Reuse one 256 KiB directory-read buffer per worker. Previously every directory,
  including empty ones, allocated and released its own buffer.
- Move parsed filenames into tree nodes instead of cloning each name under the
  global arena mutex. Prepare descent paths before taking that mutex.
- Reserve each incoming arena batch once and avoid the mutex for empty directories.
- Build and sort child lists in their final flat buffer, comparing the compact
  allocation column. Preallocate name storage and release source names while
  converting the tree.
- Batch progress updates in the count-only diagnostic walker.

Isolated flattening of 262,401 synthetic nodes improved from **6.789 ms to
5.930 ms median** over ten alternating reference/current pairs. Source-tree
destruction is included; fixture construction is excluded. Scan peak memory
must be assessed separately from this CPU microbenchmark.

First-pass end-to-end FFI comparison (`74b8fe4` → `178d256`), nine
alternating pairs after warming both builds:

| Real scan | Before median (range) | After median (range) | Peak footprint, before → after |
|---|---:|---:|---:|
| `/Applications`, 332,018 entries | 0.620 s (0.611–0.718) | 0.597 s (0.587–0.739) | 61.60 → 58.98 MB |
| Repositories, 264,259 entries | 0.485 s (0.456–1.160) | 0.480 s (0.442–1.031) | 48.55 → 45.66 MB |

Counts, allocated bytes, and errors match in every measured run. The applications
median improved 3.7%; the repository wall-time difference is within substantial
background-load variation, so this is not evidence of a meaningful repository
scan speedup. Peak footprints are the median per-process peaks in decimal MB,
about 4–6% lower in these runs. Entry counts exclude the root.

The benchmark's optional thread argument previously configured Rayon's global
pool, while the real scanner built a separate pool and ignored that setting.
It now sets `RAYON_NUM_THREADS` before creating either pool. A new `ffi` mode
measures scanning, flattening, polling/handoff, and releasing the result.
`BZ_JSON=1` emits exact counts, allocated bytes, errors, and elapsed seconds.

A 4/6/8/10/12/16/32-worker sweep (three shuffled rounds per target) did not
establish a consistent better default across applications and repositories.
Ten workers led the applications median, but four were nearly tied; repository
samples varied heavily with background load. The core-count default is unchanged.

### Treemap and rings (final combined changes)

The treemap skips a parent cushion only when its children demonstrably cover
every rounded pixel. Flat surfaces compute their shaded color once and fill
rows instead of evaluating the lighting formula per pixel. Layout geometry,
frame darkening, subpixel fallback, and color formulas stay identical.

Treemap pointer lookup uses a grid of leaf rectangles, retaining the original
last-matching-leaf rule at boundaries. Rings lookup uses angular binary search
within the pointer's ring. Rings also reuse arc paths and highlighted indices.
Invalid layouts clear geometry and invalidate the cached layout dimensions.

Review uncovered a fractional-edge coverage case and a stale ring-index crash
in intermediate versions of these optimizations. Both have dedicated regression
checks in the final rendering harness.

| Offscreen operation, 2,880 × 1,800 pixels | Before median | After median |
|---|---:|---:|
| Treemap redraw, balanced 13,280-node tree | 28.068 ms | 6.919 ms |
| Treemap redraw, 100,000 files | 25.857 ms | 22.227 ms |
| Treemap redraw, 120-level directory chain | 56.020 ms | 6.654 ms |
| Rings redraw, balanced tree with free space | 56.421 ms | 38.279 ms |
| Rings redraw, balanced full circle | 93.119 ms | 49.665 ms |
| Rings hit testing, 50,000 queries | 601.027 ms | 15.076 ms |
| Treemap hit testing, 1,000 queries, 100,000 files | 3,754.720 ms | 0.271 ms |

These are nine alternating pairs against the original `74b8fe4`, rerun after
both optimization passes. Treemap redraw includes building its hover index, so
the flatter workload trades some paint savings for much cheaper pointer
movement: about **3.75 ms → 0.00027 ms per query** in that fixture.
The index stores leaf references by 32-point cell and uses additional memory;
this audit does not claim a reduction in total app memory.

The second pass profiled the remaining rings raster cost: compound strokes
accounted for about 56.8 ms versus 26.5 ms for gradients in the diagnostic scene.
Complex Retina scenes now expand the stroke once and rasterize its immutable
outline through independent contexts clipped to disjoint integer bitmap rows.
The contexts finish before the parent creates the image. Gradients retain the
original serial path; scale 1 and scenes with fewer than 24 arcs retain the
original stroke. Deep and very small rings scenes showed essentially neutral
results. This is a draw-time improvement, not a promise of a particular FPS.

All treemap pixels and geometry/hits match exactly. Scale-1 rings match exactly.
Retina strokes differ by at most 5/255 in a channel, affecting at most 0.0967%
of stored channel bytes per fixture; most differences are one level. Side-by-side
exports were visually inspected. The harness enforces the explicit bound with
`--allow-ring-rounding`; it does not call these Retina images pixel-identical.
Raw final samples are `render-final.txt` and `rings-final-scale{1,2}.txt`.

### Cleanup and outline

Cleanup discovery stops below the 50 MB threshold: a smaller subtree cannot
contain a qualifying folder, and siblings are already sorted by size. It also
avoids decoding parent names for unrelated directory names. Outline child-count
queries read the flat child offsets without creating wrapper objects; selecting
a collapsed folder leaves its descendants unmaterialized. A tree identity check
prevents an older cleanup task from publishing results after a rescan.

| Operation | Before median | After median |
|---|---:|---:|
| Cleanup, real `/Applications`, 332,019 nodes | 10.579 ms | 0.060 ms |
| Cleanup, real repositories, 264,259 nodes | 1.677 ms | 0.096 ms |
| Cleanup, synthetic 515,001-node tree | 58.401 ms | 1.086 ms |
| Cleanup, 100,003 sorted siblings | 2.382 ms | 0.004 ms |
| Outline child-count callback, 100,000 children | 5.146 ms | <0.001 ms |

Both cleanup implementations inspect the same immutable tree in each real
comparison, and their complete ordered outputs match. Timings use nine pairs.
The outline callback creates **100,000 → 0** child wrappers. This does not measure
the total cost of expanding or reloading 100,000 visible rows. Submillisecond
ratios are less useful than the absolute time saved.

## Second pass: full-window latency, memory, and streamed plans

Unless specified otherwise, these isolated continuation measurements use
`178d256` (the first optimization pass) as their baseline. The rendering table
above compares the original source with all final renderer changes.

### Smaller engine arena

A directory already appends its complete sibling batch while holding the arena
mutex. Its children now use a `Range<u32>` instead of a separately allocated
`Vec<u32>`, saving 16 bytes of metadata per node and one allocation per nonempty
directory. Flattening expands those ranges into the same sorted C-ABI arrays.
A 96-level, 64-branch regression verifies every node belongs to exactly one
range and that parent ordering, counts, and byte totals remain correct.

| Scan peak footprint | First pass | Second pass | Reduction |
|---|---:|---:|---:|
| Applications, 332,019 nodes | 59.36 MB | 51.45 MB | 13.3% |
| Repositories, 264,380 nodes | 45.88 MB | 40.06 MB | 12.7% |

These are seven/five alternating pairs respectively. Every paired inventory
matched. The repository contents changed between the first and second audit
batches, so the different node counts must not be compared as identical inputs.
Unrelated builds/profilers overlapped these second-pass engine runs; their wall
times are not reliable additional speed evidence. Per-process peak memory is
reported separately from timing. Raw files are named `engine-ranges-*.json`.

A final nine-pair original-to-complete-app scan comparison retained the same
278,661 files, 53,357 directories, 32,533,331,968 allocated bytes and zero errors
in every run. Median peak footprint was **61.36 → 51.81 MB (15.6% lower)**.
Wall-time medians were 1.051 → 1.160 s, with broad overlapping ranges
0.786–1.293 s and 0.739–1.242 s. Another benchmark process and system/build work
were active around this run. The candidate was faster in five of nine pairs;
this batch cannot establish a stable scan speedup or regression. We retain all
samples in `engine-final-apps.json` and claim only the demonstrated memory
reduction, not an overall engine throughput gain.

### Full UI handoff

An Instruments capture of the actual window identified SwiftUI graph updates,
AppKit row construction, and a synchronous volume-capacity query. The initial
renderer microbenchmarks did not include those costs. The UI now:

- Observes 60 Hz progress and pointer-driven status text in separate views.
- Reads capacity alongside the scan without blocking the main actor, publishing
  matching tree/volume data together; progress still ticks if metadata is slow.
- Builds the empty canvases during the first scan.
- Reuses collapsed root rows and their cells on an unchanged rescan shape.
  New tree IDs and ownership are rebound before cell refresh. Expanded or
  previously materialized children, changed names/order/types/counts, and more
  than 4,096 roots use the normal reload path.
- Explicitly redraws treemap selection when a pick comes from the directory list.

Three alternating pairs of full-window processes, each doing four applications
scans, measured **166.149 → 96.848 ms** median for the first result and
**127.887 → 37.044 ms** for the nine subsequent rescans. Rescan ranges were
98.068–146.779 ms before and 34.702–48.050 ms after. Both versions used the same
first-pass renderer and Rust library to isolate the UI changes.

The measurement starts at the completed-engine poll and ends after forcing
pending window layout/display. It measures CPU-side readiness, not GPU
presentation. Every available row's tree identity/name/size is checked. For
120 hover updates, root body evaluations dropped from 120 to zero. A separate
injected 1.5-second metadata delay allowed 140 main-actor ticks and continuing
progress, verifying that the wait is asynchronous. Earlier queued-callback
logs should not be interpreted as uninterrupted main-thread blocking.
See [`benchmarks/UI.md`](benchmarks/UI.md) and `ui-comparison-final.json`.

### Plan preparation and cleanup responsiveness

Incremental plan parsing now scans only new bytes and retains one incomplete
item. JSONL processing tracks the unfinished line's search position and consumes
each read batch once. Prompt preparation prunes size-sorted subtrees while
preserving the original stable ordering and complete prompt text. Cancelling
preparation prevents a late agent-process launch.

| Offline operation | Before | After |
|---|---:|---:|
| Normal 12-item plan, about 4 KB | 1.208 ms | 0.055 ms |
| 12-item plan containing 144 long paths, about 62 KB | 169.604 ms | 0.351 ms |
| 4,000 JSONL events, 16 KB reads | 14.511 ms | 13.279 ms |
| Fragmented 512 KB JSONL record (stress case) | 688.319 ms | 2.148 ms |
| Complete prompt, synthetic 1,008,001-node/223 GB tree | 2.386 ms | 1.307 ms |

All use nine alternating pairs. Large fragmented inputs expose the old
repeated-scanning behavior; they are not typical model latency. No agent,
network request, authentication, or real cleanup ran in these tests. Complete
protocol event/outgoing-message sequences and prompt bytes match, including
random chunk boundaries, Unicode/escapes, invalid records, and restarts.

Manual cleanup's existing filesystem moves now run in one background batch.
The captured selection cannot be submitted twice; conflicting scans/agent
starts wait until the batch completes. Fake-I/O tests cover responsiveness,
ordered failures, one completion/rescan, and delayed agent discovery. Failures
are retained on the model even if the inspector closes during the batch.
See [`benchmarks/AGENT.md`](benchmarks/AGENT.md).

## Third pass: flat engine, once-per-pixel treemap, list selection

Baseline: `0648293` (v0.5.1); rechecked identical against `2d9481d`. Same machine, load average 4–11, runs alternated
under a shared lock.

### Engine builds the flat tree during the walk

Baseline for this part: `2d9481d` (PR #2). Each directory's entries are
appended straight into the C-ABI arrays (parents, sizes, flags, name offsets
and bytes) under one short lock; a finish pass derives subtree totals,
completeness and the sorted child lists from the contiguous sibling runs. There
is no node arena to convert or free, and per-worker scratch buffers mean reading
a directory allocates nothing. Hard-link ownership (first path wins),
incomplete-subtree propagation, Clean Up selection and the JSON CLI keep their
exact behaviour. Full C-ABI dumps (every path, both sizes, file count, flags,
child order and error count) are identical to `2d9481d` on `/Applications`,
`/Library` and `/System/Library`; CLI JSON is identical on `/Applications` and
`/opt/homebrew`.

| `bench ffi` | `2d9481d` | Now |
|---|---:|---:|
| Peak footprint, `/Applications` (332k nodes) | 51.1 MB | 27.5 MB |
| Peak footprint, home folder without FDA (1.12M nodes) | 143.5 MB | 74.8 MB |
| Walk end → tree ready, `/Applications` | 9.1–10.3 ms | 2.7–3.5 ms |
| Walk end → tree ready, home folder | 32.2–40.5 ms | 10.1–11.4 ms |
| Full pipeline, home folder | 4.02 s (3.96–4.15) | 3.99 s (3.90–4.05) |

Wall time is unchanged within noise: about 95% of scan CPU is kernel time in
`getattrlistbulk` and `open`. Rejected on the way: `openat` from a kept-open
parent (same wall time), breadth-first job order (33% slower), 16/64 KB read
buffers and fewer requested attributes (no change), skipping each directory's
final empty read (within noise, risky off APFS), 6–32 workers (10 stays best).

### Treemap paints each pixel once

The painter first records which shade step ends up on top of each pixel
(integer fills), then runs the cushion shader once per pixel, four pixels at a
time with the same operations in the same order, and finally applies only the
frame darkening that came after that owner. The image takes the pixel buffer
without a copy, layout is a struct with reused buffers, and hover redraws only
the outline bands that changed, with label text laid out once per render.
`benchmarks/rendering.py --real` compares any git ref on real scans:

| `/Applications`, median ms | v0.5.1 | Now |
|---|---:|---:|
| 3200×2000 layout + paint + index | 45.4 | 22.4 |
| 1600×1600 | 34.8 | 18.3 |
| 3200×2000 zoomed | 23.4 | 18.6 |
| 3200×2000 with free space | 40.3 | 19.0 |
| Redraw per mouse move | 17.4 | 0.22 |

Bitmaps, geometry and 300 hover frames (plus 51 with agent highlights) are
identical to v0.5.1, and the synthetic harness passes at scale 1 and 2.

### List selection

Outline items are `NSObject`s, so the outline view compares them by pointer
rather than through Swift runtime casts: selecting a file inside a
107k-item folder went from 212 ms (189–229) to 115 ms (114–140).

## Verification and reproduction

```sh
cargo test --release
cargo test --release --lib flatten_benchmark -- --ignored --nocapture
benchmarks/run-ui.sh
benchmarks/run-ui.sh --scan-path /Applications /path/to/projects
uv run python benchmarks/rendering.py --baseline 74b8fe4 --allow-ring-rounding
benchmarks/run-agent.sh --check-only
./build.sh
```

`benchmarks/run-ui.sh --check-only` and the rendering runner's `--check-only`
option omit timing loops. Swift harnesses use production `-O`, Swift 6, default
main-actor isolation, and the macOS 14 deployment target, without whole-module
optimization. The rendering harness compiles the actual old/new renderer files
with a deterministic synthetic tree adapter; it measures redraw operations,
not total app launch or scan time. The UI harness uses the production `Tree`
and either an in-memory C fixture adapter or the actual Rust scanner.

To compare scanner versions, put the baseline source in an ignored directory,
copy the current `src/bin/bench.rs` into it so both libraries use the same
harness, and build both with `cargo build --release`. Then run:

```sh
uv run benchmarks/scan.py \
  --baseline build/perf-baseline-source/target/release/bench \
  --candidate target/release/bench --path /Applications \
  --output build/perf-results/apps-ffi.json
```

The scanner runner warms both builds, alternates AB/BA order, records every
sample and executable SHA256, and fails if file/directory/byte/error totals
differ. `/usr/bin/time -l` records process peak memory. Do not compare timing
ratios across a changing input tree without investigating the mismatch.

Engine checks cover hardlinks, directory symlinks, parent ordering, empty
directories, cloud/mount metadata, and exact equality of every flat ABI column
against the original conversion. Cleanup checks cover all matching rules,
threshold boundaries, nesting, Trash, Unicode, randomized and wide trees, and
real NSOutlineView count/selection behavior. Benchmarking performs no cleanup
and launches no coding agent.

Rendering verification passed 28 paired bitmap/geometry cases, 126
scale/root/paint-band cases, 2,000 independent rounded-pixel coverage cases,
260,708 ring hit comparisons, and 11,344 treemap hit comparisons. It includes
fractional sizes, zero-byte and empty trees, free space, very uneven weights,
deep chains, and invalidation followed by returning to the original size. An
additional 42-case matrix passes exactly at scale 1 and within the documented
stroke-rounding bound at scale 2.

The complete app built successfully and passed `codesign --verify --deep
--strict`. Native UI smoke testing covered a real `/Applications` scan, folder
zoom, switching treemap/rings, free-space toggling, and rescan. Both scans
displayed 278,661 files and 32.53 GB; `du -skx /Applications` independently agreed
at exactly **32,533,331,968 allocated bytes**. The tested app needed no new Full
Disk Access grant for that path, and its AI startup was disabled for QA.
The final combined native harness additionally passed three applications scans,
selection synchronization, both renderers, free-space toggles, and scrolling to
the bottom and back to verify recycled cells. It checked current tree ownership,
names and sizes for every available cell; 120 hover updates caused zero root
body evaluations. Its captured final window was visually inspected. The current
release Rust suite passes five tests, with the isolated timing test ignored by
default. Final engine/UI logs are checked in alongside the benchmark samples.
The build retains two pre-existing AgentLocator concurrency warnings. The
scoped treemap buffer warning is resolved with an explicit lifetime proof.

## Experiments rejected and practical limits

- **Lazy treemap weights plus per-band operation lists:** the combined candidate
  regressed the wide fixture from 13.658 to 28.374 ms against the first pass.
  Both experiments were removed; raw samples remain in the rendering report.
- **Bounded parent descriptors / `openat`:** exact inventories and descriptor
  release tests passed, but applications changed 0.580 → 0.584 s, repositories
  0.433 → 0.430 s, and the smaller third target 0.096 → 0.095 s. The lifecycle
  complexity was not justified, and the implementation was removed.
- **Bulk buffer sizes:** 16–1,024 KiB variants did not establish a useful win.
  Overlapping unrelated workloads invalidated much of the sweep; the shipping
  256 KiB buffer is unchanged.
- **Skipping directories reported empty:** rejected because it changes
  unreadable-directory accounting and relies on metadata sampled before descent.
- **Bounded top-k heap for prompt rows:** slower than the already-pruned sort
  (0.214 versus 0.027 ms for candidate selection); simple sorting remains.
- **Whole-module Swift optimization:** no useful layout improvement in the
  tested window; production compiler settings remain unchanged.
- **FDA caching:** denied probes already measured about 0.07 ms, so it was not
  worth changing permission-refresh behavior. The successful-FDA path was not
  benchmarked.

The baseline scanner's running-CPU profile spent 53.8% in `getattrlistbulk` and
37.4% in `open`. Filesystem latency and native AppKit/SwiftUI setup still impose
costs; this report does not promise zero latency or exhaust every hardware,
filesystem, and workload combination. Accepted changes have measured benefits
or focused responsiveness/correctness checks; unproven tuning was removed.

Existing engine limitations remain outside this performance work: invalid UTF-8
entry names and per-entry metadata errors are skipped (counted in the scan's
coverage, and their folder is marked partly read); freeing a scan handle does
not cancel its worker scan, `bz_cancel` does. A cancelled scan ends with no
tree, so the UI's Stop button brings back the tree that was on screen.
