import AppKit
import Foundation

/// The file-type list against a real engine scan: the engine's extension
/// keys must name the same files, in the same colours, as the treemap's
/// own reading of the names, and picking a type must light only its files.
@main
struct TypesIntegrationChecks {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        guard let physical = realpath(fm.temporaryDirectory.path, nil) else { fatalError("cannot resolve temporary directory") }
        let fixture = URL(fileURLWithPath: String(cString: physical))
            .appendingPathComponent("blitztree-types-\(UUID().uuidString)")
        free(physical)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }

        let root = fixture.appendingPathComponent("scan_root").path
        func file(_ relative: String, bytes: Int) throws {
            let path = root + "/" + relative
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: bytes).write(to: URL(fileURLWithPath: path))
        }
        try file("photos/a.JPG", bytes: 900_000)
        try file("photos/b.jpg", bytes: 700_000)
        try file("photos/c.png", bytes: 500_000)
        try file("photos/.zshrc", bytes: 40_000)
        try file("code/main.rs", bytes: 300_000)
        try file("code/Makefile", bytes: 60_000)
        try file("code/trailing.", bytes: 50_000)
        try file("code/notes.TXT", bytes: 200_000)
        try file("code/x.a_very_long_extension_name", bytes: 80_000)
        try file("code/café.PLIST", bytes: 120_000)
        try file("code/data.unknownext", bytes: 150_000)
        try file("big.mov", bytes: 1_200_000)

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

        // 1. Totals: largest first, adding up to the folder.
        let rows = tree.types(root: 0)
        precondition(rows.reduce(0) { $0 + $1.alloc } == tree.alloc[0], "rows add up to the root's bytes")
        precondition(rows.reduce(0) { $0 + $1.files } == UInt64(tree.nFiles[0]), "every file counted once")
        precondition(zip(rows, rows.dropFirst()).allSatisfy { $0.alloc >= $1.alloc }, "sorted by size")
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        precondition(byName["jpg"]?.files == 2, "JPG and jpg are one type")
        precondition(byName[""]?.files == 3, "Makefile, .zshrc and trailing. have no extension")
        precondition(byName["a_very_long_extension_name"]?.files == 1)
        precondition(byName["mov"]?.kind.name == String(localized: "Video"))
        precondition(byName["plist"]?.kind.name == String(localized: "Logs & caches"))
        precondition(byName["unknownext"]?.kind.name == String(localized: "Other"))

        // 2. One owner: every file the treemap paints carries the colour of
        // the row whose key the engine gave it, and matches exactly one row.
        var colors = TypeColor.Cache()
        for node in 1..<tree.count where !tree.isDir(node) {
            let matching = rows.filter { TypeColor.hasExtension(tree, node, $0.ext) }
            precondition(matching.count == 1, "\(tree.name(node)) matches \(matching.count) rows")
            let painted = colors.color(tree, node), listed = matching[0].kind.color
            precondition(painted == listed, "\(tree.name(node)): map \(painted) vs list \(listed)")
        }

        // 3. Scoped to the folder on screen, recomputed when it changes.
        let photos = tree.children(0).map(Int.init).first { tree.name($0) == "photos" }!
        let scoped = tree.types(root: photos)
        precondition(Set(scoped.map(\.name)) == ["jpg", "png", ""], "only the folder's own files")
        precondition(scoped.reduce(0) { $0 + $1.alloc } == tree.alloc[photos])

        let model = ScanModel()
        model.tree = tree
        model.showTypes = true
        func settle(_ root: Int) async throws {
            for _ in 0..<200 where model.typesRoot != root || model.typeRows.isEmpty {
                try await Task.sleep(for: .milliseconds(5))
            }
            precondition(model.typesRoot == root, "rows describe the folder on screen")
        }
        try await settle(0)
        precondition(model.typeRows.map(\.ext) == rows.map(\.ext))
        model.selectedType = Array("mov".utf8)
        model.viewRoot = photos
        try await settle(photos)
        precondition(model.typeRows.map(\.ext) == scoped.map(\.ext), "zooming re-totals")
        precondition(model.selectedType == nil, "a type the folder lacks is unpicked")
        model.selectedType = Array("jpg".utf8)
        precondition(model.highlightedType == Array("jpg".utf8))
        model.showTypes = false
        precondition(model.highlightedType == nil && model.typeRows.isEmpty, "hiding the list stops the highlight")

        // 4. The highlight: picked files keep their pixels, others dim.
        let (pw, ph) = (800, 500)
        func render(_ highlight: [UInt8]?) -> TreemapRenderer.Result {
            TreemapRenderer.render(tree: tree, pw: pw, ph: ph, scale: 1, root: 0, showFree: false, freeBytes: 0,
                                   highlight: highlight)
        }
        func pixel(_ r: TreemapRenderer.Result, _ node: Int) -> UInt32 {
            guard let leaf = r.leaves.first(where: { $0.node == node }) else { fatalError("\(tree.name(node)) not drawn") }
            let data = r.image.dataProvider!.data! as Data
            let (x, y) = (Int(leaf.rect.midX), Int(leaf.rect.midY))
            return data.withUnsafeBytes { $0.load(fromByteOffset: (y * pw + x) * 4, as: UInt32.self) }
        }
        func brightness(_ p: UInt32) -> UInt32 { (p & 0xFF) + (p >> 8 & 0xFF) + (p >> 16 & 0xFF) }
        let plain = render(nil), lit = render(Array("jpg".utf8))
        let fileNodes = (1..<tree.count).filter { !tree.isDir($0) }
        for node in fileNodes where plain.leaves.contains(where: { $0.node == node }) {
            if TypeColor.hasExtension(tree, node, Array("jpg".utf8)) {
                precondition(pixel(lit, node) == pixel(plain, node), "\(tree.name(node)) keeps its colour")
            } else {
                precondition(brightness(pixel(lit, node)) < brightness(pixel(plain, node)) / 2, "\(tree.name(node)) dims")
            }
        }
        let none = render([])
        for node in fileNodes where tree.name(node) == "Makefile" {
            precondition(pixel(none, node) == pixel(plain, node), "the no-extension row lights extensionless files")
        }

        print("PASS: TypesIntegrationChecks (totals, one colour owner, scoping, highlight)")
    }
}
