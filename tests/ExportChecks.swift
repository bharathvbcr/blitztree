import AppKit
import Foundation

/// File > Export as CSV…, minus the save panel: the exporter that starts the
/// engine, follows it, reports failure and keeps the scan alive meanwhile.
@main
struct ExportChecks {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        guard let physical = realpath(fm.temporaryDirectory.path, nil) else { fatalError("tmp") }
        let base = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("blitztree-export-\(UUID().uuidString)")
        free(physical)
        let scanRoot = base.appendingPathComponent("scan")
        let out = base.appendingPathComponent("out")
        try fm.createDirectory(at: scanRoot.appendingPathComponent("sub dir"), withIntermediateDirectories: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        for (name, size) in [("a,b.txt", 3000), ("say \"hi\".txt", 2000), ("new\nline", 1000), (" padded ", 500), ("sub dir/inner", 4000)] {
            try Data(repeating: 7, count: size).write(to: scanRoot.appendingPathComponent(name))
        }

        func scan() async throws -> Tree {
            guard let handle = bz_scan_start(scanRoot.path) else { fatalError("scan did not start") }
            var f: UInt64 = 0, d: UInt64 = 0, b: UInt64 = 0, done: Int32 = 0
            while done == 0 {
                bz_progress(handle, &f, &d, &b, &done)
                if done == 0 { try await Task.sleep(for: .milliseconds(2)) }
            }
            guard let tree = Tree(handle: handle) else { bz_free(handle); fatalError("scan produced no tree") }
            return tree
        }
        func finish(_ exporter: CSVExporter) async throws {
            let deadline = Date().addingTimeInterval(20)
            while exporter.running && Date() < deadline {
                spin(0.01)
                try await Task.sleep(for: .milliseconds(1))
            }
            precondition(!exporter.running, "the export never finished")
        }
        func temporaries(_ folder: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(".blitztree-export-") }
        }
        /// A strict RFC 4180 reader for what the engine wrote.
        func parse(_ url: URL) -> [[String]] {
            let bytes = [UInt8](try! Data(contentsOf: url))
            precondition(bytes.count >= 2 && bytes[bytes.count - 2] == 13 && bytes[bytes.count - 1] == 10, "rows end with CRLF")
            var rows: [[String]] = [], row: [String] = [], field: [UInt8] = []
            var quoted = false, i = 0
            func end() { row.append(String(decoding: field, as: UTF8.self)); field = [] }
            while i < bytes.count {
                let c = bytes[i]
                if quoted {
                    if c == 34 {
                        if i + 1 < bytes.count, bytes[i + 1] == 34 { field.append(34); i += 1 } else { quoted = false }
                    } else { field.append(c) }
                } else if c == 34 {
                    precondition(field.isEmpty, "a quote inside an unquoted field")
                    quoted = true
                } else if c == 44 { end() }
                else if c == 13 { precondition(bytes[i + 1] == 10); end(); rows.append(row); row = []; i += 1 }
                else { precondition(c != 10, "a bare LF outside quotes"); field.append(c) }
                i += 1
            }
            precondition(!quoted && field.isEmpty && row.isEmpty)
            return rows
        }

        let tree = try await scan()
        let columns = ["path", "allocated_bytes", "logical_bytes", "file_count", "is_folder", "complete"]

        // 1. The whole scan: every node, awkward names quoted, Finder asked to show the file.
        let exporter = CSVExporter()
        var shown: [URL] = []
        exporter.onSaved = { shown.append($0) }
        let whole = out.appendingPathComponent("whole.csv")
        precondition(exporter.start(tree: tree, root: 0, to: whole) && exporter.running)
        precondition(!exporter.start(tree: tree, root: 0, to: out.appendingPathComponent("second.csv")), "one export at a time")
        try await finish(exporter)
        precondition(exporter.failure == nil && exporter.savedTo == whole && shown == [whole])
        precondition(exporter.rowsDone == UInt64(tree.count) && exporter.rowsTotal == UInt64(tree.count), "\(exporter.rowsDone)/\(exporter.rowsTotal)")
        var rows = parse(whole)
        precondition(rows[0] == columns && rows.count == tree.count + 1, "a header and a row per node")
        let paths = rows.dropFirst().map { $0[0] }
        for name in ["a,b.txt", "say \"hi\".txt", "new\nline", " padded ", "sub dir/inner"] {
            precondition(paths.contains(scanRoot.path + "/" + name), "no row for \(name.debugDescription)")
        }
        let top = rows[1]
        precondition(top[0] == scanRoot.path && top[4] == "true" && top[3] == "5" && top[5] == "true", "\(top)")
        precondition(rows.dropFirst().allSatisfy { $0.count == 6 })
        precondition(temporaries(out).isEmpty)

        // 2. A folder: itself and what is under it, with the full path.
        guard let sub = (0..<tree.count).first(where: { tree.name($0) == "sub dir" }) else { fatalError("no sub dir") }
        let part = out.appendingPathComponent("part.csv")
        precondition(exporter.start(tree: tree, root: sub, to: part))
        try await finish(exporter)
        rows = parse(part)
        precondition(rows.dropFirst().map { $0[0] } == [scanRoot.path + "/sub dir", scanRoot.path + "/sub dir/inner"], "\(rows)")
        precondition(rows[1][3] == "1" && rows[2][2] == "4000")

        // 3. A node outside the tree, and files that cannot be written: reported, nothing left.
        shown.removeAll()
        precondition(!exporter.start(tree: tree, root: tree.count, to: out.appendingPathComponent("never.csv")))
        precondition(exporter.failure?.isEmpty == false && !exporter.running)
        exporter.failure = nil
        precondition(exporter.start(tree: tree, root: 0, to: out.appendingPathComponent("no/such/folder/out.csv")))
        try await finish(exporter)
        precondition(exporter.failure?.contains("No such file or directory") == true, "\(exporter.failure ?? "nil")")
        precondition(exporter.savedTo == part, "a failure does not move the last saved file")
        exporter.failure = nil
        let folder = out.appendingPathComponent("folder.csv")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        precondition(exporter.start(tree: tree, root: 0, to: folder))
        try await finish(exporter)
        precondition(exporter.failure?.contains("is a folder") == true, "\(exporter.failure ?? "nil")")
        exporter.failure = nil
        precondition(shown.isEmpty && temporaries(out).isEmpty)

        // 4. Cancel: whichever side of the finish line it lands, the file is whole or absent.
        let stopped = out.appendingPathComponent("stopped.csv")
        precondition(exporter.start(tree: tree, root: 0, to: stopped))
        exporter.cancel()
        exporter.cancel()
        try await finish(exporter)
        precondition(exporter.failure == nil && temporaries(out).isEmpty)
        if fm.fileExists(atPath: stopped.path) {
            precondition(parse(stopped).count == tree.count + 1, "it finished before the stop: a whole file")
        } else {
            precondition(shown.isEmpty, "a cancelled export is not shown")
        }

        // 5. The scan stays alive while it is read, though the window lets go of it.
        weak var weakTree: Tree?
        do {
            let scanned = try await scan()
            weakTree = scanned
            precondition(exporter.start(tree: scanned, root: 0, to: out.appendingPathComponent("held.csv")))
        }
        while exporter.running {
            precondition(weakTree != nil, "the exporter holds the tree while it runs")
            spin(0.005)
            try await Task.sleep(for: .milliseconds(1))
        }
        precondition(weakTree == nil, "and lets it go afterwards")
        precondition(parse(out.appendingPathComponent("held.csv")).count == tree.count + 1)

        // 6. Quitting mid-export: abandon waits for the engine and leaves no temporary file.
        precondition(exporter.start(tree: tree, root: 0, to: out.appendingPathComponent("abandoned.csv")))
        exporter.abandon()
        precondition(!exporter.running && temporaries(out).isEmpty)
        exporter.abandon()

        // 7. The suggested name never holds a character a file name cannot.
        precondition(Tree.csvFileName(for: "Macintosh HD") == "BlitzTree - Macintosh HD.csv")
        precondition(Tree.csvFileName(for: "a/b:c") == "BlitzTree - a-b-c.csv")
        print("PASS: CSV export (whole scan, folder, quoting, failures, cancel, tree held, abandon)")
    }

    /// The timers and notifications the exporter relies on need the main run loop turning.
    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
