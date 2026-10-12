import Foundation

/// Main-thread and refresh costs of the Clean Up safety checks, on disposable
/// fixtures built with real git and the real engine. Nothing touches the
/// user's home, the Trash or the user's agent session logs (GitFixture points
/// them at the fixture). Run through `benchmarks/run-cleanup-perf.sh`.
///
///   refresh  wall time of `Cleanup.find` and the git and lsof processes it
///            spawns, with N linked worktrees in the scan
///   plan     how long the main thread is blocked while an agent's plan with
///            many worktree cards streams in
///   node     `Tree.node(at:)` against the String-per-child lookup it replaced,
///            on a directory with 100k entries, interleaved, min of N
///
///   run-cleanup-perf.sh [refresh|plan|node] [--worktrees N] [--cards K] [--rounds R]
@main
struct CleanupPerformance {
    @MainActor
    static func main() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let mode = arguments.first.flatMap { ["refresh", "plan", "node"].contains($0) ? $0 : nil } ?? "refresh"
        if arguments.first == mode { arguments.removeFirst() }
        var worktrees = 5, rounds = 7, cards = 12
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            guard let value = rest.popFirst(), let number = Int(value), number > 0 else {
                fatalError("Usage: run-cleanup-perf.sh [refresh|plan|node] [--worktrees N] [--cards K] [--rounds R]")
            }
            switch flag {
            case "--worktrees": worktrees = number
            case "--rounds": rounds = number
            case "--cards": cards = number
            default: fatalError("unknown flag \(flag)")
            }
        }
        let fm = FileManager.default
        guard let physical = realpath(fm.temporaryDirectory.path, nil) else { fatalError("no temporary directory") }
        let base = URL(fileURLWithPath: String(cString: physical))
            .appendingPathComponent("blitztree-perf-\(UUID().uuidString)")
        free(physical)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let fixture = GitFixture(base: base)
        switch mode {
        case "plan": try await plan(fixture: fixture, worktrees: worktrees, cards: cards, rounds: min(rounds, 3))
        case "node": try await node(base: base, rounds: max(rounds, 9))
        default: try await refresh(fixture: fixture, worktrees: worktrees, rounds: rounds)
        }
    }

    @MainActor
    private static func scan(_ path: String) async throws -> Tree {
        guard let handle = bz_scan_start(path) else { fatalError("scan failed") }
        var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0, done: Int32 = 0
        while done == 0 {
            bz_progress(handle, &files, &dirs, &bytes, &done)
            if done == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        guard let tree = Tree(handle: handle) else { fatalError("no tree") }
        return tree
    }

    private static func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    // MARK: refresh

    @MainActor
    private static func refresh(fixture: GitFixture, worktrees: Int, rounds: Int) async throws {
        let home = fixture.base.appendingPathComponent("home").path
        let paths = fixture.scannableWorktrees(in: home, count: worktrees)
        let tree = try await scan(home)

        var times: [Double] = []
        var git = 0, lsof = 0, verified = 0
        for _ in 0..<rounds {
            BoundedProcess.spawns.reset()
            var items: [CleanupItem] = []
            times.append(milliseconds { items = Cleanup.find(in: tree) })
            git = BoundedProcess.spawns.count("git")
            lsof = BoundedProcess.spawns.count("lsof")
            verified = items.filter { item in paths.contains(item.path) && item.target != nil }.count
        }
        precondition(verified == worktrees, "every worktree must be offered and verified, got \(verified) of \(worktrees)")
        times.sort()
        print("worktrees=\(worktrees) rounds=\(rounds) git_spawns=\(git) lsof_spawns=\(lsof)")
        print(String(format: "Cleanup.find min=%.1f ms median=%.1f ms max=%.1f ms",
                     times[0], times[times.count / 2], times[times.count - 1]))
        print("samples_ms=\(times.map { String(format: "%.1f", $0) })")

        // What the two kinds of process cost on their own, for the same machine state.
        var lsofTimes: [Double] = [], verifyTimes: [Double] = []
        for _ in 0..<rounds {
            lsofTimes.append(milliseconds {
                _ = BoundedProcess.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-w"],
                                       environment: ["PATH": "/usr/bin:/bin"], timeout: 30, cap: 32 << 20)
            })
            verifyTimes.append(milliseconds { _ = try? GitWorktree.verify(paths[0]) })
        }
        print(String(format: "one lsof min=%.1f ms; one GitWorktree.verify min=%.1f ms (lsof included)",
                     lsofTimes.min()!, verifyTimes.min()!))
    }

    // MARK: plan

    /// An agent's plan arrives card by card; each card is judged against the
    /// scan (path policy, session logs, and for a worktree git and lsof). A
    /// heartbeat on the main thread records how long it is unavailable while
    /// the cards stream in at the pace of a model writing them, once judging
    /// each card on the main thread (`PlanItem.init`, which is what the run
    /// did before the evaluation moved off it) and once the way the run does
    /// now (`PlanItem.make`). The two alternate, `rounds` times each.
    @MainActor
    private static func plan(fixture: GitFixture, worktrees: Int, cards: Int, rounds: Int) async throws {
        let fm = FileManager.default
        let home = fixture.base.appendingPathComponent("home").path
        let paths = fixture.scannableWorktrees(in: home, count: worktrees)
        // A Claude Code history of the size a developer accumulates: every
        // card's recent-use check reads the logs that could name its folder.
        let projects = AgentSessions.claude
        let padding = String(repeating: "x", count: 9000)
        for index in 0..<400 {
            let folder = projects.appendingPathComponent("-tmp-elsewhere-project\(index)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{\"type\":\"queue-operation\",\"content\":\"\(padding)\"}\n{\"cwd\":\"/tmp/elsewhere/project\(index)\"}\n".utf8)
                .write(to: folder.appendingPathComponent("\(UUID().uuidString).jsonl"))
        }
        let tree = try await scan(home)
        let specs = (0..<cards).map { index in
            PlanItemSpec(title: "Worktree \(index)", detail: "Fixture", group: "ask", bytes: 1,
                         paths: [paths[index % paths.count]], action: "trash", command: "")
        }

        struct Stalls { var longest = 0.0, total = 0.0, count = 0, wall = 0.0 }
        func measure(_ judge: (PlanItemSpec) async -> PlanItem) async -> Stalls {
            var beats: [Double] = []
            var last = DispatchTime.now().uptimeNanoseconds
            var running = true
            let heartbeat = Task { @MainActor in
                while running {
                    let now = DispatchTime.now().uptimeNanoseconds
                    beats.append(Double(now - last) / 1_000_000)
                    last = now
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            let started = DispatchTime.now().uptimeNanoseconds
            for spec in specs {
                let item = await judge(spec)
                if let blocked = item.blocked { fatalError("a card was refused: \(blocked)") }
                try? await Task.sleep(for: .milliseconds(150))
            }
            let wall = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            running = false
            await heartbeat.value
            let late = beats.filter { $0 > 50 }
            return Stalls(longest: beats.max() ?? 0, total: late.reduce(0, +), count: late.count, wall: wall)
        }
        var onMain: [Stalls] = [], offMain: [Stalls] = []
        for round in 0..<rounds {
            func before() async { onMain.append(await measure { PlanItem(spec: $0, tree: tree, home: home) }) }
            func after() async { offMain.append(await measure { await PlanItem.make(spec: $0, tree: tree, home: home) }) }
            if round.isMultiple(of: 2) { await before(); await after() } else { await after(); await before() }
        }
        print("\(cards) worktree cards (\(worktrees) worktrees, 400 session logs), one every 150 ms, \(rounds) rounds each, interleaved")
        for (name, runs) in [("judged on the main thread", onMain), ("judged off it (PlanItem.make)", offMain)] {
            let best = runs.min { $0.total < $1.total }!
            print(String(format: "%@: main thread stalled past 50 ms for %.0f ms in %d stalls (min of %d rounds); longest stall %.0f ms (min %.0f ms); run took %.0f ms",
                         name, best.total, best.count, rounds, runs.map(\.longest).max()!, runs.map(\.longest).min()!, best.wall))
        }
    }

    // MARK: node

    /// The lookup `Tree.node(at:)` replaced: a String made for every child.
    private static func referenceNode(_ tree: Tree, at path: String) -> Int? {
        let root = tree.path(0)
        guard path.hasPrefix(root + "/") else { return nil }
        var cur = 0
        for part in path.dropFirst(root.count).split(separator: "/") {
            guard let next = tree.children(cur).first(where: { tree.name(Int($0)) == part }) else { return nil }
            cur = Int(next)
        }
        return cur
    }

    @MainActor
    private static func node(base: URL, rounds: Int) async throws {
        let wide = base.appendingPathComponent("home/wide")
        try FileManager.default.createDirectory(at: wide, withIntermediateDirectories: true)
        for index in 0..<100_000 {
            let descriptor = open(wide.path + "/entry-\(index)-with-a-realistic-length-name.dat", O_CREAT | O_WRONLY, 0o644)
            precondition(descriptor >= 0 && close(descriptor) == 0)
        }
        let home = base.appendingPathComponent("home").path
        let tree = try await scan(home)
        let directory = tree.node(at: wide.path)!
        precondition(tree.children(directory).count == 100_000, "a directory of 100k entries")
        // The child listed last: the lookup walks all of them.
        let target = wide.path + "/" + tree.name(Int(tree.children(directory).last!))
        let expected = Int(tree.children(directory).last!)
        precondition(referenceNode(tree, at: target) == expected && tree.node(at: target) == expected, "both find it")
        precondition(tree.node(at: wide.path + "/no-such-entry") == nil && referenceNode(tree, at: wide.path + "/no-such-entry") == nil)

        var before: [Double] = [], after: [Double] = []
        for trial in 0..<rounds {
            func old() { before.append(milliseconds { precondition(referenceNode(tree, at: target) == expected) }) }
            func new() { after.append(milliseconds { precondition(tree.node(at: target) == expected) }) }
            if trial.isMultiple(of: 2) { old(); new() } else { new(); old() }
        }
        print(String(format: "Tree.node(at:) in a directory of 100000 entries, interleaved, %d rounds: String per child min=%.3f ms median=%.3f ms; bytes min=%.3f ms median=%.3f ms; speedup (min) %.1fx",
                     rounds, before.min()!, before.sorted()[rounds / 2], after.min()!, after.sorted()[rounds / 2],
                     before.min()! / after.min()!))
        print("string_ms=\(before.map { String(format: "%.3f", $0) }) bytes_ms=\(after.map { String(format: "%.3f", $0) })")
    }
}
