import AppKit
import SwiftUI
import Foundation
import Observation

/// Zero-copy view over the Rust engine's flat tree arrays.
/// Read-only after init, so sharing it across threads is safe.
nonisolated final class Tree: @unchecked Sendable {
    private let handle: OpaquePointer
    let count: Int
    let parents: UnsafePointer<UInt32>
    let alloc: UnsafePointer<UInt64>
    let logical: UnsafePointer<UInt64>
    let nFiles: UnsafePointer<UInt32>
    let flags: UnsafePointer<UInt8>
    /// Per node: everything below it was read (see `bz_complete`).
    let complete: UnsafePointer<Bool>
    let childOff: UnsafePointer<UInt32>
    let childArr: UnsafePointer<UInt32>
    let nameOff: UnsafePointer<UInt32>
    let nameBlob: UnsafePointer<UInt8>
    let cleanupCount: Int
    let cleanupNodes: UnsafePointer<UInt32>
    let errors: UInt64
    /// What the scan could not read: the account the CLI prints as `coverage`.
    let coverage: BzCoverage

    init?(handle: OpaquePointer) {
        let n = bz_take_tree(handle)
        var coverage = BzCoverage()
        guard n > 0,
              let parents = bz_parents(handle),
              let alloc = bz_alloc(handle),
              let logical = bz_logical(handle),
              let nFiles = bz_nfiles(handle),
              let flags = bz_flags(handle),
              let complete = bz_complete(handle),
              bz_coverage(handle, &coverage),
              let childOff = bz_child_off(handle),
              let childArr = bz_children(handle),
              let nameOff = bz_name_off(handle),
              let nameBlob = bz_name_blob(handle),
              let cleanupNodes = bz_cleanup_nodes(handle)
        else { return nil }
        self.handle = handle
        self.count = Int(n)
        self.parents = parents
        self.alloc = alloc
        self.logical = logical
        self.nFiles = nFiles
        self.flags = flags
        self.complete = complete
        self.coverage = coverage
        self.childOff = childOff
        self.childArr = childArr
        self.nameOff = nameOff
        self.nameBlob = nameBlob
        self.cleanupCount = Int(bz_cleanup_count(handle))
        self.cleanupNodes = cleanupNodes
        self.errors = bz_errors(handle)
    }

    deinit { bz_free(handle) }

    /// A new tree without `nodes` and what is under them, sizes and file
    /// counts of their ancestors reduced to match. This tree is not touched:
    /// the UI keeps reading it until it swaps the new one in. Nil if the
    /// engine could not build one.
    func removing(_ nodes: [Int]) -> Tree? {
        let ids = nodes.filter { $0 > 0 && $0 < count }.map { UInt32($0) }
        guard let next = ids.withUnsafeBufferPointer({ bz_remove(handle, $0.baseAddress, UInt32($0.count)) }) else { return nil }
        guard let tree = Tree(handle: next) else {
            bz_free(next)
            return nil
        }
        return tree
    }

    func isDir(_ i: Int) -> Bool { flags[i] & 1 != 0 }

    /// The node's own listing was partial (an unreadable entry, a skipped
    /// cloud or mounted folder, a name dropped), whatever its subtree holds.
    func isPartlyRead(_ i: Int) -> Bool { flags[i] & 2 != 0 }

    /// Why a node's size is only a lower bound, in the user's language; nil
    /// when everything in it was read. The list and the maps show this.
    func coverageNote(_ i: Int) -> String? {
        if isPartlyRead(i) {
            return String(localized: "Not fully read: some items in this folder could not be read or were skipped")
        }
        if !complete[i] {
            return String(localized: "Contains folders that were not fully read, so its size is a lower bound")
        }
        return nil
    }

    func cleanupDescription(_ index: Int) -> String {
        guard let label = bz_cleanup_description(handle, UInt64(index)) else { return "" }
        return String(cString: label)
    }

    /// Stable rule id ("node_modules", "git_worktree", ...); "" out of range.
    func cleanupKindID(_ index: Int) -> String {
        guard let id = bz_cleanup_kind_id(handle, UInt64(index)) else { return "" }
        return String(cString: id)
    }

    /// Section id ("build", "packages", ...); "" out of range.
    func cleanupSectionID(_ index: Int) -> String {
        guard let id = bz_cleanup_section_id(handle, UInt64(index)) else { return "" }
        return String(cString: id)
    }

    /// 0 safe, 1 review, 255 out of range. Anything but 0 must be treated as review.
    func cleanupGroup(_ index: Int) -> UInt8 {
        bz_cleanup_group(handle, UInt64(index))
    }

    /// Check required before acting: "" none, else a verifier id. nil out of
    /// range, so a missing answer never reads as "no check needed".
    func cleanupVerify(_ index: Int) -> String? {
        bz_cleanup_verify(handle, UInt64(index)).map { String(cString: $0) }
    }

    func name(_ i: Int) -> String { String(decoding: nameBytes(i), as: UTF8.self) }

    /// The name's UTF-8, borrowed from the tree.
    func nameBytes(_ i: Int) -> UnsafeBufferPointer<UInt8> {
        let start = Int(nameOff[i])
        let end = Int(nameOff[i + 1])
        return UnsafeBufferPointer(start: nameBlob + start, count: end - start)
    }

    func children(_ i: Int) -> UnsafeBufferPointer<UInt32> {
        let start = Int(childOff[i])
        let end = Int(childOff[i + 1])
        return UnsafeBufferPointer(start: childArr + start, count: end - start)
    }

    /// The `limit` largest files anywhere in the scan, largest first. Chosen by
    /// the engine (the CLI's `largest_files` uses the same code).
    func largestFiles(limit: Int = 1000, minBytes: UInt64 = 0) -> [Int] {
        guard let list = bz_largest_files(handle, UInt32(limit), minBytes) else { return [] }
        defer { bz_largest_free(list) }
        let count = Int(bz_largest_count(list))
        guard count > 0, let ptr = bz_largest_nodes(list) else { return [] }
        return (0..<count).map { Int(ptr[$0]) }
    }

    /// Search all nodes matching `query` (substring or wildcards with * and ?),
    /// returning the total match count and up to `limit` node indices sorted largest first.
    func search(query: String, limit: Int = 1000) -> (total: UInt64, nodes: [Int]) {
        let decomposed = query.decomposedStringWithCanonicalMapping
        guard let s = decomposed.cString(using: .utf8),
              let search = bz_search(handle, s, UInt32(limit)) else {
            return (0, [])
        }
        defer { bz_search_free(search) }
        let total = bz_search_total_matches(search)
        let count = Int(bz_search_result_count(search))
        guard count > 0, let ptr = bz_search_result_nodes(search) else {
            return (total, [])
        }
        var nodes = [Int]()
        nodes.reserveCapacity(count)
        for i in 0..<count {
            nodes.append(Int(ptr[i]))
        }
        return (total, nodes)
    }

    /// Allocated bytes and file counts per extension under `root`, largest
    /// first, totalled by the engine in one pass over the files.
    func types(root: Int) -> [TypeRow] {
        guard root >= 0, root < count, let t = bz_types(handle, UInt32(root)) else { return [] }
        defer { bz_types_free(t) }
        let n = Int(bz_types_count(t))
        guard n > 0, let off = bz_types_ext_off(t), let blob = bz_types_ext_blob(t),
              let alloc = bz_types_alloc(t), let files = bz_types_files(t) else { return [] }
        return (0..<n).map { i in
            let ext = Array(UnsafeBufferPointer(start: blob + Int(off[i]), count: Int(off[i + 1] - off[i])))
            return TypeRow(ext: ext, alloc: alloc[i], files: files[i])
        }
    }

    /// Human-facing path: the Data-volume firmlink prefix reads as "/".
    func displayPath(_ i: Int) -> String { Self.displayPath(path(i)) }

    static func displayPath(_ p: String) -> String {
        let prefix = "/System/Volumes/Data"
        if p.hasPrefix(prefix) {
            let rest = String(p.dropFirst(prefix.count))
            return rest.isEmpty ? "/" : rest
        }
        return p
    }

    /// Full path: root's name is the scanned path itself.
    func path(_ i: Int) -> String {
        var parts: [String] = []
        var cur = i
        while cur != 0 {
            parts.append(name(cur))
            cur = Int(parents[cur])
            if cur == Int(UInt32.max) { break }
        }
        var p = name(0)
        if p.hasSuffix("/") { p.removeLast() }
        for part in parts.reversed() { p += "/" + part }
        return p
    }

    /// Chain of ancestors from root to node (inclusive), for breadcrumbs.
    func ancestry(_ i: Int) -> [Int] {
        var chain = [i]
        var cur = i
        while cur != 0 && cur != Int(UInt32.max) {
            cur = Int(parents[cur])
            chain.append(cur)
        }
        return chain.reversed()
    }

    /// What a map draws for `node`: itself, or when it has no shape of its
    /// own (merged into an "A ▸ B" box, too deep for the rings) the nearest
    /// drawn folder that is mostly it. Nil when only a much larger folder is.
    func drawn(_ node: Int, isDrawn: (Int) -> Bool) -> Int? {
        var cur = node
        while !isDrawn(cur) {
            let parent = parents[cur]
            guard parent != UInt32.max, alloc[Int(parent)] <= 2 * alloc[node] else { return nil }
            cur = Int(parent)
        }
        return cur
    }
}

/// One extension's share of a folder. `ext` is ASCII-lowercased bytes
/// without the dot, empty for files without an extension.
nonisolated struct TypeRow: Sendable, Identifiable {
    let ext: [UInt8]
    let alloc: UInt64
    let files: UInt64
    var id: [UInt8] { ext }
    var name: String { String(decoding: ext, as: UTF8.self) }
    /// Its colour group, from the table the treemap paints with.
    var kind: TypeColor.Kind { TypeColor.kind(ofExtension: name) }
}

enum FDA {
    /// FDA-protected paths deny silently (no dialog), so probing is safe.
    static func isActive() -> Bool {
        let home = NSHomeDirectory()
        for p in ["\(home)/Library/Messages", "\(home)/Library/Mail", "\(home)/Library/Safari"] {
            if (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil {
                return true
            }
        }
        return false
    }

    @MainActor
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }
}

/// How the scan is drawn: WizTree-style boxes or DaisyDisk-style rings.
enum MapStyle: String {
    case treemap, rings
}

/// What to scan when BlitzTree opens.
enum LaunchTarget: String, CaseIterable, Identifiable, Sendable {
    case macintoshHD = "macintosh_hd"
    case home = "home"
    case prompt = "prompt"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .macintoshHD: return String(localized: "Scan Macintosh HD")
        case .home: return String(localized: "Scan Home folder")
        case .prompt: return String(localized: "Choose folder…")
        }
    }
}

@Observable
@MainActor
final class ScanModel {
    var files: UInt64 = 0
    var dirs: UInt64 = 0
    var bytes: UInt64 = 0
    var scanning = false
    /// The last scan ended without a tree (the engine failed, or could not
    /// start). `scanning` is false again, so a new scan is allowed; cleared
    /// when one starts.
    private(set) var scanFailed = false
    /// The last scan was stopped by the user and there is no earlier tree to
    /// fall back on. Cleared when a scan starts. (With an earlier tree, that
    /// tree is simply shown again.)
    private(set) var scanCancelled = false
    /// Stop was pressed and the engine is winding the scan down; `scanning`
    /// stays true until it reports done.
    private(set) var stopping = false
    var elapsed: Double = 0
    /// The tree on screen. Node numbers belong to the tree that made them:
    /// a rescan or a removal renumbers, so every replacement goes through
    /// `treeChanged` before anything reads the new one.
    var tree: Tree? {
        didSet { if tree !== oldValue { treeChanged() } }
    }
    /// Bumped on every tree replacement. Views key node-indexed caches on it
    /// (a freed tree's address can come back, so its identity cannot).
    private(set) var treeGeneration: UInt64 = 0
    var scanRoot: String = {
        // `BlitzTree /some/path` scans that path on launch (also handy for QA).
        if CommandLine.arguments.count > 1 {
            var isDir: ObjCBool = false
            let p = (CommandLine.arguments[1] as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                return p
            }
        }
        let target = LaunchTarget(rawValue: UserDefaults.standard.string(forKey: "bz.launchTarget") ?? "") ?? .macintoshHD
        if target == .home {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        // Whole disk by default: the user-data volume of the boot volume group.
        return "/System/Volumes/Data"
    }()
    /// What to scan at application launch.
    var launchTarget: LaunchTarget = LaunchTarget(rawValue: UserDefaults.standard.string(forKey: "bz.launchTarget") ?? "") ?? .macintoshHD {
        didSet { UserDefaults.standard.set(launchTarget.rawValue, forKey: "bz.launchTarget") }
    }
    /// Automatically plan cleanup with AI after scanning instead of waiting for a click.
    var autoAnalyze: Bool = UserDefaults.standard.bool(forKey: "bz.autoAnalyze") {
        didSet { UserDefaults.standard.set(autoAnalyze, forKey: "bz.autoAnalyze") }
    }
    /// Coding agents found on this Mac (Claude Code, Codex) and the user's PATH.
    var agentEnv = AgentEnvironment()
    /// The agent cleanup on screen, if any.
    var agentRun: AgentRun?
    /// An agent being installed or signed in from the panel.
    var agentSetup: AgentSetup?
    /// The first scan after launch opens the Clean Up panel once.
    private var panelOpenedAfterLaunch = false

    /// Custom providers, for the panel's picker menu. Shared store: settings
    /// edits land here immediately, no refresh wiring needed.
    var providerStore: ProviderStore { ProviderStore.shared }

    /// The planner for the Clean Up panel. `bz.engine` names it: a CLI agent
    /// ("claude", "codex") or a custom provider ("provider:<id>"). Default:
    /// the named agent if ready, else Claude Code, else Codex.
    var preferredAgent: InstalledAgent? {
        let ready = agentEnv.ready
        let picked = UserDefaults.standard.string(forKey: "bz.engine") ?? UserDefaults.standard.string(forKey: "bz.agent")
        if let picked, picked.hasPrefix("provider:") {
            if preferredProvider != nil { return nil }
            // The provider was deleted or is invalid: drop the stale choice
            // and fall back to the ready agents.
            UserDefaults.standard.removeObject(forKey: "bz.engine")
            return ready.first { $0.kind.rawValue == UserDefaults.standard.string(forKey: "bz.agent") }
                ?? ready.first { $0.kind == .claude } ?? ready.first
        }
        return ready.first { $0.kind.rawValue == picked } ?? ready.first { $0.kind == .claude } ?? ready.first
    }

    /// The provider picked in Settings, when `bz.engine` names one.
    var preferredProvider: LLMProvider? {
        guard let picked = UserDefaults.standard.string(forKey: "bz.engine"),
              picked.hasPrefix("provider:") else { return nil }
        let id = String(picked.dropFirst("provider:".count))
        return ProviderStore.shared.providers.first { $0.id == id }
    }

    /// Start the cleanup with whatever the user picked in Settings; with a
    /// focus, ask that planner about one item instead of the whole scan.
    func startCleanup(focus: AgentFocus? = nil) {
        if let provider = preferredProvider { startProvider(provider, focus: focus) }
        else if let agent = preferredAgent { startAgent(agent, focus: focus) }
    }

    /// What answers a right-click question right now, by name; nil when
    /// nothing is set up yet.
    var plannerName: String? { preferredProvider?.displayName ?? preferredAgent?.kind.name }

    /// A run that has started moving or deleting must not be replaced.
    var canStartRun: Bool {
        guard tree != nil, !scanning, !cleanupTrash.running else { return false }
        guard let phase = agentRun?.phase else { return true }
        return ![.trashing, .staged, .deleting].contains(phase)
    }

    /// The right-click menu's "Ask … if it's safe to clean". With nothing
    /// set up, the panel shows the setup offer and the question is answered
    /// once setup finishes.
    func ask(about node: Int) {
        guard let tree, canStartRun, node > 0, node < tree.count else { return }
        let focus = AgentFocus(node: node, tree: tree, known: cleanup)
        selection = node
        // Always ask the window to open the panel: agentRun may already be
        // non-nil, so its own observer would not fire for a replaced run.
        panelRequests += 1
        if plannerName == nil {
            pendingFocus = focus
        } else {
            startCleanup(focus: focus)
        }
    }

    /// A question asked before any planner was ready.
    private var pendingFocus: AgentFocus?

    /// The same item in the scan on screen now, which may be newer than the
    /// one the question was asked from (or no longer contain it).
    private func refocus(_ old: AgentFocus?) -> AgentFocus? {
        guard let old, let tree, let node = tree.node(at: old.path) else { return nil }
        return AgentFocus(node: node, tree: tree, known: cleanup)
    }

    func startProvider(_ provider: LLMProvider, focus: AgentFocus? = nil) {
        guard let tree, canStartRun else { return }
        UserDefaults.standard.set("provider:\(provider.id)", forKey: "bz.engine")
        pendingFocus = nil
        agentRun?.cancel()
        let run = AgentRun(agent: nil, env: agentEnv, tree: tree, scanRoot: scanRoot,
                           known: cleanup, provider: provider, focus: focus) { [weak self] in
            guard let self, !self.scanning else { return }
            self.startScan()
        }
        withAnimation(.snappy) { agentRun = run }
    }

    /// `routes`: MANVI only — one route when the menu picked local or cloud
    /// for this run; nil for Settings' choice (local, then cloud, in auto).
    func startAgent(_ agent: InstalledAgent, focus: AgentFocus? = nil, routes: [Manvi.Route]? = nil) {
        guard let tree, canStartRun else { return }
        UserDefaults.standard.set(agent.kind.rawValue, forKey: "bz.engine")
        UserDefaults.standard.set(agent.kind.rawValue, forKey: "bz.agent")
        pendingFocus = nil
        agentRun?.cancel()
        let run = AgentRun(agent: agent, env: agentEnv, tree: tree, scanRoot: scanRoot, known: cleanup,
                           focus: focus, routes: routes ?? agentEnv.manviRoutes) { [weak self] in
            guard let self, !self.scanning else { return }
            self.startScan()
        }
        withAnimation(.snappy) { agentRun = run }
    }

    /// After the launch scan: open the panel on the Clean Up button or the
    /// setup offer, or automatically start cleanup if autoAnalyze is on.
    func openPanelAfterLaunchScan() {
        guard !panelOpenedAfterLaunch, agentEnv.loaded, tree != nil, !scanning,
              !cleanupTrash.running, agentRun == nil else { return }
        panelOpenedAfterLaunch = true
        if autoAnalyze, (preferredAgent != nil || preferredProvider != nil) {
            startCleanup()
        } else {
            panelRequests += 1
            // QA only: BZ_QA_SETUP=claude|codex presses the setup button.
            if preferredAgent == nil, preferredProvider == nil, ProviderStore.shared.providers.isEmpty, let kind = ProcessInfo.processInfo.environment["BZ_QA_SETUP"].flatMap(AgentKind.init) { setUp(kind) }
        }
    }

    /// Run the same cleanup again: whatever produced this run (CLI agent or
    /// provider), re-planned from the current scan.
    func restart(_ run: AgentRun) {
        // The item asked about may be gone from a newer scan.
        let focus = refocus(run.focus)
        if run.focus != nil && focus == nil { return }
        if let provider = run.provider { startProvider(provider, focus: focus) }
        else if let agent = run.agent { startAgent(agent, focus: focus, routes: run.routes.isEmpty ? nil : run.routes) }
    }

    /// Bumped to ask the window to open the Clean Up panel.
    var panelRequests = 0

    /// Installs and signs in Claude Code or Codex. MANVI is not installed by
    /// BlitzTree: the panel links to Settings for its model instead.
    func setUp(_ kind: AgentKind) {
        guard kind.installable else { return }
        agentSetup?.cancel()
        let installed = agentEnv.agents.first { $0.kind == kind }
        agentSetup = AgentSetup(kind: kind, installed: installed, envPath: agentEnv.path) { [weak self] env in
            guard let self else { return }
            agentEnv = env
            agentSetup = nil
            if let agent = env.ready.first(where: { $0.kind == kind }) {
                // Answer the right-click question that led here, if its
                // scan is still the one on screen.
                startAgent(agent, focus: refocus(pendingFocus))
            }
        }
    }
    /// A tree has been shown at least once, so the views exist (see ContentView).
    var hasShownTree = false
    var viewRoot: Int = 0 {
        didSet {
            // A selection outside the folder on screen would read as over 100%.
            if let sel = selection, let tree, !tree.ancestry(sel).contains(viewRoot) { selection = nil }
            if viewRoot != oldValue { refreshTypes() }
        }
    }
    var selection: Int? = nil

    /// Select a node from a list, zooming out first if it is outside the
    /// folder on screen (it would have nothing to outline).
    func reveal(_ node: Int) {
        if let tree, !tree.ancestry(node).contains(viewRoot) { viewRoot = 0 }
        selection = node
    }
    var hovered: Int? = nil
    var freeBytes: UInt64 = 0
    /// Volumes the Scan menu lists; kept current by `watchVolumes`.
    var volumes: [ScanVolume] = [.bootFallback]
    private var volumeObservers: [NSObjectProtocol] = []
    private var volumeListGeneration: UInt64 = 0

    /// Lists mounted volumes now and again whenever one mounts, unmounts or
    /// is renamed.
    func watchVolumes() {
        guard volumeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }
        refreshVolumes()
    }

    /// Re-reads the volume list off the main thread: a slow disk spinning
    /// up must not stall the window. The newest request wins.
    func refreshVolumes() {
        volumeListGeneration &+= 1
        let generation = volumeListGeneration
        Task {
            let found = await Task.detached(priority: .utility) { ScanVolume.mounted() }.value
            guard generation == volumeListGeneration else { return }
            volumes = found
        }
    }
    /// Rebuildable folders worth deleting, largest first.
    var cleanup: [CleanupItem] = []
    let cleanupTrash = CleanupTrashBatch()
    /// Volume-used minus what the scan could see: root-only territory.
    var unscannedBytes: UInt64 = 0
    /// What the scan counted beyond the volume's used space.
    var overcountedBytes: UInt64 = 0
    var showFreeSpace: Bool = UserDefaults.standard.bool(forKey: "bz.showFree") {
        didSet { UserDefaults.standard.set(showFreeSpace, forKey: "bz.showFree") }
    }
    var mapStyle: MapStyle = MapStyle(rawValue: UserDefaults.standard.string(forKey: "bz.mapStyle") ?? "") ?? .treemap {
        didSet { UserDefaults.standard.set(mapStyle.rawValue, forKey: "bz.mapStyle") }
    }

    // MARK: search
    var searchQuery: String = "" {
        didSet {
            performSearch()
        }
    }
    var searchResults: [Int] = []
    var searchTotalMatches: UInt64 = 0
    var isSearching: Bool = false
    private var searchTask: Task<Void, Never>?

    func performSearch() {
        searchTask?.cancel()
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let tree else {
            searchResults = []
            searchTotalMatches = 0
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task.detached(priority: .userInitiated) { [tree, q] in
            let (total, nodes) = tree.search(query: q, limit: 1000)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.searchQuery.trimmingCharacters(in: .whitespaces) == q, self.tree === tree else { return }
                self.searchResults = nodes
                self.searchTotalMatches = total
                self.isSearching = false
            }
        }
    }


    // MARK: file types

    var showTypes: Bool = UserDefaults.standard.bool(forKey: "bz.showTypes") {
        didSet {
            UserDefaults.standard.set(showTypes, forKey: "bz.showTypes")
            refreshTypes()
        }
    }
    /// Extensions under `typesRoot`, largest first; empty while hidden.
    var typeRows: [TypeRow] = []
    /// The folder `typeRows` describes: the view root they were made for.
    var typesRoot: Int = 0
    /// The extension picked in the list (see `TypeRow.ext`).
    var selectedType: [UInt8]?
    /// What the treemap highlights: the picked type while the list is shown.
    var highlightedType: [UInt8]? { showTypes ? selectedType : nil }
    private var typesTask: Task<Void, Never>?

    /// Re-total the folder on screen, off the main thread. Only while the
    /// list is shown; a zoom or a new tree calls this again.
    func refreshTypes() {
        typesTask?.cancel()
        guard showTypes, let tree else {
            typeRows = []
            return
        }
        let root = viewRoot
        typesTask = Task.detached(priority: .userInitiated) { [tree] in
            let rows = tree.types(root: root)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.tree === tree, self.viewRoot == root, self.showTypes else { return }
                self.typeRows = rows
                self.typesRoot = root
                // A type with no files in this folder has nothing to light.
                if let picked = self.selectedType, !rows.contains(where: { $0.ext == picked }) {
                    self.selectedType = nil
                }
            }
        }
    }

    private var handle: OpaquePointer?
    private var timer: Timer?
    private var startedAt: Date?
    private var activity: NSObjectProtocol?
    private var volumeTask: Task<VolumeSpace, Never>?
    /// Distinguishes a delayed capacity result from the scan that superseded it.
    private var scanGeneration: UInt64 = 0

    /// What was on screen when a scan started, kept so that stopping the scan
    /// puts it back. Costs one extra tree in memory while the new scan runs.
    private struct Previous {
        let tree: Tree
        let scanRoot: String
        let freeBytes: UInt64
        let unscannedBytes: UInt64
        let overcountedBytes: UInt64
        let elapsed: Double
    }
    private var previous: Previous?

    func startScan(path: String? = nil) {
        if scanning || cleanupTrash.running { return }
        previous = tree.map {
            Previous(tree: $0, scanRoot: scanRoot, freeBytes: freeBytes, unscannedBytes: unscannedBytes,
                     overcountedBytes: overcountedBytes, elapsed: elapsed)
        }
        if let path { scanRoot = path }
        scanGeneration &+= 1
        tree = nil
        selectedType = nil
        // Capacity is unknown until the snapshot for this scan arrives.
        freeBytes = 0
        unscannedBytes = 0
        overcountedBytes = 0
        files = 0; dirs = 0; bytes = 0; elapsed = 0
        lastPollAt = nil; maxPollGap = 0
        scanFailed = false
        scanCancelled = false
        stopping = false
        scanning = true
        startedAt = Date()
        // Keep the process out of App Nap / timer coalescing while scanning.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Disk scan"
        )
        // Foundation may ask a disk-management service about purgeable space.
        // Read it alongside the scan; its result is applied after the tree is
        // visible so a slow service cannot delay the first useful frame.
        let volumePath = scanRoot
        volumeTask = Task.detached(priority: .userInitiated) { VolumeSpace.read(volumePath) }
        guard let started = bz_scan_start(scanRoot) else {
            // No handle means no scan to poll: end it here, as failed.
            volumeTask?.cancel()
            volumeTask = nil
            finishScan(nil, generation: scanGeneration, doneAt: Date())
            return
        }
        handle = started

        // 60 Hz: the elapsed time ticks every frame, so the screen keeps
        // moving while the engine assembles the tree after the last file is
        // counted (the counters sit still for that part).
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // Common modes: keep polling while a control is being clicked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops the scan under way. The engine reads no further folder and
    /// reports done at once; the tree that was on screen before the scan (if
    /// any) comes back, otherwise the window says the scan was stopped. A
    /// no-op when nothing is scanning or a stop is already on its way.
    func stopScan() {
        guard scanning, !stopping, let handle else { return }
        stopping = true
        bz_cancel(handle)
    }

    private var lastPollAt: Date?
    private var maxPollGap: Double = 0

    private func poll() {
        guard let handle else { return }
        if let last = lastPollAt { maxPollGap = max(maxPollGap, -last.timeIntervalSinceNow) }
        lastPollAt = Date()
        var f: UInt64 = 0, d: UInt64 = 0, b: UInt64 = 0
        var done: Int32 = 0
        bz_progress(handle, &f, &d, &b, &done)
        files = f; dirs = d; bytes = b
        elapsed = -(startedAt?.timeIntervalSinceNow ?? 0)
        if done != 0 {
            let doneAt = Date()
            let generation = scanGeneration
            // Read before the tree is taken: a stopped scan and a failed one
            // both have none, and only one of them is an error.
            let stopped = bz_scan_status(handle) == Int32(BZ_SCAN_CANCELLED)
            let result = stopped ? nil : Tree(handle: handle)
            self.handle = nil
            if result == nil { bz_free(handle) }
            let pendingVolume = volumeTask
            volumeTask = nil
            if stopped {
                // The volume figures belong to a tree that will not arrive.
                pendingVolume?.cancel()
                finishScan(nil, stopped: true, generation: generation, doneAt: doneAt)
                return
            }
            finishScan(result, generation: generation, doneAt: doneAt)
            Task { [weak self] in
                let space = await pendingVolume?.value ?? VolumeSpace(free: nil, used: nil)
                // The generation identifies the scan; do not capture `result`
                // here, or a large tree would live for the whole volume query.
                self?.applyVolume(space, generation: generation)
            }
        }
    }

    private func finishScan(_ result: Tree?, stopped: Bool = false, generation: UInt64, doneAt: Date) {
        guard generation == scanGeneration else { return }
        timer?.invalidate()
        timer = nil
        let earlier = previous
        previous = nil
        if stopped {
            // Logged first: `elapsed` is about to be the earlier scan's.
            NSLog("BZ scan stopped after %.2f s, %llu files read", elapsed, files)
            // Back to what was on screen, or an idle window that says so.
            scanFailed = false
            if let earlier {
                scanRoot = earlier.scanRoot
                freeBytes = earlier.freeBytes
                unscannedBytes = earlier.unscannedBytes
                overcountedBytes = earlier.overcountedBytes
                elapsed = earlier.elapsed
                tree = earlier.tree
            } else {
                scanCancelled = true
            }
        } else {
            tree = result
            scanFailed = result == nil
        }
        if tree != nil { hasShownTree = true }
        if ProcessInfo.processInfo.environment["BZ_TIMING"] != nil {
            // Queue latency includes awaiting metadata and UI updates; it is
            // not a measurement of uninterrupted main-thread blocking.
            DispatchQueue.main.async {
                NSLog("BZ hand-off: queued completion %.1f ms after engine done", -doneAt.timeIntervalSinceNow * 1000)
            }
            NSLog("BZ done at %.3f, longest gap between polls %.1f ms", doneAt.timeIntervalSinceReferenceDate, maxPollGap * 1000)
        }
        scanning = false
        stopping = false
        // Used and free change as files come and go; the menu is usable again.
        refreshVolumes()
        if let tree {
            refreshForNewTree(tree)
            NSLog("BZ scan done: %llu nodes, %llu unreadable dirs", UInt64(tree.count), tree.errors)
            // Items trashed while the walk ran may be in it.
            if !deletedPaths.isEmpty { forget(paths: []) }
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// The one place node-indexed state is dropped when the tree is replaced,
    /// in the same main-actor turn as the swap: nothing computed from the old
    /// tree is ever read against the new one. Runs for rescans, removals and
    /// any other assignment. Callers that keep the zoom or selection (by
    /// path) set them again afterwards.
    private func treeChanged() {
        treeGeneration &+= 1
        searchTask?.cancel()
        searchResults = []
        searchTotalMatches = 0
        isSearching = false
        cleanup = []
        typesTask?.cancel()
        typeRows = []
        typesRoot = 0
        // Selection first: viewRoot's didSet reads it against the new tree.
        selection = nil
        hovered = nil
        viewRoot = 0
    }

    /// Redoes what is keyed by node numbers (Clean Up candidates, search hits,
    /// file types) for a tree just installed.
    private func refreshForNewTree(_ tree: Tree) {
        Task {
            let found = await Task.detached(priority: .userInitiated) { Cleanup.find(in: tree) }.value
            // A rescan may have replaced the tree while discovery ran.
            // Node IDs only belong to the scan that produced them.
            guard self.tree === tree else { return }
            cleanup = found
            openPanelAfterLaunchScan()
        }
        if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            performSearch()
        }
        refreshTypes()
    }

    // MARK: removing deleted items

    /// Paths moved to the Trash (or deleted) that the tree still shows.
    private var deletedPaths: [String] = []
    private var removalTask: Task<Void, Never>?

    /// Takes just-deleted paths out of the tree on screen, instead of a full
    /// rescan (10–14 s on a whole disk). The engine builds a new tree without
    /// them; sizes above them drop by their allocated bytes. Calls overlap
    /// safely: paths that arrive while one is being built are applied to the
    /// result, one after another. Awaiting `settled()` waits for all of them.
    /// Paths handed over while a rescan runs are applied to the tree it
    /// delivers: the walk may have listed them before they went.
    ///
    /// The agent run still rescans when it finishes: besides the folders it
    /// trashes it runs tool commands (cache cleanups) whose affected paths
    /// are not known, so only a scan shows what they freed.
    func forget(paths: [String]) {
        deletedPaths += paths
        guard removalTask == nil else { return }
        removalTask = Task {
            await drainDeletedPaths()
            removalTask = nil
        }
    }

    /// Returns once every path handed to `forget` is out of the tree.
    func settled() async { await removalTask?.value }

    private func drainDeletedPaths() async {
        while !deletedPaths.isEmpty {
            guard let old = tree else {
                // A scan under way may already have walked past them: keep
                // them for the tree it delivers (see finishScan). With no
                // scan there is no tree to take them out of.
                if !scanning { deletedPaths = [] }
                return
            }
            // Only what is still gone: a path kept for a later tree may hold
            // something new by the time that tree lands.
            let paths = deletedPaths.filter { !Self.exists($0) }
            deletedPaths = []
            let nodes = paths.compactMap { old.node(at: $0) }.filter { $0 > 0 }
            if nodes.isEmpty { continue }
            let next = await Task.detached(priority: .userInitiated) { old.removing(nodes) }.value
            guard tree === old else {
                // Replaced meanwhile (a rescan started or landed): apply them
                // to the tree on screen next.
                deletedPaths = paths + deletedPaths
                continue
            }
            guard let next else {
                // No new tree: a stale map is worse than waiting for a scan.
                startScan()
                return
            }
            install(removalResult: next, replacing: old)
        }
    }

    /// Whether anything is at `path`, a dangling symlink included.
    private nonisolated static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Swaps in the tree without the deleted items and keeps what the user
    /// was looking at: the zoomed folder and the selection by path (nearest
    /// surviving folder when theirs went), nothing hovered.
    private func install(removalResult next: Tree, replacing old: Tree) {
        let rootPath = old.ancestry(viewRoot).reversed().lazy.compactMap { next.node(at: old.path($0)) }.first
        let kept = selection.flatMap { next.node(at: old.path($0)) }
        tree = next
        selection = kept
        viewRoot = rootPath ?? 0
        refreshForNewTree(next)
    }

    /// Applies capacity only to the tree and scan generation that requested it.
    /// A rescan may finish while an older volume service call is still pending.
    private func applyVolume(_ space: VolumeSpace, generation: UInt64) {
        guard generation == scanGeneration, let tree else { return }
        freeBytes = space.free ?? 0
        // Coverage honesty: compare scanned bytes with what the volume
        // says it holds. The difference is root-only space (Spotlight
        // index, unified logs, …) no unelevated app can read.
        unscannedBytes = 0
        overcountedBytes = 0
        if let used = space.used {
            let seen = tree.alloc[0]
            if used > seen {
                unscannedBytes = used - seen
            } else {
                // More than the volume holds: data shared between paths that
                // the engine could not attribute once (clones edited after
                // copying). Said out loud rather than shown as full coverage.
                overcountedBytes = seen - used
            }
        }
    }
}

nonisolated struct VolumeSpace: Sendable {
    let free: UInt64?
    let used: UInt64?

    static func read(_ path: String) -> VolumeSpace {
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return VolumeSpace(
            free: free(important: values?.volumeAvailableCapacityForImportantUsage,
                       available: values?.volumeAvailableCapacity),
            used: path == "/System/Volumes/Data" ? volumeUsedBytes(path) : nil
        )
    }

    /// Free space as Finder counts it. APFS adds purgeable space to the
    /// important-usage figure; exFAT, FAT and NTFS answer it with 0, so
    /// those fall back to the plain free count.
    static func free(important: Int64?, available: Int?) -> UInt64? {
        if let important, important > 0 { return UInt64(important) }
        if let available { return UInt64(max(0, available)) }
        return important.map { UInt64(max(0, $0)) }
    }
}

/// A mounted volume the Scan menu offers.
nonisolated struct ScanVolume: Sendable, Equatable, Identifiable {
    let name: String
    /// What scanning this volume reads.
    let path: String
    let isInternal: Bool
    let total: UInt64
    let free: UInt64
    var used: UInt64 { total > free ? total - free : 0 }
    var id: String { path }

    static let bootDataPath = "/System/Volumes/Data"
    /// Shown until the first enumeration finishes, or if it finds nothing.
    static let bootFallback = ScanVolume(
        name: String(localized: "Macintosh HD"), path: bootDataPath, isInternal: true, total: 0, free: 0)

    /// One mount as plain values, so the menu's rules can be checked
    /// without the mount existing.
    struct Facts: Sendable {
        var path: String
        var name: String?
        var isRootFileSystem = false
        var isLocal = true
        var isBrowsable = true
        var isInternal: Bool?
        var total: Int?
        var available: Int?
        var availableForImportantUsage: Int64?
    }

    init(name: String, path: String, isInternal: Bool, total: UInt64, free: UInt64) {
        self.name = name; self.path = path; self.isInternal = isInternal
        self.total = total; self.free = free
    }

    init?(_ facts: Facts) {
        // Hidden mounts (VM, Preboot, Recovery, cryptexes, autofs) are
        // system plumbing, not something to scan.
        guard facts.isBrowsable else { return nil }
        // Network shares are left out; Choose Folder… still reaches them.
        // Each directory read is a server round trip, so the engine's
        // parallel walk turns a large share into a long scan that loads the
        // server, and a stalled share can hang the read entirely. The
        // capacity a server reports may be a quota rather than its disk.
        guard facts.isLocal else { return nil }
        if facts.isRootFileSystem {
            // `/` is the sealed system snapshot; the user's data is on the
            // Data volume, which is what Macintosh HD scans everywhere else.
            name = String(localized: "Macintosh HD")
            path = Self.bootDataPath
            isInternal = true
        } else {
            name = facts.name ?? (facts.path as NSString).lastPathComponent
            path = facts.path
            isInternal = facts.isInternal ?? false
        }
        total = UInt64(max(0, facts.total ?? 0))
        free = min(total, VolumeSpace.free(important: facts.availableForImportantUsage,
                                           available: facts.available) ?? 0)
    }

    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey,
        .volumeIsBrowsableKey, .volumeIsInternalKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ]

    /// Mounted local volumes, the boot volume first. Reads every mount's
    /// metadata, so call it off the main thread.
    static func mounted() -> [ScanVolume] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.compactMap { url -> ScanVolume? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return ScanVolume(Facts(
                path: url.path, name: v.volumeLocalizedName,
                isRootFileSystem: v.volumeIsRootFileSystem ?? false,
                // Unknown counts as remote and hidden: left out, not guessed in.
                isLocal: v.volumeIsLocal ?? false, isBrowsable: v.volumeIsBrowsable ?? false,
                isInternal: v.volumeIsInternal, total: v.volumeTotalCapacity,
                available: v.volumeAvailableCapacity,
                availableForImportantUsage: v.volumeAvailableCapacityForImportantUsage))
        }
        // Macintosh HD stays on the menu even if its mount could not be read.
        let boot = volumes.first { $0.path == bootDataPath } ?? bootFallback
        return [boot] + volumes.filter { $0.path != bootDataPath }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// Space used by this APFS volume alone, the figure `df` shows. statfs and
/// Foundation's systemSize/systemFreeSize describe the whole container,
/// which also holds the macOS system volume, VM swap and Recovery.
nonisolated func volumeUsedBytes(_ path: String) -> UInt64? {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
    var reply = (length: UInt32(0), used: UInt64(0))
    let status = withUnsafeMutableBytes(of: &reply) {
        getattrlist(path, &request, $0.baseAddress, $0.count, 0)
    }
    guard status == 0 else { return nil }
    // Packed buffer: u_int32_t length, then off_t at offset 4 (unaligned).
    return withUnsafeBytes(of: &reply) { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
}

/// The scan's coverage in sentences (the status bar's popover): what the
/// engine could not read or counted once. The same fields the CLI reports.
nonisolated enum CoverageText {
    static func headline(_ c: BzCoverage) -> String {
        c.complete
            ? String(localized: "Every folder was read in full.")
            : String(localized: "Some folders were only partly read, so their sizes are lower bounds.")
    }

    /// One line per thing left unread or counted once; empty when there is none.
    static func lines(_ c: BzCoverage) -> [String] {
        var out: [String] = []
        // `errors` is the total and already holds every entry error and every
        // dropped name; each is listed once, on its own line.
        let listed = c.entry_errors &+ c.invalid_names
        let otherErrors = c.errors > listed ? c.errors - listed : 0
        if otherErrors > 0 {
            out.append(String(localized: "\(Fmt.num(otherErrors)) folders could not be read (permissions, or changed during the scan)"))
        }
        if c.entry_errors > 0 {
            out.append(String(localized: "\(Fmt.num(c.entry_errors)) entries could not be read or were malformed"))
        }
        if c.invalid_names > 0 {
            out.append(String(localized: "\(Fmt.num(c.invalid_names)) items with names that are not valid UTF-8 were left out, with everything inside them"))
        }
        if c.skipped_cloud_directories > 0 {
            out.append(String(localized: "\(Fmt.num(c.skipped_cloud_directories)) cloud-only folders were not opened, so nothing was downloaded"))
        }
        if c.skipped_mount_points > 0 {
            out.append(String(localized: "\(Fmt.num(c.skipped_mount_points)) other volumes mounted inside were not scanned"))
        }
        if c.shared_allocated_bytes > 0 {
            out.append(String(localized: "\(Fmt.size(c.shared_allocated_bytes)) in hard-linked or cloned files is counted once"))
        }
        if c.clone_ids_unavailable_directories > 0 {
            out.append(String(localized: "\(Fmt.num(c.clone_ids_unavailable_directories)) folders are on a volume that does not report clones; cloned files there count in full"))
        }
        return out
    }
}

nonisolated enum Fmt {
    static func size(_ b: UInt64) -> String { Int64(b).formatted(.byteCount(style: .file)) }
    static func num(_ n: UInt64) -> String { n.formatted() }
    /// Like `size`, but always two decimals, so a live counter keeps its width
    /// instead of jumping as trailing zeros drop ("225.5 GB" → "225.57 GB").
    static func fixedSize(_ b: UInt64) -> String {
        let units = ["KB", "MB", "GB", "TB", "PB"]
        guard b >= 1000 else { return size(b) }
        var v = Double(b) / 1000, i = 0
        while v >= 999.995, i < units.count - 1 { v /= 1000; i += 1 }
        return "\(v.formatted(.number.precision(.fractionLength(2)).grouping(.never))) \(units[i])"
    }
}
