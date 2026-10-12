import AppKit
import Foundation

/// The geometry behind the two maps, against properties rather than
/// snapshots: the squarified treemap (areas follow sizes, tiles never
/// overlap or leave their folder, the same input lays out the same way, no
/// pixel is left unpainted) and the rings (angles follow sizes and nest in
/// their parent, thin arcs are gathered into one "smaller items" arc).
/// Squarify and the leaf index run on seeded random input; the renderer and
/// the rings run on a real engine scan of a disposable folder.

nonisolated struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Overlap of two rectangles in each axis; positive in both means they share area.
func overlap(_ a: CGRect, _ b: CGRect) -> (dx: Double, dy: Double) {
    (Double(min(a.maxX, b.maxX) - max(a.minX, b.minX)), Double(min(a.maxY, b.maxY) - max(a.minY, b.minY)))
}

func inside(_ inner: CGRect, _ outer: CGRect, slack: Double = 1e-6) -> Bool {
    Double(inner.minX - outer.minX) >= -slack && Double(inner.minY - outer.minY) >= -slack
        && Double(outer.maxX - inner.maxX) >= -slack && Double(outer.maxY - inner.maxY) >= -slack
}

@main
struct LayoutChecks {
    // MARK: Squarify on random input

    static func squarifyProperties() {
        var rng = SplitMix(state: 0xB17_7EE)
        var covered = 0, dropped = 0
        for trial in 0..<800 {
            let small = trial % 3 == 0
            let rect = CGRect(x: Double.random(in: 0...500, using: &rng), y: Double.random(in: 0...500, using: &rng),
                              width: Double.random(in: 8...(small ? 300 : 3000), using: &rng),
                              height: Double.random(in: 8...(small ? 300 : 3000), using: &rng))
            let sizes = (0..<Int.random(in: 1...80, using: &rng)).map { _ -> Double in
                switch trial % 4 {
                case 0: return Double.random(in: 1...100, using: &rng)
                case 1: return exp(Double.random(in: 0...14, using: &rng))
                case 2: return 7
                default: return pow(10, Double.random(in: 0...8, using: &rng))
                }
            }.sorted(by: >)
            let items = sizes.enumerated().map { (node: $0.offset, size: $0.element) }
            var out: [Squarify.Placed] = []
            let fully = Squarify.layoutItems(items, rect: rect, into: &out)
            let label = "trial \(trial) rect \(rect) n=\(items.count)"

            // Laid out in order, from the largest; only a tail is ever dropped.
            precondition(out.map(\.node) == Array(0..<out.count), "\(label): placed nodes are a prefix in input order")
            dropped += items.count - out.count
            let scale = Double(rect.width * rect.height) / sizes.reduce(0, +)
            var again: [Squarify.Placed] = []
            _ = Squarify.layoutItems(items, rect: rect, into: &again)
            precondition(again.map(\.node) == out.map(\.node) && again.map(\.rect) == out.map(\.rect),
                         "\(label): the same input lays out the same way")
            for (node, r) in out {
                let expected = sizes[node] * scale, area = Double(r.width * r.height)
                precondition(abs(area - expected) <= 1e-6 * max(expected, 1), "\(label): node \(node) area \(area) vs \(expected)")
                precondition(inside(r, rect, slack: 1e-6 * Double(max(rect.width, rect.height))), "\(label): \(r) leaves \(rect)")
                precondition(r.width > 0 && r.height > 0, "\(label): empty tile")
            }
            for i in out.indices {
                for j in out.indices where j > i {
                    let o = overlap(out[i].rect, out[j].rect)
                    precondition(!(o.dx > 1e-6 && o.dy > 1e-6), "\(label): tiles \(i) and \(j) overlap by \(o)")
                }
            }
            // Equal sizes keep their input order (the sort upstream is stable).
            if trial % 4 == 2, out.count > 1 {
                let areas = out.map { Double($0.rect.width * $0.rect.height) }
                precondition(areas.allSatisfy { abs($0 - areas[0]) <= 1e-6 * areas[0] }, "\(label): equal sizes, equal areas")
            }

            // "Fully covered" is a promise the renderer relies on to skip the
            // parent's cushion: every pixel of the rounded rectangle must lie in a
            // tile that survives the half-pixel cutoff.
            if fully {
                covered += 1
                let x0 = Int(rect.minX.rounded()), x1 = Int(rect.maxX.rounded())
                let y0 = Int(rect.minY.rounded()), y1 = Int(rect.maxY.rounded())
                if x1 > x0, y1 > y0, rect.width <= 300, rect.height <= 300 {
                    var painted = [Bool](repeating: false, count: (x1 - x0) * (y1 - y0))
                    for (_, r) in out where r.width >= 0.5 && r.height >= 0.5 {
                        for y in max(y0, Int(r.minY.rounded()))..<min(y1, Int(r.maxY.rounded())) {
                            for x in max(x0, Int(r.minX.rounded()))..<min(x1, Int(r.maxX.rounded())) {
                                painted[(y - y0) * (x1 - x0) + (x - x0)] = true
                            }
                        }
                    }
                    precondition(!painted.contains(false), "\(label): reported fully covered but a pixel is bare")
                }
            }
        }
        precondition(covered > 100, "the coverage promise was exercised: \(covered) of 800 trials reported it")
        precondition(dropped > 0, "the tail-dropping path was exercised")

        // Fixed shapes.
        var out: [Squarify.Placed] = []
        let square = CGRect(x: 0, y: 0, width: 100, height: 100)
        precondition(!Squarify.layoutItems([], rect: square, into: &out) && out.isEmpty, "nothing to lay out")
        precondition(!Squarify.layoutItems([(0, 0), (1, 0)], rect: square, into: &out) && out.isEmpty, "zero sizes lay out nothing")
        precondition(Squarify.layoutItems([(5, 9)], rect: square, into: &out) && out.count == 1
                     && out[0].node == 5 && out[0].rect == square, "one item fills the rectangle")
        out.removeAll()
        precondition(Squarify.layoutItems([(0, 1), (1, 1), (2, 1), (3, 1)], rect: square, into: &out), "four equal tiles cover the square")
        precondition(out.allSatisfy { $0.rect.width == 50 && $0.rect.height == 50 }, "four equal tiles are 50 by 50: \(out)")
        out.removeAll()
        // A tile of a few thousandths of a pixel is dropped; the pixels are still all painted.
        precondition(Squarify.layoutItems([(0, 1e6), (1, 1e6), (2, 1)], rect: square, into: &out), "an invisible tail leaves no bare pixel")
        precondition(out.map(\.node) == [0, 1], "the invisible tile is dropped, the large ones kept: \(out)")
        out.removeAll()
        // Two thousand tiles of under a pixel each: rounding to pixels leaves gaps, so the parent keeps its cushion.
        precondition(!Squarify.layoutItems((0..<2000).map { (node: $0, size: 1.0) }, rect: CGRect(x: 0, y: 0, width: 30, height: 30), into: &out),
                     "sub-pixel tiles are not full coverage")
        out.removeAll()
        precondition(!Squarify.layoutItems([(0, 1000), (1, 1)], rect: CGRect(x: 0, y: 0, width: 300, height: 0.7), into: &out) && out.isEmpty,
                     "a strip thinner than a pixel is not laid out and not covered")
        out.removeAll()
        _ = Squarify.layoutItems([(0, 1)], rect: CGRect(x: 3, y: 3, width: 0.4, height: 0.4), into: &out)
        precondition(out.isEmpty, "a rectangle under a pixel holds no tiles")
        print("PASS: Squarify (800 random layouts: proportional, disjoint, contained, ordered, deterministic; \(covered) fully covered)")
    }

    // MARK: Leaf index

    static func leafIndexAgreesWithLinearSearch() {
        var rng = SplitMix(state: 0x1EAF)
        let size = CGSize(width: 800, height: 600)
        // Overlapping rectangles too: the later one in draw order must win.
        let leaves = (0..<400).map { i -> TMRect in
            TMRect(rect: CGRect(x: Double.random(in: -50...800, using: &rng), y: Double.random(in: -50...600, using: &rng),
                                width: Double.random(in: 0.5...90, using: &rng), height: Double.random(in: 0.5...90, using: &rng)),
                   node: i, isDir: false)
        }
        let index = TMLeafIndex(leaves: leaves, size: size)
        var hits = 0
        var points = (0..<4000).map { _ in
            CGPoint(x: Double.random(in: -20...820, using: &rng), y: Double.random(in: -20...620, using: &rng))
        }
        // Cell edges (32 pt) and the outer edges are where an off-by-one hides.
        for x in stride(from: 0.0, through: 800, by: 32) { for y in stride(from: 0.0, through: 600, by: 32) { points.append(CGPoint(x: x, y: y)) } }
        for p in points {
            let expected = leaves.last { $0.rect.contains(p) }
            let actual = index.hit(p, leaves: leaves)
            precondition(expected?.node == actual?.node, "\(p): index \(String(describing: actual?.node)) vs search \(String(describing: expected?.node))")
            if expected != nil { hits += 1 }
        }
        precondition(hits > 500, "enough points land on a leaf: \(hits)")
        precondition(index.hit(CGPoint(x: CGFloat.nan, y: 5), leaves: leaves) == nil, "a NaN point hits nothing")
        precondition(TMLeafIndex().hit(CGPoint(x: 1, y: 1), leaves: []) == nil, "an empty index hits nothing")
        precondition(TMLeafIndex(leaves: leaves, size: .zero).hit(CGPoint(x: 1, y: 1), leaves: leaves) == nil, "a zero-size view has no cells")
        print("PASS: TMLeafIndex agrees with a linear search (\(points.count) points, \(hits) hits, last drawn wins)")
    }

    // MARK: A real scan

    static func makeTree(root: String, seed: UInt64) async throws -> Tree {
        let fm = FileManager.default
        var rng = SplitMix(state: seed)
        func file(_ relative: String, bytes: Int) throws {
            let path = root + "/" + relative
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: bytes).write(to: URL(fileURLWithPath: path))
        }
        for d in 0..<6 {
            for sub in 0..<(2 + d % 3) {
                for f in 0..<Int.random(in: 4...30, using: &rng) {
                    // Log-uniform from 1 KB to 3 MB, so sizes span several orders of magnitude.
                    let bytes = Int(1000 * pow(3000, Double.random(in: 0...1, using: &rng)))
                    try file("d\(d)/s\(sub)/f\(f).bin", bytes: bytes)
                }
            }
        }
        // One chain of folders holding almost everything, as a build output does.
        try file("chain/inner/payload.dat", bytes: 4_000_000)
        try file("chain/inner/more.dat", bytes: 3_000_000)
        // Hundreds of tiny files next to two large ones: the rings must gather them.
        for i in 0..<300 { try file("crowd/tiny\(i).txt", bytes: 1) }
        try file("crowd/big1.bin", bytes: 8_000_000)
        try file("crowd/big2.bin", bytes: 6_000_000)
        try fm.createDirectory(atPath: root + "/empty", withIntermediateDirectories: true)

        guard let handle = bz_scan_start(root) else { fatalError("fixture scan failed") }
        var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0, done: Int32 = 0
        while done == 0 {
            bz_progress(handle, &files, &dirs, &bytes, &done)
            if done == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        guard let tree = Tree(handle: handle) else {
            bz_free(handle)
            fatalError("fixture tree failed")
        }
        return tree
    }

    /// The engine hands every folder its children largest first; both maps depend on it.
    static func childrenAreSortedLargestFirst(_ tree: Tree) {
        var items: [Squarify.Item] = []
        for dir in 0..<tree.count where tree.isDir(dir) {
            let kids = tree.children(dir).map { tree.alloc[Int($0)] }
            precondition(zip(kids, kids.dropFirst()).allSatisfy { $0 >= $1 }, "\(tree.name(dir)): children not largest first")
            Squarify.items(tree: tree, dir: dir, into: &items)
            precondition(items.map { UInt64($0.size) } == kids.filter { $0 > 0 }, "\(tree.name(dir)): empty children are not laid out")
        }
    }

    static func verifyRender(_ tree: Tree, pw: Int, ph: Int, scale: CGFloat, free: UInt64) {
        let label = "\(pw)x\(ph)@\(scale) free \(free)"
        let result = TreemapRenderer.render(tree: tree, pw: pw, ph: ph, scale: scale, root: 0, showFree: free > 0, freeBytes: free)
        precondition(result.image.width == pw && result.image.height == ph, "\(label): image size")
        let view = CGRect(x: 0, y: 0, width: Double(pw) / Double(scale), height: Double(ph) / Double(scale))
        var rectOf: [Int: CGRect] = [:]
        for d in result.rects { rectOf[d.node] = d.rect }
        precondition(rectOf[0] == view, "\(label): the root fills the view")
        precondition(result.leaves.allSatisfy { !tree.isDir($0.node) && !$0.isDir }, "\(label): leaves are files")
        precondition(result.rects.allSatisfy { tree.isDir($0.node) && $0.isDir }, "\(label): rects are folders")

        // Items are laid out per folder by one Squarify call: inside it, area is
        // proportional to size, and the tiles are disjoint and inside the folder.
        func container(_ node: Int) -> Int {
            var parent = Int(tree.parents[node])
            while rectOf[parent] == nil && parent != 0 { parent = Int(tree.parents[parent]) }
            return parent
        }
        var groups: [Int: [(node: Int, rect: CGRect)]] = [:]
        for t in result.leaves + result.rects where t.node != 0 { groups[container(t.node), default: []].append((t.node, t.rect)) }
        for (parent, tiles) in groups {
            let name = tree.name(parent)
            let parentRect = rectOf[parent] ?? view
            let ratio = Double(tiles[0].rect.width * tiles[0].rect.height) / Double(tree.alloc[tiles[0].node])
            for t in tiles {
                precondition(inside(t.rect, parentRect), "\(label): \(tree.name(t.node)) leaves \(name)")
                let r = Double(t.rect.width * t.rect.height) / Double(tree.alloc[t.node])
                precondition(abs(r - ratio) <= 1e-6 * ratio, "\(label): \(tree.name(t.node)) area/size \(r) vs siblings' \(ratio)")
            }
            for i in tiles.indices {
                for j in tiles.indices where j > i {
                    let o = overlap(tiles[i].rect, tiles[j].rect)
                    precondition(!(o.dx > 1e-6 && o.dy > 1e-6), "\(label): \(tree.name(tiles[i].node)) overlaps \(tree.name(tiles[j].node))")
                }
            }
        }
        for i in result.leaves.indices {
            for j in result.leaves.indices where j > i {
                let o = overlap(result.leaves[i].rect, result.leaves[j].rect)
                precondition(!(o.dx > 1e-6 && o.dy > 1e-6), "\(label): leaves overlap")
            }
        }
        if free > 0 {
            // The free-space tile competes for the root's area like a file.
            let top = groups[0] ?? []
            let sizes = top.reduce(0.0) { $0 + Double(tree.alloc[$1.node]) }
            let area = top.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
            let expected = Double(view.width * view.height) * sizes / (sizes + Double(free))
            precondition(abs(area - expected) <= 0.005 * expected, "\(label): items take \(area) of \(expected)")
        }
        for l in result.labels where l.node != -1 {
            precondition(inside(l.strip, l.region) && l.depth >= 1, "\(label): strip of \(l.name) outside its folder")
            precondition(result.rects.contains { $0.rect == l.region }, "\(label): label region of \(l.name) is not a drawn folder")
        }

        // Every pixel is painted: parents shade whatever their children leave bare.
        let data = result.image.dataProvider!.data! as Data
        let bare = data.withUnsafeBytes { raw in
            raw.bindMemory(to: UInt32.self).reduce(0) { $0 + ($1 == 0xFF16_1616 ? 1 : 0) }
        }
        precondition(bare == 0, "\(label): \(bare) pixels were never painted")

        // The index finds each tile at its centre.
        let index = TMLeafIndex(leaves: result.leaves, size: view.size)
        for leaf in result.leaves {
            let hit = index.hit(CGPoint(x: leaf.rect.midX, y: leaf.rect.midY), leaves: result.leaves)
            precondition(hit?.node == leaf.node, "\(label): hit-test at the centre of \(tree.name(leaf.node))")
        }

        let again = TreemapRenderer.render(tree: tree, pw: pw, ph: ph, scale: scale, root: 0, showFree: free > 0, freeBytes: free)
        precondition(again.leaves.map(\.rect) == result.leaves.map(\.rect) && again.rects.map(\.rect) == result.rects.map(\.rect)
                     && again.labels.map(\.strip) == result.labels.map(\.strip), "\(label): same layout twice")
        precondition((again.image.dataProvider!.data! as Data) == data, "\(label): same pixels twice")
    }

    // MARK: Rings

    static func verifyRings(_ tree: Tree, root: Int, outer: CGFloat, free: UInt64) -> (smaller: Int, deepest: Int) {
        let label = "outer \(outer) root \(tree.name(root)) free \(free)"
        let radii = SunburstNSView.ringRadii(outer: outer)
        let rings = radii.count - 1
        precondition((4...8).contains(rings), "\(label): \(rings) rings")
        precondition(abs(radii[0] - max(outer, 40) * 0.27) < 1e-9 && abs(radii[rings] - max(outer, 40)) < 1e-9, "\(label): radii span hole to outer: \(radii)")
        let widths = zip(radii, radii.dropFirst()).map { $1 - $0 }
        precondition(widths.allSatisfy { $0 > 0 } && zip(widths, widths.dropFirst()).allSatisfy { abs($1 / $0 - 0.87) < 1e-9 }, "\(label): rings taper by 0.87")

        let segments = SunburstNSView.layout(tree: tree, root: root, radii: radii, freeBytes: free)
        let again = SunburstNSView.layout(tree: tree, root: root, radii: radii, freeBytes: free)
        precondition(segments.map { [Double($0.node), Double($0.ring), $0.start, $0.end, Double($0.bytes), Double($0.count)] }
                     == again.map { [Double($0.node), Double($0.ring), $0.start, $0.end, Double($0.bytes), Double($0.count)] },
                     "\(label): same segments twice")
        let minAngle = (0..<rings).map { max(0.003, 2 / Double(radii[$0])) }
        let full = 2 * Double.pi, eps = 1e-9

        for s in segments {
            precondition((0..<rings).contains(s.ring) && s.start >= -eps && s.end <= full + eps, "\(label): \(s) out of bounds")
            precondition(s.end - s.start >= minAngle[s.ring] - eps || s.node == -1, "\(label): arc thinner than the culling limit: \(s)")
            precondition(s.node >= 0 || s.node == -1 || s.node == -2, "\(label): node \(s.node)")
        }
        for ring in 0..<rings {
            let inRing = segments.filter { $0.ring == ring }
            precondition(zip(inRing, inRing.dropFirst()).allSatisfy { $0.end <= $1.start + eps }, "\(label): ring \(ring) arcs are ascending and disjoint")
        }

        // Children of one folder: contiguous from its start, sized by bytes,
        // a prefix of the folder's children, thin ones gathered into one arc.
        func check(parent: (node: Int, ring: Int, start: Double, end: Double)) -> (smaller: Int, deepest: Int) {
            let ring = parent.ring + 1
            let kids = tree.children(parent.node).map(Int.init)
            let inRange = segments.filter { $0.ring == ring && $0.start >= parent.start - eps && $0.end <= parent.end + eps }
            guard ring < rings else {
                precondition(inRange.isEmpty, "\(label): arcs beyond the last ring")
                return (0, parent.ring)
            }
            let shown = inRange.filter { $0.node >= 0 && tree.parents[$0.node] == UInt32(parent.node) }
            let gathered = inRange.filter { $0.node == -2 }
            precondition(shown.map(\.node) == Array(kids.prefix(shown.count)), "\(label): \(tree.name(parent.node)) shows its largest children in order")
            let total = Double(max(tree.alloc[parent.node], 1)), span = parent.end - parent.start
            var cursor = parent.start
            var deepest = ring
            var smaller = gathered.count
            for s in shown {
                precondition(abs(s.start - cursor) < 1e-9, "\(label): \(tree.name(s.node)) starts where the previous arc ended")
                precondition(abs((s.end - s.start) - span * Double(tree.alloc[s.node]) / total) < 1e-9, "\(label): \(tree.name(s.node)) angle follows its bytes")
                precondition(s.bytes == tree.alloc[s.node] && s.count == 1, "\(label): arc bytes")
                cursor = s.end
                if tree.isDir(s.node) {
                    let sub = check(parent: (s.node, ring, s.start, s.end))
                    smaller += sub.smaller
                    deepest = max(deepest, sub.deepest)
                } else {
                    precondition(!segments.contains { $0.ring == ring + 1 && $0.start >= s.start - eps && $0.end <= s.end + eps && $0.node >= 0 && tree.parents[$0.node] == UInt32(s.node) },
                                 "\(label): a file has no arcs inside it")
                }
            }
            precondition(cursor <= parent.end + eps, "\(label): children overrun \(tree.name(parent.node))")
            if shown.count < kids.count {
                // The first child left out was too thin for the ring.
                let next = span * Double(tree.alloc[kids[shown.count]]) / total
                precondition(next < minAngle[ring], "\(label): a drawable child was left out (\(next) >= \(minAngle[ring]))")
            }
            let rest = parent.end - cursor
            let needsGatherer = shown.count < kids.count && rest >= minAngle[ring]
            precondition(gathered.count == (needsGatherer ? 1 : 0), "\(label): smaller-items arc iff thin children and room (\(gathered.count), rest \(rest))")
            if let g = gathered.first {
                precondition(abs(g.start - cursor) < 1e-9 && abs(g.end - parent.end) < 1e-9, "\(label): smaller-items arc spans the rest")
                precondition(g.count == kids.count - shown.count && g.bytes == kids[shown.count...].reduce(0) { $0 + tree.alloc[$1] },
                             "\(label): smaller-items arc counts what it gathers")
            }
            return (smaller, deepest)
        }

        let used = Double(tree.alloc[root]), usedSpan = free > 0 ? full * used / (used + Double(free)) : full
        let result = check(parent: (root, -1, 0, usedSpan))
        if free > 0 {
            let arcs = segments.filter { $0.node == -1 }
            precondition(arcs.count == 1 && arcs[0].ring == 0 && arcs[0].bytes == free && abs(arcs[0].start - usedSpan) < 1e-9
                         && abs(arcs[0].end - full) < 1e-9, "\(label): free space closes the circle")
        } else {
            precondition(!segments.contains { $0.node == -1 }, "\(label): no free-space arc when none is shown")
        }
        return result
    }

    // MARK: Navigating the tree

    /// Paths, breadcrumbs and "what does the map draw for this node".
    static func navigation(_ tree: Tree) {
        let fm = FileManager.default
        for node in 0..<tree.count {
            let chain = tree.ancestry(node)
            precondition(chain.first == 0 && chain.last == node, "ancestry of \(node) runs root to node: \(chain)")
            precondition(zip(chain, chain.dropFirst()).allSatisfy { Int(tree.parents[$1]) == $0 }, "each ancestor is the parent of the next")
            let path = tree.path(node)
            precondition(path == tree.name(0) + chain.dropFirst().map { "/" + tree.name($0) }.joined(), "path of \(node): \(path)")
            precondition(fm.fileExists(atPath: path), "\(path) names a real file")
        }

        // What the map draws for a node: itself, or a folder that is mostly it.
        let result = TreemapRenderer.render(tree: tree, pw: 1600, ph: 1000, scale: 1, root: 0, showFree: false, freeBytes: 0)
        let drawnSet = Set(result.rects.map(\.node) + result.leaves.map(\.node))
        let isDrawn: (Int) -> Bool = { drawnSet.contains($0) }
        var merged = 0, undrawn = 0
        for node in 1..<tree.count {
            let found = tree.drawn(node, isDrawn: isDrawn)
            if drawnSet.contains(node) {
                precondition(found == node, "a drawn node stands for itself")
                continue
            }
            undrawn += 1
            if let found {
                precondition(drawnSet.contains(found) && tree.ancestry(node).contains(found), "\(tree.path(node)) is shown as an ancestor")
                precondition(tree.alloc[found] <= 2 * tree.alloc[node], "...that is mostly it")
                let between = tree.ancestry(node).drop { $0 != found }.dropFirst().dropLast()
                precondition(between.allSatisfy { !drawnSet.contains($0) }, "...the nearest drawn one")
                merged += 1
            } else {
                // Only a much larger folder is drawn: pointing at it would mislead.
                let nearest = tree.ancestry(node).reversed().first { drawnSet.contains($0) }!
                precondition(tree.alloc[nearest] > 2 * tree.alloc[node], "\(tree.path(node)) is nowhere: its nearest drawn ancestor is only a little bigger")
            }
        }
        precondition(merged > 0 && undrawn > merged, "both outcomes were exercised: \(merged) merged, \(undrawn - merged) nowhere")
        let inner = (0..<tree.count).first { tree.name($0) == "inner" }!
        let chain = Int(tree.parents[inner])
        precondition(tree.name(chain) == "chain" && !drawnSet.contains(inner), "the pass-through folder is merged into its parent's box")
        precondition(tree.drawn(inner, isDrawn: isDrawn) == chain, "...so selecting it shows the box")

        // Paths shown to people: the Data volume's firmlink prefix is dropped, and only that prefix.
        precondition(Tree.displayPath("/System/Volumes/Data/Users/x") == "/Users/x")
        precondition(Tree.displayPath("/System/Volumes/Data") == "/" && Tree.displayPath("/System/Volumes/Data/") == "/")
        precondition(Tree.displayPath("/Users/x") == "/Users/x" && Tree.displayPath("/Volumes/Backup") == "/Volumes/Backup")
        precondition(Tree.displayPath("/System/Volumes/DataBackup/x") == "/System/Volumes/DataBackup/x", "a longer name sharing the prefix is not the Data volume")
        precondition(Tree.displayPath("/System/Volumes/Update/x") == "/System/Volumes/Update/x")
    }

    static func fixedSizes() {
        // Two decimals always, so a live counter keeps its width; units step at 1000.
        let cases: [(UInt64, String)] = [(1000, "KB"), (1_500, "KB"), (999_994, "KB"), (999_996, "MB"), (1_500_000, "MB"),
                                         (225_570_000_000, "GB"), (999_996_000_000, "TB"), (1_234_000_000_000_000, "PB")]
        for (bytes, unit) in cases {
            let text = Fmt.fixedSize(bytes)
            let parts = text.split(separator: " ").map(String.init)
            precondition(parts.count == 2 && parts[1] == unit, "\(bytes) -> \(text), expected unit \(unit)")
            let digits = parts[0].replacingOccurrences(of: ",", with: ".")
            precondition(digits.range(of: #"^\d{1,3}\.\d{2}$"#, options: .regularExpression) != nil, "\(bytes) -> \(text): two decimals")
            let scale = ["KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15][unit]!
            precondition(abs(Double(digits)! * scale - Double(bytes)) <= 0.006 * scale, "\(bytes) -> \(text) is the right size")
        }
        precondition(Fmt.fixedSize(0) == Fmt.size(0) && Fmt.fixedSize(999) == Fmt.size(999), "under 1 KB it is the plain size")
        var width = Set<Int>()
        for exponent in stride(from: 3.0, through: 14.9, by: 0.1) { width.insert(Fmt.fixedSize(UInt64(pow(10, exponent))).split(separator: " ")[0].count) }
        precondition(width.isSubset(of: [4, 5, 6]), "numbers stay 1.00 to 999.99 wide: \(width)")
    }

    @MainActor
    static func main() async throws {
        squarifyProperties()
        fixedSizes()
        leafIndexAgreesWithLinearSearch()

        let fm = FileManager.default
        guard let physical = realpath(fm.temporaryDirectory.path, nil) else { fatalError("cannot resolve temporary directory") }
        let fixture = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("blitztree-layout-\(UUID().uuidString)")
        free(physical)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let tree = try await makeTree(root: fixture.appendingPathComponent("scan_root").path, seed: 0xD15C)
        childrenAreSortedLargestFirst(tree)
        navigation(tree)
        print("PASS: Tree paths, breadcrumbs and drawn(); Fmt.fixedSize")

        for (pw, ph, scale) in [(800, 500, 1.0), (1600, 1000, 2.0), (301, 197, 1.0), (1200, 90, 2.0), (60, 40, 1.0)] {
            verifyRender(tree, pw: pw, ph: ph, scale: CGFloat(scale), free: 0)
        }
        verifyRender(tree, pw: 900, ph: 600, scale: 1, free: tree.alloc[0])
        verifyRender(tree, pw: 900, ph: 600, scale: 2, free: tree.alloc[0] / 20)
        print("PASS: TreemapRenderer on a real scan (\(tree.count) nodes: proportional, disjoint, contained, no bare pixels, hit-testable, deterministic)")

        var smaller = 0, deepest = 0
        let crowd = tree.children(0).map(Int.init).first { tree.name($0) == "crowd" }!
        for root in [0, crowd] {
            for outer in [CGFloat(30), 120, 300, 700] {
                for free in [UInt64(0), tree.alloc[root] / 3] {
                    let r = verifyRings(tree, root: root, outer: outer, free: free)
                    smaller += r.smaller
                    deepest = max(deepest, r.deepest)
                }
            }
        }
        precondition(smaller > 0, "the smaller-items arc was exercised")
        precondition(deepest >= 2, "nested rings were exercised")
        print("PASS: Sunburst rings (angles follow bytes, nest in their parent, thin arcs gathered: \(smaller) smaller-items arcs, \(deepest + 1) rings deep)")
    }
}
