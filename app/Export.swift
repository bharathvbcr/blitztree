import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// File > Export as CSV…: the folder on screen, and everything in it, as a CSV
/// file (path, allocated and logical bytes, file count, folder, complete). At
/// the top of the scan that is the whole scan.
///
/// The engine streams the file to disk on its own thread (`bz_export_*`), into
/// a hidden temporary file beside the destination that it renames into place
/// when whole. This type only starts it, shows how far it is, stops it, and
/// says why it failed: it never holds a half-written file.
@Observable
@MainActor
final class CSVExporter {
    private(set) var running = false
    /// Cancel was pressed and the engine is winding the export down.
    private(set) var stopping = false
    private(set) var rowsDone: UInt64 = 0
    private(set) var rowsTotal: UInt64 = 0
    /// The export has run long enough to be worth a progress sheet. A small
    /// folder is written before anyone could read one.
    private(set) var showsProgress = false
    /// What the last export failed with, in the user's language, until dismissed.
    var failure: String?
    /// Where the last export that finished was written.
    private(set) var savedTo: URL?
    /// How long an export runs before its progress shows.
    var progressDelay: TimeInterval = 0.4
    /// Called once with the file when an export finished. The window reveals it in Finder.
    var onSaved: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    private var handle: OpaquePointer?
    /// The scan the export reads. Held so that a rescan, which drops the
    /// window's own reference, cannot free the tree under a running export.
    private var tree: Tree?
    private var destination: URL?
    private var startedAt = Date()
    private var timer: Timer?
    private var terminationObserver: NSObjectProtocol?

    /// Starts writing the folder at `root` of `tree` to `url`. False when one
    /// is already running or the engine would not start (the reason is then
    /// in `failure`).
    @discardableResult
    func start(tree: Tree, root: Int, to url: URL) -> Bool {
        guard !running else { return false }
        guard let started = tree.startExport(root: root, to: url.path) else {
            failure = Self.failureMessage(String(localized: "The export could not be started."))
            return false
        }
        handle = started
        self.tree = tree
        destination = url
        running = true
        stopping = false
        showsProgress = false
        rowsDone = 0
        rowsTotal = 0
        startedAt = Date()
        // 10 Hz is plenty for a bar that moves in batches of thousands of rows.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Quitting mid-export removes the temporary file instead of leaving it.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.abandon() }
        }
        return true
    }

    /// Ask the engine to stop; the export ends with no file and nothing left behind.
    func cancel() {
        guard running, !stopping, let handle else { return }
        stopping = true
        bz_export_cancel(handle)
    }

    private func poll() {
        guard let handle else { return }
        var done: UInt64 = 0, total: UInt64 = 0
        var status: Int32 = 0
        bz_export_progress(handle, &done, &total, &status)
        rowsDone = done
        rowsTotal = total
        if !showsProgress, Date().timeIntervalSince(startedAt) > progressDelay { showsProgress = true }
        guard status != Int32(BZ_EXPORT_RUNNING) else { return }
        let reason = status == Int32(BZ_EXPORT_FAILED) ? bz_export_error(handle).map { String(cString: $0) } : nil
        let saved = status == Int32(BZ_EXPORT_DONE) ? destination : nil
        release()
        if let saved {
            savedTo = saved
            onSaved(saved)
        } else if status == Int32(BZ_EXPORT_FAILED) {
            failure = Self.failureMessage(reason ?? String(localized: "The export failed."))
        }
    }

    /// Stops an export and waits for it, so its temporary file is gone.
    func abandon() {
        guard handle != nil else { return }
        release()
    }

    private func release() {
        timer?.invalidate()
        timer = nil
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        terminationObserver = nil
        if let handle { bz_export_free(handle) }
        handle = nil
        tree = nil
        destination = nil
        running = false
        stopping = false
        showsProgress = false
    }

    private static func failureMessage(_ reason: String) -> String {
        String(localized: "BlitzTree could not save the CSV file. \(reason)")
    }
}

extension Tree {
    /// A file name for the CSV of the folder at `root`, without a character
    /// that a file name cannot hold.
    static func csvFileName(for name: String) -> String {
        let safe = name.map { $0 == "/" || $0 == ":" ? "-" : String($0) }.joined()
        return "BlitzTree - \(safe).csv"
    }
}

// MARK: menu

/// What File > Export as CSV… does in the window that has focus.
struct CSVExportAction {
    let isEnabled: Bool
    let perform: () -> Void
}

private struct CSVExportKey: FocusedValueKey {
    typealias Value = CSVExportAction
}

extension FocusedValues {
    var csvExport: CSVExportAction? {
        get { self[CSVExportKey.self] }
        set { self[CSVExportKey.self] = newValue }
    }
}

struct ExportCommands: Commands {
    @FocusedValue(\.csvExport) private var csvExport

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Export as CSV…") { csvExport?.perform() }
                .disabled(!(csvExport?.isEnabled ?? false))
        }
    }
}

// MARK: window

private struct CSVExportSupport: ViewModifier {
    let model: ScanModel
    let exporter: CSVExporter
    let rootName: () -> String

    private var canExport: Bool {
        model.tree != nil && !model.scanning && !exporter.running
    }

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.csvExport, CSVExportAction(isEnabled: canExport, perform: chooseDestination))
            .sheet(isPresented: Binding(get: { exporter.showsProgress }, set: { _ in })) {
                CSVExportProgress(exporter: exporter)
            }
            .alert("Could not export", isPresented: Binding(get: { exporter.failure != nil },
                                                           set: { if !$0 { exporter.failure = nil } })) {
                Button("OK") { exporter.failure = nil }
            } message: {
                Text(exporter.failure ?? "")
            }
    }

    private func chooseDestination() {
        guard canExport, let tree = model.tree, model.viewRoot < tree.count else { return }
        let root = model.viewRoot
        let name = root == 0 ? rootName() : tree.name(root)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Tree.csvFileName(for: name)
        panel.message = String(localized: "Exports “\(name)” and everything in it as a CSV file.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporter.start(tree: tree, root: root, to: url)
    }
}

extension View {
    /// File > Export as CSV… for this window, with its progress and errors.
    func csvExport(model: ScanModel, exporter: CSVExporter, rootName: @escaping () -> String) -> some View {
        modifier(CSVExportSupport(model: model, exporter: exporter, rootName: rootName))
    }
}

private struct CSVExportProgress: View {
    let exporter: CSVExporter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exporting to CSV…")
                .font(.headline)
            ProgressView(value: Double(exporter.rowsDone), total: Double(max(exporter.rowsTotal, 1)))
            Text("\(Fmt.num(exporter.rowsDone)) of \(Fmt.num(exporter.rowsTotal)) rows")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(exporter.stopping ? LocalizedStringKey("Stopping…") : LocalizedStringKey("Cancel"),
                       role: .cancel) { exporter.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(exporter.stopping)
            }
        }
        .padding(20)
        .frame(width: 360)
        .interactiveDismissDisabled()
    }
}
