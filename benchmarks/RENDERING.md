# Rendering regression and performance harness

Run on an Apple Silicon Mac with the Swift toolchain:

```sh
uv run --no-project python benchmarks/rendering.py --baseline 74b8fe4f097a819ece484a73e08f5368e64c3001 --allow-ring-rounding
```

To isolate the second rendering pass, compare with `--baseline 178d256` instead.
Treemap pixels and all geometry/hit tests still require
exact equality. Retina ring strokes permit only a maximum channel difference
of 5/255 affecting fewer than 0.1% of stored channel bytes per fixture. This
explicit option records the changed-byte histogram and maximum error; without
it any changed pixel fails. Ring gradients retain their original serial raster
path. Non-Retina scenes and scenes with fewer than 24 arcs retain the original
serial stroke too.

Add `--check-only` to omit timings. `--build-only --output /tmp/blitztree-rendering-bench`
builds an executable that can be timed later while other benchmarks are idle.
Use `--rings-only --check-only --scale 1` for the 42-case non-Retina matrix;
repeat with `--scale 2 --allow-ring-rounding` for Retina. `--rings-only` without
`--check-only` also times full-circle ring scenes in nine alternating pairs.
Set `BZ_RENDER_IMAGES` to a directory to export matching baseline/candidate PNGs
for the large balanced fixture. `--profile rings` or `--profile treemap` adds
phase instrumentation to temporary sources for diagnosis only.

The harness compiles the actual baseline and working-tree renderer files as
separate Swift files, widening private visibility only in temporary copies. It
uses the app's `-O`, Swift 6, main actor isolation, and macOS 14 deployment target
without whole-module optimization. A deterministic immutable synthetic Tree
adapter replaces the Rust FFI tree; these are offscreen rendering comparisons,
not end-to-end scan or application responsiveness measurements.

Correctness checks compare bitmap bytes, leaf/directory rectangles, labels,
and ring segments for seven fixtures, two view sizes, and free space on/off.
Additional checks cover scale 1/2, alternate band boundaries, directory/file
roots, 2,000 fractional-boundary raster coverage cases, hover points and arc/leaf
boundaries, and valid-to-tiny-to-valid view invalidation. The coverage cases
include an exact half-pixel rounding regression and distributions ranging from
tiny weights to 10^18.

Timing cases use 2,880 × 1,800 pixel bitmaps. Each case reports the median of
nine alternating baseline/optimized pairs and all raw samples. Treemap timing
includes construction of its hover index; hit testing times 1,000 treemap
queries or 50,000 ring queries over the same deterministic coordinates. The
balanced fixture has 13,280 nodes, the wide fixture 100,001, and the deep fixture
contains a chain of 120 directories. Run timing without concurrent builds or
other performance tests.

The second pass rejected lazy treemap weight access plus per-band operation
lists: the combined candidate regressed the 100,001-node fixture from 13.658 ms
to 28.374 ms against `178d256`, with balanced/deep maps essentially unchanged.
Those algorithm changes are absent from the final source. The raw paired
samples are retained as `results/2026-09-27/render-rejected-treemap.txt`.

## Ring hover and window drag (`--interaction-only`)

```sh
python3 benchmarks/rendering.py --baseline e088f7d --interaction-only          # checks and timings
python3 benchmarks/rendering.py --baseline bf3b1fc --interaction-only --check-only
```

Checks (also part of every full run):

- 1,092 hover, select and deselect events on the rings, for balanced, deep and
  flat fixtures with and without agent highlights, redraw only the rects the
  event returns into a persistent canvas. After each event the canvas must equal
  a full redraw, to within the clip-dependent antialiasing Quartz applies at
  rect edges (at most 4 levels on at most 0.2% of pixels; a missed overlay is
  over a hundred levels). The first frame must equal the baseline's.
- A drag (`viewWillStartLiveResize`, 12 `setFrameSize`/`layout` frames,
  `viewDidEndLiveResize`) renders neither map before its end and renders once at
  its end, to the baseline's pixels; a zoom during a drag renders at once.

Timings, each the min and median of nine alternating baseline/candidate pairs
with raw samples:

- `sunburst_hover_*`: 60 pointer steps on a 1440×900 pt view, each an
  `updateHover` plus the repaint of what it invalidated (the baseline repaints
  the whole view). `_logic_` and `_repaint_` split the two.
- `*_drag_*`: 24 frames of `setFrameSize` + `layout`, then the drag's end. The
  baseline also draws every frame. The candidate does not: the views draw only
  when invalidated, so Core Animation scales the layer during the drag. That
  scaling is on the GPU and cannot be timed offscreen, so these rows are the
  layout and render work removed, not a measured frame time.

The canvas is drawn with `draw(_:)` called under a clip, not AppKit's own
display pass, so repaint times are indicative; the invalidated area is exact.

## Real scans (`--real`)

```sh
uv run --no-project python benchmarks/rendering.py --baseline origin/main --real /Applications --real ~
```

Compiles the baseline's `Treemap.swift`/`TreemapView.swift` (renamed `Legacy*`)
beside the whole current app and the Rust engine (`rendering_real.swift`), scans
each folder once, and for 3200×2000 and 1600×1600 bitmaps, a zoomed-in root and
free space shown, requires identical bitmaps (FNV hashes printed) and identical
leaf, directory and label geometry. It then times alternating pairs: layout,
paint, and the view's full relayout plus its first hit test (the candidate builds
its leaf index lazily; the baseline builds it during relayout).

It also replays 300 mouse moves with selection changes and 50 with agent
highlights at 1600×1000 pt @2x. The baseline receives real `mouseMoved` events and
redraws its whole view; the candidate redraws only the rects it invalidates,
clipped like AppKit's damaged region, into a persistent context that must equal
the baseline's full redraw after every move. It reports hit-test and redraw time
per move. `--check-only` skips timings; `--iterations N` sets the pairs.
