import SwiftUI
import AppKit

/// What the left panel lists.
enum ListMode: Hashable {
    case folders
    case largestFiles
}

/// The biggest files anywhere in the scan, flat. The engine picks them (the
/// same selection as the CLI's `largest_files`); this only shows them.
struct LargestFilesList: View {
    let model: ScanModel
    @State private var nodes: [Int] = []
    @State private var loadedFor: ObjectIdentifier?

    private nonisolated static let limit = 1000

    var body: some View {
        VStack(spacing: 0) {
            if let tree = model.tree {
                HStack {
                    Text(String(format: String(localized: "%@ largest files"), Fmt.num(UInt64(nodes.count))))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(localized: "Largest first"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
                if nodes.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        if loadedFor == ObjectIdentifier(tree) {
                            Image(systemName: "doc")
                                .font(.system(size: 24))
                                .foregroundStyle(.tertiary)
                            Text(String(localized: "No files"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(nodes, id: \.self) { node in
                                SearchResultRow(
                                    tree: tree,
                                    node: node,
                                    isSelected: model.selection == node
                                ) {
                                    model.reveal(node)
                                }
                                .overlay { RightClickMenu(node: node, model: model) }
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: model.tree.map(ObjectIdentifier.init)) {
            guard let tree = model.tree else {
                nodes = []
                loadedFor = nil
                return
            }
            let found = await Task.detached(priority: .userInitiated) {
                tree.largestFiles(limit: Self.limit)
            }.value
            guard !Task.isCancelled, model.tree === tree else { return }
            nodes = found
            loadedFor = ObjectIdentifier(tree)
        }
    }
}

/// Opens the shared node menu on right-click (or control-click) without
/// taking left clicks from the row underneath.
private struct RightClickMenu: NSViewRepresentable {
    let node: Int
    let model: ScanModel

    func makeNSView(context: Context) -> NSView { MenuView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? MenuView else { return }
        view.node = node
        view.model = model
    }

    final class MenuView: NSView {
        var node = 0
        weak var model: ScanModel?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { showMenu(with: event) }

        override func mouseDown(with event: NSEvent) { showMenu(with: event) }

        private func showMenu(with event: NSEvent) {
            guard let model, model.tree != nil else { return }
            model.selection = node
            NodeMenu.popUp(node: node, model: model, with: event, for: self)
        }
    }
}
