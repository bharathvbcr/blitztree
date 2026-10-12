import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @State private var model = ScanModel()
    @State private var showTable = true
    @State private var listMode: ListMode = .folders
    @FocusState private var isSearchFocused: Bool
    @AppStorage("bz.showCleanup") private var showCleanup = false
    @AppStorage("bz.listWidth") private var listWidth = 390.0
    @AppStorage("bz.typesWidth") private var typesWidth = 300.0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: NSColor(calibratedWhite: 0.10, alpha: 1))
                // Build the empty canvases while the first scan is running,
                // so AppKit setup does not delay the finished tree. Once built,
                // the list and treemap stay alive (hidden) through
                // a rescan: tearing them down and rebuilding them made AppKit
                // redo its first-time setup and froze the window as the new
                // scan landed. A new tree only reloads into the same views.
                if model.scanning || model.tree != nil || model.hasShownTree {
                    // Not HSplitView: next to the Clean Up inspector it put AppKit
                    // in an endless constraint-update loop and crashed the app
                    // seconds after every scan with the panel open.
                    HStack(spacing: 0) {
                        if showTable {
                            VStack(spacing: 0) {
                                Picker("List", selection: $listMode) {
                                    Text("Folders").tag(ListMode.folders)
                                    Text("Largest Files").tag(ListMode.largestFiles)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                // The outline stays in the hierarchy (see above);
                                // the file list covers it rather than replacing it.
                                ZStack {
                                    OutlinePanel(model: model)
                                    if listMode == .largestFiles {
                                        LargestFilesList(model: model)
                                    }
                                }
                            }
                            .frame(width: listWidth)
                            ListDivider(width: $listWidth)
                        }
                        if model.showTypes {
                            TypesPanel(model: model)
                                .frame(width: typesWidth)
                            ListDivider(width: $typesWidth)
                        }
                        Group {
                            switch model.mapStyle {
                            case .treemap:
                                TreemapView(model: model, freeBytes: model.showFreeSpace ? model.freeBytes : 0,
                                            highlight: model.highlightedType)
                            case .rings:
                                SunburstView(model: model, freeBytes: model.showFreeSpace && model.viewRoot == 0 ? model.freeBytes : 0)
                            }
                        }
                        .frame(minWidth: 400, maxWidth: .infinity)
                    }
                    // Hidden by an opaque cover below, not by opacity or hit
                    // testing: SwiftUI re-inserts AppKit views when those change.
                }
                if model.tree == nil {
                    Group {
                        if model.scanning {
                            ScanProgress(model: model)
                        } else if needsFDA {
                            fdaOverlay
                        } else {
                            idleOverlay
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: NSColor(calibratedWhite: 0.10, alpha: 1)))
                    .contentShape(Rectangle())
                }
            }
            Divider()
            ScanStatusBar(model: model)
        }
        .frame(minWidth: 760, minHeight: 500)
        .inspector(isPresented: $showCleanup) {
            CleanupPanel(model: model)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
        }
        .toolbar { toolbar }
        .task {
            model.watchVolumes()
            model.agentEnv = await AgentLocator.find()
            model.openPanelAfterLaunchScan()
        }
        // An agent run or the setup offer always shows in the panel.
        .onChange(of: model.agentRun == nil) { if model.agentRun != nil { showCleanup = true } }
        .onChange(of: model.panelRequests) { showCleanup = true }
        // A MANVI model picked in Settings decides whether MANVI is ready.
        .onReceive(NotificationCenter.default.publisher(for: Manvi.settingsChanged)) { _ in
            Task { model.agentEnv = await AgentLocator.find() }
        }
        .hidingWindowTitle()
        .onAppear {
            if CommandLine.arguments.count > 1 {
                if FDA.isActive() {
                    model.startScan()
                } else {
                    needsFDA = true
                }
                return
            }
            switch model.launchTarget {
            case .prompt:
                DispatchQueue.main.async {
                    chooseFolder()
                }
            case .home:
                model.startScan(path: FileManager.default.homeDirectoryForCurrentUser.path)
            case .macintoshHD:
                // Never start a whole-disk scan without FDA: every protected
                // app container would fire a permission prompt.
                if FDA.isActive() {
                    model.startScan(path: "/System/Volumes/Data")
                } else {
                    needsFDA = true
                }
            }
        }
        .background {
            Button("") {
                isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
        }
        .background {
            // The toolbar's Stop button takes Esc; ⌘. is the other usual way out.
            Button("") {
                model.stopScan()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!model.scanning || model.stopping)
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    @State private var needsFDA = false

    private var fdaOverlay: some View {
        // Top-anchored like the window's other states: dead-center made the
        // permission card float in the middle of an empty scan area.
        VStack(alignment: .leading, spacing: 14) {
            Label("BlitzTree needs Full Disk Access", systemImage: "lock.shield")
                .font(.title3.weight(.semibold))
            Text("System Settings → Privacy & Security → Full Disk Access.\nRemove any old BlitzTree rows, then add /Applications/BlitzTree.app.\nmacOS only applies the permission to a freshly launched app.")
                .multilineTextAlignment(.leading)
                .foregroundStyle(.secondary)
                .font(.callout)
            HStack(spacing: 12) {
                Button("Open System Settings") { openFDASettings() }
                Button("I granted it — Relaunch") { FDA.relaunch() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Scan without it") {
                needsFDA = false
                model.startScan()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 480, alignment: .leading)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 56)
    }

    // MARK: toolbar

    @ViewBuilder
    private var titleCrumbs: some View {
        if let tree = model.tree {
            breadcrumbs(tree: tree)
        } else {
            Text(displayRootName())
                .font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // macOS 26+: crumbs sit bare in the Liquid Glass toolbar, pushed apart
        // from the controls by a flexible spacer. Older systems lay out the
        // classic toolbar themselves.
        if #available(macOS 26, *) {
            ToolbarItem(placement: .navigation) { titleCrumbs }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem(placement: .navigation) { titleCrumbs }
        }

        ToolbarItemGroup(placement: .automatic) {
            Menu {
                ForEach(model.volumes) { volume in
                    Button {
                        model.startScan(path: volume.path)
                    } label: {
                        Label(volume.total > 0
                              ? String(localized: "\(volume.name) — \(Fmt.size(volume.used)) of \(Fmt.size(volume.total)) used")
                              : volume.name,
                              systemImage: volume.isInternal ? "internaldrive" : "externaldrive")
                    }
                }
                Divider()
                Button("Home") { model.startScan(path: FileManager.default.homeDirectoryForCurrentUser.path) }
                Divider()
                Button("Choose Folder…") { chooseFolder() }
            } label: {
                Label("Scan", systemImage: "folder")
            }
            .disabled(model.scanning || model.cleanupTrash.running)
            .help("Choose what to scan")

            Button {
                model.startScan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(model.scanning || model.cleanupTrash.running)
            .help("Rescan")

            if model.scanning {
                Button {
                    model.stopScan()
                } label: {
                    Label(model.stopping ? LocalizedStringKey("Stopping…") : LocalizedStringKey("Stop"),
                          systemImage: "stop.fill")
                }
                .disabled(model.stopping)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Stop scanning (Esc or ⌘.)")
            }
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .automatic)
        }

        ToolbarItem(placement: .automatic) {
            Picker("View", selection: $model.mapStyle) {
                Label("Treemap", systemImage: "square.grid.2x2").tag(MapStyle.treemap)
                Label("Rings", systemImage: "circle.circle").tag(MapStyle.rings)
            }
            .pickerStyle(.segmented)
            .help("Treemap (WizTree-style) or rings (DaisyDisk-style)")
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .automatic)
        }

        ToolbarItem(placement: .automatic) {
            SearchToolbarField(model: model, showTable: $showTable, isFocused: $isSearchFocused)
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .automatic)
        }

        ToolbarItemGroup(placement: .automatic) {
            Toggle(isOn: $model.showFreeSpace) {
                Label("Free Space", systemImage: "square.dashed")
            }
            .help("Show free space in the map")

            Toggle(isOn: $showTable) {
                Label("Directory List", systemImage: "sidebar.leading")
            }
            .help("Show directory list")

            Toggle(isOn: $model.showTypes) {
                Label("File Types", systemImage: "chart.bar.doc.horizontal")
            }
            .help("Show space by file type")

            Toggle(isOn: $showCleanup) {
                Label("Clean Up", systemImage: "sparkles")
            }
            .help("Show folders that are safe to clean up")
        }
    }

    private func breadcrumbs(tree: Tree) -> some View {
        HStack(spacing: 4) {
            let chain = tree.ancestry(model.viewRoot)
            ForEach(Array(chain.enumerated()), id: \.offset) { i, node in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Button {
                    model.viewRoot = node
                } label: {
                    Text(node == 0 ? displayRootName() : tree.name(node))
                        .font(.system(.body, design: .rounded).weight(i == chain.count - 1 ? .semibold : .regular))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(i == chain.count - 1 ? .primary : .secondary)
            }
        }
    }

    private func displayRootName() -> String {
        let p = model.scanRoot
        if p == "/System/Volumes/Data" { return String(localized: "Macintosh HD") }
        return (p as NSString).lastPathComponent.isEmpty ? p : (p as NSString).lastPathComponent
    }

    // MARK: overlays

    private var idleOverlay: some View {
        VStack(spacing: 10) {
            if model.scanFailed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("The scan failed")
                    .foregroundStyle(.secondary)
                Text("BlitzTree could not scan \(model.scanRoot)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Button("Rescan") { model.startScan() }
            } else if model.scanCancelled {
                Image(systemName: "stop.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Scan stopped")
                    .foregroundStyle(.secondary)
                Text("BlitzTree stopped scanning \(model.scanRoot) before it finished.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Button("Rescan") { model.startScan() }
            } else {
                Image(systemName: "internaldrive")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Pick a target and scan")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.startScan(path: url.path)
        }
    }

    private func openFDASettings() { openFullDiskAccessSettings() }
}

/// Observe 60 Hz counters here so progress updates do not rebuild the toolbar.
private struct ScanProgress: View {
    let model: ScanModel
    var body: some View {
        VStack(spacing: 14) {
            Text(Fmt.fixedSize(model.bytes))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text("\(Fmt.num(model.files)) files · \(Fmt.num(model.dirs)) folders · \(String(format: "%.2f", model.elapsed))s")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            if model.stopping {
                Text("Stopping…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        // No spinner: the counters are the progress, and a ProgressView is an
        // AppKit view whose insertion recomputed the window's key-view loop
        // (laying out the hidden list) just as each scan started.
        // No numeric-text transition: its blur is rasterized on the CPU and
        // stalled the main thread for most of a short scan. Plain digits
        // updated at the 60 Hz poll count up smoothly on their own.
    }
}

/// Pointer movement changes only the status text, not the window's view graph.
private struct ScanStatusBar: View {
    let model: ScanModel
    var body: some View {
        HStack(spacing: 8) {
            if let tree = model.tree {
                if let sel = model.hovered ?? model.selection {
                    Text(tree.displayPath(sel))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .contextMenu {
                            Button(String(localized: "Copy Path")) {
                                NodeMenu.copyPath(tree.path(sel))
                            }
                            Button(String(localized: "Reveal in Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tree.path(sel))])
                            }
                        }
                    Spacer()
                    let a = tree.alloc[sel]
                    let rootA = max(tree.alloc[model.viewRoot], 1)
                    Text("\(Fmt.size(a)) · \(String(format: "%.1f%%", 100 * Double(a) / Double(rootA)))")
                        .monospacedDigit()
                } else {
                    Text("\(Fmt.num(UInt64(tree.nFiles[model.viewRoot]))) files · \(Fmt.size(tree.alloc[model.viewRoot]))")
                        .monospacedDigit()
                    Spacer()
                    if model.overcountedBytes > 1_000_000_000 {
                        Text("Sizes exceed disk usage by \(Fmt.size(model.overcountedBytes))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .help(String(localized: "Files cloned on APFS and edited afterwards share most of their blocks, but each one is counted in full."))
                    }
                    if tree.errors > 0 {
                        if FDA.isActive() {
                            // Root-owned system dirs: unreadable by design,
                            // not a permissions problem the user can fix.
                            let gap = model.unscannedBytes > 1_000_000_000
                                ? " · " + String(localized: "~\(Fmt.size(model.unscannedBytes)) root-only") : ""
                            Text("\(String(tree.errors)) system folders unreadable\(gap)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            Button {
                                openFullDiskAccessSettings()
                            } label: {
                                Label("\(String(tree.errors)) folders skipped — grant Full Disk Access", systemImage: "lock.shield")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    CoverageButton(coverage: tree.coverage)
                    Text("scanned in \(String(format: "%.1fs", model.elapsed))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text("BlitzTree").foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// After a scan: whether every folder was read, and what was left out or
/// counted once. The popover lists the same fields the CLI reports.
private struct CoverageButton: View {
    let coverage: BzCoverage
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Label("Coverage", systemImage: coverage.complete ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(coverage.complete ? .tertiary : .secondary)
        .help("What the scan could and could not read")
        .popover(isPresented: $shown, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(CoverageText.headline(coverage))
                    .font(.callout.weight(.semibold))
                ForEach(CoverageText.lines(coverage), id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !coverage.complete {
                    Text("Folders marked with a warning sign in the list were only partly read.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 320, alignment: .leading)
            .padding(14)
        }
    }
}

private func openFullDiskAccessSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
        NSWorkspace.shared.open(url)
    }
}

/// Left panel: a real NSOutlineView — the same control as Finder's list
/// view. Native disclosure triangles, real file icons, alternating rows,
/// keyboard navigation.
/// The draggable line between the list and the treemap (210–400 pt).
private struct ListDivider: View {
    @Binding var width: Double
    @State private var dragStart: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStart ?? width
                                dragStart = start
                                width = min(400, max(210, start + drag.translation.width))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
    }
}

/// List cells laid out by frame, not Auto Layout: AppKit re-lays out every
/// row as it reloads, and solving constraints per row made reloads stall.
final class NameCell: NSTableCellView {
    private static let font = NSFont.systemFont(ofSize: 13)
    private static let lineHeight = ceil(font.ascender - font.descender + font.leading)
    /// Text height plus breathing room, so the glyphs never touch the row edges.
    static let rowHeight = lineHeight + 8

    /// A warning sign at the row's right edge for a folder that was only
    /// partly read; hidden otherwise.
    private let partialBadge = NSImageView()
    private static let badgeWidth: CGFloat = 18

    override init(frame: NSRect) {
        super.init(frame: frame)
        let iv = NSImageView()
        let tf = NSTextField(labelWithString: "")
        tf.font = Self.font
        tf.lineBreakMode = .byTruncatingMiddle
        partialBadge.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        partialBadge.contentTintColor = .systemOrange
        partialBadge.isHidden = true
        addSubview(iv)
        addSubview(tf)
        addSubview(partialBadge)
        imageView = iv
        textField = tf
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Marks the row as partly read, with `note` as its tooltip and spoken
    /// label; nil clears the mark (rows are reused).
    func showPartial(_ note: String?) {
        partialBadge.isHidden = note == nil
        partialBadge.toolTip = note
        partialBadge.setAccessibilityLabel(note)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let badge = partialBadge.isHidden ? 0 : Self.badgeWidth
        imageView?.frame = NSRect(x: 2, y: ((h - 16) / 2).rounded(), width: 16, height: 16)
        textField?.frame = NSRect(x: 23, y: ((h - Self.lineHeight) / 2).rounded(),
                                  width: max(0, bounds.width - 25 - badge), height: Self.lineHeight)
        partialBadge.frame = NSRect(x: max(0, bounds.width - Self.badgeWidth), y: ((h - 14) / 2).rounded(),
                                    width: 14, height: 14)
    }
}

/// A right-aligned figure (size or percentage) in the list.
final class ValueCell: NSTableCellView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let lineHeight = ceil(font.ascender - font.descender + font.leading)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let tf = NSTextField(labelWithString: "")
        tf.font = Self.font
        tf.textColor = .secondaryLabelColor
        tf.alignment = .right
        addSubview(tf)
        textField = tf
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        textField?.frame = NSRect(x: 0, y: ((bounds.height - Self.lineHeight) / 2).rounded(),
                                  width: max(0, bounds.width - 2), height: Self.lineHeight)
    }
}

/// How the list orders a folder's children. Size descending is the engine's
/// own order, so the default costs nothing; other orders keep it for ties.
nonisolated struct ListOrder: Equatable, CustomStringConvertible {
    enum Key: String { case name, size, files }
    var key: Key
    var ascending: Bool

    static let engine = ListOrder(key: .size, ascending: false)

    init(key: Key, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    /// The order a header click asked for.
    init(_ descriptors: [NSSortDescriptor]) {
        guard let first = descriptors.first, let key = first.key.flatMap(Key.init(rawValue:)) else {
            self = .engine
            return
        }
        self.init(key: key, ascending: first.ascending)
    }

    var descriptor: NSSortDescriptor { NSSortDescriptor(key: key.rawValue, ascending: ascending) }
    var description: String { "\(key.rawValue) \(ascending ? "ascending" : "descending")" }

    func children(of parent: Int, in tree: Tree) -> [Int] {
        let ids = tree.children(parent)
        switch key {
        case .size:
            return ascending ? ids.reversed().map(Int.init) : ids.map(Int.init)
        case .files:
            let counts = ids.map { tree.isDir(Int($0)) ? Int64(tree.nFiles[Int($0)]) : -1 }
            return sorted(ids) { a, b in counts[a] == counts[b] ? 0 : counts[a] < counts[b] ? -1 : 1 }
        case .name:
            // All keys in one buffer, compared with memcmp.
            var keys: [UInt8] = []
            keys.reserveCapacity(ids.count * 24)
            var ends: [Int] = []
            ends.reserveCapacity(ids.count)
            for id in ids {
                Self.appendNameKey(tree.nameBytes(Int(id)), to: &keys)
                ends.append(keys.count)
            }
            return keys.withUnsafeBufferPointer { buf in
                sorted(ids) { a, b in
                    let aStart = a == 0 ? 0 : ends[a - 1], bStart = b == 0 ? 0 : ends[b - 1]
                    let aCount = ends[a] - aStart, bCount = ends[b] - bStart
                    let common = min(aCount, bCount)
                    let c = common == 0 ? 0 : memcmp(buf.baseAddress! + aStart, buf.baseAddress! + bStart, common)
                    return c != 0 ? Int(c) : aCount - bCount
                }
            }
        }
    }

    /// `ids` by a three-way `compare` of their positions; equal ones stay in
    /// engine order whichever way it runs.
    private func sorted(_ ids: UnsafeBufferPointer<UInt32>, by compare: (Int, Int) -> Int) -> [Int] {
        var at = Array(ids.indices)
        at.sort { a, b in
            let c = compare(a, b)
            return c != 0 ? (ascending ? c < 0 : c > 0) : a < b
        }
        return at.map { Int(ids[$0]) }
    }

    /// Finder's name order (`localizedStandardCompare`: case- and
    /// accent-blind, digit runs by value) as bytes compared with memcmp.
    /// Building one key per name is several times faster on a 100k-item
    /// folder than calling the comparator in the sort. Scripts whose
    /// collation isn't code-point order (pinyin, for one) come out by code point.
    static func nameKey(_ name: String) -> [UInt8] {
        var key: [UInt8] = []
        var utf8 = Array(name.utf8)
        utf8.withUnsafeMutableBufferPointer { appendNameKey(UnsafeBufferPointer($0), to: &key) }
        return key
    }

    static func appendNameKey(_ name: UnsafeBufferPointer<UInt8>, to key: inout [UInt8]) {
        if name.allSatisfy({ $0 < 0x80 }) {
            appendFoldedKey(name, to: &key)
            return
        }
        // Folded, then composed: byte order is then code-point order.
        var folded = Array(String(decoding: name, as: UTF8.self)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping.utf8)
        folded.withUnsafeMutableBufferPointer { appendFoldedKey(UnsafeBufferPointer($0), to: &key) }
    }

    /// ASCII letters lowercased (folding already did the rest); each digit
    /// run as a control byte for its width, then its digits without leading
    /// zeros, so shorter numbers come first and numbers precede letters.
    private static func appendFoldedKey(_ bytes: UnsafeBufferPointer<UInt8>, to key: inout [UInt8]) {
        let zero = UInt8(ascii: "0"), nine = UInt8(ascii: "9")
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte >= zero && byte <= nine {
                var end = i
                while end < bytes.count && bytes[end] >= zero && bytes[end] <= nine { end += 1 }
                var start = i
                while start < end && bytes[start] == zero { start += 1 }
                key.append(UInt8(1 + min(end - start, 30)))
                key.append(contentsOf: bytes[start..<end])
                i = end
            } else {
                key.append(byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte)
                i += 1
            }
        }
    }
}

struct OutlinePanel: NSViewRepresentable {
    let model: ScanModel

    /// An NSObject so the outline hashes and compares items by pointer: as a
    /// plain Swift class every lookup went through the Swift runtime's
    /// conformance checks, a third of expanding a 100k-item folder.
    final class Item: NSObject {
        private(set) var id: Int
        private(set) var tree: Tree
        private var kids: [Item]?
        private var kidsOrder = ListOrder.engine
        init(id: Int, tree: Tree) {
            self.id = id
            self.tree = tree
        }
        func children(_ order: ListOrder) -> [Item] {
            if let kids, kidsOrder == order { return kids }
            let ids = order.children(of: id, in: tree)
            kids = kids.map { Item.reorder($0, to: ids) } ?? ids.map { Item(id: $0, tree: tree) }
            kidsOrder = order
            return kids!
        }

        /// The same wrappers in a new order: AppKit keeps rows expanded and
        /// selected by item identity, so a re-sort must not replace them.
        static func reorder(_ items: [Item], to ids: [Int]) -> [Item] {
            var byID = [Int: Item](minimumCapacity: items.count)
            for item in items { byID[item.id] = item }
            return ids.map { byID[$0]! }
        }

        /// Only an untouched, collapsed item can be rebound without leaving
        /// stale child identities in AppKit's outline cache.
        func canRebind(to id: Int, in tree: Tree) -> Bool {
            kids == nil && self.tree.isDir(self.id) == tree.isDir(id)
                && self.tree.children(self.id).count == tree.children(id).count
                && self.tree.name(self.id) == tree.name(id)
        }

        func rebind(to id: Int, in tree: Tree) {
            precondition(kids == nil)
            self.id = id
            self.tree = tree
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var model: ScanModel?
        var tree: Tree?
        var viewRoot = -1
        var roots: [Item] = []
        /// The column the user sorted by; size descending until they click one.
        private(set) var order = ListOrder.engine
        weak var outline: NSOutlineView?
        private var iconCache: [String: NSImage] = [:]

        /// The selected rows' nodes, top to bottom; empty while the list
        /// still shows a tree a rescan replaced.
        var selectedNodes: [Int] {
            guard let outline, let tree, model?.tree === tree else { return [] }
            return outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Item)?.id }
        }

        func rebuildIfNeeded() {
            guard let model, let t = model.tree else { return }
            if t !== tree || model.viewRoot != viewRoot {
                let childIDs = order.children(of: model.viewRoot, in: t)
                // Bound name comparisons for extremely wide directories.
                let reuseRows = t !== tree && model.viewRoot == viewRoot
                    && roots.count <= 4_096
                    && outline?.numberOfRows == roots.count && childIDs.count == roots.count
                    && zip(roots, childIDs).allSatisfy { item, id in
                        item.canRebind(to: id, in: t) && outline?.isItemExpanded(item) == false
                    }
                tree = t
                viewRoot = model.viewRoot
                let started = Date()
                if reuseRows, let outline {
                    // A rescan often has the same top-level shape. Keep row
                    // views/disclosure buttons and refresh only their cells.
                    for (item, id) in zip(roots, childIDs) { item.rebind(to: id, in: t) }
                    outline.deselectAll(nil)
                    outline.enumerateAvailableRowViews { rowView, row in
                        guard self.roots.indices.contains(row) else { return }
                        for (column, definition) in outline.tableColumns.enumerated() {
                            if let cell = rowView.view(atColumn: column) as? NSTableCellView {
                                self.configure(cell, column: definition.identifier.rawValue, item: self.roots[row])
                            }
                        }
                    }
                } else {
                    roots = childIDs.map { Item(id: $0, tree: t) }
                    outline?.reloadData()
                }
                if ProcessInfo.processInfo.environment["BZ_TIMING"] != nil {
                    NSLog("BZ list reload: %.1f ms", -started.timeIntervalSinceNow * 1000)
                }
            }
        }

        func icon(for name: String, isDir: Bool) -> NSImage {
            let key: String
            if isDir {
                key = "/folder"
            } else if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                key = String(name[name.index(after: dot)...]).lowercased()
            } else {
                key = "/plain"
            }
            if let hit = iconCache[key] { return hit }
            let img: NSImage
            if key == "/folder" {
                img = NSWorkspace.shared.icon(for: .folder)
            } else if key == "/plain" {
                img = NSWorkspace.shared.icon(for: .data)
            } else {
                img = NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
            }
            // Pre-render to a small bitmap: workspace icons are lazy, and every
            // row asking IconServices for one again made list reloads slow.
            let scale = outline?.window?.backingScaleFactor ?? 2
            let px = Int(16 * scale)
            let flat: NSImage
            if let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) {
                rep.size = NSSize(width: 16, height: 16)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                img.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
                NSGraphicsContext.restoreGraphicsState()
                flat = NSImage(size: NSSize(width: 16, height: 16))
                flat.addRepresentation(rep)
            } else {
                flat = img
            }
            iconCache[key] = flat
            return flat
        }

        // MARK: data source
        func outlineView(_ v: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item = item as? Item else { return roots.count }
            // AppKit asks counts without expanding a row. The flat tree
            // already knows this; do not allocate wrappers for its children.
            return item.tree.children(item.id).count
        }
        func outlineView(_ v: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            item == nil ? roots[index] : (item as! Item).children(order)[index]
        }
        func outlineView(_ v: NSOutlineView, isItemExpandable item: Any) -> Bool {
            let it = item as! Item
            return it.tree.isDir(it.id) && !it.tree.children(it.id).isEmpty
        }

        /// A header click. Folders already opened re-sort lazily, when the
        /// reload asks for their rows; the selection follows its items.
        func outlineView(_ v: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            let next = ListOrder(v.sortDescriptors)
            OutlinePanel.showSortIndicator(v, for: next)
            guard next != order else { return }
            order = next
            guard let tree, tree === model?.tree else { return }
            let started = Date()
            let selected = v.selectedRowIndexes.compactMap { v.item(atRow: $0) as? Item }
            let primary = model?.selection
            roots = Item.reorder(roots, to: order.children(of: viewRoot, in: tree))
            v.reloadData()
            let rows = IndexSet(selected.map { v.row(forItem: $0) }.filter { $0 >= 0 })
            v.selectRowIndexes(rows, byExtendingSelection: false)
            if let primary, let it = selected.first(where: { $0.id == primary }) {
                model?.selection = primary
                v.scrollRowToVisible(v.row(forItem: it))
            }
            if ProcessInfo.processInfo.environment["BZ_TIMING"] != nil {
                NSLog("BZ list sort (%@, %d rows): %.1f ms", order.description, v.numberOfRows,
                      -started.timeIntervalSinceNow * 1000)
            }
        }

        // MARK: cells
        func outlineView(_ v: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
            let it = item as! Item
            let colID = col?.identifier.rawValue ?? "name"
            let reuse = NSUserInterfaceItemIdentifier("cell-\(colID)")

            if colID == "name" {
                let cell = (v.makeView(withIdentifier: reuse, owner: nil) as? NameCell) ?? {
                    let c = NameCell()
                    c.identifier = reuse
                    return c
                }()
                configure(cell, column: colID, item: it)
                return cell
            }

            let cell = (v.makeView(withIdentifier: reuse, owner: nil) as? ValueCell) ?? {
                let c = ValueCell()
                c.identifier = reuse
                return c
            }()
            configure(cell, column: colID, item: it)
            return cell
        }

        private func configure(_ cell: NSTableCellView, column: String, item it: Item) {
            let tree = it.tree
            if column == "name" {
                let name = tree.name(it.id)
                cell.textField?.stringValue = name
                cell.imageView?.image = icon(for: name, isDir: tree.isDir(it.id))
                // Only a folder whose own listing was partial is marked; the
                // ones above it are lower bounds too, said in the map's tooltip.
                (cell as? NameCell)?.showPartial(tree.isPartlyRead(it.id) ? tree.coverageNote(it.id) : nil)
            } else if column == "size" {
                cell.textField?.stringValue = Fmt.size(tree.alloc[it.id])
            } else if column == "files" {
                cell.textField?.stringValue = tree.isDir(it.id) ? Fmt.num(UInt64(tree.nFiles[it.id])) : ""
            } else {
                let parent = Int(tree.parents[it.id])
                let pAlloc = parent == Int(UInt32.max) ? tree.alloc[0] : tree.alloc[parent]
                let pct = pAlloc > 0 ? 100 * Double(tree.alloc[it.id]) / Double(pAlloc) : 0
                cell.textField?.stringValue = pct < 0.5 ? "–" : String(format: "%.0f%%", pct)
                cell.textField?.textColor = .tertiaryLabelColor
            }
        }

        func outlineViewSelectionDidChange(_ n: Notification) {
            // While a rescan runs the list still shows the old tree, hidden.
            guard let outline, let model, model.tree != nil, model.tree === tree else { return }
            // With several rows selected the maps show the one picked last.
            if let it = outline.item(atRow: outline.selectedRow) as? Item {
                model.selection = it.id
            }
        }

        /// Treemap click → expand ancestors, select and reveal the row here.
        /// A node already among several selected rows keeps that selection.
        func syncSelection() {
            guard let outline, let tree, let sel = model?.selection else { return }
            if let cur = outline.item(atRow: outline.selectedRow) as? Item, cur.id == sel { return }
            if outline.selectedRowIndexes.contains(where: { (outline.item(atRow: $0) as? Item)?.id == sel }) { return }

            var chain: [Int] = []
            var cur = sel
            while cur != viewRoot {
                if cur == Int(UInt32.max) { return } // outside current view root
                chain.append(cur)
                cur = Int(tree.parents[cur])
            }
            chain.reverse()

            var level = roots
            var target: Item?
            for id in chain {
                guard let it = level.first(where: { $0.id == id }) else { return }
                target = it
                if id != chain.last {
                    outline.expandItem(it)
                    level = it.children(order)
                }
            }
            if let target {
                let row = outline.row(forItem: target)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
            }
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard let it = sender.item(atRow: sender.clickedRow) as? Item else { return }
            if it.tree.isDir(it.id) {
                model?.viewRoot = it.id
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: it.tree.path(it.id))])
            }
        }
    }

    @MainActor
    final class OutlineView: NSOutlineView {
        weak var coordinator: Coordinator?

        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            var row = self.row(at: point)
            if row < 0 && event.type != .rightMouseDown {
                row = selectedRow
            }
            // Rows from a tree since replaced (a removal renumbers) name
            // other items in the new one; the list rebuilds before acting.
            guard let coordinator, let model = coordinator.model,
                  row >= 0, let it = item(atRow: row) as? OutlinePanel.Item, it.tree === model.tree else {
                return nil
            }
            // As in Finder: a right-click inside the selection acts on all of
            // it, one outside replaces it.
            if !isRowSelected(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            model.selection = it.id
            let menu = NSMenu()
            NodeMenu.fill(menu, nodes: coordinator.selectedNodes, model: model)
            return menu
        }

        @objc(copy:)
        func copySelection(_ sender: Any?) {
            guard let coordinator, let tree = coordinator.model?.tree else { return }
            let nodes = coordinator.selectedNodes
            guard !nodes.isEmpty else { return }
            NodeMenu.copyPath(nodes.map(tree.displayPath).joined(separator: "\n"))
        }

        override func keyDown(with event: NSEvent) {
            let cmdDelete = event.modifierFlags.contains(.command) && (event.keyCode == 51 || event.keyCode == 117)
            if cmdDelete, let coordinator, let model = coordinator.model,
               case let nodes = coordinator.selectedNodes, !nodes.isEmpty, !nodes.contains(0) {
                NodeMenu.moveToTrash(nodes: nodes, model: model)
                return
            }
            super.keyDown(with: event)
        }
    }

    /// The cells use fixed fonts, so the row height must not follow the system
    /// "Sidebar icon size" setting: Small made rows shorter than the 13pt text
    /// and clipped it.
    static func configureRows(_ outline: NSOutlineView) {
        outline.rowSizeStyle = .custom
        outline.rowHeight = NameCell.rowHeight
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Columns, sorting and selection; the data source is attached after, so
    /// showing the default sort in the header doesn't re-sort anything.
    static func configure(_ outline: NSOutlineView) {
        outline.style = .plain
        Self.configureRows(outline)
        outline.usesAlternatingRowBackgroundColors = true
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 13
        outline.autoresizesOutlineColumn = false
        outline.allowsMultipleSelection = true

        // Each column's first click sorts the way people usually want it:
        // names A–Z, sizes and counts largest first.
        let name = NSTableColumn(identifier: .init("name"))
        name.title = String(localized: "Name")
        name.minWidth = 120
        name.sortDescriptorPrototype = ListOrder(key: .name, ascending: true).descriptor
        let size = NSTableColumn(identifier: .init("size"))
        size.title = String(localized: "Size")
        size.width = 92; size.minWidth = 84; size.maxWidth = 116
        size.sortDescriptorPrototype = ListOrder.engine.descriptor
        let pct = NSTableColumn(identifier: .init("pct"))
        pct.title = "%"
        pct.width = 34; pct.minWidth = 30; pct.maxWidth = 44
        let files = NSTableColumn(identifier: .init("files"))
        files.title = String(localized: "Files")
        files.width = 60; files.minWidth = 44; files.maxWidth = 84
        files.sortDescriptorPrototype = ListOrder(key: .files, ascending: false).descriptor

        outline.addTableColumn(name)
        outline.addTableColumn(size)
        outline.addTableColumn(pct)
        outline.addTableColumn(files)
        outline.outlineTableColumn = name
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.sortDescriptors = [ListOrder.engine.descriptor]
        showSortIndicator(outline, for: .engine)
    }

    /// The header's arrow and highlight. AppKit draws them for a header
    /// click but not for sort descriptors set in code, such as the default.
    static func showSortIndicator(_ outline: NSOutlineView, for order: ListOrder) {
        let arrow = NSImage(named: order.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator")
        for column in outline.tableColumns {
            let sorted = column.identifier.rawValue == order.key.rawValue
            outline.setIndicatorImage(sorted ? arrow : nil, in: column)
            if sorted { outline.highlightedTableColumn = column }
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = OutlineView()
        let coord = context.coordinator
        outline.coordinator = coord
        Self.configure(outline)

        coord.model = model
        coord.outline = outline
        outline.dataSource = coord
        outline.delegate = coord
        outline.target = coord
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        coord.rebuildIfNeeded()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.rebuildIfNeeded()
        context.coordinator.syncSelection()
    }
}

private extension View {
    /// The breadcrumbs are the title; drop the duplicate window title.
    @ViewBuilder
    func hidingWindowTitle() -> some View {
        if #available(macOS 15, *) {
            toolbar(removing: .title)
        } else {
            navigationTitle("")
        }
    }
}

// MARK: search toolbar & results

struct SearchToolbarField: View {
    @Bindable var model: ScanModel
    @Binding var showTable: Bool
    @FocusState.Binding var isFocused: Bool
    @State private var isPopoverPresented: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
                .accessibilityHidden(true)

            TextField(String(localized: "Search"), text: $model.searchQuery)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .frame(width: 140)
                .onSubmit(submitSearch)

            if !model.searchQuery.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }

            if model.isSearching {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .disabled(model.tree == nil)
        .help("Filter by name (*, ? wildcards, ⌘F)")
        .onChange(of: isFocused) {
            if isFocused && !model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty && model.tree != nil {
                isPopoverPresented = true
            }
        }
        .onChange(of: model.searchQuery) {
            let trimmed = model.searchQuery.trimmingCharacters(in: .whitespaces)
            isPopoverPresented = !trimmed.isEmpty && model.tree != nil
        }
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            SearchResultsPopover(model: model, showTable: $showTable, isPresented: $isPopoverPresented)
        }
    }

    private func submitSearch() {
        if let first = model.searchResults.first {
            showTable = true
            model.reveal(first)
        }
    }

    private func clearSearch() {
        model.searchQuery = ""
        isPopoverPresented = false
    }
}

struct SearchResultsPopover: View {
    let model: ScanModel
    @Binding var showTable: Bool
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let tree = model.tree {
                if model.searchResults.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        if model.isSearching {
                            ProgressView()
                            Text(String(localized: "Searching…"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 24))
                                .foregroundStyle(.tertiary)
                            Text(String(localized: "No matching files or folders"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.searchResults, id: \.self) { node in
                                SearchResultRow(
                                    tree: tree,
                                    node: node,
                                    isSelected: model.selection == node
                                ) {
                                    showTable = true
                                    model.reveal(node)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    }
                }
            }
        }
        .frame(width: 440, height: 380)
    }

    private var headerText: String {
        if model.searchResults.isEmpty {
            return String(localized: "No matches")
        }
        let shown = Fmt.num(UInt64(model.searchResults.count))
        let total = Fmt.num(model.searchTotalMatches)
        if model.searchResults.count < Int(model.searchTotalMatches) {
            return String(format: String(localized: "Showing %1$@ of %2$@ matches"), shown, total)
        } else {
            return String(format: String(localized: "%@ matches"), total)
        }
    }

    private var header: some View {
        HStack {
            Text(headerText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(localized: "Largest first"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SearchResultRow: View {
    let tree: Tree
    let node: Int
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: tree.isDir(node) ? "folder.fill" : "doc")
                    .foregroundStyle(tree.isDir(node) ? Color.accentColor : Color.secondary)
                    .font(.system(size: 14))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tree.name(node))
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                        Spacer()
                        Text(Fmt.size(tree.alloc[node]))
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    }
                    Text(tree.displayPath(node))
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.clear)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Space by file type in the folder on screen (WizTree's Extensions tab).
/// Picking a row lights that type's files in the treemap.
struct TypesPanel: View {
    let model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("File Types")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(localized: "Largest first"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let tree = model.tree, model.typesRoot < tree.count {
                let total = max(tree.alloc[model.typesRoot], 1)
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.typeRows) { row in
                            TypeRowView(row: row, fraction: Double(row.alloc) / Double(total),
                                        isSelected: model.selectedType == row.ext) {
                                model.selectedType = model.selectedType == row.ext ? nil : row.ext
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                }
                if model.selectedType != nil && model.mapStyle == .rings {
                    Text("Highlighting shows in the treemap")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(8)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct TypeRowView: View {
    let row: TypeRow
    let fraction: Double
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let kind = row.kind
        Button(action: onSelect) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(nsColor: NSColor(deviceRed: kind.color.r, green: kind.color.g, blue: kind.color.b, alpha: 1)))
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.ext.isEmpty ? String(localized: "No extension") : "." + row.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !row.ext.isEmpty {
                        Text(kind.name)
                            .font(.system(size: 10))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Fmt.size(row.alloc)) · \(String(format: "%.1f%%", 100 * fraction))")
                        .font(.system(size: 11))
                        .monospacedDigit()
                    Text("\(Fmt.num(row.files)) files")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                // Share of the folder, as a bar behind the row.
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07))
                        .frame(width: isSelected ? g.size.width : g.size.width * min(1, fraction))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSelected ? String(localized: "Click to stop highlighting") : String(localized: "Highlight these files in the treemap"))
    }
}

