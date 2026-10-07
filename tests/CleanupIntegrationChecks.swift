import AppKit
import Foundation

@main
struct CleanupIntegrationChecks {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.path
        guard let physical = realpath(temporary, nil) else { fatalError("cannot resolve temporary directory") }
        let temporaryURL = URL(fileURLWithPath: String(cString: physical))
        free(physical)
        let fixture = temporaryURL
            .appendingPathComponent("blitztree-cleanup-\(UUID().uuidString)")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home").path
        func directory(_ relative: String) throws -> String {
            let path = home + "/" + relative
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        let cache = try directory(".cache/uv")
        let other = try directory(".cache/other")
        let secret = try directory(".ssh/node_modules")
        try Data(repeating: 1, count: 8192).write(to: URL(fileURLWithPath: cache + "/data"))
        // Over a focused question's 1 MB cutoff, so they get table rows.
        let asked = try directory("projects/big")
        let askedInside = try directory("projects/big/sub")
        let askedSibling = try directory("projects/sibling")
        let askedFile = askedInside + "/blob.bin"
        try Data(repeating: 2, count: 3_000_000).write(to: URL(fileURLWithPath: askedFile))
        try Data(repeating: 3, count: 3_000_000).write(to: URL(fileURLWithPath: askedSibling + "/blob.bin"))
        guard let handle = bz_scan_start(home) else { fatalError("fixture scan failed") }
        var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0, done: Int32 = 0
        while done == 0 {
            bz_progress(handle, &files, &dirs, &bytes, &done)
            if done == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        guard let tree = Tree(handle: handle) else { bz_free(handle); fatalError("fixture tree failed") }
        func spec(_ paths: [String], action: String = "trash", command: String = "") -> PlanItemSpec {
            PlanItemSpec(title: "Same title", detail: "Fixture", group: "safe", bytes: 999_999,
                         paths: paths, action: action, command: command)
        }
        func plan(_ value: PlanItemSpec) -> PlanItem { PlanItem(spec: value, tree: tree, home: home) }
        let valid = plan(spec([cache], action: "command", command: "uv cache clean"))
        precondition(valid.blocked == nil && valid.viaTrash && valid.paths == [cache])
        precondition(valid.bytes == tree.alloc[tree.node(at: cache)!], "use scanned bytes")
        let inferred = plan(spec([], action: "command", command: "uv cache clean"))
        precondition(inferred.paths == [cache] && inferred.blocked == nil)
        for value in [
            spec([other], action: "command", command: "uv cache clean"),
            spec([other], action: "command", command: "uv cache clean --all"),
            spec([secret]), spec([home]), spec([cache], action: "unknown"),
            spec([cache], command: "uv cache clean"),
        ] {
            let item = plan(value)
            precondition(item.blocked != nil && !item.selected && item.cleanupTargets.isEmpty)
        }
        let unscanned = try directory(".cache/created-after-scan")
        precondition(plan(spec([unscanned])).blocked != nil)
        let partial = plan(spec([secret, cache, cache + "/data", cache]))
        precondition(partial.paths == [cache] && partial.note != nil)
        precondition(partial.bytes == valid.bytes, "nested and duplicate targets counted once")
        precondition(plan(spec([], action: "command", command: "docker builder prune -f")).blocked != nil)
        let original = plan(spec([cache], action: "command", command: "docker builder prune -f"))
        precondition(original.blocked == nil && !original.selected && original.note != nil)
        for state in [PlanItem.Status.waiting, .running] {
            original.status = state
            precondition(original.pendingBytes == original.bytes, "running commands stay in the countdown")
        }
        original.status = .done
        precondition(original.pendingBytes == 0, "completed commands leave the countdown")
        original.status = .waiting
        valid.trashedBytes = valid.bytes / 2
        valid.status = .running
        precondition(valid.pendingBytes == valid.trashedBytes, "count only folders actually moved")
        valid.status = .failed("partial removal")
        precondition(valid.pendingBytes == valid.trashedBytes, "failed receipts remain visible")
        valid.trashedBytes = 0
        valid.status = .done
        precondition(valid.pendingBytes == 0)
        let simulatorID = "12345678-1234-1234-1234-123456789ABC"
        for command in ["xcrun simctl erase \(simulatorID)", "xcrun simctl runtime delete \(simulatorID)"] {
            let simulator = plan(spec([other], action: "command", command: command))
            precondition(simulator.blocked == nil && !simulator.selected && simulator.isCommand)
            precondition(simulator.cleanupTargets.isEmpty && simulator.bytes == tree.alloc[tree.node(at: other)!])
            precondition(plan(spec([unscanned], action: "command", command: command)).blocked != nil)
        }
        let changed = spec([], action: "command", command: "docker system prune -f --volumes")
        let final = PlanItem.reconcile([original.spec, changed], previous: [original], tree: tree)
        precondition(final[0] === original, "unchanged actions retain their captured identities")
        precondition(final[1].blocked != nil && !final[1].selected, "same title must not hide changed action")
        let newValid = spec([], action: "command", command: "docker builder prune -f")
        precondition(!PlanItem.reconcile([newValid], previous: [original], tree: tree)[0].selected)
        let invalidCommand = await AgentRun.runCommand("docker system prune -f --volumes", path: "/usr/bin")
        precondition(invalidCommand != nil, "execution must independently reject changed arguments")
        let relativeTool = await AgentRun.runCommand("docker builder prune -f", path: ".:relative:")
        precondition(relativeTool != nil, "relative executable lookup must be refused")

        // "Is this safe to clean?": a focused run keeps every card inside the
        // item asked about, and its prompt covers only that item.
        let uvNode = tree.node(at: cache)!, dataNode = tree.node(at: cache + "/data")!
        func scoped(_ value: PlanItemSpec, _ scope: Int) -> PlanItem {
            PlanItem(spec: value, tree: tree, home: home, scope: scope)
        }
        precondition(scoped(spec([cache]), uvNode).blocked == nil, "the item itself is in scope")
        precondition(scoped(spec([cache]), tree.node(at: home + "/.cache")!).blocked == nil, "inside the item is in scope")
        precondition(scoped(spec([cache + "/data"]), uvNode).blocked == nil)
        for (value, scope) in [(spec([other]), uvNode), (spec([cache, other]), uvNode),
                               (spec([cache], action: "command", command: "uv cache clean"), dataNode),
                               (spec([other], action: "command", command: "docker builder prune -f"), uvNode)] {
            let item = scoped(value, scope)
            precondition(item.blocked == "Outside the item you asked about" && !item.selected
                         && item.cleanupTargets.isEmpty, "a path or command past the item blocks the card")
        }
        precondition(scoped(spec([cache], action: "command", command: "uv cache clean"), uvNode).blocked == nil,
                     "the tool's own cache command fits when its folder is the item")
        let rescoped = PlanItem.reconcile([spec([other])], previous: [], tree: tree, scope: uvNode)
        precondition(rescoped[0].blocked != nil, "cards from the final plan are scoped too")

        let askedNode = tree.node(at: asked)!
        let focus = AgentFocus(node: askedNode, tree: tree, known: [], home: home)
        precondition(focus.path == asked && focus.name == "big" && focus.isDir && focus.local == nil)
        let focused = AgentPrompt.build(tree: tree, scanRoot: home, known: [], running: [], focus: focus)
        precondition(focused.contains("asked whether it is safe to clean: \(asked)"))
        precondition(focused.contains("| \(askedInside)/ |"), "the item's own subfolders are listed")
        precondition(!focused.contains(askedSibling), "an unrelated sibling stays out of the question")
        precondition(!focused.contains("BlitzTree's own check"), "no local check line when there is none")
        let fileFocus = AgentFocus(node: tree.node(at: askedFile)!, tree: tree, known: [], home: home)
        let filePrompt = AgentPrompt.build(tree: tree, scanRoot: home, known: [], running: [], focus: fileFocus)
        precondition(!fileFocus.isDir && filePrompt.contains("Answer about this file only")
                     && filePrompt.contains("## The file") && !filePrompt.contains("## Largest folders"))
        let whole = AgentPrompt.build(tree: tree, scanRoot: home, known: [], running: [])
        precondition(whole.contains("The user clicked \"Clean up\"") && !whole.contains("right-clicked"))
        let guarded = AgentFocus(node: tree.node(at: secret)!, tree: tree, known: [], home: home)
        precondition(guarded.local?.hasPrefix("BlitzTree won't remove this: ") == true,
                     "a protected item says so before any agent answers")
        let guardedPrompt = AgentPrompt.build(tree: tree, scanRoot: home, known: [], running: [], focus: guarded)
        precondition(guardedPrompt.contains("BlitzTree's own check: BlitzTree won't remove this"))
        precondition(AgentPrompt.relevant("/a/b", to: nil) && AgentPrompt.relevant("/a/b", to: "/a")
                     && AgentPrompt.relevant("/a/b", to: "/a/b/c") && AgentPrompt.relevant("/a/b", to: "/")
                     && !AgentPrompt.relevant("/a/b", to: "/a/bc") && !AgentPrompt.relevant("/a/b", to: "/x"))
        precondition(AgentPrompt.appData(tree: tree, focus: asked).isEmpty,
                     "simulator and Codex sections are skipped for an unrelated item")

        // Move only inside this disposable fixture: never use the user's Trash.
        let trash = fixture.appendingPathComponent("fake-trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        func stage(_ relative: String) throws -> CleanupReceipt {
            let path = try directory(relative)
            let target = try CleanupPathSafety.capture(path: path, root: home, home: home)
            return try CleanupOperations.trash(target) { source in
                let destination = trash.appendingPathComponent(UUID().uuidString)
                try fm.moveItem(at: source, to: destination)
                return destination
            }
        }
        let replacedPath = try directory(".cache/replaced")
        let stale = try CleanupPathSafety.capture(path: replacedPath, root: home, home: home)
        try fm.moveItem(atPath: replacedPath, toPath: replacedPath + "-old")
        _ = try directory(".cache/replaced")
        var movedStale = false
        do {
            _ = try CleanupOperations.trash(stale) { url in movedStale = true; return url }
            fatalError("replacement should fail validation")
        } catch { precondition(!movedStale) }

        let failed = try stage(".cache/partial")
        let good = try stage(".cache/success")
        for name in ["keep", "remove"] {
            try Data([1]).write(to: failed.url.appendingPathComponent(name))
        }
        let result = await CleanupOperations.remove([failed, good]) { path in
            if URL(fileURLWithPath: path).lastPathComponent == "keep" { return "injected removal failure" }
            do { try FileManager.default.removeItem(atPath: path); return nil }
            catch { return error.localizedDescription }
        }
        precondition(result.remaining.count == 1 && result.remaining[0].url == failed.url)
        precondition(!result.errors.isEmpty && fm.fileExists(atPath: failed.url.path + "/keep"))
        precondition(!fm.fileExists(atPath: good.url.path))
        let retry = await CleanupOperations.remove(result.remaining)
        precondition(retry.errors.isEmpty && retry.remaining.isEmpty && !fm.fileExists(atPath: failed.url.path))

        let linked = try stage(".cache/linked-child")
        let unrelated = fixture.appendingPathComponent("unrelated")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data([1]).write(to: unrelated.appendingPathComponent("keep"))
        try fm.createSymbolicLink(at: linked.url.appendingPathComponent("link"), withDestinationURL: unrelated)
        let unlinked = await CleanupOperations.remove([linked])
        precondition(unlinked.errors.isEmpty && fm.fileExists(atPath: unrelated.path + "/keep"),
                     "recursive removal must not follow a symlink child")

        let altered = try stage(".cache/altered")
        try fm.moveItem(at: altered.url, to: altered.url.appendingPathExtension("old"))
        try fm.createDirectory(at: altered.url, withIntermediateDirectories: true)
        let rejected = await CleanupOperations.remove([altered]) { _ in
            fatalError("a replaced Trash item must not reach the eraser")
        }
        precondition(rejected.remaining.count == 1 && !rejected.errors.isEmpty)
        let parent = try stage(".cache/parent")
        let movedTrash = trash.appendingPathExtension("old")
        try fm.moveItem(at: trash, to: movedTrash)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try fm.moveItem(at: movedTrash.appendingPathComponent(parent.url.lastPathComponent), to: parent.url)
        let changedParent = await CleanupOperations.remove([parent]) { _ in
            fatalError("a replaced Trash parent must not reach the eraser")
        }
        precondition(changedParent.remaining.count == 1 && !changedParent.errors.isEmpty)

        // A project Claude Code worked in lately counts as used, even when
        // nothing on disk was touched; its session logs are the evidence.
        let old = Date().addingTimeInterval(-5 * 86400)
        let project = try directory("work/app")
        let modules = try directory("work/app/node_modules")
        let sibling = try directory("work/app-other")
        for path in [modules, project] { try fm.setAttributes([.modificationDate: old], ofItemAtPath: path) }
        let claudeConfig = fixture.appendingPathComponent("claude-config")
        setenv("CLAUDE_CONFIG_DIR", claudeConfig.path, 1)
        defer { unsetenv("CLAUDE_CONFIG_DIR") }
        // Claude Code files a session under a folder named after the working
        // folder it started in; subagent and worktree sessions go under the
        // parent session's folder, which can be an ancestor of their cwd.
        func session(_ cwd: String, filedUnder started: String, modified: Date = Date()) throws {
            let encoded = String(String.UnicodeScalarView(started.unicodeScalars.map {
                CharacterSet.alphanumerics.contains($0) && $0.isASCII ? $0 : "-"
            }))
            let folder = claudeConfig.appendingPathComponent("projects/\(encoded)/\(UUID().uuidString)/subagents")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("\(UUID().uuidString).jsonl")
            try Data("{\"type\":\"user\",\"cwd\":\"\(cwd)\"}\n".utf8).write(to: file)
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }
        precondition(!CleanupGuard.recentlyUsed(modules), "no session: stale project is not in use")
        try session(sibling, filedUnder: sibling)
        try session(project, filedUnder: project, modified: old)
        try session(home + "/elsewhere", filedUnder: home)
        precondition(!CleanupGuard.recentlyUsed(modules), "sibling prefix, stale or unrelated session does not count")
        try session(project + "/src", filedUnder: project)
        precondition(CleanupGuard.recentlyUsed(modules), "Claude Code session inside the project counts as use")
        try fm.removeItem(at: claudeConfig)
        precondition(!CleanupGuard.recentlyUsed(modules))
        try session(project + "/.claude/worktrees/agent", filedUnder: home + "/work")
        precondition(CleanupGuard.recentlyUsed(modules), "a session filed under an ancestor folder counts as use")

        // [#9] Folder context menu & actions from directory list and treemap labels:
        // Test NodeMenu.fill, copyPath, trashItem, Scan.hit, and OutlineView.menu(for:)
        let model = ScanModel()
        model.tree = tree
        model.scanRoot = home

        // Directory node context menu
        let dirMenu = NSMenu()
        NodeMenu.fill(dirMenu, node: askedNode, model: model)
        let dirTitles = dirMenu.items.map(\.title)
        precondition(dirTitles.contains("Zoom In"), "directory menu has Zoom In")
        precondition(dirTitles.contains("Reveal in Finder"), "directory menu has Reveal in Finder")
        precondition(dirTitles.contains("Copy Path"), "directory menu has Copy Path")
        precondition(dirTitles.contains("Move to Trash"), "directory menu has Move to Trash")
        let trashItem = dirMenu.items.first(where: { $0.title == "Move to Trash" })!
        precondition(trashItem.isEnabled, "Move to Trash is enabled for directory")
        let copyItem = dirMenu.items.first(where: { $0.title == "Copy Path" })!
        precondition(copyItem.isEnabled, "Copy Path is enabled for directory")
        precondition(copyItem.keyEquivalent == "C" && copyItem.keyEquivalentModifierMask == [.command, .option], "Copy Path has ⌥⌘C shortcut")
        precondition(trashItem.keyEquivalent == "\u{08}" && trashItem.keyEquivalentModifierMask == [.command], "Move to Trash has ⌘⌫ shortcut")

        // Root node context menu: Move to Trash must be disabled
        let rootMenu = NSMenu()
        NodeMenu.fill(rootMenu, node: 0, model: model)
        let rootTrash = rootMenu.items.first(where: { $0.title == "Move to Trash" })!
        precondition(!rootTrash.isEnabled, "Move to Trash is disabled for scan root")

        // File node context menu: Open instead of Zoom In
        let fileNode = tree.node(at: askedFile)!
        let fileMenu = NSMenu()
        NodeMenu.fill(fileMenu, node: fileNode, model: model)
        let fileTitles = fileMenu.items.map(\.title)
        precondition(fileTitles.contains("Open"), "file menu has Open")
        precondition(!fileTitles.contains("Zoom In"), "file menu does not have Zoom In")
        precondition(fileTitles.contains("Copy Path"), "file menu has Copy Path")
        precondition(fileTitles.contains("Move to Trash"), "file menu has Move to Trash")

        // Copy path functionality
        NodeMenu.copyPath(asked)
        precondition(NSPasteboard.general.string(forType: .string) == asked, "NodeMenu.copyPath writes path to general pasteboard")

        // Trash folder with custom move handler and rescan
        let trashTarget = try directory("to-trash-folder")
        let trashTargetFile = trashTarget + "/file.txt"
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: trashTargetFile))
        var movedURL: URL?
        var movedDestination: URL?
        try NodeMenu.trashItem(at: trashTarget, model: model) { url in
            movedURL = url
            let dest = trash.appendingPathComponent("trashed-" + UUID().uuidString)
            try fm.moveItem(at: url, to: dest)
            movedDestination = dest
        }
        precondition(movedURL?.path == trashTarget, "NodeMenu.trashItem moves source URL")
        precondition(!fm.fileExists(atPath: trashTarget), "Folder was moved away from source")
        precondition(movedDestination != nil && fm.fileExists(atPath: movedDestination!.path), "Folder arrived in destination")

        // Whole-disk scan item check: /System/Volumes/Data prefix removal in menus & confirmation
        let wholeDiskRoot = "/System/Volumes/Data" + home
        if fm.fileExists(atPath: wholeDiskRoot) {
            guard let wdHandle = bz_scan_start(wholeDiskRoot) else { fatalError("whole-disk fixture scan failed") }
            var wdFiles: UInt64 = 0, wdDirs: UInt64 = 0, wdBytes: UInt64 = 0, wdDone: Int32 = 0
            while wdDone == 0 {
                bz_progress(wdHandle, &wdFiles, &wdDirs, &wdBytes, &wdDone)
                if wdDone == 0 { try await Task.sleep(for: .milliseconds(5)) }
            }
            guard let wdTree = Tree(handle: wdHandle) else { bz_free(wdHandle); fatalError("whole-disk tree failed") }
            let wdModel = ScanModel()
            wdModel.tree = wdTree
            wdModel.scanRoot = "/System/Volumes/Data"

            let wdNode = wdTree.node(at: "/System/Volumes/Data" + asked)!
            let wdPath = wdTree.path(wdNode)
            let wdDisplayPath = wdTree.displayPath(wdNode)
            precondition(wdPath.hasPrefix("/System/Volumes/Data"), "whole-disk path has /System/Volumes/Data prefix")
            precondition(!wdDisplayPath.hasPrefix("/System/Volumes/Data"), "displayPath strips /System/Volumes/Data prefix")
            precondition(wdDisplayPath == asked, "displayPath matches expected path")

            // Verify both point to the same physical file (same inode)
            let attr1 = try fm.attributesOfItem(atPath: wdPath)
            let attr2 = try fm.attributesOfItem(atPath: wdDisplayPath)
            precondition(attr1[.systemFileNumber] as? UInt == attr2[.systemFileNumber] as? UInt, "wdPath and wdDisplayPath point to the same inode")

            let wdMenu = NSMenu()
            NodeMenu.fill(wdMenu, node: wdNode, model: wdModel)
            let wdCopyItem = wdMenu.items.first(where: { $0.title == "Copy Path" })!
            _ = (wdCopyItem.target as AnyObject).perform(wdCopyItem.action, with: wdCopyItem)
            let copied = NSPasteboard.general.string(forType: .string)
            precondition(copied == wdDisplayPath, "Copy Path copies displayPath (\(wdDisplayPath)), not \(wdPath), got: \(copied ?? "nil")")

            // Trash confirmation shows tree.displayPath(node)
            let alertWithDisplay = NodeMenu.trashAlert(path: wdPath, displayPath: wdDisplayPath)
            precondition(alertWithDisplay.informativeText == wdDisplayPath, "trashAlert with displayPath shows displayPath")
            let alertFallback = NodeMenu.trashAlert(path: wdPath)
            precondition(alertFallback.informativeText == wdDisplayPath, "trashAlert without displayPath removes /System/Volumes/Data prefix")

            // Test file node under whole-disk scan: Open, Reveal, and Trash act on the same file
            let wdFileNode = wdTree.node(at: "/System/Volumes/Data" + askedFile)!
            let wdFilePath = wdTree.path(wdFileNode)
            let wdFileDisplayPath = wdTree.displayPath(wdFileNode)
            precondition(wdFilePath.hasPrefix("/System/Volumes/Data"), "file path has data prefix")
            precondition(!wdFileDisplayPath.hasPrefix("/System/Volumes/Data") && wdFileDisplayPath == askedFile, "file displayPath stripped prefix")
            let fileAttr1 = try fm.attributesOfItem(atPath: wdFilePath)
            let fileAttr2 = try fm.attributesOfItem(atPath: wdFileDisplayPath)
            precondition(fileAttr1[.systemFileNumber] as? UInt == fileAttr2[.systemFileNumber] as? UInt, "wdFilePath and wdFileDisplayPath point to the same inode")

            let wdFileMenu = NSMenu()
            NodeMenu.fill(wdFileMenu, node: wdFileNode, model: wdModel)

            let fileCopyItem = wdFileMenu.items.first(where: { $0.title == "Copy Path" })!
            _ = (fileCopyItem.target as AnyObject).perform(fileCopyItem.action, with: fileCopyItem)
            precondition(NSPasteboard.general.string(forType: .string) == wdFileDisplayPath, "Copy Path on file copies file displayPath")

            let openItem = wdFileMenu.items.first(where: { $0.title == "Open" })!
            precondition(openItem.action != nil, "Open item has action selector")
            let revealItem = wdFileMenu.items.first(where: { $0.title == "Reveal in Finder" })!
            precondition(revealItem.action != nil, "Reveal in Finder has action selector")
            let trashItem = wdFileMenu.items.first(where: { $0.title == "Move to Trash" })!
            precondition(trashItem.action != nil, "Move to Trash has action selector")

            // Disposable whole-disk trash target to verify trashItem removes the underlying file
            let wdTrashFolder = try directory("wd-trash-target")
            let wdTrashFilePath = "/System/Volumes/Data" + wdTrashFolder + "/trashable.bin"
            let wdTrashDisplayPath = wdTrashFolder + "/trashable.bin"
            try Data([4, 5, 6]).write(to: URL(fileURLWithPath: wdTrashDisplayPath))
            precondition(fm.fileExists(atPath: wdTrashFilePath) && fm.fileExists(atPath: wdTrashDisplayPath))
            let trashAttr1 = try fm.attributesOfItem(atPath: wdTrashFilePath)
            let trashAttr2 = try fm.attributesOfItem(atPath: wdTrashDisplayPath)
            precondition(trashAttr1[.systemFileNumber] as? UInt == trashAttr2[.systemFileNumber] as? UInt, "wdTrashFilePath and wdTrashDisplayPath point to the same inode")

            var confirmedText: String?
            NodeMenu.moveToTrash(path: wdTrashFilePath, displayPath: wdTrashDisplayPath, model: wdModel, confirm: { alert in
                confirmedText = alert.informativeText
                return .alertFirstButtonReturn
            }, move: { url in
                try fm.removeItem(at: url)
            })
            precondition(confirmedText == wdTrashDisplayPath, "Trash confirmation showed displayPath")
            precondition(!fm.fileExists(atPath: wdTrashFilePath), "Trashing via wdPath removed file at wdPath")
            precondition(!fm.fileExists(atPath: wdTrashDisplayPath), "Trashing via wdPath removed file at displayPath")
        }

        // Treemap label hit testing with Scan.hit
        let testStrip = CGRect(x: 10, y: 10, width: 200, height: 16)
        let testRegion = CGRect(x: 10, y: 10, width: 200, height: 300)
        let label = TMLabel(strip: testStrip, region: testRegion, node: askedNode, depth: 1, name: "big")
        let hits = Scan.hits([label])
        precondition(hits.count == 1 && hits[0].node == askedNode, "Scan.hits creates correct tuple")
        precondition(Scan.hit(hits, CGPoint(x: 50, y: 18), slop: 2) == askedNode, "Scan.hit hits inside strip")
        precondition(Scan.hit(hits, CGPoint(x: 50, y: 8), slop: 2) == askedNode, "Scan.hit hits within slop")
        precondition(Scan.hit(hits, CGPoint(x: 50, y: 5), slop: 2) == nil, "Scan.hit misses outside slop")

        // OutlineView contextual menu and row selection
        model.scanning = false
        model.tree = tree
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let coord = OutlinePanel.Coordinator()
        coord.model = model
        let outlineView = OutlinePanel.OutlineView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        window.contentView = outlineView
        outlineView.coordinator = coord
        coord.outline = outlineView
        let col = NSTableColumn(identifier: .init("name"))
        col.width = 300
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col
        outlineView.dataSource = coord
        outlineView.delegate = coord
        outlineView.rowSizeStyle = .small
        OutlinePanel.configureRows(outlineView)
        let textHeight = ceil(NSFont.systemFont(ofSize: 13).boundingRectForFont.height)
        precondition(outlineView.rowSizeStyle == .custom && outlineView.rowHeight >= textHeight + 6,
                     "outline rows are taller than their text regardless of system row size: \(outlineView.rowHeight)")
        coord.rebuildIfNeeded()
        outlineView.reloadData()
        window.displayIfNeeded()
        precondition(coord.roots.count > 0, "coord has roots")
        precondition(outlineView.numberOfRows > 0, "outline view has rows: \(outlineView.numberOfRows)")
        let rowRect = outlineView.rect(ofRow: 0)
        let clickInView = NSPoint(x: rowRect.midX, y: rowRect.midY)
        let clickInWindow = outlineView.convert(clickInView, to: nil)
        let rightClickEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: clickInWindow, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let outlineMenu = outlineView.menu(for: rightClickEvent)
        precondition(outlineMenu != nil, "outlineView.menu(for:) returns menu")
        let outlineTitles = outlineMenu!.items.map(\.title)
        precondition(outlineTitles.contains("Copy Path"), "outline menu contains Copy Path")
        precondition(outlineTitles.contains("Move to Trash"), "outline menu contains Move to Trash")
        precondition(outlineView.selectedRow == 0, "right-clicking row selects it in outline view")

        // Localization checks:
        // 1. Acceptance Criterion 2: Guarded prompt stays English
        precondition(guarded.local?.hasPrefix("BlitzTree won't remove this: ") == true)
        precondition(guarded.localDisplay != nil)
        precondition(guardedPrompt.contains("BlitzTree's own check: BlitzTree won't remove this: "))
        let error = CleanupPathError.gitPath("/test/.git")
        precondition(error.englishDescription == "Git metadata path is protected: /test/.git")
        precondition(error.errorDescription != nil)

        // 2. Acceptance Criterion 3: All 7 translation tables contain all new keys
        let languages = ["en", "de", "es", "fr", "ja", "tr", "zh-Hans"]
        let requiredKeys: [String] = [
            /* Step lines */
            "Reading your scan",
            "Asking %@ what can go",
            "Asking %@ about %@",
            "Thinking",
            "Writing the plan",
            "Reading %@",
            "Measuring folders",
            "Measuring %@",
            "Looking around",
            "Looking in %@",
            "Checking Docker",
            "Checking Xcode simulators",
            "Checking Ollama models",
            "Checking %@",

            /* Guard block reasons */
            "Invalid cleanup path: %@",
            "Cannot inspect %@ (errno %d)",
            "Path is missing: %@",
            "Path component is not a directory: %@",
            "Symlinks are not allowed in cleanup paths: %@",
            "Cloud-only path is not available locally: %@",
            "Path is outside the authorized scan root: %@",
            "Path is on a different volume: %@",
            "Path changed since it was checked: %@",
            "Protected path: %@",
            "Path is too broad to clean: %@",
            "Git metadata path is protected: %@",

            /* Card block reasons */
            "Unknown cleanup action",
            "A Trash action cannot contain a command",
            "The supplied paths do not match this tool's cache",
            "Command or arguments not allowed",
            "Outside the item you asked about",
            "Nothing to remove",
            "Path is not an item in this scan",
            "The cache path is not a scanned directory",
            "Quit %@ to clean this",
            "A Codex chat you used in the last 2 days",
            "In a project used in the last 2 days",
            "A supplied path is not in this scan",
            "Runs the tool's cleanup, which may affect data outside the listed paths",
            "Leaves %lld path(s) unchanged: %@",
            "not eligible",

            /* Local check lines */
            "Recognised as %@, but BlitzTree won't remove it: %@",
            "Recognised by BlitzTree as %@",
            "Inside %@, recognised by BlitzTree as %@",
            "BlitzTree won't remove this: %@",

            /* Directory list: Files column, several items to the Trash */
            "Files",
            "Move %lld items to Trash?",
            "%@ in total",
            "and %lld more",
            "Couldn’t move %lld items to the Trash",
        ]

        for lang in languages {
            guard let bundle = Bundle(path: "app/\(lang).lproj") ?? Bundle.main.path(forResource: lang, ofType: "lproj").flatMap(Bundle.init(path:)) else {
                fatalError("Missing bundle for language: \(lang)")
            }
            for key in requiredKeys {
                let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
                precondition(!localized.isEmpty, "Empty translation for key '\(key)' in \(lang)")
                if lang != "en" {
                    precondition(localized != key, "Untranslated key '\(key)' in \(lang)")
                }
            }
        }

        // 3. Acceptance Criterion 1: Verify specific localized translations in non-English bundles
        let deBundle = Bundle(path: "app/de.lproj")!
        precondition(deBundle.localizedString(forKey: "Reading your scan", value: nil, table: nil) == "Ihr Scan wird gelesen")
        precondition(deBundle.localizedString(forKey: "Checking Docker", value: nil, table: nil) == "Docker prüfen")
        precondition(deBundle.localizedString(forKey: "Outside the item you asked about", value: nil, table: nil) == "Außerhalb des angefragten Elements")
        precondition(deBundle.localizedString(forKey: "Git metadata path is protected: %@", value: nil, table: nil) == "Git-Metadatenpfad ist geschützt: %@")

        let jaBundle = Bundle(path: "app/ja.lproj")!
        precondition(jaBundle.localizedString(forKey: "Writing the plan", value: nil, table: nil) == "プランを作成中")
        precondition(jaBundle.localizedString(forKey: "Thinking", value: nil, table: nil) == "思考中")
        precondition(jaBundle.localizedString(forKey: "Nothing to remove", value: nil, table: nil) == "削除する項目はありません")
        precondition(jaBundle.localizedString(forKey: "Checking Ollama models", value: nil, table: nil) == "Ollamaモデルを確認中")

        let frBundle = Bundle(path: "app/fr.lproj")!
        precondition(frBundle.localizedString(forKey: "Thinking", value: nil, table: nil) == "Réflexion")
        precondition(frBundle.localizedString(forKey: "Quit %@ to clean this", value: nil, table: nil) == "Quittez %@ pour nettoyer ceci")
        precondition(frBundle.localizedString(forKey: "Symlinks are not allowed in cleanup paths: %@", value: nil, table: nil) == "Les liens symboliques ne sont pas autorisés dans les chemins de nettoyage : %@")

        let esBundle = Bundle(path: "app/es.lproj")!
        precondition(esBundle.localizedString(forKey: "A Trash action cannot contain a command", value: nil, table: nil) == "Una acción de papelera no puede contener un comando")
        precondition(esBundle.localizedString(forKey: "Command or arguments not allowed", value: nil, table: nil) == "Comando o argumentos no permitidos")

        let trBundle = Bundle(path: "app/tr.lproj")!
        precondition(trBundle.localizedString(forKey: "Unknown cleanup action", value: nil, table: nil) == "Bilinmeyen temizleme eylemi")
        precondition(trBundle.localizedString(forKey: "Path is missing: %@", value: nil, table: nil) == "Yol eksik: %@")

        let zhBundle = Bundle(path: "app/zh-Hans.lproj")!
        precondition(zhBundle.localizedString(forKey: "Protected path: %@", value: nil, table: nil) == "受保护的路径：%@")
        precondition(zhBundle.localizedString(forKey: "Measuring folders", value: nil, table: nil) == "正在计算文件夹大小")

        // 4. Step line generator verification
        precondition(AgentStreamReader.describe(tool: "du", input: ["command": "du -sk /a /b"]) == "Measuring a, b")
        precondition(AgentStreamReader.describe(tool: "du", input: ["command": "du -sk"]) == "Measuring folders")
        precondition(AgentStreamReader.describe(tool: "ls", input: ["command": "ls"]) == "Looking around")
        precondition(AgentStreamReader.describe(tool: "ls", input: ["command": "ls /a/b"]) == "Looking in b")
        precondition(AgentStreamReader.describe(tool: "docker", input: ["command": "docker system df"]) == "Checking Docker")
        precondition(AgentStreamReader.describe(tool: "xcrun", input: ["command": "xcrun simctl list"]) == "Checking Xcode simulators")
        precondition(AgentStreamReader.describe(tool: "ollama", input: ["command": "ollama list"]) == "Checking Ollama models")
        precondition(AgentStreamReader.describe(tool: "Read", input: ["file_path": "/a/b/foo.txt"]) == "Reading foo.txt")

        // Auto-analyse suggestions & LaunchTarget options
        UserDefaults.standard.removeObject(forKey: "bz.launchTarget")
        UserDefaults.standard.removeObject(forKey: "bz.autoAnalyze")
        let launchModel = ScanModel()
        precondition(launchModel.launchTarget == .macintoshHD, "default launch target is Macintosh HD")
        precondition(!launchModel.autoAnalyze, "autoAnalyze is false by default")

        launchModel.launchTarget = .home
        precondition(UserDefaults.standard.string(forKey: "bz.launchTarget") == "home")
        precondition(launchModel.launchTarget == .home)

        launchModel.launchTarget = .prompt
        precondition(UserDefaults.standard.string(forKey: "bz.launchTarget") == "prompt")
        precondition(launchModel.launchTarget == .prompt)

        launchModel.autoAnalyze = true
        precondition(UserDefaults.standard.bool(forKey: "bz.autoAnalyze") == true)
        precondition(launchModel.autoAnalyze == true)

        // When autoAnalyze is false: launch scan does not start an agent
        let testModelFalse = ScanModel()
        testModelFalse.autoAnalyze = false
        testModelFalse.tree = tree
        testModelFalse.agentEnv = AgentEnvironment(agents: [InstalledAgent(kind: .claude, path: "/fake/claude", signedIn: true)], loaded: true)
        testModelFalse.openPanelAfterLaunchScan()
        precondition(testModelFalse.agentRun == nil, "autoAnalyze=false must not start agent run")
        precondition(testModelFalse.panelRequests == 1, "autoAnalyze=false opens panel")

        // When autoAnalyze is true: launch scan automatically starts cleanup with ready agent
        let testModelTrue = ScanModel()
        testModelTrue.autoAnalyze = true
        testModelTrue.tree = tree
        testModelTrue.agentEnv = AgentEnvironment(agents: [InstalledAgent(kind: .claude, path: "/fake/claude", signedIn: true)], loaded: true)
        testModelTrue.openPanelAfterLaunchScan()
        precondition(testModelTrue.agentRun != nil, "autoAnalyze=true must start agent run automatically")

        // Ask about an item while a run is already active: the panel must be
        // requested again (the agentRun-nil observer would not fire).
        let requestsBeforeAsk = testModelTrue.panelRequests
        testModelTrue.ask(about: 1)
        precondition(testModelTrue.panelRequests == requestsBeforeAsk + 1, "ask(about:) requests the panel even when agentRun is already set")

        // When autoAnalyze is true but no agent/provider ready: gracefully opens panel without crash
        let testModelNoAgent = ScanModel()
        testModelNoAgent.autoAnalyze = true
        testModelNoAgent.tree = tree
        testModelNoAgent.agentEnv = AgentEnvironment(agents: [], loaded: true)
        testModelNoAgent.openPanelAfterLaunchScan()
        precondition(testModelNoAgent.agentRun == nil, "no agent available means no agent run")
        precondition(testModelNoAgent.panelRequests == 1, "falls back to opening panel on setup offer")

        // Clean up UserDefaults after test
        UserDefaults.standard.removeObject(forKey: "bz.launchTarget")
        UserDefaults.standard.removeObject(forKey: "bz.autoAnalyze")

        print("PASS: scanned plans, final action changes, guarded moves, receipt identity and partial removal")
        print("PASS: [#9] folder trashing, copy path, treemap label hits and directory outline context menu")
        print("PASS: translation tables, English prompt safety, and step/guard localization")
        print("PASS: launch target and auto-analyse suggestions")
    }
}
