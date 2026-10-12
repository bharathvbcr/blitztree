import AppKit
import Foundation

/// Stopping a scan, and what the app is told about folders that were only
/// partly read. Runs the real engine on disposable fixtures.
@main
struct ScanCancelChecks {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        guard let physical = realpath(fm.temporaryDirectory.path, nil) else { fatalError("tmp") }
        let base = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("blitztree-cancel-\(UUID().uuidString)")
        free(physical)
        defer {
            // The unreadable folder must be readable again to be removed.
            chmod(base.appendingPathComponent("tree/locked").path, 0o755)
            try? fm.removeItem(at: base)
        }

        // A small tree with one folder the scan cannot open.
        let small = base.appendingPathComponent("tree")
        try fm.createDirectory(at: small.appendingPathComponent("open"), withIntermediateDirectories: true)
        try fm.createDirectory(at: small.appendingPathComponent("locked"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5000).write(to: small.appendingPathComponent("open/a.bin"))
        try Data(repeating: 2, count: 5000).write(to: small.appendingPathComponent("locked/b.bin"))
        chmod(small.appendingPathComponent("locked").path, 0o000)

        // Many folders, so a scan has something to be stopped in.
        let wide = base.appendingPathComponent("wide")
        for a in 0..<30 {
            for b in 0..<30 {
                let dir = wide.appendingPathComponent("a\(a)/b\(b)")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data([1]).write(to: dir.appendingPathComponent("f"))
            }
        }

        // 1. Coverage reaches the app: per-node flags, the summary struct, the text.
        let model = ScanModel()
        try await scan(model, small.path)
        guard let tree = model.tree else { fatalError("the small tree did not scan") }
        precondition(!tree.coverage.complete && tree.coverage.errors >= 1, "the unreadable folder is counted")
        precondition(!tree.complete[0], "and the root reads as partly covered")
        let locked = tree.children(0).map(Int.init).first { tree.name($0) == "locked" }!
        let open = tree.children(0).map(Int.init).first { tree.name($0) == "open" }!
        precondition(tree.isPartlyRead(locked) && !tree.complete[locked], "the folder that could not be opened is marked")
        precondition(!tree.isPartlyRead(0) && !tree.complete[0], "the root is partial only through it")
        precondition(tree.complete[open] && !tree.isPartlyRead(open), "its sibling was read in full")
        precondition(tree.coverageNote(locked) != nil && tree.coverageNote(0) != nil && tree.coverageNote(open) == nil)
        precondition(tree.coverageNote(locked) != tree.coverageNote(0), "own and inherited partial coverage read differently")
        precondition(CoverageText.lines(tree.coverage).count == 1, "one line for the failed read")
        precondition(CoverageText.headline(tree.coverage) != CoverageText.headline(covered()))

        var every = BzCoverage()
        every.errors = 3; every.invalid_names = 2; every.skipped_cloud_directories = 4
        every.skipped_mount_points = 5; every.shared_allocated_bytes = 6_000_000
        every.clone_ids_unavailable_directories = 7
        let lines = CoverageText.lines(every)
        precondition(lines.count == 6, "a line for every field the CLI reports (\(lines.count))")
        precondition(CoverageText.lines(covered()).isEmpty, "nothing to say about a clean scan")

        // 2. Stopping. The race between the stop and a very short scan is real,
        // so each round accepts either end; the stop must win at least once.
        var stopped = 0
        for round in 0..<30 {
            let m = ScanModel()
            try await scan(m, small.path) // something on screen to come back to
            let before = m.tree
            let root = m.scanRoot
            m.startScan(path: wide.path)
            precondition(m.scanning && m.tree == nil)
            m.stopScan()
            m.stopScan() // a second press changes nothing
            try await finish(m)
            precondition(!m.scanning && !m.stopping && !m.scanFailed, "round \(round): ended, and not as a failure")
            if m.scanRoot == root {
                stopped += 1
                precondition(m.tree === before, "round \(round): the earlier tree is shown again")
                precondition(!m.scanCancelled, "round \(round): there was something to show")
            } else {
                precondition(m.tree?.coverage.complete == true && m.tree?.count == 1 + 30 + 900 + 900,
                             "round \(round): a scan the stop missed is whole")
            }
        }
        precondition(stopped > 0, "the stop never beat a 900-folder scan in 30 tries")

        // With nothing to come back to: an idle window that says so.
        var idleStops = 0
        for round in 0..<30 {
            let m = ScanModel()
            m.startScan(path: wide.path)
            m.stopScan()
            try await finish(m)
            precondition(!m.scanning && !m.scanFailed, "round \(round)")
            if m.tree == nil {
                idleStops += 1
                precondition(m.scanCancelled, "round \(round): stopped, so it says so")
            } else {
                precondition(!m.scanCancelled)
            }
        }
        precondition(idleStops > 0, "the stop never beat the scan with no earlier tree")

        // A new scan is allowed after a stop, and clears the stopped state.
        let again = ScanModel()
        again.startScan(path: wide.path)
        again.stopScan()
        try await finish(again)
        again.startScan(path: small.path)
        precondition(again.scanning && !again.scanCancelled && !again.stopping)
        try await finish(again)
        precondition(again.tree != nil, "the rescan after a stop completes")

        // Stop with nothing running does nothing.
        let idle = ScanModel()
        idle.stopScan()
        precondition(!idle.scanning && !idle.stopping && !idle.scanCancelled)

        // 3. The new strings exist, translated, in every table.
        let keys = [
            "Stopping…", "Stop scanning (Esc or ⌘.)", "Scan stopped",
            "BlitzTree stopped scanning %@ before it finished.",
            "Not fully read: some items in this folder could not be read or were skipped",
            "Contains folders that were not fully read, so its size is a lower bound",
            "Every folder was read in full.",
            "Some folders were only partly read, so their sizes are lower bounds.",
            "%@ items could not be read (permissions, or changed during the scan)",
            "%@ items with names that are not valid UTF-8 were left out, with everything inside them",
            "%@ cloud-only folders were not opened, so nothing was downloaded",
            "%@ other volumes mounted inside were not scanned",
            "%@ in hard-linked or cloned files is counted once",
            "%@ folders are on a volume that does not report clones; cloned files there count in full",
            "Coverage", "What the scan could and could not read",
            "Folders marked with a warning sign in the list were only partly read.",
        ]
        for lang in ["en", "de", "es", "fr", "ja", "tr", "zh-Hans"] {
            guard let bundle = Bundle(path: "app/\(lang).lproj") ?? Bundle.main.path(forResource: lang, ofType: "lproj").flatMap(Bundle.init(path:)) else {
                fatalError("Missing bundle for language: \(lang)")
            }
            for key in keys {
                let text = bundle.localizedString(forKey: key, value: nil, table: nil)
                precondition(!text.isEmpty, "Empty translation for '\(key)' in \(lang)")
                if lang != "en" {
                    precondition(text != key, "Untranslated '\(key)' in \(lang)")
                }
                // A translation keeps the number placeholder of its source.
                precondition(text.contains("%@") == key.contains("%@"), "placeholder lost in \(lang): '\(key)'")
            }
        }
        print("PASS: scan coverage in the app, stop with and without an earlier tree, strings in 7 languages")
    }

    /// A coverage record that reports everything read and nothing skipped.
    private static func covered() -> BzCoverage {
        var c = BzCoverage()
        c.complete = true
        return c
    }

    @MainActor
    private static func scan(_ model: ScanModel, _ path: String) async throws {
        model.startScan(path: path)
        try await finish(model)
        precondition(model.tree != nil && !model.scanFailed, "the fixture at \(path) scans")
    }

    @MainActor
    private static func finish(_ model: ScanModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.scanning && Date() < deadline {
            runLoop(for: 0.005)
            try await Task.sleep(for: .milliseconds(1))
        }
        precondition(!model.scanning, "the scan never ended")
        // Let a pending tree install (Clean Up discovery) settle.
        runLoop(for: 0.01)
    }

    private static func runLoop(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
