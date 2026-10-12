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
  split across cores. The code is kept in `src/searchfs.rs` for reference.
- Thread count sweet spot is about the core count. 32+ threads regress ~40%.
- Scan threads run at `QOS_CLASS_USER_INITIATED`. At a GUI app's default
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

## Map interaction: ring hover and window drag

Two costs from the 2026-10-07 audit, measured before changing them and again
after. Both run through `benchmarks/rendering.py --baseline e088f7d
--interaction-only` (`e088f7d` is the code before this change); the harness
compiles the baseline and working-tree views side by side, offscreen, and
alternates them. Raw output:
[benchmarks/results/2026-10-12](benchmarks/results/2026-10-12). Method details
are in [benchmarks/RENDERING.md](benchmarks/RENDERING.md).

**The machine was not quiet.** The load average was 160–360 from other agents'
builds for the whole session, so every absolute time below is inflated and
noisy. Each row is the min of nine interleaved baseline/candidate pairs (the
medians and all samples are in the raw files, and the medians are noisier);
treat the ratios as indicative and rerun on an idle Mac before quoting one.

*Sunburst hover (item 7).* The baseline set `needsDisplay = true` on every
hover change, and `updateNSView` dirtied the whole view on every SwiftUI update
(the `_ = model.selection` line). Profile of 60 pointer steps on a 1440×900 pt
(2880×1800 px) view: the hover logic is ~0.1 ms in total, so all the time is the
repaint. Now a hover invalidates the old and new wedge, the centre label and,
when the selection moves, its arc; `updateNSView` calls `syncOverlay()`, which
reads the selection (so SwiftUI still re-runs it when the selection changes)
and invalidates nothing when nothing changed. On average a hover event
invalidates 18% of the view's area (largest 100%: a folder's wedge covers every
ring outside it, and pieces that add up to more than the view become one rect).

| fixture | 60 hover steps, baseline | candidate | |
|---|---|---|---|
| balanced (13,280 nodes) repaint only | 36.5 ms | 15.4 ms | 2.4× |
| balanced, logic + repaint | 49.4 ms | 35.0 ms | 1.4× |
| flat (100,001 files in one folder) repaint only | 42.2 ms | 12.1 ms | 3.5× |
| flat, logic + repaint | 47.2 ms | 24.2 ms | 2.0× |
| deep (a chain of 120 folders: one wedge covers the chart) | 161.8 ms | 169.0 ms | 1.0× (no change, noise) |

The hover logic itself is about 1 µs slower per step (0.079 → 0.113 ms over 60
steps) for the overlay bookkeeping. Rejected: drawing each dirty rect from
`bitmap.cropping(to:)` (what the treemap does) was 0.56× the baseline here
(62.6 ms vs 35.3 ms for the same 60 steps), because a fresh `CGImage` per draw
misses Core Graphics' image cache (isolated: 0.8–2.1 ms per cropped draw vs
0.14 ms for drawing the whole cached image through a clip). The rings draw the
whole bitmap and let AppKit's clip bound the work. The treemap's crop path
shows the same cost in this harness; it was not changed here.

Correctness is asserted in the same run: 1,092 hover, select and deselect events
(with and without agent highlights) redraw the same pixels as a full draw,
within the antialiasing differences Quartz makes under a different clip (at most
4 levels on at most 0.2% of pixels), and the first frame matches the baseline's
outside the centre label. The bitmap rendering is untouched:
`rendering.py --baseline bf3b1fc --check-only` still requires identical bitmaps.

*Live window resize (item 6).* The baseline re-ran layout and paint for the
whole map on every frame of a window drag (`layout()` → `relayoutIfNeeded()`).
Per frame that is, measured here: treemap 3.4–5.2 ms (balanced), 9–28 ms (100k
files), 3–10 ms (deep); rings 45–55 ms (balanced), 7–24 ms (flat),
60–100 ms (deep). Now both views remember a live resize
(`viewWillStartLiveResize`), keep their last render, and render once in
`viewDidEndLiveResize`. They draw only when invalidated
(`layerContentsRedrawPolicy = .onSetNeedsDisplay`), so during the drag Core
Animation scales the existing picture (the rings keep their aspect ratio and
stay round) and `draw` is not called. A zoom or a new tree during a drag still
renders at once.

| 24 drag frames, 1440×900 → 960×540 pt | baseline | candidate | |
|---|---|---|---|
| treemap, balanced | 236 ms | 6.0 ms | 39× |
| treemap, flat | 566 ms | 27 ms | 21× |
| treemap, deep | 210 ms | 8.7 ms | 24× |
| rings, balanced | 1,290 ms | 30.9 ms | 42× |
| rings, flat | 361 ms | 8.8 ms | 41× |
| rings, deep | 948 ms | 20.2 ms | 47× |

These rows are the layout and render work removed, not frame times: the
baseline column also draws each frame, the candidate column renders once at the
end, and the Core Animation scaling during the drag is on the GPU and cannot be
timed offscreen. The check that goes with them asserts that no frame of a drag
remakes either map's bitmap and that the end remakes it once, to the baseline's
pixels. **Not measured:** a real drag in the app (frame pacing, how the scaled
picture looks, whether AppKit calls `draw` mid-drag as expected). A drag needs
an interactive session; none was run. What was run in the built app (a QA copy
under its own bundle ID) is the accessibility tree, read through the real AX
server: the treemap list `Treemap of tests` with 22 rows such as
`CleanupIntegrationChecks.swift, 57 kB, 14.1% of tests` (role AXButton,
description `file`), AXPress on a file selecting it, AXPress on a folder
zooming in, and the same on the rings.

