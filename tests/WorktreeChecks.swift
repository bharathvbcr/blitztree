import Darwin
import Foundation

/// GitWorktree verification, CleanupVerify, and the worktree Trash → delete →
/// admin-entry flow, all against real git in disposable fixtures.
@main
enum WorktreeChecks {
    private static let fm = FileManager.default

    static func main() async throws {
        let raw = fm.temporaryDirectory.appendingPathComponent("blitztree-worktree-\(UUID().uuidString)")
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        let base = GitFixture.canonical(raw)
        defer { try? fm.removeItem(at: base) }
        let fixture = GitFixture(base: base)
        let repo = fixture.repository(base.appendingPathComponent("repo").path)
        var serial = 0
        func worktree(_ name: String) -> String {
            serial += 1
            return fixture.worktree(of: repo, at: base.appendingPathComponent("wts/\(serial)-\(name)").path)
        }

        try verification(fixture: fixture, repo: repo, worktree: worktree)
        try recency(fixture: fixture, worktree: worktree)
        try processes(worktree: worktree)
        try cleanupVerify(base: base, worktree: worktree)
        try await flow(fixture: fixture, base: base, repo: repo, worktree: worktree)
        print("PASS WorktreeChecks")
    }

    // MARK: Verification

    private static func verification(fixture: GitFixture, repo: String,
                                     worktree: (String) -> String) throws {
        let clean = worktree("clean")
        let info = expectVerified("clean worktree on a branch", clean)
        precondition(info.branch == (clean as NSString).lastPathComponent, "branch name")
        precondition(info.head.count == 40 && info.path == clean, "head and path")
        precondition(info.commonDir == GitFixture.canonical(URL(fileURLWithPath: repo + "/.git")).path)
        precondition((info.adminDir as NSString).deletingLastPathComponent == info.commonDir + "/worktrees")

        let modified = worktree("modified")
        fixture.write(modified + "/a.txt", "changed\n")
        expectBlocked("modified tracked file", modified, .changes(modified))

        let staged = worktree("staged")
        fixture.write(staged + "/staged.txt", "staged\n")
        fixture.run(["add", "staged.txt"], in: staged)
        expectBlocked("staged new file", staged, .changes(staged))

        let untracked = worktree("untracked")
        fixture.write(untracked + "/new.txt", "new\n")
        expectBlocked("untracked file", untracked, .changes(untracked))

        let ignored = worktree("ignored")
        try fm.createDirectory(atPath: ignored + "/node_modules/pkg", withIntermediateDirectories: true)
        fixture.write(ignored + "/node_modules/pkg/index.js", "x\n")
        _ = expectVerified("ignored files only", ignored)

        let hidden = worktree("assume-unchanged")
        fixture.run(["update-index", "--assume-unchanged", "a.txt"], in: hidden)
        fixture.write(hidden + "/a.txt", "hidden change\n")
        precondition(fixture.run(["status", "--porcelain"], in: hidden).isEmpty, "status cannot see it")
        expectBlocked("assume-unchanged file", hidden, .hiddenChanges(hidden))

        let locked = worktree("locked")
        fixture.run(["worktree", "lock", "--reason", "fixture", locked], in: repo)
        expectBlocked("locked worktree", locked, .locked(locked))

        let orphan = worktree("detached-orphan")
        fixture.run(["checkout", "-q", "--detach"], in: orphan)
        fixture.run(["commit", "-q", "--allow-empty", "-m", "on no ref"], in: orphan)
        expectBlocked("detached HEAD with a commit on no ref", orphan, .unreachableHead(orphan))

        let detached = worktree("detached-contained")
        fixture.run(["checkout", "-q", "--detach"], in: detached)
        let detachedInfo = expectVerified("detached HEAD at a branch commit", detached)
        precondition(detachedInfo.branch == nil)

        let modules = worktree("gitmodules")
        fixture.write(modules + "/.gitmodules", "")
        expectBlocked(".gitmodules present", modules, .submodules(modules))

        // Structural: anything but a `.git` file that round-trips to its own
        // admin entry is not a worktree.
        let linked = fixture.base.appendingPathComponent("git-symlink").path
        try fm.createDirectory(atPath: linked, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: linked + "/.git", withDestinationPath: clean + "/.git")
        expectBlocked(".git symlink", linked, .notWorktree(linked))
        expectBlocked(".git directory (plain repository)", repo, .notWorktree(repo))
        let outside = fixture.base.appendingPathComponent("git-file-outside").path
        let elsewhere = fixture.base.appendingPathComponent("plain-dir").path
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        fixture.write(outside + "/.git", "gitdir: \(elsewhere)\n")
        expectBlocked(".git file pointing outside a repository", outside, .notWorktree(outside))
        fixture.write(outside + "/.git", "gitdir: \(repo)/.git/worktrees/no-such-entry\n")
        expectBlocked(".git file naming a missing admin dir", outside, .notWorktree(outside))
        fixture.write(outside + "/.git", "gitdir: \(info.adminDir)\nextra\n")
        expectBlocked(".git file with more than one line", outside, .notWorktree(outside))
        let copy = fixture.base.appendingPathComponent("git-file-copy").path
        try fm.createDirectory(atPath: copy, withIntermediateDirectories: true)
        try fm.copyItem(atPath: clean + "/.git", toPath: copy + "/.git")
        expectBlocked("admin gitdir names another worktree", copy, .notWorktree(copy))
        let repointed = worktree("repointed")
        fixture.write(fixture.admin(of: repointed) + "/gitdir", clean + "/.git\n")
        expectBlocked("admin gitdir pointing elsewhere", repointed, .notWorktree(repointed))
        // The repository moved inside its own worktree, metadata still
        // consistent: trashing the worktree would take the repository along.
        let nestRepo = fixture.repository(fixture.base.appendingPathComponent("nest-repo").path)
        let nested = fixture.worktree(of: nestRepo, at: fixture.base.appendingPathComponent("wts/nested").path)
        let nestedID = (fixture.admin(of: nested) as NSString).lastPathComponent
        try fm.moveItem(atPath: nestRepo, toPath: nested + "/repo")
        let movedAdmin = nested + "/repo/.git/worktrees/" + nestedID
        let dataRoot = "/System/Volumes/Data"
        for spelling in [movedAdmin, dataRoot + movedAdmin] where fm.fileExists(atPath: spelling) {
            fixture.write(nested + "/.git", "gitdir: \(spelling)\n")
            precondition((try? GitWorktree.layout(of: nested)) == nil, "repository inside its worktree via \(spelling)")
            expectBlocked("repository inside its worktree via \(spelling)", nested, .notWorktree(nested))
        }
        // The Data-volume spelling of an ordinary worktree still verifies.
        if fm.fileExists(atPath: dataRoot + clean) {
            precondition(expectVerified("Data-volume spelling", dataRoot + clean).path == dataRoot + clean)
        }

        // Git lookup: never the /usr/bin shim; nothing usable means blocked.
        precondition(GitWorktree.locateGit(GitLookup(searchPath: "/usr/bin:relative/bin", useDeveloperDir: false)) == nil,
                     "the /usr/bin/git shim and relative PATH entries are never used")
        expectBlocked("git missing", clean, .gitMissing(clean),
                      lookup: GitLookup(searchPath: "", useDeveloperDir: false))

        // A repository fsmonitor hook must not run during verification.
        let monitored = worktree("fsmonitor")
        let sentinel = fixture.base.appendingPathComponent("fsmonitor-ran").path
        let hook = fixture.base.appendingPathComponent("fsmonitor-hook.sh").path
        fixture.write(hook, "#!/bin/sh\n/usr/bin/touch '\(sentinel)'\nexit 1\n")
        precondition(chmod(hook, 0o755) == 0)
        fixture.run(["config", "core.fsmonitor", hook], in: repo)
        _ = expectVerified("clean worktree with an fsmonitor hook configured", monitored)
        precondition(!fm.fileExists(atPath: sentinel), "verification ran the repository's fsmonitor hook")
        fixture.run(["status", "--porcelain"], in: monitored)
        precondition(fm.fileExists(atPath: sentinel), "fixture hook is real: plain git status runs it")
        fixture.run(["config", "--unset", "core.fsmonitor"], in: repo)
    }

    // MARK: Recent use

    private static func recency(fixture: GitFixture, worktree: (String) -> String) throws {
        let fresh = worktree("fresh")
        expectBlocked("freshly created worktree", fresh, .recentlyUsed(fresh), within: GitWorktree.recentWindow)
        fixture.backdate(fresh)
        // Twice with the real window: verification must not refresh what it reads.
        for round in 1...2 {
            _ = expectVerified("backdated worktree, round \(round)", fresh, within: GitWorktree.recentWindow)
        }

        // A Claude Code session that worked inside it counts as use.
        let worked = worktree("claude-session")
        fixture.backdate(worked)
        _ = expectVerified("backdated, no sessions", worked, within: GitWorktree.recentWindow)
        let key = String(String.UnicodeScalarView(worked.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? $0 : "-"
        }))
        let folder = AgentSessions.claude.appendingPathComponent(key)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("\(UUID().uuidString).jsonl")
        try Data("{\"type\":\"user\",\"cwd\":\"\(worked)/src\"}\n".utf8).write(to: log)
        expectBlocked("Claude Code session inside", worked, .recentlyUsed(worked), within: GitWorktree.recentWindow)
        try fm.removeItem(at: folder)

        // And so does a Codex session.
        let day = AgentSessions.codex.appendingPathComponent("2026/10/06")
        try fm.createDirectory(at: day, withIntermediateDirectories: true)
        let rollout = day.appendingPathComponent("rollout.jsonl")
        try Data("{\"payload\":{\"cwd\":\"\(worked)\"}}\n".utf8).write(to: rollout)
        expectBlocked("Codex session inside", worked, .recentlyUsed(worked), within: GitWorktree.recentWindow)
        try fm.removeItem(at: rollout)
        _ = expectVerified("sessions gone", worked, within: GitWorktree.recentWindow)
    }

    // MARK: Processes

    private static func processes(worktree: (String) -> String) throws {
        let busy = worktree("process-cwd")
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try fm.createDirectory(atPath: busy + "/node_modules/deep", withIntermediateDirectories: true)
        sleeper.currentDirectoryURL = URL(fileURLWithPath: busy + "/node_modules/deep")
        try sleeper.run()
        usleep(200_000)
        expectBlocked("a process working inside", busy, .inUse(busy))
        sleeper.terminate()
        sleeper.waitUntilExit()
        _ = expectVerified("process gone", busy)
    }

    // MARK: CleanupVerify

    private static func cleanupVerify(base: URL, worktree: (String) -> String) throws {
        precondition(CleanupVerify.blockReason(verify: "", path: "/nonexistent") == nil, "no verifier")
        let unknown = CleanupVerify.blockReason(verify: "made_up", path: base.path)
        precondition(unknown?.english.hasPrefix("Unknown check made_up") == true, "unknown verifier fails closed")

        func cache(_ name: String) throws -> String {
            let path = base.appendingPathComponent("caches/\(name)").path
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        let good = try cache("good")
        try Data((CleanupVerify.cacheSignature + "\n# This file is a cache directory tag.\n").utf8)
            .write(to: URL(fileURLWithPath: good + "/CACHEDIR.TAG"))
        precondition(CleanupVerify.blockReason(verify: "cachedir_tag", path: good) == nil, "valid tag")
        let bad = try cache("bad")
        try Data("Signature: 0000000000000000000000000000000\n".utf8).write(to: URL(fileURLWithPath: bad + "/CACHEDIR.TAG"))
        let short = try cache("short")
        try Data("Signature: 8a477f597d28d172789f06".utf8).write(to: URL(fileURLWithPath: short + "/CACHEDIR.TAG"))
        let missing = try cache("missing")
        let directory = try cache("directory")
        try fm.createDirectory(atPath: directory + "/CACHEDIR.TAG", withIntermediateDirectories: true)
        let linked = try cache("linked")
        try fm.createSymbolicLink(atPath: linked + "/CACHEDIR.TAG", withDestinationPath: good + "/CACHEDIR.TAG")
        for (label, path) in [("bad signature", bad), ("truncated signature", short), ("missing tag", missing),
                              ("directory named CACHEDIR.TAG", directory), ("symlinked tag", linked)] {
            precondition(CleanupVerify.blockReason(verify: "cachedir_tag", path: path) != nil, label)
        }

        let activity = try cache("activity")
        for index in 0..<5 {
            try Data([UInt8(index)]).write(to: URL(fileURLWithPath: activity + "/f\(index)"))
        }
        try fm.createDirectory(atPath: activity + "/sub", withIntermediateDirectories: true)
        try Data([9]).write(to: URL(fileURLWithPath: activity + "/sub/inner"))
        func age(_ paths: [String]) throws {
            let old = Date().addingTimeInterval(-5 * 86400)
            for path in paths { try fm.setAttributes([.modificationDate: old], ofItemAtPath: path) }
        }
        let all = (0..<5).map { activity + "/f\($0)" } + [activity + "/sub/inner", activity + "/sub", activity]
        try age(all)
        precondition(CleanupVerify.blockReason(verify: "recent_activity", path: activity) == nil, "old folder")
        precondition(CleanupVerify.blockReason(verify: "recent_activity", path: activity, entryCap: 3)?
            .english.hasPrefix("Too many files to check") == true, "entry cap blocks")
        try Data([1]).write(to: URL(fileURLWithPath: activity + "/sub/inner"))
        try age([activity + "/sub", activity])
        precondition(CleanupVerify.blockReason(verify: "recent_activity", path: activity)?
            .english.hasPrefix("Changed in the last 2 days") == true, "a new file deep inside blocks")
        try age(all)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: activity + "/sub")
        precondition(CleanupVerify.blockReason(verify: "recent_activity", path: activity)?
            .english.hasPrefix("Could not check every file") == true, "unreadable folder blocks")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: activity + "/sub")
        precondition(CleanupVerify.blockReason(verify: "recent_activity", path: base.path + "/no-such") != nil,
                     "missing folder blocks")

        let tree = worktree("verify-kind")
        precondition(CleanupVerify.blockReason(verify: "git_worktree", path: tree, within: 0) == nil)
        precondition(CleanupVerify.blockReason(verify: "git_worktree", path: tree)?
            .english == GitWorktreeError.recentlyUsed(tree).englishDescription)
    }

    // MARK: Trash → delete → admin entry

    private static func flow(fixture: GitFixture, base: URL, repo: String,
                             worktree: (String) -> String) async throws {
        let trash = base.appendingPathComponent("fake-trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        func toTrash(_ target: CleanupTarget) throws -> CleanupReceipt {
            try CleanupOperations.trash(target) { source in
                let destination = trash.appendingPathComponent(UUID().uuidString)
                try fm.moveItem(at: source, to: destination)
                return destination
            }
        }
        func listed(_ path: String) -> Bool {
            fixture.run(["worktree", "list", "--porcelain"], in: repo)
                .split(separator: "\n").contains { $0 == "worktree \(path)" }
        }
        func ready(_ name: String) throws -> (path: String, admin: String, target: CleanupTarget) {
            let path = worktree(name)
            fixture.backdate(path)
            let target = try CleanupPathSafety.capture(path: path, root: base.path, home: base.path)
            return (path, fixture.admin(of: path), target)
        }

        // Full flow: Trash, delete for good, then only this admin entry goes.
        let neighbour = worktree("neighbour")
        let done = try ready("full-flow")
        precondition(listed(done.path))
        let receipt = try toTrash(done.target)
        precondition(receipt.worktree?.adminDir == done.admin, "receipt records the admin entry")
        precondition(fm.fileExists(atPath: done.admin), "step 1 leaves the admin entry")
        let removed = await CleanupOperations.remove([receipt])
        precondition(removed.errors.isEmpty && removed.remaining.isEmpty && removed.notices.isEmpty,
                     "removal: \(removed.errors) \(removed.notices)")
        precondition(!fm.fileExists(atPath: receipt.url.path), "worktree deleted")
        precondition(!fm.fileExists(atPath: done.admin), "admin entry removed")
        precondition(!listed(done.path), "git no longer lists the worktree")
        precondition(listed(neighbour) && fm.fileExists(atPath: fixture.admin(of: neighbour)),
                     "other worktrees untouched")
        let branch = (done.path as NSString).lastPathComponent
        precondition(!fixture.run(["rev-parse", "--verify", "refs/heads/\(branch)"], in: repo).isEmpty,
                     "the branch survives")

        // Restored from the Trash before step 2: the receipt no longer
        // validates, nothing is deleted and the admin entry stays.
        let restored = try ready("restored")
        let restoredReceipt = try toTrash(restored.target)
        try fm.moveItem(atPath: restoredReceipt.url.path, toPath: restored.path)
        let refused = await CleanupOperations.remove([restoredReceipt]) { _ in
            fatalError("a restored worktree must not reach the eraser")
        }
        precondition(refused.remaining.count == 1 && !refused.errors.isEmpty)
        precondition(fm.fileExists(atPath: restored.admin) && listed(restored.path), "admin entry intact")

        // Admin entry changed while the worktree sat in the Trash: the
        // worktree is freed, the entry is left and reported.
        let changed = try ready("admin-changed")
        let changedReceipt = try toTrash(changed.target)
        fixture.write(changed.admin + "/gitdir", neighbour + "/.git\n")
        let partial = await CleanupOperations.remove([changedReceipt])
        precondition(partial.errors.isEmpty && partial.remaining.isEmpty, "the worktree itself was freed")
        precondition(partial.notices.count == 1 && fm.fileExists(atPath: changed.admin), "entry left and reported")

        // A worktree dirtied after planning is refused at the Trash boundary.
        let late = try ready("dirtied-late")
        fixture.write(late.path + "/late.txt", "late\n")
        do {
            _ = try toTrash(late.target)
            fatalError("a dirtied worktree must not move")
        } catch CleanupPathError.gitWorktree(.changes) {
            precondition(fm.fileExists(atPath: late.path))
        }
    }

    // MARK: Helpers

    @discardableResult
    private static func expectVerified(_ label: String, _ path: String, within: TimeInterval = 0) -> WorktreeInfo {
        do {
            return try GitWorktree.verify(path, recentWithin: within)
        } catch {
            fatalError("\(label): unexpectedly blocked: \(error)")
        }
    }

    private static func expectBlocked(_ label: String, _ path: String, _ expected: GitWorktreeError,
                                      within: TimeInterval = 0, lookup: GitLookup? = nil) {
        do {
            let info = try GitWorktree.verify(path, recentWithin: within, lookup: lookup)
            fatalError("\(label): unexpectedly verified: \(info)")
        } catch let error as GitWorktreeError {
            precondition(error == expected, "\(label): blocked for the wrong reason: \(error)")
            precondition(!error.englishDescription.isEmpty && error.errorDescription != nil)
        } catch {
            fatalError("\(label): unexpected error \(error)")
        }
    }
}
