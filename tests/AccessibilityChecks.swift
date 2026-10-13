import AppKit
import Foundation

/// VoiceOver on the maps, and error text in the user's language.
///
/// - The treemap and the rings are lists whose children say what is on
///   screen (name, size, share), press to zoom or select, and tell
///   assistive apps when the selection or the folder changes.
/// - Every error string the app shows is made with `String(localized:)`,
///   and every key added for that is in all seven tables.
///
/// To see the checks fail on the sources from before this change, build with
/// those sources: `-DPREFIX_CHECK` leaves out what needs the new types and
/// stops at the first section (the old views have no accessibility children);
/// `-DSKIP_VOICEOVER` runs only the text checks, with `BZ_APP_DIR` naming the
/// old `app` directory.
@main
struct AccessibilityChecks {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        guard let physical = realpath(fm.temporaryDirectory.path, nil) else { fatalError("cannot resolve temporary directory") }
        let fixture = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("blitztree-a11y-\(UUID().uuidString)")
        free(physical)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("scan_root").path
        func file(_ relative: String, bytes: Int) throws {
            let path = root + "/" + relative
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: bytes).write(to: URL(fileURLWithPath: path))
        }
        try file("big.bin", bytes: 600_000)
        try file("Movies/clip.mov", bytes: 400_000)
        try file("Movies/more/take.mov", bytes: 100_000)
        try file("notes.txt", bytes: 50_000)
        // A folder with more files than a list should read out.
        for i in 0..<250 { try file("wide/f\(i).bin", bytes: 1_000 + i) }

        guard let handle = bz_scan_start(root) else { fatalError("fixture scan failed") }
        var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0, done: Int32 = 0
        while done == 0 {
            bz_progress(handle, &files, &dirs, &bytes, &done)
            if done == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        guard let tree = Tree(handle: handle) else { bz_free(handle); fatalError("fixture tree failed") }
        func node(_ relative: String) -> Int { tree.node(at: root + "/" + relative)! }

        _ = NSApplication.shared
        let model = ScanModel()
        model.tree = tree
        model.scanRoot = root
        let frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        let treemap = TreemapNSView(frame: frame), rings = SunburstNSView(frame: frame)
        treemap.model = model
        rings.model = model

        func rows(_ view: NSView) -> [NSAccessibilityElement] {
            (view.accessibilityChildren() ?? []).map { $0 as! NSAccessibilityElement }
        }
        func row(_ view: NSView, _ name: String) -> NSAccessibilityElement? {
            rows(view).first { ($0.accessibilityLabel() ?? "").hasPrefix(name + ",") }
        }

        #if !SKIP_VOICEOVER
        // 1. Both maps are accessibility elements with a role, a label and one
        //    row per child of the folder shown, saying name and size.
        for (name, view) in [("treemap", treemap as NSView), ("rings", rings as NSView)] {
            precondition(view.isAccessibilityElement(), "\(name) is an accessibility element")
            precondition(view.accessibilityRole() == .list, "\(name) has a role")
            let children = rows(view)
            precondition(!children.isEmpty, "\(name) exposes no accessibility children: VoiceOver reads it as an empty group")
            for expected in ["big.bin", "Movies", "notes.txt"] {
                guard let child = row(view, expected) else { fatalError("\(name): no row for \(expected): \(children.map { $0.accessibilityLabel() ?? "nil" })") }
                let label = child.accessibilityLabel() ?? ""
                precondition(label.contains(Fmt.size(tree.alloc[node(expected)])), "\(name): '\(label)' says the size")
                precondition(label.contains("%"), "\(name): '\(label)' says the share")
                precondition(label.contains("scan_root"), "\(name): '\(label)' says what the share is of")
                precondition(child.accessibilityRole() == .button, "\(name): \(expected) can be pressed")
                let f = child.accessibilityFrame()
                precondition(f.width > 0 && f.height > 0, "\(name): \(expected) has a frame")
            }
            precondition(row(view, "Movies")?.accessibilityRoleDescription() == String(localized: "folder"), "\(name): a folder says so")
            precondition(row(view, "big.bin")?.accessibilityRoleDescription() == String(localized: "file"), "\(name): a file says so")
        }
        #if !PREFIX_CHECK
        let folder = model.rootDisplayName
        precondition(treemap.accessibilityLabel() == String(localized: "Treemap of \(folder)"), "treemap label: \(treemap.accessibilityLabel() ?? "nil")")
        precondition(rings.accessibilityLabel() == String(localized: "Rings of \(folder)"), "rings label: \(rings.accessibilityLabel() ?? "nil")")

        // 2. A folder with hundreds of files lists at most `maxItems`, and the
        //    rest as one row that counts them.
        let wide = node("wide")
        let wideCount = tree.children(wide).count
        precondition(wideCount > MapAccessibility.maxItems, "the fixture folder is wider than the list's cap")
        model.viewRoot = wide
        treemap.relayoutIfNeeded(); rings.relayoutIfNeeded()
        for (name, view) in [("treemap", treemap as NSView), ("rings", rings as NSView)] {
            let all = rows(view)
            let listed = all.filter { $0.accessibilityRoleDescription() == String(localized: "file") }
            precondition(listed.count <= MapAccessibility.maxItems, "\(name): \(listed.count) rows listed, the cap is \(MapAccessibility.maxItems)")
            let smaller = all.first { ($0.accessibilityLabel() ?? "").contains(Fmt.num(UInt64(wideCount - listed.count))) }
            precondition(listed.count + (wideCount - listed.count) == wideCount && (smaller != nil || listed.count == wideCount),
                         "\(name): \(listed.count) listed of \(wideCount) with the rest as one row; rows: \(all.count)")
            precondition(all.first?.accessibilityLabel()?.hasPrefix(String(localized: "Back to \(model.rootDisplayName)")) == true,
                         "\(name): a zoomed map starts with a way back")
        }
        model.viewRoot = 0
        treemap.relayoutIfNeeded(); rings.relayoutIfNeeded()

        // 3. What VoiceOver is told. AppKit drops notifications when nothing
        //    listens, so the checks read them where the maps post them.
        var posted: [(String, Any)] = []
        var announced: [String] = []
        let (post, announce, running) = (MapAccessibility.post, MapAccessibility.announce, MapAccessibility.voiceOverRunning)
        defer { (MapAccessibility.post, MapAccessibility.announce, MapAccessibility.voiceOverRunning) = (post, announce, running) }
        MapAccessibility.post = { element, notification in posted.append((notification.rawValue, element)) }
        MapAccessibility.announce = { _, text in announced.append(text) }
        MapAccessibility.voiceOverRunning = { true }

        for (name, view) in [("treemap", treemap as NSView), ("rings", rings as NSView)] {
            model.selection = nil
            if let t = view as? TreemapNSView { t.syncOverlay() } else if let r = view as? SunburstNSView { r.syncOverlay() }
            posted = []; announced = []
            // Pressing a file selects it, marks its row, and announces it.
            guard let big = row(view, "big.bin") else { fatalError("\(name): no big.bin row") }
            precondition(!big.isAccessibilitySelected(), "\(name): nothing is selected yet")
            precondition(big.accessibilityPerformPress(), "\(name): pressing a file works")
            precondition(model.selection == node("big.bin"), "\(name): pressing a file selects it")
            precondition(row(view, "big.bin")?.isAccessibilitySelected() == true, "\(name): the row says it is selected")
            precondition((view.accessibilitySelectedChildren() ?? []).count == 1, "\(name): the list names its selected child")
            precondition(posted.contains { $0.0 == NSAccessibility.Notification.selectedChildrenChanged.rawValue },
                         "\(name): a new selection is announced: \(posted.map(\.0))")
            let focused = posted.first { $0.0 == NSAccessibility.Notification.focusedUIElementChanged.rawValue }?.1
            precondition((focused as? NSAccessibilityElement)?.accessibilityLabel()?.hasPrefix("big.bin,") == true,
                         "\(name): VoiceOver is moved to the selected row")
            // A selection inside a folder marks the folder's row too.
            model.selection = node("Movies/clip.mov")
            if let t = view as? TreemapNSView { t.syncOverlay() } else if let r = view as? SunburstNSView { r.syncOverlay() }
            precondition(row(view, "Movies")?.isAccessibilitySelected() == true, "\(name): the folder holding the selection is marked")
            precondition(row(view, "big.bin")?.isAccessibilitySelected() == false, "\(name): the old selection is cleared")

            // Pressing a folder zooms in and says where it went; Back returns.
            posted = []; announced = []
            guard let movies = row(view, "Movies") else { fatalError("\(name): no Movies row") }
            precondition(movies.accessibilityPerformPress(), "\(name): pressing a folder works")
            precondition(model.viewRoot == node("Movies"), "\(name): pressing a folder zooms into it")
            precondition(announced == [String(localized: "Showing Movies")], "\(name): the zoom is announced: \(announced)")
            precondition(posted.contains { $0.0 == NSAccessibility.Notification.layoutChanged.rawValue }, "\(name): the new rows are announced")
            precondition(row(view, "clip.mov") != nil && row(view, "big.bin") == nil, "\(name): the rows are the zoomed folder's")
            let back = rows(view).first
            precondition(back?.accessibilityLabel()?.hasPrefix(String(localized: "Back to \(model.rootDisplayName)")) == true,
                         "\(name): first row is Back: \(back?.accessibilityLabel() ?? "nil")")
            precondition(back?.accessibilityPerformPress() == true && model.viewRoot == 0, "\(name): Back zooms out")

            // Each row offers Select and the right-click menu's actions.
            let names = (row(view, "Movies")?.accessibilityCustomActions() ?? []).map(\.name)
            precondition(names.contains(String(localized: "Select")) && names.contains(String(localized: "Reveal in Finder"))
                         && names.contains(String(localized: "Copy Path")), "\(name): actions: \(names)")
            model.selection = nil
            if let t = view as? TreemapNSView { t.syncOverlay() } else if let r = view as? SunburstNSView { r.syncOverlay() }
        }

        // 3b. "N smaller items" has its own wording for one.
        precondition(MapAccessibility.smallerItems(1) == String(localized: "1 smaller item"), "one smaller item: \(MapAccessibility.smallerItems(1))")
        precondition(MapAccessibility.smallerItems(2) == String(localized: "\(Fmt.num(2)) smaller items"), "two smaller items: \(MapAccessibility.smallerItems(2))")
        precondition(MapAccessibility.smallerItems(1) != MapAccessibility.smallerItems(2), "one and many read differently")

        // 3c. Move to Trash from VoiceOver goes through the confirmation and
        //     the same safety path as the right-click menu, and does not hold
        //     the accessibility call while the alert is up. The alert is
        //     answered and the move done by stand-ins: nothing reaches the
        //     real Trash.
        let (realConfirm, realMove) = (NodeMenu.confirm, NodeMenu.trashMove)
        defer { (NodeMenu.confirm, NodeMenu.trashMove) = (realConfirm, realMove) }
        let standIn = fixture.appendingPathComponent("stand-in-trash")
        try fm.createDirectory(at: standIn, withIntermediateDirectories: true)
        var alerts: [NSAlert] = []
        var moves: [String] = []
        var answer = NSApplication.ModalResponse.alertSecondButtonReturn
        NodeMenu.confirm = { alerts.append($0); return answer }
        NodeMenu.trashMove = { url in
            moves.append(url.path)
            try fm.moveItem(at: url, to: standIn.appendingPathComponent(url.lastPathComponent))
        }
        func settle(timeout: TimeInterval = 5, until done: () -> Bool) async {
            let deadline = Date().addingTimeInterval(timeout)
            while !done() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        }
        func action(_ view: NSView, _ rowName: String, _ title: String) -> NSAccessibilityCustomAction {
            guard let found = row(view, rowName)?.accessibilityCustomActions()?.first(where: { $0.name == title }) else {
                fatalError("no '\(title)' action on \(rowName): \((row(view, rowName)?.accessibilityCustomActions() ?? []).map(\.name))")
            }
            return found
        }
        let trashTitle = String(localized: "Move to Trash")
        // A row listed now, used after the tree is replaced (3d).
        let staleRow = row(treemap, "Movies")! as! MapAccessibility.Element
        let staleActions = staleRow.accessibilityCustomActions() ?? []
        let staleSelect = staleActions.first { $0.name == String(localized: "Select") }!
        let staleCopy = staleActions.first { $0.name == String(localized: "Copy Path") }!

        for (name, view, target) in [("treemap", treemap as NSView, "notes.txt"), ("rings", rings as NSView, "big.bin")] {
            let path = root + "/" + target
            alerts = []; moves = []
            // Cancel: the call returns at once (the alert is not up yet), the
            // alert names the full path, and the file stays.
            answer = .alertSecondButtonReturn
            precondition(action(view, target, trashTitle).handler?() == true, "\(name): the action reports success")
            precondition(alerts.isEmpty, "\(name): the action returned before the alert ran, not while it was up")
            await settle { !alerts.isEmpty }
            precondition(alerts.count == 1, "\(name): Move to Trash asks first (\(alerts.count) alerts)")
            precondition(alerts[0].informativeText.contains(Tree.displayPath(path)) && alerts[0].messageText.contains(target),
                         "\(name): the alert names the item: \(alerts[0].messageText) / \(alerts[0].informativeText)")
            precondition(moves.isEmpty && fm.fileExists(atPath: path), "\(name): cancelling leaves \(target) in place")
            // Confirm: the same alert, then the move.
            alerts = []
            answer = .alertFirstButtonReturn
            precondition(action(view, target, trashTitle).handler?() == true, "\(name): the action reports success")
            await settle { !moves.isEmpty }
            precondition(alerts.count == 1, "\(name): the confirmed move was asked about too")
            precondition(moves == [path], "\(name): moved \(moves)")
            precondition(!fm.fileExists(atPath: path) && fm.fileExists(atPath: standIn.appendingPathComponent(target).path),
                         "\(name): \(target) went to the stand-in Trash")
            await model.settled()
            precondition(model.tree?.node(at: path) == nil, "\(name): the item left the map")
            treemap.relayoutIfNeeded(); rings.relayoutIfNeeded()
        }

        // 3d. A row from before the tree changed refuses to act: its node
        //     number may now be another file.
        //     (`staleRow` was taken before the trash loop above replaced the tree.)
        precondition(staleRow.item.treeGeneration != model.treeGeneration, "removing items started a new generation")
        model.selection = nil
        NSPasteboard.general.clearContents()
        precondition(staleSelect.handler?() == false && model.selection == nil, "Select refuses a row from an older tree")
        precondition(staleCopy.handler?() == false, "a menu action refuses a row from an older tree")
        precondition(staleRow.accessibilityPerformPress() == false && model.viewRoot == 0, "press refuses a row from an older tree")
        await settle(timeout: 0.2) { false }
        precondition(NSPasteboard.general.string(forType: .string) == nil, "Copy Path did not run for the stale row")
        precondition(model.selection == nil, "nothing was selected through the stale row")
        treemap.relayoutIfNeeded()
        precondition(action(treemap, "Movies", String(localized: "Select")).handler?() == true && model.selection == model.tree?.node(at: root + "/Movies"),
                     "a row listed from the current tree acts")

        // 3e. A drag that skips frames and ends at the size it began with
        //     still renders once at the end (the size alone says "no change").
        func relayoutIfNeeded(_ view: NSView) {
            if let t = view as? TreemapNSView { t.relayoutIfNeeded() } else if let r = view as? SunburstNSView { r.relayoutIfNeeded() }
        }
        for (name, view) in [("treemap", treemap as NSView), ("rings", rings as NSView)] {
            relayoutIfNeeded(view)
            let original = view.frame.size
            posted = []
            view.viewWillStartLiveResize()
            view.setFrameSize(NSSize(width: original.width + 80, height: original.height + 40))
            relayoutIfNeeded(view)
            precondition(posted.isEmpty, "\(name): a frame of the drag is not rendered")
            view.setFrameSize(original)
            view.viewDidEndLiveResize()
            precondition(posted.contains { $0.0 == NSAccessibility.Notification.layoutChanged.rawValue },
                         "\(name): a drag back to its first size renders at the end")
            // And a drag with no skipped frame renders nothing.
            posted = []
            view.viewWillStartLiveResize()
            view.viewDidEndLiveResize()
            precondition(posted.isEmpty, "\(name): an untouched view is not rendered again")
        }
        #endif
        #endif // SKIP_VOICEOVER

        // 4. Every error string is made with `String(localized:)`. A bare
        //    literal handed to `.failed(...)` or `CleanupOperations.failure(...)`
        //    reaches the screen in English whatever the language. `BZ_APP_DIR`
        //    points the checks at another copy of the sources.
        let appDir = ProcessInfo.processInfo.environment["BZ_APP_DIR"] ?? "app"
        let sources = try fm.contentsOfDirectory(atPath: appDir).filter { $0.hasSuffix(".swift") }.sorted()
        var bare: [String] = []
        for name in sources {
            let text = try String(contentsOfFile: appDir + "/" + name, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || code.hasPrefix("///") { continue }
                if line.contains(".failed(\"") || line.contains("failure(\"") || (line.contains(".failed(") && line.contains("?? \"")) {
                    bare.append("\(name):\(number + 1): \(code)")
                }
            }
        }
        precondition(bare.isEmpty, "error text built without String(localized:):\n" + bare.joined(separator: "\n"))
        // Messages that do not go through `.failed(` or `failure(`, named so they cannot slip back.
        let agent = try String(contentsOfFile: appDir + "/Agent.swift", encoding: .utf8)
        // `runCommand`'s reason becomes the card's status. Its result type can
        // only be made from a localized message (or a tool's own text, marked
        // `verbatim`), so a bare literal does not compile; this keeps the type
        // and keeps a `return "..."` out of the body.
        guard let start = agent.range(of: "static func runCommand("),
              let end = agent.range(of: "\n    }\n", range: start.upperBound..<agent.endIndex) else {
            fatalError("\(appDir)/Agent.swift has no runCommand")
        }
        let runCommandText = String(agent[start.lowerBound..<end.upperBound])
        precondition(runCommandText.contains("-> StepFailure?"), "runCommand returns a StepFailure, not a String")
        precondition(!runCommandText.contains("return \""), "runCommand returns a bare literal:\n" + runCommandText)
        precondition(agent.contains("init(_ message: LocalizedStringResource)"), "StepFailure takes a LocalizedStringResource")
        for snippet in [
            "StepFailure(\"Took too long\")", "StepFailure(\"Cancelled\")",
            "StepFailure(\"Exited with \\(String(outcome.status))\")",
            "String(localized: \"\\(displayName) stopped (exit \\(String(status))).\")",
            "String(localized: \"About \\(Fmt.size(",
        ] {
            precondition(agent.contains(snippet), "\(appDir)/Agent.swift lacks \(snippet)")
        }

        // 5. The keys added for the maps and the error text are in all seven
        //    tables, with the placeholders of the English, and translated.
        let languages = ["en", "de", "es", "fr", "ja", "tr", "zh-Hans"]
        let keys = [
            "Treemap of %@", "Rings of %@", "%@, %@, %@ of %@", "%@, %@", "folder", "file", "Select",
            "Showing %@", "Selected %@", "Clear search",
            "Couldn't install %@: %@", "Sign-in didn't finish (%@). Try again.", "Sign-in didn't finish. Try again.",
            "Couldn't start %@: %@", "%@ stopped (exit %@).", "%@ didn't return a plan.", "About %@ can go.",
            "Took too long", "Cancelled", "Exited with %@", "Claude Code stopped without a plan.",
            "Codex refused the request.", "The reply was not valid plan JSON.", "The endpoint returned no plan.",
            "The request failed.",
            "The moved item changed identity; leave it in the Trash and review it",
            "The item in the Trash or its parent changed; review it before deleting",
            "The item was moved but its Trash location was not returned; review the Trash manually",
            "The item in the Trash is missing", "This folder could not be validated; rescan before cleaning",
            "Command or arguments not allowed", "Cleanup tool not found in an absolute PATH directory",
            "1 smaller item", "%@ smaller items",
        ]
        // Texts that read the same in some language.
        let sameInSomeLanguages: Set<String> = ["%@, %@"]
        func placeholders(_ s: String) -> Int { s.components(separatedBy: "%").count - 1 }
        for language in languages {
            guard let table = NSDictionary(contentsOfFile: "\(appDir)/\(language).lproj/Localizable.strings") as? [String: String] else {
                fatalError("\(appDir)/\(language).lproj/Localizable.strings does not parse")
            }
            for key in keys {
                guard let text = table[key], !text.isEmpty else { fatalError("'\(key)' is missing from the \(language) table") }
                precondition(placeholders(text) == placeholders(key), "\(language): '\(key)' changed its placeholders: '\(text)'")
                if language != "en", !sameInSomeLanguages.contains(key) {
                    precondition(text != key, "\(language): '\(key)' is not translated")
                }
            }
        }

        // 6. The keys the code makes are the keys in the tables: look each
        //    message up as the app builds it, in each language's own bundle.
        let samples: [(String, (Bundle) -> String)] = [
            ("Treemap of %@", { String(localized: "Treemap of \("x")", bundle: $0) }),
            ("Rings of %@", { String(localized: "Rings of \("x")", bundle: $0) }),
            ("%@, %@, %@ of %@", { String(localized: "\("a"), \("b"), \("c") of \("d")", bundle: $0) }),
            ("Showing %@", { String(localized: "Showing \("x")", bundle: $0) }),
            ("Selected %@", { String(localized: "Selected \("x")", bundle: $0) }),
            ("Couldn't install %@: %@", { String(localized: "Couldn't install \("x"): \("y")", bundle: $0) }),
            ("Sign-in didn't finish (%@). Try again.", { String(localized: "Sign-in didn't finish (\("x")). Try again.", bundle: $0) }),
            ("Couldn't start %@: %@", { String(localized: "Couldn't start \("x"): \("y")", bundle: $0) }),
            ("%@ stopped (exit %@).", { String(localized: "\("x") stopped (exit \("1")).", bundle: $0) }),
            ("%@ didn't return a plan.", { String(localized: "\("x") didn't return a plan.", bundle: $0) }),
            ("About %@ can go.", { String(localized: "About \("x") can go.", bundle: $0) }),
            ("Exited with %@", { String(localized: "Exited with \("1")", bundle: $0) }),
            ("Cleanup tool not found in an absolute PATH directory", { String(localized: "Cleanup tool not found in an absolute PATH directory", bundle: $0) }),
            ("1 smaller item", { String(localized: "1 smaller item", bundle: $0) }),
            ("%@ smaller items", { String(localized: "\("2") smaller items", bundle: $0) }),
        ]
        for language in languages where language != "en" {
            guard let bundle = Bundle(path: "\(appDir)/\(language).lproj") else { fatalError("no bundle for \(language)") }
            for (key, make) in samples where !sameInSomeLanguages.contains(key) {
                let english = make(Bundle(path: "\(appDir)/en.lproj")!)
                precondition(make(bundle) != english, "\(language): the code's '\(key)' finds no translation (key mismatch)")
            }
        }
        print("PASS: VoiceOver rows, press, selection and zoom announcements; error text localized in 7 languages")
    }
}
