#!/usr/bin/env python3
"""Compile real before/after rendering sources against deterministic tree fixtures.

uv run --no-project python benchmarks/rendering.py --baseline <git-ref> [--check-only]
uv run --no-project python benchmarks/rendering.py --baseline <git-ref> --real /Applications [--real ~]
Private access is widened only in temporary benchmark copies; production code
needs no test hooks. AppKit/CoreGraphics run offscreen, without opening windows.
--real scans real folders with the Rust engine instead of synthetic fixtures
(treemap only; see rendering_real.swift).
"""
import argparse
import os
import pathlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline", required=True)
parser.add_argument("--check-only", action="store_true")
parser.add_argument("--build-only", action="store_true")
parser.add_argument("--output", type=pathlib.Path)
parser.add_argument("--profile", choices=["rings", "treemap"])
parser.add_argument("--rings-only", action="store_true")
parser.add_argument("--allow-ring-rounding", action="store_true")
parser.add_argument("--scale", type=int, choices=[1, 2], default=2)
parser.add_argument("--real", action="append", default=[], metavar="FOLDER",
                    help="scan FOLDER and compare the treemaps on it (repeatable)")
parser.add_argument("--iterations", type=int, default=11, help="timing pairs per --real case")
args = parser.parse_args()
work = pathlib.Path(tempfile.mkdtemp(prefix="blitztree-rendering-"))
sources = ["Treemap.swift", "TreemapView.swift"] + ([] if args.real else ["SunburstView.swift"])
renames = ["TMRect", "TMLabel", "TMLeafIndex", "Squarify", "TypeColor", "TreemapNSView", "NodeMenu",
           "TreemapView", "SBSegment", "SunburstNSView", "SunburstView", "TreemapRenderer", "Scan"]
files = []
baseline_has_layout = False
baseline_has_renderer = False
for legacy in (True, False):
    for name in sources:
        source = (subprocess.check_output(["git", "show", f"{args.baseline}:app/{name}"], cwd=ROOT).decode()
                  if legacy else (ROOT / "app" / name).read_text())
        # Widen access for the bench, except file-private extensions (NSFont helpers):
        # nothing calls them from outside, and widened they clash between the copies.
        source = re.sub(r"\bprivate\s+(?!extension\b)", "", source)
        source = source.replace("window?.backingScaleFactor ?? 2", "window?.backingScaleFactor ?? renderingScale")
        if legacy and name == "Treemap.swift":
            baseline_has_renderer = "enum TreemapRenderer" in source
            baseline_has_layout = "struct Layout" in source and not baseline_has_renderer
        if args.profile == "rings" and not legacy and name == "SunburstView.swift":
            if "func paintBase" in source:
                source = source.replace("    func render() -> CGImage? {", "    func render() -> CGImage? {\n        let profileStart = DispatchTime.now().uptimeNanoseconds")
                source = source.replace("        Self.paintBase(scene, in: ctx, scale: scale)", "        let profilePrepared = DispatchTime.now().uptimeNanoseconds\n        Self.paintBase(scene, in: ctx, scale: scale)\n        let profileBase = DispatchTime.now().uptimeNanoseconds")
                end = "        return ctx.makeImage()\n    }\n\n    nonisolated static func paintBase"
                diagnostic = '''        let profileFinished = DispatchTime.now().uptimeNanoseconds
        print("phase,rings,prepare,\\(Double(profilePrepared - profileStart) / 1e6),fill_shade,\\(Double(profileBase - profilePrepared) / 1e6),stroke_center,\\(Double(profileFinished - profileBase) / 1e6)")
'''
                source = source.replace(end, diagnostic + end)
            else:
                source = source.replace("        // Soft depth:", "        let profileFilled = DispatchTime.now().uptimeNanoseconds\n\n        // Soft depth:")
                source = source.replace("        // Hairline gaps", "        let profileShaded = DispatchTime.now().uptimeNanoseconds\n\n        // Hairline gaps")
                source = source.replace("        // Centre disc:", "        let profileStroked = DispatchTime.now().uptimeNanoseconds\n\n        // Centre disc:")
                source = source.replace("        ctx.fill(bounds)\n", "        ctx.fill(bounds)\n        let profileStart = DispatchTime.now().uptimeNanoseconds\n")
                diagnostic = '''        let profileFinished = DispatchTime.now().uptimeNanoseconds
        print("phase,rings,fill,\\(Double(profileFilled - profileStart) / 1e6),shade,\\(Double(profileShaded - profileFilled) / 1e6),stroke,\\(Double(profileStroked - profileShaded) / 1e6),center,\\(Double(profileFinished - profileStroked) / 1e6)")
'''
                source = source.replace("        return ctx.makeImage()", diagnostic + "        return ctx.makeImage()")
        if legacy:
            for symbol in renames:
                source = re.sub(rf"\b{symbol}\b", "Legacy" + symbol, source)
        path = work / (("Legacy" if legacy else "") + name)
        path.write_text(source)
        files.append(str(path))
binary = args.output.resolve() if args.output else work / "rendering"
runner = (ROOT / "benchmarks" / ("rendering_real.swift" if args.real else "rendering.swift")).read_text()
# Adapt the runner to the baseline's renderer API.
if baseline_has_layout:  # squarify returns a Layout with coverage (0648293)
    runner = runner.replace("let legacy = LegacySquarify.layoutItems(items, rect: rect)",
                            "let legacy = LegacySquarify.layoutItems(items, rect: rect).tiles")
elif baseline_has_renderer:  # squarify appends into a buffer and returns coverage
    runner = runner.replace("let legacy = LegacySquarify.layoutItems(items, rect: rect)",
                            "var legacy: [LegacySquarify.Placed] = []\n"
                            "            let legacyCovers = LegacySquarify.layoutItems(items, rect: rect, into: &legacy)")
    runner = runner.replace("LegacySquarify.layoutItems(items, rect: rect).coversBounds", "legacyCovers")
else:  # 74b8fe4: no coverage report to compare
    runner = "\n".join(l for l in runner.split("\n") if "// baseline reports coverage" not in l)
if baseline_has_renderer and "// BASELINE-RENDER-BEGIN" in runner:
    begin, end = runner.index("        // BASELINE-RENDER-BEGIN"), runner.index("        // BASELINE-RENDER-END")
    runner = runner[:begin] + """        let r = LegacyTreemapRenderer.render(tree: tree, pw: pw, ph: ph, scale: 2, root: root,
                                             showFree: free, freeBytes: freeBytes)
        return (r.layoutMs, r.paintMs)
""" + runner[end:]
if baseline_has_renderer and "// BASELINE-PAINTER-BEGIN" in runner:
    begin, end = runner.index("        // BASELINE-PAINTER-BEGIN"), runner.index("        // BASELINE-PAINTER-END")
    runner = runner[:begin] + """        let old = legacyRendererCushions(tree, pw: pw, ph: ph, scale: scale, root: root, free: free)
        return (old.pixels, old.leaves, old.labels)
""" + runner[end:]
    runner += """
extension RenderingBench {
    static func legacyRendererCushions(_ tree: Tree, pw: Int, ph: Int, scale: CGFloat, root: Int,
                                       free: Bool) -> (pixels: [UInt32], leaves: Int, labels: Int) {
        let r = LegacyTreemapRenderer.render(tree: tree, pw: pw, ph: ph, scale: scale, root: root,
                                             showFree: free, freeBytes: tree.alloc[0] / 3)
        let data = r.image.dataProvider!.data! as Data
        return (data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }, r.leaves.count, r.labels.count)
    }
}
"""
if not args.real:
    # The fixture Tree stands in for the Rust-backed one, but Tree.drawn is pure
    # over parents/alloc: compile the app's own copy instead of a second one.
    model = (ROOT / "app" / "Model.swift").read_text()
    start = model.find("    func drawn(_ node: Int, isDrawn: (Int) -> Bool) -> Int? {")
    if start < 0:
        raise SystemExit("rendering.py: Tree.drawn not found in app/Model.swift; update the splice")
    depth, end = 0, start
    for end in range(model.index("{", start), len(model)):
        depth += {"{": 1, "}": -1}.get(model[end], 0)
        if depth == 0:
            break
    if depth != 0:
        raise SystemExit("rendering.py: unbalanced braces in Tree.drawn in app/Model.swift")
    runner += "\nnonisolated extension Tree {\n" + model[start:end + 1] + "\n}\n"
runner_path = work / "RenderingBench.swift"
runner_path.write_text(runner)
if args.real:
    # The real Tree (Rust engine) and the rest of the app, minus its entry point.
    subprocess.run(["cargo", "build", "--release", "-q"], check=True, cwd=ROOT)
    app = [str(f) for f in sorted((ROOT / "app").glob("*.swift"))
           if f.name not in ("Main.swift", "Treemap.swift", "TreemapView.swift")]
    extra = [*app, "-import-objc-header", str(ROOT / "app" / "bz.h"),
             "-L", str(ROOT / "target" / "release"), "-lblitztree"]
else:
    # TreemapView asks CleanupPathSafety which items Clean Up would refuse; it and
    # what it builds on compile as in the app (the guard checks in run-cleanup.sh).
    extra = [str(ROOT / "app" / name) for name in
             ("CleanupSafety.swift", "CleanupVerify.swift", "GitWorktree.swift", "AgentSessions.swift", "Subprocess.swift")]
subprocess.run(["swiftc", *files, str(runner_path), *extra,
                "-O", "-parse-as-library", "-swift-version", "6", "-default-isolation", "MainActor",
                "-target", "arm64-apple-macos14.0",
                "-framework", "AppKit", "-framework", "SwiftUI", "-o", str(binary)], check=True, cwd=ROOT)
print(f"Renderer benchmark binary: {binary}", flush=True)
if args.real and not args.build_only:
    mode = ["--check-only"] if args.check_only else []
    subprocess.run([str(binary), *mode, "--iterations", str(args.iterations),
                    *[os.path.expanduser(f) for f in args.real]], check=True, cwd=ROOT)
elif not args.build_only:
    mode = [f"--profile-{args.profile}"] if args.profile else (["--check-only"] if args.check_only else [])
    if args.rings_only:
        mode.append("--rings-only")
    if args.allow_ring_rounding:
        mode.append("--allow-ring-rounding")
    if args.scale == 1:
        mode.append("--scale1")
    subprocess.run([str(binary), *mode], check=True, cwd=ROOT)
if not args.build_only or args.output:
    shutil.rmtree(work)
