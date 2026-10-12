import Foundation

/// What one Clean Up refresh costs when the scan holds linked git worktrees:
/// wall time of `Cleanup.find` and how many git and lsof processes it spawns,
/// on a disposable home built with real git. Nothing touches the user's home,
/// the Trash or the user's agent session logs (GitFixture points them at the
/// fixture). Run through `benchmarks/run-worktree.sh`.
@main
struct WorktreeRefreshBenchmark {
    @MainActor
    static func main() throws {
        var worktrees = 6, rounds = 7
        var arguments = CommandLine.arguments.dropFirst()
        while let flag = arguments.popFirst() {
            guard let value = arguments.popFirst(), let number = Int(value), number > 0 else {
                fatalError("Usage: worktree-refresh [--worktrees N] [--rounds R]")
            }
            switch flag {
            case "--worktrees": worktrees = number
            case "--rounds": rounds = number
            default: fatalError("unknown flag \(flag)")
            }
        }
        let fm = FileManager.default
        guard let physical = realpath(fm.temporaryDirectory.path, nil) else { fatalError("no temporary directory") }
        let base = URL(fileURLWithPath: String(cString: physical))
            .appendingPathComponent("blitztree-worktree-bench-\(UUID().uuidString)")
        free(physical)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let fixture = GitFixture(base: base)
        let home = base.appendingPathComponent("home").path
        let paths = fixture.scannableWorktrees(in: home, count: worktrees)

        guard let handle = bz_scan_start(home) else { fatalError("scan failed") }
        var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0, done: Int32 = 0
        while done == 0 {
            bz_progress(handle, &files, &dirs, &bytes, &done)
            if done == 0 { usleep(5_000) }
        }
        guard let tree = Tree(handle: handle) else { fatalError("no tree") }

        var times: [Double] = []
        var git = 0, lsof = 0, verified = 0
        for _ in 0..<rounds {
            BoundedProcess.spawns.reset()
            let start = DispatchTime.now().uptimeNanoseconds
            let items = Cleanup.find(in: tree)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
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
            var start = DispatchTime.now().uptimeNanoseconds
            _ = BoundedProcess.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-w"],
                                   environment: ["PATH": "/usr/bin:/bin"], timeout: 30, cap: 32 << 20)
            lsofTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            start = DispatchTime.now().uptimeNanoseconds
            _ = try GitWorktree.verify(paths[0])
            verifyTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        print(String(format: "one lsof min=%.1f ms; one GitWorktree.verify min=%.1f ms (lsof included)",
                     lsofTimes.min()!, verifyTimes.min()!))
    }
}
