import AppKit
import Foundation
import ImageIO

@MainActor let renderingScale: CGFloat = CommandLine.arguments.contains("--scale1") ? 1 : 2

// Minimal immutable adapter for the production Tree read interface. Every
// rendering algorithm, shader and event hit test is compiled from app sources;
// rendering.py splices Tree.drawn in from app/Model.swift.
nonisolated final class Tree: @unchecked Sendable {
    let alloc: [UInt64]
    let parents: [UInt32]
    let nFiles: [UInt32]
    let nameOff: [UInt32]
    let nameBlob: [UInt8]
    let names: [String]
    let dirs: [Bool]
    let childLists: [[UInt32]]
    var count: Int { names.count }

    init(kind: String, seed: UInt64 = 1) {
        var names = [String](), parents = [UInt32](), sizes = [UInt64]()
        var dirs = [Bool](), kids = [[UInt32]](), files = [UInt32]()
        var random = seed
        func next() -> UInt64 { random = random &* 6364136223846793005 &+ 1442695040888963407; return random }
        func add(_ name: String, parent: UInt32, directory: Bool, bytes: UInt64 = 0) -> Int {
            let i = names.count
            names.append(name); parents.append(parent); sizes.append(bytes); dirs.append(directory)
            kids.append([]); files.append(directory ? 0 : 1)
            if parent != .max { kids[Int(parent)].append(UInt32(i)) }
            return i
        }
        let root = add("fixture", parent: .max, directory: true)
        func populate(_ parent: Int, depth: Int, branches: Int) {
            if depth > 0 {
                for j in 0..<branches {
                    let n = add("folder-\(depth)-\(j)", parent: UInt32(parent), directory: true)
                    populate(n, depth: depth - 1, branches: branches)
                }
            }
            for j in 0..<(depth == 0 ? 19 : 4) {
                let ext = ["swift", "mp4", "jpg", "db", "zip"][j % 5]
                _ = add("file-\(j).\(ext)", parent: UInt32(parent), directory: false,
                        bytes: 1 + next() % (kind == "skewed" ? 1_000_000 : 16_384))
            }
        }
        switch kind {
        case "flat":
            for j in 0..<100_000 {
                _ = add("file-\(j).dat", parent: UInt32(root), directory: false, bytes: 1 + next() % 8192)
            }
        case "one_huge":
            _ = add("huge.bin", parent: 0, directory: false, bytes: 1_000_000_000_000)
            for j in 0..<1000 { _ = add("tiny-\(j)", parent: 0, directory: false, bytes: 1) }
        case "empty": break
        case "zero":
            for j in 0..<100 { _ = add("empty-\(j)", parent: 0, directory: j % 2 == 0) }
        case "deep":
            var parent = root
            for j in 0..<120 { parent = add("chain-\(j)", parent: UInt32(parent), directory: true) }
            populate(parent, depth: 2, branches: 4)
        default: populate(root, depth: 4, branches: 5)
        }
        for i in names.indices.reversed() {
            if parents[i] != .max {
                sizes[Int(parents[i])] += sizes[i]
                files[Int(parents[i])] += files[i]
            }
            kids[i].sort { sizes[Int($0)] > sizes[Int($1)] }
        }
        var offsets: [UInt32] = [0], blob: [UInt8] = []
        for name in names { blob += name.utf8; offsets.append(UInt32(blob.count)) }
        self.names = names; self.parents = parents; self.alloc = sizes; self.dirs = dirs
        self.nFiles = files; self.childLists = kids; self.nameOff = offsets; self.nameBlob = blob
    }
    func children(_ node: Int) -> [UInt32] { childLists[node] }
    func isDir(_ node: Int) -> Bool { dirs[node] }
    func name(_ node: Int) -> String { names[node] }
    func path(_ node: Int) -> String { names[node] }
    func displayPath(_ node: Int) -> String { names[node] }
    static func displayPath(_ path: String) -> String { path }
    // The tooltip's partial-read note; every fixture folder was read in full.
    func coverageNote(_ node: Int) -> String? { nil }
}

@MainActor final class ScanModel {
    var tree: Tree?
    var viewRoot = 0
    var showFreeSpace = false
    var freeBytes: UInt64 = 0
    var hovered: Int?
    var selection: Int?
    var scanRoot = "fixture"
    var agentRun: AgentRun?
    // Bumped by the real model on each new tree; the fixtures never change theirs.
    var treeGeneration: UInt64 = 0
    var highlightedType: [UInt8]? { nil }
    // The node menu's actions; no fixture opens it, so they do nothing.
    var plannerName: String? { nil }
    var canStartRun: Bool { false }
    func startScan(path: String? = nil) {}
    func ask(about node: Int) {}
    func forget(paths: [String]) {}
}
@MainActor struct AgentRun { func highlights(in tree: Tree?) -> [Int] { [] } }
enum Fmt {
    static func size(_ bytes: UInt64) -> String { String(bytes) }
    static func num(_ number: UInt64) -> String { String(number) }
}

@main struct RenderingBench {
    static var ringMaxDelta = 0
    static var ringMaxChangedFraction = 0.0

    static func ms(_ action: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        action()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func pixels(_ image: CGImage?) -> Data {
        guard let image, let data = image.dataProvider?.data else { fatalError("missing bitmap") }
        return data as Data
    }

    static func samePixels(_ lhs: CGImage?, _ rhs: CGImage?, _ label: String) {
        if let directory = ProcessInfo.processInfo.environment["BZ_RENDER_IMAGES"], label.contains("balanced"), label.contains("1440") {
            try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let name = label.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            for (suffix, image) in [("candidate", lhs!), ("baseline", rhs!)] {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("scale-\(Int(renderingScale))-\(name)-\(suffix).png")
                let writer = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(writer, image, nil)
                precondition(CGImageDestinationFinalize(writer))
            }
        }
        let a = pixels(lhs), b = pixels(rhs)
        precondition(a.count == b.count, "bitmap storage differs")
        if a != b {
            let differing = zip(a, b).filter { $0 != $1 }.count
            var maximum = 0, total = 0, histogram: [Int: Int] = [:]
            for (x, y) in zip(a, b) where x != y {
                let delta = abs(Int(x) - Int(y))
                maximum = max(maximum, delta); total += delta; histogram[delta, default: 0] += 1
            }
            let diagnostic = "pixel-diff,\(label),bytes,\(differing),max_delta,\(maximum),mean_delta,\(Double(total) / Double(differing)),histogram,\(histogram.sorted { $0.key < $1.key })\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
            if CommandLine.arguments.contains("--allow-ring-rounding"), label.contains("rings") || label.contains("sunburst") {
                ringMaxDelta = max(ringMaxDelta, maximum)
                ringMaxChangedFraction = max(ringMaxChangedFraction, Double(differing) / Double(a.count))
                return
            }
            fatalError("\(label): \(differing) differing bytes out of \(a.count)")
        }
    }

    static func checkRingRounding() {
        print("rings_rounding,max_channel_delta,\(ringMaxDelta),max_changed_byte_fraction,\(ringMaxChangedFraction)")
        precondition(ringMaxDelta <= 5 && ringMaxChangedFraction < 0.001, "ring rounding exceeded bounds")
    }

    static func hitID(_ hit: SunburstNSView.Hit?) -> Int {
        switch hit { case .center: -2; case .segment(let i): i; case nil: -1 }
    }
    static func hitID(_ hit: LegacySunburstNSView.Hit?) -> Int {
        switch hit { case .center: -2; case .segment(let i): i; case nil: -1 }
    }

    /// The baseline's cushion painter over the whole bitmap in one band.
    static func legacyCushions(_ tree: Tree, pw: Int, ph: Int, scale: CGFloat, root: Int,
                               free: Bool) -> (pixels: [UInt32], leaves: Int, labels: Int) {
        // BASELINE-PAINTER-BEGIN
        let oldOut = LegacyTreemapNSView.RenderOutput()
        let oldOps = LegacyTreemapNSView.layoutOps(tree: tree, pw: pw, ph: ph, scale: scale, root: root,
                                                  showFree: free, freeBytes: tree.alloc[0] / 3, out: oldOut)
        var a = [UInt32](repeating: 0xFF16_1616, count: pw * ph)
        a.withUnsafeMutableBufferPointer { pixels in
            oldOps.withUnsafeBufferPointer { LegacyTreemapNSView.paint($0, base: pixels.baseAddress!, pw: pw, ph: ph, rows: 0..<ph) }
        }
        return (a, oldOut.leaves.count, oldOut.labels.count)
        // BASELINE-PAINTER-END
    }

    /// The candidate's layout, painted in `bands` separate row ranges.
    static func cushions(_ tree: Tree, pw: Int, ph: Int, scale: CGFloat, root: Int,
                         free: Bool, bands: Int) -> (pixels: [UInt32], leaves: Int, labels: Int) {
        var layout = TreemapRenderer.Layout(tree: tree, pw: pw, ph: ph, scale: scale,
                                            showFree: free, freeBytes: tree.alloc[0] / 3)
        layout.draw(root, CGRect(x: 0, y: 0, width: pw, height: ph),
                    TreemapRenderer.Cushion.baseHeight, TreemapRenderer.Surface(), 0)
        var b = [UInt32](repeating: 0, count: pw * ph) // the painter writes every pixel
        b.withUnsafeMutableBufferPointer { pixels in
            layout.ops.withUnsafeBufferPointer { ops in
                layout.shades.withUnsafeBufferPointer { shades in
                    for i in 0..<bands {
                        TreemapRenderer.paint(ops, shades, base: pixels.baseAddress!, pw: pw,
                                              rows: (ph * i / bands)..<(ph * (i + 1) / bands))
                    }
                }
            }
        }
        return (b, layout.leaves.count, layout.labels.count)
    }

    static func verifyCushions(_ tree: Tree, seed: Int) {
        let pw = 13 + seed * 313 % 1103, ph = 7 + seed * 997 % 787
        let scale: CGFloat = seed % 2 == 0 ? 1 : 2
        let root = seed % 3 == 0 ? (tree.children(0).first.map(Int.init) ?? 0) : 0
        let old = legacyCushions(tree, pw: pw, ph: ph, scale: scale, root: root, free: seed % 5 == 0)
        // Different partitions verify edge handling between painter bands.
        let new = cushions(tree, pw: pw, ph: ph, scale: scale, root: root, free: seed % 5 == 0, bands: seed % 7 + 1)
        if old.pixels != new.pixels {
            let differing = zip(old.pixels, new.pixels).filter { $0 != $1 }.count
            fatalError("cushion seed \(seed) root \(root) scale \(scale): \(differing) differing pixels")
        }
        precondition(new.leaves == old.leaves && new.labels == old.labels)
    }

    static func verifyCoverage() {
        let sizes: [Double] = [98060, 97305, 96211, 89669, 85842, 83969, 81516, 80132, 69471,
                               66690, 50416, 33725, 28778, 19791, 12017, 7069, 4059, 1538]
        var random: UInt64 = 982451653
        func next() -> UInt64 { random = random &* 6364136223846793005 &+ 1442695040888963407; return random }
        for seed in 0..<2000 {
            let rect = seed == 0 ? CGRect(x: 0.25, y: 0.75, width: 100.25, height: 79.75)
                : CGRect(x: CGFloat(seed % 7) / 4, y: CGFloat(seed % 11) / 4,
                         width: 3.25 + CGFloat(seed * 71 % 211), height: 2.75 + CGFloat(seed * 47 % 179))
            let weights = seed == 0 ? sizes : (0..<(1 + Int(next() % 100))).map { i in
                i % 5 == 0 ? 0.000001 : Double(1 + next() % (seed % 2 == 0 ? 1_000_000_000_000_000_000 : 100_000))
            }.sorted(by: >)
            let items = weights.enumerated().map { (node: $0.offset, size: $0.element) }
            var tiles: [Squarify.Placed] = []
            let coversBounds = Squarify.layoutItems(items, rect: rect, into: &tiles)
            let legacy = LegacySquarify.layoutItems(items, rect: rect)
            precondition(tiles.count == legacy.count)
            for (a, b) in zip(tiles, legacy) { precondition(a.node == b.node && a.rect == b.rect) }
            precondition(coversBounds == LegacySquarify.layoutItems(items, rect: rect).coversBounds) // baseline reports coverage
            if !coversBounds { continue }
            let width = Int(ceil(rect.maxX)) + 1, height = Int(ceil(rect.maxY)) + 1
            var covered = [Bool](repeating: false, count: width * height)
            for (_, tile) in tiles where tile.width >= 0.5 && tile.height >= 0.5 {
                for y in Int(tile.minY.rounded())..<Int(tile.maxY.rounded()) {
                    for x in Int(tile.minX.rounded())..<Int(tile.maxX.rounded()) { covered[y * width + x] = true }
                }
            }
            for y in Int(rect.minY.rounded())..<Int(rect.maxY.rounded()) {
                for x in Int(rect.minX.rounded())..<Int(rect.maxX.rounded()) {
                    precondition(covered[y * width + x], "false coverage at seed \(seed) pixel \(x),\(y)")
                }
            }
        }
    }

    static func measure(_ label: String, before: () -> Void, after: () -> Void) {
        var a: [Double] = [], b: [Double] = []
        for i in 0..<9 {
            if i % 2 == 0 { a.append(ms(before)); b.append(ms(after)) }
            else { b.append(ms(after)); a.append(ms(before)) }
        }
        let old = a.sorted()[4], new = b.sorted()[4]
        print(String(format: "%@,%.3f,%.3f,%.2fx", label, old, new, old / new))
        print("samples,\(label),baseline,\(a.map { String(format: "%.3f", $0) }.joined(separator: ","))")
        print("samples,\(label),optimized,\(b.map { String(format: "%.3f", $0) }.joined(separator: ","))")
    }

    static func verifyFreeSpaceUpdates() {
        let model = ScanModel()
        let tree = Tree(kind: "balanced")
        model.tree = tree
        let frame = CGRect(x: 0, y: 0, width: 480, height: 320)
        let treemap = TreemapNSView(frame: frame), rings = SunburstNSView(frame: frame)
        treemap.model = model; rings.model = model

        func check(_ name: String, freeWhenZoomed: Bool, refresh: () -> Void,
                   rebuild: () -> Void, image: () -> CGImage?) {
            model.viewRoot = 0; model.showFreeSpace = true; model.freeBytes = 0
            refresh()
            // The tree is already visible when capacity arrives, with the
            // same root, dimensions and display option throughout.
            for bytes in [tree.alloc[0] / 3, tree.alloc[0], 0] {
                let before = pixels(image())
                model.freeBytes = bytes
                refresh()
                precondition(pixels(image()) != before, "\(name): stale free-space rendering")
                let cached = image()!
                refresh()
                precondition(image() === cached, "\(name): unchanged capacity rerendered")
            }
            // Treemap also shows capacity when zoomed; rings only at the root.
            // Preserve each view's existing behavior and reuse hidden bitmaps.
            for (root, showFree) in [(0, false), (Int(tree.children(0)[0]), true)] {
                model.viewRoot = root; model.showFreeSpace = showFree
                refresh()
                let cached = image()!
                model.freeBytes += tree.alloc[0]
                refresh()
                if showFree && freeWhenZoomed {
                    precondition(pixels(image()) != pixels(cached), "\(name): stale zoomed capacity")
                } else {
                    precondition(image() === cached, "\(name): invisible capacity rerendered")
                }
                model.viewRoot = 0; model.showFreeSpace = true
                refresh()
                let restored = pixels(image())
                rebuild()
                precondition(pixels(image()) == restored, "\(name): latest capacity missing on return")
            }
        }
        check("treemap", freeWhenZoomed: true, refresh: { treemap.relayoutIfNeeded() },
              rebuild: { treemap.relayout() }, image: { treemap.bitmap })
        check("rings", freeWhenZoomed: false, refresh: { rings.relayoutIfNeeded() },
              rebuild: { rings.relayout() }, image: { rings.bitmap })
        print("PASS: delayed capacity, changes/reset and cache reuse in both views")
    }

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0) // a killed run keeps the rows it printed
        if CommandLine.arguments.contains("--interaction-only") {
            verifyInteraction()
            if !CommandLine.arguments.contains("--check-only") { measureInteraction() }
            return
        }
        if CommandLine.arguments.contains("--rings-only") {
            for kind in ["balanced", "skewed", "deep", "flat", "empty", "zero", "one_huge"] {
                for (width, height) in [(480.0, 320.0), (1024.25, 700.75), (1440.0, 900.0)] {
                    for free in [false, true] {
                        let model = ScanModel(); model.tree = Tree(kind: kind)
                        model.showFreeSpace = free; model.freeBytes = max(1, model.tree!.alloc[0] / 3)
                        let frame = CGRect(x: 0, y: 0, width: width, height: height)
                        let sb = SunburstNSView(frame: frame), old = LegacySunburstNSView(frame: frame)
                        old.model = model; sb.model = model
                        precondition(sb.segments.count == old.segments.count)
                        for (a, b) in zip(sb.segments, old.segments) {
                            precondition(a.node == b.node && a.ring == b.ring && a.start == b.start && a.end == b.end
                                         && a.bytes == b.bytes && a.count == b.count)
                        }
                        samePixels(sb.bitmap, old.bitmap, "rings \(kind) \(width)x\(height) free=\(free)")
                    }
                }
            }
            checkRingRounding()
            print("PASS: 42 rings bitmap and geometry comparisons")
            if CommandLine.arguments.contains("--check-only") { return }
            for kind in ["balanced", "deep", "flat"] {
                let model = ScanModel(); model.tree = Tree(kind: kind)
                let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
                let sb = SunburstNSView(frame: frame), old = LegacySunburstNSView(frame: frame)
                old.model = model; sb.model = model
                measure("rings_\(kind)", before: { old.relayout() }, after: { sb.relayout() })
            }
            return
        }
        if CommandLine.arguments.contains("--profile-rings") {
            let model = ScanModel(); model.tree = Tree(kind: "balanced")
            let sb = SunburstNSView(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
            sb.model = model
            for _ in 0..<100 { sb.relayout() }
            return
        }
        if CommandLine.arguments.contains("--profile-treemap") {
            let tree = Tree(kind: "flat")
            var sink = 0
            for _ in 0..<15 {
                let r = TreemapRenderer.render(tree: tree, pw: 2880, ph: 1800, scale: 2, root: 0,
                                               showFree: true, freeBytes: tree.alloc[0] / 3)
                let index = ms { sink += TMLeafIndex(leaves: r.leaves, size: CGSize(width: 1440, height: 900)).cells.count }
                print("phase,treemap,layout,\(r.layoutMs),index,\(index),paint,\(r.paintMs)")
                sink += r.image.width
            }
            precondition(sink > 0)
            return
        }
        let onlyCheck = CommandLine.arguments.contains("--check-only")
        verifyFreeSpaceUpdates()
        verifyCoverage()
        var checks = 0, hitChecks = 0
        var leafHitChecks = 0
        for kind in ["balanced", "skewed", "flat", "deep", "empty", "zero", "one_huge"] {
            let tree = Tree(kind: kind)
            for seed in 1...18 { verifyCushions(tree, seed: seed) }
            for (width, height) in [(480.0, 320.0), (1024.25, 700.75)] {
                for free in [false, true] {
                    let model = ScanModel()
                    model.tree = tree; model.showFreeSpace = free; model.freeBytes = max(1, tree.alloc[0] / 3)
                    let frame = CGRect(x: 0, y: 0, width: width, height: height)
                    let tm = TreemapNSView(frame: frame), oldTM = LegacyTreemapNSView(frame: frame)
                    tm.model = model; oldTM.model = model
                    samePixels(tm.bitmap, oldTM.bitmap, "treemap \(kind) \(width) free=\(free)")
                    precondition(tm.leaves.count == oldTM.leaves.count && tm.rects.count == oldTM.rects.count)
                    for (a, b) in zip(tm.leaves, oldTM.leaves) { precondition(a.node == b.node && a.rect == b.rect) }
                    for (a, b) in zip(tm.rects, oldTM.rects) { precondition(a.node == b.node && a.rect == b.rect) }
                    precondition(tm.labels.count == oldTM.labels.count)
                    for (a, b) in zip(tm.labels, oldTM.labels) {
                        precondition(a.node == b.node && a.strip == b.strip && a.region == b.region && a.name == b.name)
                    }
                    for i in 0..<256 {
                        let p = CGPoint(x: Double((i * 7919) % (Int(width) + 2)) - 1,
                                        y: Double((i * 1543) % (Int(height) + 2)) - 1)
                        precondition(tm.hit(p)?.node == oldTM.hit(p)?.node)
                        leafHitChecks += 1
                    }
                    let leafStride = max(1, tm.leaves.count / 64)
                    for leaf in tm.leaves.enumerated() where leaf.offset % leafStride == 0 {
                        let r = leaf.element.rect
                        for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                                  CGPoint(x: r.midX, y: r.midY), CGPoint(x: r.maxX.nextDown, y: r.maxY.nextDown)] {
                            precondition(tm.hit(p)?.node == oldTM.hit(p)?.node)
                            leafHitChecks += 1
                        }
                    }
                    let sb = SunburstNSView(frame: frame), oldSB = LegacySunburstNSView(frame: frame)
                    sb.model = model; oldSB.model = model
                    samePixels(sb.bitmap, oldSB.bitmap, "sunburst \(kind) \(width) free=\(free)")
                    precondition(sb.segments.count == oldSB.segments.count)
                    for (a, b) in zip(sb.segments, oldSB.segments) {
                        precondition(a.node == b.node && a.ring == b.ring && a.start == b.start && a.end == b.end)
                    }
                    for y in stride(from: -1.0, through: height + 1, by: 7.375) {
                        for x in stride(from: -1.0, through: width + 1, by: 7.125) {
                            let p = CGPoint(x: x, y: y)
                            precondition(hitID(sb.hit(p)) == hitID(oldSB.hit(p)))
                            hitChecks += 1
                        }
                    }
                    // Include every arc boundary and the immediate neighbors.
                    for s in sb.segments {
                        let radius = (sb.radii[s.ring] + sb.radii[s.ring + 1]) / 2
                        for a in [s.start - 1e-12, s.start, s.start + 1e-12, s.end - 1e-12, s.end, s.end + 1e-12] {
                            let p = CGPoint(x: sb.center.x + radius * cos(a - .pi / 2),
                                            y: sb.center.y + radius * sin(a - .pi / 2))
                            precondition(hitID(sb.hit(p)) == hitID(oldSB.hit(p)))
                            hitChecks += 1
                        }
                    }
                    sb.setFrameSize(CGSize(width: 20, height: 20))
                    sb.relayout()
                    precondition(hitID(sb.hit(CGPoint(x: 10, y: 10))) == -1)
                    tm.setFrameSize(CGSize(width: 1, height: 1)); tm.relayout()
                    precondition(tm.hit(CGPoint(x: 0.5, y: 0.5)) == nil)
                    precondition(tm.labels.isEmpty && tm.labelHits.isEmpty)
                    // Restoring the original size must rebuild invalid caches.
                    if kind == "balanced", !free, width == 480 {
                        tm.setFrameSize(frame.size); tm.relayoutIfNeeded()
                        sb.setFrameSize(frame.size); sb.relayoutIfNeeded()
                        precondition(tm.bitmap != nil && sb.bitmap != nil)
                        samePixels(tm.bitmap, oldTM.bitmap, "treemap restored size")
                        samePixels(sb.bitmap, oldSB.bitmap, "sunburst restored size")
                    }
                    checks += 1
                }
            }
        }
        checkRingRounding()
        print("PASS: \(checks) treemap/sunburst pixel and geometry comparisons; 126 cushion scale/root/band checks; 2000 fractional coverage checks; \(hitChecks) sunburst and \(leafHitChecks) treemap hit checks")
        verifyInteraction()
        if onlyCheck { return }
        print("workload,baseline_median_ms,optimized_median_ms,speedup")
        for kind in ["balanced", "flat", "deep"] {
            let tree = Tree(kind: kind)
            let model = ScanModel(); model.tree = tree; model.showFreeSpace = true; model.freeBytes = tree.alloc[0] / 3
            let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
            let tm = TreemapNSView(frame: frame), oldTM = LegacyTreemapNSView(frame: frame)
            let sb = SunburstNSView(frame: frame), oldSB = LegacySunburstNSView(frame: frame)
            tm.model = model; oldTM.model = model; sb.model = model; oldSB.model = model
            for (label, before, after) in [
                ("treemap_\(kind)_2880x1800", { oldTM.relayout(); _ = oldTM.hit(.zero) }, { tm.relayout(); _ = tm.hit(.zero) }),
                ("sunburst_\(kind)_2880x1800", { oldSB.relayout() }, { sb.relayout() }),
            ] {
                measure(label, before: before, after: after)
            }
            var sink = 0
            let points = (0..<50_000).map { i in CGPoint(x: Double((i * 7919) % 1440), y: Double((i * 1543) % 900)) }
            measure("sunburst_hits_\(kind)_50000",
                    before: { for p in points { sink &+= hitID(oldSB.hit(p)) } },
                    after: { for p in points { sink &+= hitID(sb.hit(p)) } })
            measure("treemap_hits_\(kind)_1000",
                    before: { for p in points.prefix(1000) { sink &+= oldTM.hit(p)?.node ?? -1 } },
                    after: { for p in points.prefix(1000) { sink &+= tm.hit(p)?.node ?? -1 } })
            precondition(sink != .min)
        }
        measureInteraction()
    }
}

// What a pointer and a window drag cost the views. The candidate's hover redraws
// the wedges that changed; a drag renders once, at its end. The baseline redraws
// the whole ring chart per hover and lays out and paints every frame of a drag.
extension RenderingBench {
    /// `precondition` drops its message in -O builds; a failing check here must say which.
    static func expect(_ ok: Bool, _ message: @autoclosure () -> String) {
        if !ok { fatalError(message()) }
    }

    /// A pointer path round the rings: nearly every step lands in another wedge,
    /// now and then in the centre or outside the chart.
    static func hoverPath(_ frame: CGRect, steps: Int) -> [CGPoint] {
        let outer = Double(min(frame.width, frame.height) / 2 - 18)
        return (0..<steps).map { i in
            let radius = i % 11 == 10 ? 2 : i % 13 == 12 ? outer + 40 : outer * (0.35 + 0.1 * Double(i % 6))
            let angle = Double(i) * 0.37
            return CGPoint(x: frame.midX + radius * cos(angle), y: frame.midY + radius * sin(angle))
        }
    }

    /// An RGBA canvas covering `size` view points at 2x, as a window would back it.
    static func canvas(_ size: CGSize) -> CGContext {
        CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Draws `rects` of `view` into `context` as AppKit does for a dirty region:
    /// clipped, flipped, one `draw(_:)` per rect.
    static func paint(_ view: NSView, _ rects: [CGRect], into context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: 2, y: -2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for dirty in rects {
            // The window backing store works in whole device pixels.
            let scaled = dirty.applying(CGAffineTransform(scaleX: 2, y: 2)).integral
            let rect = scaled.applying(CGAffineTransform(scaleX: 0.5, y: 0.5))
            context.saveGState()
            context.clip(to: rect)
            view.draw(rect)
            context.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    /// How two canvases differ: the largest channel difference, the pixels that
    /// differ, and the box round them in view points.
    static func differences(_ a: CGContext, _ b: CGContext) -> (maxDelta: Int, pixels: Int, box: CGRect) {
        let (x, y) = (bytes(a), bytes(b))
        var box = CGRect.null, count = 0, maxDelta = 0
        for row in 0..<a.height {
            for col in 0..<a.width {
                let i = row * a.bytesPerRow + col * 4
                guard x[i..<i + 4] != y[i..<i + 4] else { continue }
                count += 1
                box = box.union(CGRect(x: col / 2, y: row / 2, width: 1, height: 1))
                for c in 0..<4 { maxDelta = max(maxDelta, abs(Int(x[i + c]) - Int(y[i + c]))) }
            }
        }
        return (maxDelta, count, box)
    }

    /// Quartz antialiases an edge slightly differently under a different clip
    /// rect (the app's own ring rounding note says the same about gradients), so
    /// a partial redraw may differ from a full one by a few levels on some edge
    /// pixels. A missed overlay differs by over a hundred levels, so anything
    /// bigger than 4, or on more than 0.2% of pixels, fails.
    static func sameUnderClipRounding(_ a: CGContext, _ b: CGContext) -> (ok: Bool, why: String) {
        if bytes(a) == bytes(b) { return (true, "") }
        let d = differences(a, b)
        return (d.maxDelta <= 4 && d.pixels * 500 <= a.width * a.height,
                "\(d.pixels) pixels differ by up to \(d.maxDelta) within \(d.box)")
    }

    static func bytes(_ context: CGContext) -> Data {
        Data(bytes: context.data!, count: context.bytesPerRow * context.height)
    }

    /// Hovering, selecting and clearing on the rings, with only the rects each
    /// event reports redrawn, must give the same pixels as redrawing everything.
    static func verifySunburstRedraw() -> (events: Int, largest: Double, mean: Double) {
        var events = 0, largest = 0.0, total = 0.0
        for kind in ["balanced", "deep", "flat"] {
            for lit in [false, true] {
                let model = ScanModel(); model.tree = Tree(kind: kind)
                model.showFreeSpace = true; model.freeBytes = model.tree!.alloc[0] / 3
                let frame = CGRect(x: 0, y: 0, width: 480, height: 320)
                let view = SunburstNSView(frame: frame); view.model = model
                let kids = model.tree!.children(0).map { Int($0) }
                if lit { view.highlights = Array(kids.prefix(2)) }
                let partial = canvas(frame.size), fresh = canvas(frame.size)
                paint(view, [frame], into: partial)
                // The first frame, before any pointer, is what the baseline drew,
                // except for the centre label, whose wording a baseline may differ in.
                let baseline = LegacySunburstNSView(frame: frame); baseline.model = model
                if lit { baseline.highlights = Array(kids.prefix(2)) }
                let baselineCanvas = canvas(frame.size)
                paint(baseline, [frame], into: baselineCanvas)
                let first = sameUnderClipRounding(partial, baselineCanvas)
                if !first.ok {
                    let d = differences(partial, baselineCanvas)
                    expect(view.centerRect.contains(d.box), "sunburst \(kind) lit=\(lit): the first draw differs from the baseline's outside the centre: \(first.why)")
                }
                expect(view.syncOverlay().isEmpty, "sunburst \(kind): nothing changed, nothing to redraw")
                func redraw(_ dirty: [CGRect], _ what: String) {
                    expect(view.syncOverlay().isEmpty, "sunburst \(kind): \(what): a second sync found more to redraw")
                    paint(view, dirty, into: partial)
                    paint(view, [frame], into: fresh)
                    let same = sameUnderClipRounding(partial, fresh)
                    expect(same.ok, "sunburst \(kind) lit=\(lit) \(what): partial redraw differs: \(same.why); redrew \(dirty)")
                    let area = dirty.map { $0.intersection(frame) }.reduce(0.0) { $0 + Double($1.isNull ? 0 : $1.width * $1.height) }
                    largest = max(largest, area / Double(frame.width * frame.height))
                    total += area / Double(frame.width * frame.height)
                    events += 1
                }
                for (i, point) in hoverPath(frame, steps: 160).enumerated() {
                    redraw(view.updateHover(at: point), "hover \(i)")
                    if i % 9 == 4 {
                        model.selection = kids[(i / 9) % kids.count]
                        redraw(view.syncOverlay(), "select \(i)")
                    }
                    if i % 40 == 39 {
                        model.selection = nil
                        redraw(view.syncOverlay(), "deselect \(i)")
                    }
                }
            }
        }
        expect(largest <= 1.0, "a hover should not redraw more than the view")
        return (events, largest, total / Double(events))
    }

    /// A window drag renders the map once, at its end, and lands on the same
    /// pixels as laying out every frame did.
    static func verifyLiveResize() -> Int {
        var frames = 0
        for kind in ["balanced", "deep", "flat"] {
            let model = ScanModel(); model.tree = Tree(kind: kind)
            model.showFreeSpace = true; model.freeBytes = model.tree!.alloc[0] / 3
            let start = CGRect(x: 0, y: 0, width: 960, height: 600)
            let sizes = (1...12).map { CGSize(width: 960 - 20 * CGFloat($0), height: 600 - 12 * CGFloat($0)) }
            let tm = TreemapNSView(frame: start), oldTM = LegacyTreemapNSView(frame: start)
            let sb = SunburstNSView(frame: start), oldSB = LegacySunburstNSView(frame: start)
            tm.model = model; oldTM.model = model; sb.model = model; oldSB.model = model
            let (tmBitmap, sbBitmap) = (tm.bitmap, sb.bitmap)
            for view in [tm, oldTM, sb, oldSB] as [NSView] { view.viewWillStartLiveResize() }
            for size in sizes {
                for view in [tm, oldTM, sb, oldSB] as [NSView] { view.setFrameSize(size); view.layout() }
                expect(tm.bitmap === tmBitmap && sb.bitmap === sbBitmap, "\(kind): a drag frame rendered")
                expect(oldTM.bitmap !== tmBitmap, "\(kind): the baseline should render every frame")
                // Mid-drag draws show the stretched bitmap; they must not trap.
                let context = canvas(size)
                paint(tm, [CGRect(origin: .zero, size: size)], into: context)
                paint(sb, [CGRect(origin: .zero, size: size)], into: context)
                frames += 1
            }
            for view in [tm, oldTM, sb, oldSB] as [NSView] { view.viewDidEndLiveResize() }
            expect(tm.bitmap !== tmBitmap && sb.bitmap !== sbBitmap, "\(kind): the drag's end did not render")
            samePixels(tm.bitmap, oldTM.bitmap, "treemap live resize \(kind)")
            samePixels(sb.bitmap, oldSB.bitmap, "sunburst live resize \(kind)")
            // A drag that changes nothing leaves the picture alone.
            let rendered = tm.bitmap
            tm.viewWillStartLiveResize(); tm.viewDidEndLiveResize()
            expect(tm.bitmap === rendered, "\(kind): an empty drag re-rendered")
            // Zooming mid-drag renders at once; the layout must not go stale.
            if let child = model.tree!.children(0).first(where: { model.tree!.isDir(Int($0)) }) {
                tm.viewWillStartLiveResize(); sb.viewWillStartLiveResize()
                model.viewRoot = Int(child)
                tm.relayoutIfNeeded(); sb.relayoutIfNeeded()
                expect(tm.bitmap !== rendered, "\(kind): a zoom mid-drag waited")
                tm.viewDidEndLiveResize(); sb.viewDidEndLiveResize()
            }
        }
        return frames
    }

    static func verifyInteraction() {
        let redraw = verifySunburstRedraw()
        print("PASS: \(redraw.events) sunburst hover/selection events redraw the same pixels as a full draw "
              + String(format: "(redrawn per event: mean %.0f%%, largest %.0f%% of the view)", redraw.mean * 100, redraw.largest * 100))
        print("PASS: \(verifyLiveResize()) drag frames render nothing; the end renders once to the baseline's pixels")
    }

    /// Min and median of nine alternating pairs; the raw samples follow.
    static func measureMin(_ label: String, before: () -> Void, after: () -> Void) {
        var a: [Double] = [], b: [Double] = []
        for i in 0..<9 {
            if i % 2 == 0 { a.append(ms(before)); b.append(ms(after)) }
            else { b.append(ms(after)); a.append(ms(before)) }
        }
        let (oldMin, newMin) = (a.min()!, b.min()!)
        print(String(format: "%@,min %.3f,%.3f,%.2fx,median %.3f,%.3f,%.2fx", label, oldMin, newMin, oldMin / newMin,
                     a.sorted()[4], b.sorted()[4], a.sorted()[4] / b.sorted()[4]))
        print("samples,\(label),baseline,\(a.map { String(format: "%.3f", $0) }.joined(separator: ","))")
        print("samples,\(label),optimized,\(b.map { String(format: "%.3f", $0) }.joined(separator: ","))")
    }

    static func measureInteraction() {
        print("workload,baseline_ms,optimized_ms,speedup (min of 9 interleaved pairs, then medians)")
        // BZ_KINDS=deep runs one fixture; a loaded machine may not let one process run all three.
        let kinds = (ProcessInfo.processInfo.environment["BZ_KINDS"] ?? "balanced,flat,deep").split(separator: ",").map(String.init)
        for kind in kinds {
            let model = ScanModel(); model.tree = Tree(kind: kind)
            model.showFreeSpace = true; model.freeBytes = model.tree!.alloc[0] / 3
            // Hover: 60 pointer steps on a 1440x900 pt (2880x1800 px) view.
            let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
            let sb = SunburstNSView(frame: frame), oldSB = LegacySunburstNSView(frame: frame)
            sb.model = model; oldSB.model = model
            let path = hoverPath(frame, steps: 60)
            let (canvasNew, canvasOld) = (canvas(frame.size), canvas(frame.size))
            paint(sb, [frame], into: canvasNew); paint(oldSB, [frame], into: canvasOld)
            // Where the time goes: the hover logic alone, and the repaint alone.
            measureMin("sunburst_hover_logic_\(kind)_60_steps",
                       before: { for p in path { oldSB.updateHover(at: p) } },
                       after: { for p in path { sb.updateHover(at: p) } })
            let dirtyPerStep = path.map { sb.updateHover(at: $0) }
            measureMin("sunburst_repaint_\(kind)_60_steps",
                       before: { for _ in path { paint(oldSB, [frame], into: canvasOld) } },
                       after: { for dirty in dirtyPerStep { paint(sb, dirty, into: canvasNew) } })
            measureMin("sunburst_hover_\(kind)_60_steps",
                       before: { for p in path { oldSB.updateHover(at: p); paint(oldSB, [frame], into: canvasOld) } },
                       after: { for p in path { paint(sb, sb.updateHover(at: p), into: canvasNew) } })
            // Drag: 24 frames from 1440x900 down to 960x540 pt; the first layout at
            // full size is part of both. The baseline lays out and draws every
            // frame. The candidate lays out (which only notes the size) and, the
            // views asking to redraw only on request, AppKit calls no `draw` until
            // the end of the drag: Core Animation scales the layer meanwhile,
            // which an offscreen run cannot show, so it is not counted.
            let sizes = (1...24).map { CGSize(width: 1440 - 20 * CGFloat($0), height: 900 - 15 * CGFloat($0)) }
            let tm = TreemapNSView(frame: frame), oldTM = LegacyTreemapNSView(frame: frame)
            let ring = SunburstNSView(frame: frame), oldRing = LegacySunburstNSView(frame: frame)
            tm.model = model; oldTM.model = model; ring.model = model; oldRing.model = model
            func drag(_ view: NSView, drawsEachFrame: Bool) {
                view.setFrameSize(frame.size); view.layout()
                view.viewWillStartLiveResize()
                for size in sizes {
                    view.setFrameSize(size); view.layout()
                    if drawsEachFrame { paint(view, [CGRect(origin: .zero, size: size)], into: canvas(size)) }
                }
                view.viewDidEndLiveResize()
                if !drawsEachFrame { paint(view, [view.bounds], into: canvas(view.bounds.size)) }
            }
            measureMin("treemap_drag_\(kind)_24_frames",
                       before: { drag(oldTM, drawsEachFrame: true) }, after: { drag(tm, drawsEachFrame: false) })
            measureMin("sunburst_drag_\(kind)_24_frames",
                       before: { drag(oldRing, drawsEachFrame: true) }, after: { drag(ring, drawsEachFrame: false) })
        }
    }
}
