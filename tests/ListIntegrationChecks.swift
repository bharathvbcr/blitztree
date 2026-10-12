import AppKit
import Foundation

/// The directory list: sortable columns, the Files column, and several rows
/// selected at once for the right-click menu and Move to Trash.
@main
struct ListIntegrationChecks {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        guard let physical = realpath(fm.temporaryDirectory.path, nil) else { fatalError("cannot resolve temporary directory") }
        let fixture = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("blitztree-list-\(UUID().uuidString)")
        free(physical)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("scan_root").path
        @discardableResult
        func file(_ relative: String, bytes: Int) throws -> String {
            let path = root + "/" + relative
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: bytes).write(to: URL(fileURLWithPath: path))
            return path
        }
        try file("a.txt", bytes: 50_000)
        try file("B9.txt", bytes: 300_000)
        try file("b10.txt", bytes: 100_000)
        try file("Folder1/f1.bin", bytes: 10_000)
        try file("Folder1/f10.bin", bytes: 12_000)
        try file("Folder1/f2.bin", bytes: 14_000)
        try file("Folder1/inner/deep.bin", bytes: 200_000)
        try file("folder2/one.bin", bytes: 500_000)
        try file("Émile/x.bin", bytes: 1_000)
        try file("Émile/y.bin", bytes: 1_000)

        func scan() async throws -> Tree {
            guard let handle = bz_scan_start(root) else { fatalError("fixture scan failed") }
            var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0, done: Int32 = 0
            while done == 0 {
                bz_progress(handle, &files, &dirs, &bytes, &done)
                if done == 0 { try await Task.sleep(for: .milliseconds(5)) }
            }
            guard let tree = Tree(handle: handle) else { bz_free(handle); fatalError("fixture tree failed") }
            return tree
        }
        let tree = try await scan()
        func node(_ relative: String) -> Int { tree.node(at: root + "/" + relative)! }
        let finder: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }

        // Name keys order like Finder's comparator, the oracle here.
        let tricky = ["file10", "file9", "File2", "file1", "éclair", "eclair2", "Zed", "alpha", "Alpha 3",
                      "alpha 20", "IMG_0042.JPG", "img_42.jpg", "IMG_100.jpg", "café", "Cafe", "cafes", "x2y10", "x2y9", "10", "9"]
        let byKey = tricky.indices.sorted {
            let a = ListOrder.nameKey(tricky[$0]), b = ListOrder.nameKey(tricky[$1])
            return a != b ? a.lexicographicallyPrecedes(b) : $0 < $1
        }.map { tricky[$0] }
        precondition(byKey.map { ListOrder.nameKey($0) } == tricky.sorted(by: finder).map { ListOrder.nameKey($0) },
                     "name keys order like localizedStandardCompare: \(byKey) vs \(tricky.sorted(by: finder))")

        // A configured list in a window, as the app builds it.
        _ = NSApplication.shared
        let model = ScanModel()
        model.tree = tree
        model.scanRoot = root
        model.scanning = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let list = OutlinePanel.OutlineView(frame: window.contentLayoutRect)
        OutlinePanel.configure(list)
        window.contentView = list
        let coord = OutlinePanel.Coordinator()
        coord.model = model
        coord.outline = list
        list.coordinator = coord
        list.dataSource = coord
        list.delegate = coord
        coord.rebuildIfNeeded()
        window.displayIfNeeded()

        precondition(list.allowsMultipleSelection, "list allows several rows selected")
        precondition(list.tableColumns.map(\.identifier.rawValue) == ["name", "size", "pct", "files"], "Name, Size, %, Files columns")
        precondition(list.tableColumns.map { $0.sortDescriptorPrototype.map { "\($0.key!) \($0.ascending)" } }
                        == ["name true", "size false", nil, "files false"],
                     "Name sorts A–Z first, Size and Files largest first, % doesn't sort")
        precondition(list.tableColumns[3].title == "Files")
        precondition(coord.order == .engine && list.sortDescriptors == [ListOrder.engine.descriptor],
                     "size descending is the default, shown in the header")
        precondition(coord.roots.map(\.id) == tree.children(0).map(Int.init), "default order is the engine's")
        let indicated = list.tableColumns.filter { list.indicatorImage(in: $0) != nil }.map(\.identifier.rawValue)
        precondition(indicated == ["size"], "the header marks Size as the sorted column: \(indicated)")
        func rowNames() -> [String] { (0..<list.numberOfRows).map { tree.name((list.item(atRow: $0) as! OutlinePanel.Item).id) } }
        func row(_ relative: String) -> Int {
            list.row(forItem: coord.roots.first { $0.id == node(relative) } ?? { fatalError("no row \(relative)") }())
        }
        func cell(_ column: String, _ relative: String) -> String {
            let c = list.column(withIdentifier: .init(column))
            return (list.view(atColumn: c, row: row(relative), makeIfNecessary: true) as! NSTableCellView).textField!.stringValue
        }

        // Files column: a folder's file count, all the way down; nothing for a file.
        precondition(cell("files", "Folder1") == "4", "Folder1 holds 4 files, got \(cell("files", "Folder1"))")
        precondition(cell("files", "Émile") == "2" && cell("files", "folder2") == "1")
        precondition(cell("files", "a.txt") == "", "files show no count")

        // Open a folder and select two rows; sorting keeps both.
        let folder1 = coord.roots.first { $0.id == node("Folder1") }!
        list.expandItem(folder1)
        let innerRow = list.item((list.row(forItem: folder1) + 1)..<list.numberOfRows, named: "inner", in: tree)
        list.expandItem(innerRow)
        list.selectRowIndexes(IndexSet([row("a.txt"), row("folder2"), list.row(forItem: innerRow)]), byExtendingSelection: false)
        let picked = Set([node("a.txt"), node("folder2"), node("Folder1/inner")])
        precondition(Set(coord.selectedNodes) == picked)

        let names = ["a.txt", "B9.txt", "b10.txt", "Folder1", "folder2", "Émile"]
        list.sortDescriptors = [ListOrder(key: .name, ascending: true).descriptor]
        precondition(coord.order == ListOrder(key: .name, ascending: true))
        precondition(list.tableColumns.filter { list.indicatorImage(in: $0) != nil }.map(\.identifier.rawValue) == ["name"],
                     "the header follows the click")
        precondition(coord.roots.map { tree.name($0.id) } == names.sorted(by: finder), "Name A–Z: \(coord.roots.map { tree.name($0.id) })")
        precondition(list.isItemExpanded(folder1) && list.isItemExpanded(innerRow), "open folders stay open across a sort")
        precondition(rowNames() == ["a.txt", "B9.txt", "b10.txt", "Émile", "Folder1", "f1.bin", "f2.bin", "f10.bin", "inner", "deep.bin", "folder2"],
                     "open folder's rows sort too: \(rowNames())")
        precondition(Set(coord.selectedNodes) == picked, "selection follows its rows across a sort")

        list.sortDescriptors = [ListOrder(key: .name, ascending: false).descriptor]
        precondition(coord.roots.map { tree.name($0.id) } == names.sorted(by: finder).reversed(), "Name Z–A")

        list.sortDescriptors = [ListOrder(key: .files, ascending: false).descriptor]
        precondition(coord.roots.map { tree.name($0.id) } == ["Folder1", "Émile", "folder2", "B9.txt", "b10.txt", "a.txt"],
                     "Files: most first, files after folders by size: \(coord.roots.map { tree.name($0.id) })")
        list.sortDescriptors = [ListOrder(key: .files, ascending: true).descriptor]
        precondition(coord.roots.map { tree.name($0.id) } == ["B9.txt", "b10.txt", "a.txt", "folder2", "Émile", "Folder1"],
                     "Files fewest first, ties by size: \(coord.roots.map { tree.name($0.id) })")

        list.sortDescriptors = [ListOrder(key: .size, ascending: true).descriptor]
        precondition(coord.roots.map(\.id) == tree.children(0).reversed().map(Int.init), "Size smallest first")
        list.sortDescriptors = [ListOrder.engine.descriptor]
        precondition(coord.order == .engine && coord.roots.map(\.id) == tree.children(0).map(Int.init), "back to the default")
        precondition(Set(coord.selectedNodes) == picked && list.isItemExpanded(folder1) && list.isItemExpanded(innerRow))

        // A rescan while sorted by name lists the new tree in that order.
        list.collapseItem(innerRow)
        list.collapseItem(folder1)
        list.sortDescriptors = [ListOrder(key: .name, ascending: true).descriptor]
        try file("aa-new.txt", bytes: 1_000)
        let rescanned = try await scan()
        model.tree = rescanned
        coord.rebuildIfNeeded()
        precondition(coord.roots.map { rescanned.name($0.id) } == (names + ["aa-new.txt"]).sorted(by: finder),
                     "rescan keeps the name order: \(coord.roots.map { rescanned.name($0.id) })")
        precondition(coord.roots.allSatisfy { $0.tree === rescanned })
        model.tree = tree
        coord.rebuildIfNeeded()
        list.sortDescriptors = [ListOrder.engine.descriptor]

        // A map click on a node already among the selected rows keeps them all.
        list.selectRowIndexes(IndexSet([row("a.txt"), row("folder2"), row("B9.txt")]), byExtendingSelection: false)
        model.selection = node("folder2")
        coord.syncSelection()
        precondition(list.selectedRowIndexes.count == 3, "syncSelection kept the multi-selection")
        model.selection = node("Émile")
        coord.syncSelection()
        precondition(coord.selectedNodes == [node("Émile")], "a map click elsewhere selects just that row")

        // Right-click inside the selection acts on all of it.
        list.selectRowIndexes(IndexSet([row("a.txt"), row("B9.txt")]), byExtendingSelection: false)
        func rightClick(_ r: Int) -> NSMenu? {
            let rect = list.rect(ofRow: r)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: list.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
                                           modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 1, clickCount: 1, pressure: 1)!
            return list.menu(for: event)
        }
        let filesMenu = rightClick(row("a.txt"))!
        precondition(Set(coord.selectedNodes) == [node("a.txt"), node("B9.txt")], "right-click inside the selection keeps it")
        func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? { menu.items.first { $0.title == title } }
        precondition(item(filesMenu, "Open")?.isEnabled == true, "several files: Open")
        precondition(item(filesMenu, "Move to Trash")?.isEnabled == true)
        precondition(item(filesMenu, NodeMenu.askTitle(model))?.isEnabled == false, "Ask takes one item")
        let copy = item(filesMenu, "Copy Path")!
        _ = (copy.target as AnyObject).perform(copy.action, with: copy)
        let expectedCopy = coord.selectedNodes.map(tree.displayPath).joined(separator: "\n")
        precondition(NSPasteboard.general.string(forType: .string) == expectedCopy, "Copy Path copies every selected path")
        NSPasteboard.general.clearContents()
        list.copySelection(nil)
        precondition(NSPasteboard.general.string(forType: .string) == expectedCopy, "⌘C copies every selected path")

        list.selectRowIndexes(IndexSet([row("a.txt"), row("Folder1")]), byExtendingSelection: false)
        let mixedMenu = rightClick(row("Folder1"))!
        precondition(item(mixedMenu, "Zoom In")?.isEnabled == false, "Zoom In takes one folder")
        precondition(item(mixedMenu, "Open") == nil)

        _ = rightClick(row("folder2"))
        precondition(coord.selectedNodes == [node("folder2")], "right-click outside the selection replaces it")
        let oneMenu = rightClick(row("folder2"))!
        precondition(item(oneMenu, "Zoom In")?.isEnabled == true, "one folder: Zoom In as before")

        // Trash: one confirmation with the count and total size; a folder's
        // selected contents go with it rather than separately.
        let inner = node("Folder1/inner")
        let targets = NodeMenu.trashTargets([node("Folder1"), inner, node("a.txt"), node("a.txt")], in: tree)
        precondition(targets.map(\.path) == [tree.path(node("Folder1")), tree.path(node("a.txt"))], "nested and repeated nodes dropped")
        let total = tree.alloc[node("Folder1")] + tree.alloc[node("a.txt")]
        let alert = NodeMenu.trashAlert(targets)
        precondition(alert.messageText == "Move 2 items to Trash?", alert.messageText)
        precondition(alert.informativeText.hasPrefix("\(Fmt.size(total)) in total\n"), alert.informativeText)
        precondition(targets.allSatisfy { alert.informativeText.contains($0.displayPath) })
        let single = NodeMenu.trashAlert([targets[1]])
        precondition(single.messageText == "Move “a.txt” to Trash?" && single.informativeText == targets[1].displayPath,
                     "one item keeps its own wording")
        let many = (0..<10).map { NodeMenu.TrashTarget(path: "/tmp/item\($0)", bytes: 1) }
        let manyAlert = NodeMenu.trashAlert(many)
        precondition(manyAlert.informativeText.hasSuffix("/tmp/item7\nand 2 more"), manyAlert.informativeText)

        let bin = fixture.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        var moved: [String] = []
        func moveToBin(_ url: URL) throws {
            moved.append(url.path)
            try fm.moveItem(at: url, to: bin.appendingPathComponent(UUID().uuidString))
        }
        var reported: NSAlert?
        var asked: NSAlert?
        NodeMenu.moveToTrash(nodes: [node("Folder1"), inner, node("a.txt")], model: model,
                             confirm: { asked = $0; return .alertSecondButtonReturn }, move: moveToBin, report: { reported = $0 })
        precondition(asked?.messageText == "Move 2 items to Trash?" && moved.isEmpty && model.tree === tree,
                     "Cancel moves nothing")

        let trashModel = ScanModel()
        trashModel.tree = tree
        trashModel.scanRoot = root
        let rootBefore = tree.alloc[0], filesBefore = tree.nFiles[0], countBefore = tree.count
        let folder2Before = tree.alloc[node("folder2")]
        trashModel.viewRoot = node("folder2")
        trashModel.selection = node("folder2/one.bin")
        NodeMenu.moveToTrash(nodes: [node("Folder1"), inner, node("a.txt")], model: trashModel,
                             confirm: { _ in .alertFirstButtonReturn }, move: moveToBin, report: { reported = $0 })
        precondition(moved == [tree.path(node("Folder1")), tree.path(node("a.txt"))], "each target moved once: \(moved)")
        precondition(!fm.fileExists(atPath: root + "/Folder1") && !fm.fileExists(atPath: root + "/a.txt"))
        precondition(reported == nil, "nothing to report")
        await trashModel.settled()
        // No rescan: a new tree without the moved items, the old one untouched.
        let after = trashModel.tree!
        precondition(!trashModel.scanning && after !== tree, "the tree is replaced, not rescanned")
        precondition(after.node(at: root + "/Folder1") == nil && after.node(at: root + "/Folder1/inner/deep.bin") == nil
                     && after.node(at: root + "/a.txt") == nil, "moved items are gone from the new tree")
        precondition(after.node(at: root + "/B9.txt") != nil && after.node(at: root + "/folder2/one.bin") != nil, "the rest stays")
        let freed = tree.alloc[node("Folder1")] + tree.alloc[node("a.txt")]
        precondition(freed > 0 && after.alloc[0] == rootBefore - freed, "ancestors drop by the allocated bytes")
        // Folder1 holds 4 files and 2 folders (itself and inner); plus a.txt.
        precondition(after.nFiles[0] == filesBefore - 5 && after.count == countBefore - 7, "file and node counts drop")
        precondition(tree.alloc[0] == rootBefore && tree.node(at: root + "/Folder1") != nil && tree.count == countBefore,
                     "the tree handed out earlier is never edited in place")
        precondition(trashModel.viewRoot == after.node(at: root + "/folder2")! && trashModel.selection == after.node(at: root + "/folder2/one.bin"),
                     "zoom and selection follow their folders to the new numbering")
        precondition(after.alloc[after.node(at: root + "/folder2")!] == folder2Before, "untouched folders keep their size")
        NodeMenu.moveToTrash(nodes: [0, node("b10.txt")], model: model, confirm: { _ in fatalError("the scan root never goes to the Trash") })

        // Failures are reported together, after moving what could be moved.
        struct Refused: LocalizedError { var errorDescription: String? { "refused" } }
        moved = []
        let failingModel = ScanModel()
        failingModel.tree = tree
        failingModel.scanRoot = root
        failingModel.viewRoot = node("folder2")
        NodeMenu.moveToTrash(nodes: [node("B9.txt"), node("b10.txt"), node("folder2")], model: failingModel,
                             confirm: { _ in .alertFirstButtonReturn },
                             move: { url in if url.lastPathComponent != "folder2" { throw Refused() }; try moveToBin(url) },
                             report: { reported = $0 })
        await failingModel.settled()
        precondition(moved == [tree.path(node("folder2"))], "what could move moved")
        let partial = failingModel.tree!
        precondition(!failingModel.scanning && partial !== tree && partial.node(at: root + "/folder2") == nil
                     && partial.node(at: root + "/B9.txt") != nil && partial.node(at: root + "/b10.txt") != nil,
                     "only what moved leaves the map; what failed stays")
        precondition(failingModel.viewRoot == 0, "a zoomed folder that went falls back to the nearest one left")
        precondition(reported?.messageText == "Couldn’t move 2 items to the Trash", reported?.messageText ?? "no report")
        precondition(reported!.informativeText.contains("\(tree.displayPath(node("B9.txt"))): refused"), reported!.informativeText)
        reported = nil
        NodeMenu.moveToTrash(nodes: [node("Émile")], model: model, confirm: { _ in .alertFirstButtonReturn },
                             move: { _ in throw Refused() }, report: { reported = $0 })
        precondition(reported?.messageText == "Couldn’t move “Émile” to the Trash" && reported?.informativeText == "refused",
                     "one failure keeps its own wording")
        precondition(model.tree === tree, "no rescan when nothing moved")

        // A removal renumbers the nodes. Nothing computed from the old tree
        // (search hits, Clean Up's list, the map's layout) may be read against
        // the new one: an old number names another item, or none at all.
        let staleModel = ScanModel()
        staleModel.tree = tree
        staleModel.scanRoot = root
        staleModel.searchQuery = ".bin"
        for _ in 0..<400 where staleModel.isSearching || staleModel.searchResults.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(staleModel.searchResults.contains(node("folder2/one.bin")), "the search lists the fixture's .bin files")
        let folder2Path = tree.path(node("folder2"))
        staleModel.cleanup = [CleanupItem(node: node("folder2"), path: folder2Path, display: "folder2",
                                          kind: "test", bytes: tree.alloc[node("folder2")], verify: "")]
        let mapFrame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let map = TreemapNSView(frame: mapFrame)
        map.model = staleModel
        // A point over the largest file, and one over something else.
        let grid = stride(from: 5.0, to: 400.0, by: 10.0).flatMap { x in
            stride(from: 5.0, to: 300.0, by: 10.0).map { CGPoint(x: x, y: $0) }
        }
        func hovered(_ view: TreemapNSView, _ m: ScanModel, at p: CGPoint) -> Int? { view.hover(at: p); return m.hovered }
        guard let probe = grid.first(where: { hovered(map, staleModel, at: $0) == node("folder2/one.bin") }),
              let elsewhere = grid.first(where: { hovered(map, staleModel, at: $0).map { $0 != node("folder2/one.bin") } ?? false })
        else { fatalError("no map point over folder2/one.bin and another item") }

        let generationBefore = staleModel.treeGeneration
        staleModel.forget(paths: [root + "/Folder1"])
        await staleModel.settled()
        let renumbered = staleModel.tree!
        precondition(renumbered !== tree && renumbered.node(at: root + "/Folder1") == nil, "Folder1 left the tree")
        precondition(staleModel.treeGeneration != generationBefore, "views see the swap by generation, not by address")
        precondition(staleModel.searchResults.allSatisfy { $0 < renumbered.count && renumbered.name($0).hasSuffix(".bin") },
                     "search hits name .bin files of the new tree, never old numbers")
        precondition(staleModel.cleanup.allSatisfy { $0.node < renumbered.count && renumbered.path($0.node) == $0.path },
                     "Clean Up's items name their own folders in the new tree")
        // Clean Up's picks are paths: a pick made before the renumbering
        // still means that folder, never the item now holding its old number.
        // Picked as node N; after the swap N names another movable folder.
        let emile = root + "/Émile", other = root + "/other"
        try fm.createDirectory(atPath: other, withIntermediateDirectories: true)
        let pickedAs = node("Émile")
        let relisted = [CleanupItem(node: pickedAs, path: other, display: "other", kind: "test", bytes: 1, root: root, verify: ""),
                        CleanupItem(node: renumbered.count, path: emile, display: "Émile", kind: "test", bytes: 1, root: root, verify: "")]
        precondition(relisted.allSatisfy { $0.target != nil }, "both folders can be moved: \(relisted.compactMap(\.blocked))")
        precondition(Cleanup.picked([emile], in: relisted).map(\.path) == [emile],
                     "the pick is the folder chosen, not whatever holds its old number")
        // The map hit-tests the tree on screen, not the layout it drew for
        // the old one: the same answer as a map built for the new tree.
        let freshModel = ScanModel()
        freshModel.tree = renumbered
        let freshMap = TreemapNSView(frame: mapFrame)
        freshMap.model = freshModel
        _ = hovered(map, staleModel, at: elsewhere)
        let got = hovered(map, staleModel, at: probe)
        let expected = hovered(freshMap, freshModel, at: probe)
        func describe(_ n: Int?) -> String { n.map { $0 < renumbered.count ? renumbered.path($0) : "node \($0) of \(renumbered.count)" } ?? "nothing" }
        precondition(got == expected, "hover after a removal: \(describe(got)) vs \(describe(expected))")
        precondition(map.toolTip == expected.map { "\(renumbered.displayPath($0))\n\(Fmt.size(renumbered.alloc[$0]))" },
                     "the tooltip describes the item under the pointer")
        // The list's rows belong to the tree it was built from: a right-click
        // before it rebuilds selects nothing in the new one.
        model.tree = renumbered
        let staleMenu = rightClick(row("folder2"))
        precondition(staleMenu == nil && model.selection == nil, "no old row number becomes the selection: \(String(describing: model.selection))")

        // A Move to Trash while a rescan is under way: the walk may already
        // have listed the item, so the tree it delivers must still drop it.
        let raceRoot = fixture.appendingPathComponent("race").path
        try fm.createDirectory(atPath: raceRoot + "/gone", withIntermediateDirectories: true)
        try Data(repeating: 1, count: 40_000).write(to: URL(fileURLWithPath: raceRoot + "/gone/f.bin"))
        try Data(repeating: 2, count: 4_000).write(to: URL(fileURLWithPath: raceRoot + "/keep.bin"))
        let raceModel = ScanModel()
        raceModel.startScan(path: raceRoot)
        // Block the main thread so the walk finishes before the first poll:
        // the scan has seen "gone" but not handed its tree over yet.
        usleep(500_000)
        try moveToBin(URL(fileURLWithPath: raceRoot + "/gone"))
        raceModel.forget(paths: [raceRoot + "/gone"])
        let deadline = Date().addingTimeInterval(20)
        // The model polls the scan from a run-loop timer whose tick queues a
        // main-actor task: run the loop, then yield so that task runs.
        while raceModel.scanning && Date() < deadline {
            runLoop(for: 0.01)
            try await Task.sleep(for: .milliseconds(1))
        }
        precondition(!raceModel.scanning, "the fixture scan finished")
        await raceModel.settled()
        precondition(raceModel.files == 2, "the walk listed the trashed file before it went (counted \(raceModel.files))")
        let landed = raceModel.tree!
        precondition(landed.node(at: raceRoot + "/gone") == nil && landed.node(at: raceRoot + "/keep.bin") != nil,
                     "an item trashed during the scan stays gone when the scan lands")
        precondition(landed.alloc[0] == landed.alloc[landed.node(at: raceRoot + "/keep.bin")!], "its bytes left the total")

        print("PASS: list sorting, Files column, multi-select menu and Trash")
    }

    /// Runs the main run loop (timers, main-queue work) for `seconds`.
    private static func runLoop(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

private extension NSOutlineView {
    func item(_ rows: Range<Int>, named name: String, in tree: Tree) -> OutlinePanel.Item {
        for r in rows {
            if let it = item(atRow: r) as? OutlinePanel.Item, tree.name(it.id) == name { return it }
        }
        fatalError("no row named \(name)")
    }
}
