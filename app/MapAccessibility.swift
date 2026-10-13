import AppKit

/// What VoiceOver gets from the treemap and the rings.
///
/// Both maps are custom-drawn views, so they describe themselves. Each is a
/// list whose children are the contents of the folder on screen, largest
/// first: a folder or file per row (name, size and share of the folder), a
/// "Back to" row when zoomed in, and a closing row for free space or for the
/// items too small to draw. At most `maxItems` rows are listed, so a folder
/// of 100,000 files stays quick to read; the rest are one "smaller items" row,
/// and zooming in (pressing a folder) reaches whatever is beneath.
///
/// The views supply the geometry (`Host.items`) and what pressing does; this
/// owns the wording, the elements and the notifications, so the two maps say
/// the same things the same way.
@MainActor
final class MapAccessibility {
    /// Most folder or file rows listed for one folder.
    static let maxItems = 200

    enum Kind { case treemap, rings }

    /// One row of the list, in the view's coordinates.
    nonisolated struct Item {
        enum Role {
            case folder, file
            /// Zoom out to `node`, the folder above the one on screen.
            case back
            case free
            /// Items too small to draw (or past `maxItems`), gathered into one.
            case smaller(count: Int)
        }

        var role: Role
        /// The tree node; -1 for free space and -2 for smaller items.
        var node: Int
        var bytes: UInt64
        var rect: CGRect
        /// The tree the row was listed from. Set when the rows are built; an
        /// action on a row from an older tree is refused rather than applied
        /// to whatever node number now means something else.
        var treeGeneration: UInt64 = 0

        var isNode: Bool {
            switch role {
            case .folder, .file: true
            case .back, .free, .smaller: false
            }
        }
    }

    /// What a view lends the list: its geometry and its click behaviour.
    struct Host {
        var model: () -> ScanModel?
        /// The rows for the folder on screen; empty while the layout is stale.
        var items: () -> [Item]
        /// Activates a row as a click would: a folder zooms in, a file is selected.
        var press: (Item) -> Bool
        var select: (Item) -> Void
    }

    /// Notifications go through here so a check can see what VoiceOver would
    /// be told. AppKit drops them when no assistive app is listening.
    static var post: (Any, NSAccessibility.Notification) -> Void = { NSAccessibility.post(element: $0, notification: $1) }
    static var announce: (NSView, String) -> Void = { view, text in
        NSAccessibility.post(element: view, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    /// Building the row to focus costs a pass over the layout; only worth it
    /// when something is listening.
    static var voiceOverRunning: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }

    /// "N smaller items", with its own wording for one. Both maps use this;
    /// the count is at least one, so no zero form is needed.
    static func smallerItems(_ count: Int) -> String {
        count == 1 ? String(localized: "1 smaller item") : String(localized: "\(Fmt.num(UInt64(count))) smaller items")
    }

    private unowned let view: NSView
    private let kind: Kind
    private let host: Host
    private var elements: [Element]?
    /// The selection last announced, and the folder last shown.
    private var announcedSelection: Int?
    private var shownRoot: (generation: UInt64, root: Int)?

    init(view: NSView, kind: Kind, host: Host) {
        self.view = view
        self.kind = kind
        self.host = host
    }

    // ---- The list ----

    var roleDescription: String {
        switch kind {
        case .treemap: String(localized: "Treemap")
        case .rings: String(localized: "Rings")
        }
    }

    var label: String {
        guard let model = host.model(), let tree = model.tree else { return roleDescription }
        let folder = name(of: model.viewRoot, model: model, tree: tree)
        switch kind {
        case .treemap: return String(localized: "Treemap of \(folder)")
        case .rings: return String(localized: "Rings of \(folder)")
        }
    }

    /// The rows, built on first ask after each layout and kept: the vendor
    /// of accessibility elements must own them.
    var children: [Element] {
        if let elements { return elements }
        let built = build()
        elements = built
        return built
    }

    var selectedChildren: [Element] {
        children.filter { $0.isAccessibilitySelected() }
    }

    private func build() -> [Element] {
        guard let model = host.model(), let tree = model.tree else { return [] }
        let rootBytes = max(tree.alloc[model.viewRoot], 1)
        let folder = name(of: model.viewRoot, model: model, tree: tree)
        return host.items().map { listed in
            var item = listed
            item.treeGeneration = model.treeGeneration
            return Element(item: item, title: title(for: item, model: model, tree: tree, folder: folder, rootBytes: rootBytes),
                    owner: self, parent: view)
        }
    }

    private func name(of node: Int, model: ScanModel, tree: Tree) -> String {
        node == 0 ? model.rootDisplayName : tree.name(node)
    }

    private func title(for item: Item, model: ScanModel, tree: Tree, folder: String, rootBytes: UInt64) -> String {
        let size = Fmt.size(item.bytes)
        switch item.role {
        case .folder, .file:
            let share = (Double(item.bytes) / Double(rootBytes)).formatted(.percent.precision(.fractionLength(0...1)))
            return String(localized: "\(tree.name(item.node)), \(size), \(share) of \(folder)")
        case .back:
            return String(localized: "Back to \(name(of: item.node, model: model, tree: tree))")
        case .free:
            let free = String(localized: "Free space")
            return String(localized: "\(free), \(size)")
        case .smaller(let count):
            let smaller = Self.smallerItems(count)
            return String(localized: "\(smaller), \(size)")
        }
    }

    /// The row holds the selection, or a folder that does.
    func isSelected(_ item: Item) -> Bool {
        guard item.isNode, let tree = host.model()?.tree, var cur = host.model()?.selection else { return false }
        while true {
            if cur == item.node { return true }
            let parent = tree.parents[cur]
            if parent == UInt32.max { return false }
            cur = Int(parent)
        }
    }

    /// The row was listed from the tree on screen now.
    func isCurrent(_ item: Item) -> Bool {
        host.model()?.treeGeneration == item.treeGeneration
    }

    func press(_ item: Item) -> Bool { isCurrent(item) && host.press(item) }

    /// Runs `work` after the accessibility call has returned. A custom action
    /// that opens a confirmation would otherwise hold the call past the
    /// accessibility timeout (-25204) while the alert is up.
    static var afterReturn: (@escaping @MainActor () -> Void) -> Void = { work in
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }

    /// Select, then what the right-click menu offers for the row (Zoom In or
    /// Open, Reveal in Finder, Copy Path, Ask, Move to Trash). Each is refused
    /// if the tree changed since the row was listed, again after the hop.
    func actions(for item: Item) -> [NSAccessibilityCustomAction] {
        guard item.isNode, let model = host.model() else { return [] }
        let select = NSAccessibilityCustomAction(name: String(localized: "Select")) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isCurrent(item) else { return false }
                self.host.select(item)
                return true
            }
        }
        let menu = NSMenu()
        NodeMenu.fill(menu, node: item.node, model: model)
        let fromMenu = menu.items.filter { $0.isEnabled && !$0.isSeparatorItem && $0.action != nil }.map { entry in
            NSAccessibilityCustomAction(name: entry.title) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isCurrent(item), let action = entry.action else { return false }
                    Self.afterReturn { [weak self] in
                        guard self?.isCurrent(item) == true else { return }
                        NSApplication.shared.sendAction(action, to: entry.target, from: entry)
                    }
                    return true
                }
            }
        }
        return [select] + fromMenu
    }

    /// Screen coordinates, as accessibility asks for; `convert` handles the
    /// flipped view.
    func screenFrame(of rect: CGRect) -> CGRect {
        let inWindow = view.convert(rect, to: nil)
        return view.window?.convertToScreen(inWindow) ?? inWindow
    }

    // ---- Notifications ----

    /// The layout was rebuilt (a new folder, tree or size): the rows are
    /// stale, and zooming to another folder is said out loud since the row
    /// that had focus is gone.
    func layoutChanged() {
        elements = nil
        guard let model = host.model(), let tree = model.tree else { return }
        let now = (model.treeGeneration, model.viewRoot)
        let zoomed = shownRoot.map { $0.generation == now.0 && $0.root != now.1 } ?? false
        shownRoot = now
        Self.post(view, .layoutChanged)
        if zoomed {
            let folder = name(of: now.1, model: model, tree: tree)
            Self.announce(view, String(localized: "Showing \(folder)"))
        }
    }

    /// The selection changed (from a click, VoiceOver or the list). Its row
    /// gets VoiceOver's focus; a node the map does not list is announced.
    func selectionChanged(_ selection: Int?) {
        guard selection != announcedSelection else { return }
        announcedSelection = selection
        Self.post(view, .selectedChildrenChanged)
        guard let selection, Self.voiceOverRunning(), let model = host.model(), let tree = model.tree else { return }
        if let row = children.first(where: { $0.item.isNode && $0.item.node == selection }) {
            Self.post(row, .focusedUIElementChanged)
        } else {
            let text = "\(tree.name(selection)), \(Fmt.size(tree.alloc[selection]))"
            Self.announce(view, String(localized: "Selected \(text)"))
        }
    }

    // ---- One row ----

    /// AppKit's element class is not main-actor isolated, and its callbacks
    /// arrive on the main thread, where `assumeIsolated` holds.
    nonisolated final class Element: NSAccessibilityElement, @unchecked Sendable {
        let item: Item
        private let title: String
        nonisolated(unsafe) private weak var owner: MapAccessibility?
        nonisolated(unsafe) private weak var parent: NSView?

        init(item: Item, title: String, owner: MapAccessibility, parent: NSView) {
            self.item = item
            self.title = title
            self.owner = owner
            self.parent = parent
            super.init()
        }

        override func accessibilityFrame() -> NSRect {
            let (owner, rect) = (owner, item.rect)
            return MainActor.assumeIsolated { owner?.screenFrame(of: rect) ?? .zero }
        }

        override func accessibilityParent() -> Any? { parent }

        override func accessibilityRole() -> NSAccessibility.Role? {
            switch item.role {
            case .folder, .file, .back: .button
            case .free, .smaller: .staticText
            }
        }

        override func accessibilityRoleDescription() -> String? {
            switch item.role {
            case .folder: String(localized: "folder")
            case .file: String(localized: "file")
            case .back, .free, .smaller: nil
            }
        }

        override func accessibilityLabel() -> String? { title }

        override func accessibilityIdentifier() -> String { "map.row.\(item.node)" }

        override func isAccessibilitySelected() -> Bool {
            let (owner, item) = (owner, item)
            return MainActor.assumeIsolated { owner?.isSelected(item) ?? false }
        }

        override func accessibilityPerformPress() -> Bool {
            let (owner, item) = (owner, item)
            return MainActor.assumeIsolated { owner?.press(item) ?? false }
        }

        override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
            let (owner, item) = (owner, item)
            return MainActor.assumeIsolated { Handoff(value: owner?.actions(for: item)) }.value
        }

        /// Carries a main-thread value out of `assumeIsolated`.
        private struct Handoff<Value>: @unchecked Sendable { let value: Value }
    }
}
