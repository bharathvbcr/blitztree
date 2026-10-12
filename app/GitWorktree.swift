import Darwin
import Foundation

/// A linked git worktree that passed every check in `GitWorktree.verify`.
nonisolated struct WorktreeInfo: Sendable, Equatable {
    /// The worktree folder, as it was asked about (normalized).
    let path: String
    /// `<common>/worktrees/<id>`, resolved.
    let adminDir: String
    /// The repository's shared git directory, resolved.
    let commonDir: String
    /// Short branch name, or nil when HEAD is detached (then it is contained in a ref).
    let branch: String?
    let head: String
    /// Latest of the admin entry's index, HEAD and logs/HEAD modification dates.
    let lastUsed: Date
}

/// The admin entry of a worktree moved to the Trash, as it was just before the
/// move. `GitWorktree.removeAdminEntry` deletes it only if it is still exactly this.
nonisolated struct WorktreeAdminEntry: Sendable, Equatable {
    let adminDir: String
    let adminIdentity: CleanupIdentity
    /// `<common>/worktrees`, which must still hold the admin dir.
    let worktreesIdentity: CleanupIdentity
    let commonIdentity: CleanupIdentity
    let gitdirIdentity: CleanupIdentity
    /// Raw bytes of `<admin>/gitdir`.
    let gitdirContent: Data
    /// The `.git` file that content names (relative names joined to the admin dir).
    let gitFile: String
}

nonisolated enum GitWorktreeError: Error, LocalizedError, Equatable, Sendable {
    /// Not a linked worktree whose metadata points back to itself. The cleanup
    /// guard reports this exactly as it reports any other `.git` marker.
    case notWorktree(String)
    case locked(String)
    case submodules(String)
    case gitMissing(String)
    case gitFailed(String, String)
    case timedOut(String)
    case changes(String)
    case hiddenChanges(String)
    case unreachableHead(String)
    case recentlyUsed(String)
    case inUse(String)
    case processCheckFailed(String)
    /// Ignored files git status leaves out that a build would not recreate.
    case ignoredFiles(String)
    /// The agents' session logs could not all be read, so use cannot be ruled out.
    case sessionsUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .notWorktree(let path): return String(localized: "Not a linked git worktree: \(path)")
        case .locked(let path): return String(localized: "Git worktree is locked: \(path)")
        case .submodules(let path): return String(localized: "Git worktree has submodules: \(path)")
        case .gitMissing(let path): return String(localized: "Git is not available to check this worktree: \(path)")
        case .gitFailed(let path, let detail): return String(localized: "Git could not check \(path): \(detail)")
        case .timedOut(let path): return String(localized: "Checking this git worktree took too long: \(path)")
        case .changes(let path): return String(localized: "Git worktree has uncommitted or untracked changes: \(path)")
        case .hiddenChanges(let path): return String(localized: "Git worktree has files hidden from git status: \(path)")
        case .unreachableHead(let path): return String(localized: "Git worktree has commits on no branch or tag: \(path)")
        case .recentlyUsed(let path): return String(localized: "Git worktree used in the last 2 days: \(path)")
        case .inUse(let path): return String(localized: "A running process is working in this git worktree: \(path)")
        case .processCheckFailed(let path): return String(localized: "Could not check for processes using this git worktree: \(path)")
        case .ignoredFiles(let path): return String(localized: "Git worktree has ignored files that a build would not recreate (such as .env): \(path)")
        case .sessionsUnreadable(let path): return String(localized: "Could not read the coding agents' session logs to check whether this git worktree is in use: \(path)")
        }
    }

    var englishDescription: String {
        switch self {
        case .notWorktree(let path): return "Not a linked git worktree: \(path)"
        case .locked(let path): return "Git worktree is locked: \(path)"
        case .submodules(let path): return "Git worktree has submodules: \(path)"
        case .gitMissing(let path): return "Git is not available to check this worktree: \(path)"
        case .gitFailed(let path, let detail): return "Git could not check \(path): \(detail)"
        case .timedOut(let path): return "Checking this git worktree took too long: \(path)"
        case .changes(let path): return "Git worktree has uncommitted or untracked changes: \(path)"
        case .hiddenChanges(let path): return "Git worktree has files hidden from git status: \(path)"
        case .unreachableHead(let path): return "Git worktree has commits on no branch or tag: \(path)"
        case .recentlyUsed(let path): return "Git worktree used in the last 2 days: \(path)"
        case .inUse(let path): return "A running process is working in this git worktree: \(path)"
        case .processCheckFailed(let path): return "Could not check for processes using this git worktree: \(path)"
        case .ignoredFiles(let path): return "Git worktree has ignored files that a build would not recreate (such as .env): \(path)"
        case .sessionsUnreadable(let path): return "Could not read the coding agents' session logs to check whether this git worktree is in use: \(path)"
        }
    }
}

/// Where verification may find git. /usr/bin/git and /usr/bin/xcrun are
/// shims that can raise the Command Line Tools install prompt, so they are
/// never run; a git is taken from `searchPath`, else from the selected
/// developer directory when `xcode-select -p` names one that has git.
nonisolated struct GitLookup: Sendable, Equatable {
    var searchPath: String
    var useDeveloperDir: Bool

    /// The app's PATH plus the usual package-manager locations. The app should
    /// set `GitWorktree.lookup` from the user's shell PATH once it is known.
    static var standard: GitLookup {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return GitLookup(searchPath: inherited + ":/opt/homebrew/bin:/usr/local/bin", useDeveloperDir: true)
    }
}

/// Verifies linked git worktrees with read-only, hardened git: no fsmonitor
/// hooks, no optional index writes, no prompts, no stdin, bounded time and
/// output. Anything that cannot be checked blocks.
nonisolated enum GitWorktree {
    static let recentWindow: TimeInterval = 2 * 86400

    private static let settings = Settings(GitLookup.standard)

    /// The lookup the cleanup guard uses. Tests inject an empty one to prove
    /// that a missing git blocks.
    static var lookup: GitLookup {
        get { settings.value }
        set { settings.value = newValue }
    }

    private static let gitBudget: TimeInterval = 20
    private static let lsofTimeout: TimeInterval = 10
    private static let markerLimit = 4096
    private static let statusCap = 1 << 20
    private static let listCap = 64 << 20
    private static let lsofCap = 32 << 20
    private static let dataRoot = "/System/Volumes/Data"

    // MARK: Verification

    static func verify(
        _ rawPath: String,
        recentWithin: TimeInterval = recentWindow,
        lookup: GitLookup? = nil,
        now: Date = Date()
    ) throws -> WorktreeInfo {
        let layout = try self.layout(of: rawPath)
        let path = layout.path
        if try exists(layout.admin + "/locked", path: path) { throw GitWorktreeError.locked(path) }
        if try exists(path + "/.gitmodules", path: path) { throw GitWorktreeError.submodules(path) }

        // Read the recency evidence before git runs, so the check can never
        // be satisfied (or defeated) by its own activity.
        let stamps = [layout.admin + "/index", layout.admin + "/HEAD", layout.admin + "/logs/HEAD"]
        let dates = stamps.compactMap(modificationDate)
        guard let lastUsed = dates.max() else { throw GitWorktreeError.notWorktree(path) }
        let cutoff = now.addingTimeInterval(-recentWithin)
        if lastUsed > cutoff { throw GitWorktreeError.recentlyUsed(path) }
        // A session found anywhere is use; logs that could not be read leave the
        // question open, which blocks with its own reason, not as "unused".
        var unreadable = false
        let reads: [(String) -> AgentSessions.Usage] = [
            { AgentSessions.claudeUsage(in: $0, since: cutoff) },
            { AgentSessions.usage(in: $0, root: AgentSessions.codex, since: cutoff) },
        ]
        for spelling in spellings(of: path, real: layout.realPath) {
            for read in reads {
                switch read(spelling) {
                case .used: throw GitWorktreeError.recentlyUsed(path)
                case .unknown: unreadable = true
                case .unused: break
                }
            }
        }
        if unreadable { throw GitWorktreeError.sessionsUnreadable(path) }

        guard let git = locateGit(lookup ?? self.lookup) else { throw GitWorktreeError.gitMissing(path) }
        let runner = GitRunner(git: git, layout: layout, deadline: Date().addingTimeInterval(gitBudget))

        // Ignored files count too: git status leaves them out, yet `.env` files,
        // local databases and data kept under an ignored path are not recreated
        // by a build. Only what a build recreates (an ignored `node_modules`...)
        // may be there.
        let status = try runner.run(["status", "--porcelain=v1", "-z", "--untracked-files=all",
                                     "--ignore-submodules=none", "--no-renames", "--ignored=matching"], cap: statusCap)
        if status.overflow { throw GitWorktreeError.changes(path) }
        for entry in status.stdout.split(separator: 0, omittingEmptySubsequences: true) {
            guard entry.count > 3, entry.starts(with: Array("!! ".utf8)) else { throw GitWorktreeError.changes(path) }
            let parts = String(decoding: entry.dropFirst(3), as: UTF8.self).split(separator: "/").map(String.init)
            // Finder writes .DS_Store into every folder it opens, and most
            // global gitignores list it: it holds nothing worth keeping.
            if parts.last == ".DS_Store" { continue }
            if !parts.contains(where: { CleanupPathSafety.rebuildable.contains($0) }) {
                throw GitWorktreeError.ignoredFiles(path)
            }
        }

        // Assume-unchanged (lowercase tag) and skip-worktree ("S") entries are
        // invisible to status, so only plain tracked entries ("H") pass.
        let listed = try runner.run(["ls-files", "-v", "-z"], cap: listCap)
        if listed.overflow { throw GitWorktreeError.gitFailed(path, "too many files to check") }
        for entry in listed.stdout.split(separator: 0, omittingEmptySubsequences: true) {
            guard entry.count >= 2, entry[entry.startIndex] == UInt8(ascii: "H"),
                  entry[entry.startIndex + 1] == UInt8(ascii: " ") else {
                throw GitWorktreeError.hiddenChanges(path)
            }
        }

        let symbolic = try runner.run(["symbolic-ref", "-q", "HEAD"], cap: 4096, allowed: [0, 1])
        let headRef = symbolic.status == 0 ? symbolic.text : nil
        let resolved = try runner.run(["rev-parse", "--verify", "-q", "HEAD^{commit}"], cap: 4096)
        let head = resolved.text
        guard head.count == 40 || head.count == 64,
              head.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else {
            throw GitWorktreeError.gitFailed(path, "unexpected HEAD")
        }
        var branch: String?
        if let headRef, headRef.hasPrefix("refs/heads/"), headRef.count > "refs/heads/".count {
            branch = String(headRef.dropFirst("refs/heads/".count))
        } else {
            let containing = try runner.run(["for-each-ref", "--contains", head, "--count=1",
                                             "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"],
                                            cap: 4096)
            if containing.text.isEmpty { throw GitWorktreeError.unreachableHead(path) }
            branch = nil
        }

        try rejectProcesses(inside: path, real: layout.realPath)
        return WorktreeInfo(path: path, adminDir: layout.admin, commonDir: layout.common,
                            branch: branch, head: head, lastUsed: lastUsed)
    }

    /// Records the admin entry immediately before the worktree is moved.
    static func adminEntry(for info: WorktreeInfo) throws -> WorktreeAdminEntry {
        let admin = info.adminDir
        let parent = (admin as NSString).deletingLastPathComponent
        let gitdir = try readMarker(admin + "/gitdir", path: info.path)
        let line = try singleLine(gitdir.data, path: info.path)
        return WorktreeAdminEntry(
            adminDir: admin,
            adminIdentity: try identity(admin, path: info.path),
            worktreesIdentity: try identity(parent, path: info.path),
            commonIdentity: try identity(info.commonDir, path: info.path),
            gitdirIdentity: gitdir.identity,
            gitdirContent: gitdir.data,
            gitFile: join(line, to: admin)
        )
    }

    /// After the worktree itself was deleted for good: removes its admin entry
    /// only while that entry is unchanged and still names the vanished `.git`
    /// file. Returns nil on success, otherwise why it was left in place.
    static func removeAdminEntry(_ entry: WorktreeAdminEntry, erase: (String) -> String?) -> String? {
        let admin = entry.adminDir
        let parent = (admin as NSString).deletingLastPathComponent
        let common = (parent as NSString).deletingLastPathComponent
        guard (parent as NSString).lastPathComponent == "worktrees",
              (try? identity(admin, path: admin)) == entry.adminIdentity,
              entry.adminIdentity.type == directoryMode,
              (try? identity(parent, path: admin)) == entry.worktreesIdentity,
              (try? identity(common, path: admin)) == entry.commonIdentity,
              let gitdir = try? readMarker(admin + "/gitdir", path: admin),
              gitdir.identity == entry.gitdirIdentity, gitdir.data == entry.gitdirContent else {
            return String(localized: "Left git worktree metadata in place because it changed: \(admin)")
        }
        let worktree = (entry.gitFile as NSString).deletingLastPathComponent
        guard isMissing(entry.gitFile), isMissing(worktree) else {
            return String(localized: "Left git worktree metadata in place because the worktree exists again: \(admin)")
        }
        guard isMissing(admin + "/locked") else {
            return String(localized: "Left git worktree metadata in place because it is locked: \(admin)")
        }
        if let error = erase(admin) {
            return String(localized: "Could not remove git worktree metadata: \(error)")
        }
        return nil
    }

    // MARK: Layout

    struct Layout: Sendable {
        let path: String
        let realPath: String
        let admin: String
        let common: String
    }

    /// Structural checks only, no git: `<path>/.git` is a small regular file of
    /// exactly one `gitdir: ` line naming `<common>/worktrees/<id>`, whose
    /// `gitdir` names this same `.git` file back, and whose common dir lies
    /// outside the worktree.
    static func layout(of rawPath: String) throws -> Layout {
        guard let path = try? CleanupPathSafety.normalize(rawPath) else {
            throw GitWorktreeError.notWorktree(rawPath)
        }
        let fail = GitWorktreeError.notWorktree(path)
        guard let folder = try? lstatInfo(path), folder.st_mode & S_IFMT == S_IFDIR,
              let realPath = realPath(path) else { throw fail }

        let gitFile = path + "/.git"
        let marker = try readMarker(gitFile, path: path)
        let markerLine = try singleLine(marker.data, path: path)
        guard markerLine.hasPrefix("gitdir: ") else { throw fail }
        let reference = String(markerLine.dropFirst("gitdir: ".count))
        guard !reference.isEmpty, let admin = self.realPath(join(reference, to: path)),
              let adminInfo = try? lstatInfo(admin), adminInfo.st_mode & S_IFMT == S_IFDIR else { throw fail }

        let commonLine = try singleLine(try readMarker(admin + "/commondir", path: path).data, path: path)
        guard !commonLine.isEmpty, let common = self.realPath(join(commonLine, to: admin)),
              let commonInfo = try? lstatInfo(common), commonInfo.st_mode & S_IFMT == S_IFDIR else { throw fail }
        // The admin entry must be one of the common dir's own worktree entries.
        let parent = (admin as NSString).deletingLastPathComponent
        guard (parent as NSString).lastPathComponent == "worktrees",
              let parentID = try? identity(parent, path: path),
              let worktreesID = try? identity(common + "/worktrees", path: path),
              parentID == worktreesID else { throw fail }

        let backLine = try singleLine(try readMarker(admin + "/gitdir", path: path).data, path: path)
        guard !backLine.isEmpty, let back = try? lstatInfo(join(backLine, to: admin)),
              back.st_dev == marker.info.st_dev, back.st_ino == marker.info.st_ino else { throw fail }

        // By identity, so the Data-volume and firmlinked spellings of one
        // folder cannot hide a repository nested inside the worktree.
        for (inner, outer) in [(common, realPath), (admin, realPath), (realPath, common)]
        where isWithin(inner, outer) {
            throw fail
        }
        return Layout(path: path, realPath: realPath, admin: admin, common: common)
    }

    /// Whether `inner` is `outer` or inside it, comparing each ancestor of
    /// `inner` with `outer` by device and inode. Unreadable means yes.
    private static func isWithin(_ inner: String, _ outer: String) -> Bool {
        guard let target = try? lstatInfo(outer) else { return true }
        var current = inner
        while true {
            guard let info = try? lstatInfo(current) else { return true }
            if info.st_dev == target.st_dev && info.st_ino == target.st_ino { return true }
            if current == "/" { return false }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    // MARK: Git

    static func locateGit(_ lookup: GitLookup) -> String? {
        let shim = try? statInfo("/usr/bin/git")
        func usable(_ candidate: String) -> Bool {
            guard candidate != "/usr/bin/git", let info = try? statInfo(candidate),
                  info.st_mode & S_IFMT == S_IFREG, access(candidate, X_OK) == 0 else { return false }
            if let shim, shim.st_dev == info.st_dev, shim.st_ino == info.st_ino { return false }
            return true
        }
        for directory in lookup.searchPath.split(separator: ":").map(String.init)
        where directory.hasPrefix("/") {
            let candidate = (directory as NSString).appendingPathComponent("git")
            if usable(candidate) { return candidate }
        }
        guard lookup.useDeveloperDir,
              let selected = BoundedProcess.run("/usr/bin/xcode-select", ["-p"],
                                                environment: minimalEnvironment, timeout: 5, cap: 4096),
              selected.status == 0, !selected.timedOut, !selected.overflow else { return nil }
        let developer = selected.text
        guard developer.hasPrefix("/") else { return nil }
        let candidate = (developer as NSString).appendingPathComponent("usr/bin/git")
        return usable(candidate) ? candidate : nil
    }

    private static var minimalEnvironment: [String: String] {
        ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    }

    private struct GitRunner {
        let git: String
        let layout: Layout
        let deadline: Date

        /// Runs one read-only git command against exactly the verified admin
        /// dir and worktree; no repository discovery, no inherited GIT_* state.
        func run(_ arguments: [String], cap: Int, allowed: Set<Int32> = [0]) throws -> BoundedProcess.Outcome {
            let path = layout.path
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw GitWorktreeError.timedOut(path) }
            var environment = GitWorktree.minimalEnvironment
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_PAGER"] = "cat"
            environment["PAGER"] = "cat"
            let full = ["--no-optional-locks", "--git-dir=" + layout.admin, "--work-tree=" + layout.path,
                        "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false"] + arguments
            guard let outcome = BoundedProcess.run(git, full, environment: environment,
                                                   timeout: remaining, cap: cap) else {
                throw GitWorktreeError.gitMissing(path)
            }
            if outcome.timedOut { throw GitWorktreeError.timedOut(path) }
            guard allowed.contains(outcome.status) else {
                let detail = String(decoding: outcome.stderr.prefix(300), as: UTF8.self)
                    .split(separator: "\n").first.map(String.init) ?? "exit \(outcome.status)"
                throw GitWorktreeError.gitFailed(path, detail)
            }
            return outcome
        }
    }

    // MARK: Processes

    /// Blocks when any process this user can see has its working directory at
    /// or inside the worktree. lsof failing to run or answer blocks too.
    private static func rejectProcesses(inside path: String, real: String) throws {
        guard let outcome = BoundedProcess.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-w"],
                                               environment: minimalEnvironment, timeout: lsofTimeout, cap: lsofCap),
              !outcome.timedOut, !outcome.overflow, outcome.status == 0 else {
            throw GitWorktreeError.processCheckFailed(path)
        }
        let names = String(decoding: outcome.stdout, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("n") }.map { $0.dropFirst().lowercased() }
        guard !names.isEmpty else { throw GitWorktreeError.processCheckFailed(path) }
        for spelling in spellings(of: path, real: real).map({ $0.lowercased() }) {
            if names.contains(where: { $0 == spelling || $0.hasPrefix(spelling + "/") }) {
                throw GitWorktreeError.inUse(path)
            }
        }
    }

    /// The given, resolved and Data-volume spellings of a folder.
    private static func spellings(of path: String, real: String) -> [String] {
        var result: [String] = []
        for spelling in [path, real] {
            let other = spelling.hasPrefix(dataRoot + "/") ? String(spelling.dropFirst(dataRoot.count))
                                                           : dataRoot + spelling
            for candidate in [spelling, other] where !result.contains(candidate) { result.append(candidate) }
        }
        return result
    }

    // MARK: Files

    private static let directoryMode = UInt16(S_IFDIR)

    private struct Marker {
        let data: Data
        let info: stat
        var identity: CleanupIdentity {
            CleanupIdentity(device: UInt64(truncatingIfNeeded: info.st_dev),
                            inode: UInt64(truncatingIfNeeded: info.st_ino),
                            type: UInt16(truncatingIfNeeded: info.st_mode) & UInt16(S_IFMT))
        }
    }

    /// A small regular file, read without following a final symlink and only
    /// when the opened file is the one lstat saw.
    private static func readMarker(_ file: String, path: String) throws -> Marker {
        let fail = GitWorktreeError.notWorktree(path)
        guard let seen = try? lstatInfo(file), seen.st_mode & S_IFMT == S_IFREG,
              seen.st_size > 0, seen.st_size <= markerLimit else { throw fail }
        let fd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw fail }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == seen.st_dev, opened.st_ino == seen.st_ino else { throw fail }
        var buffer = [UInt8](repeating: 0, count: markerLimit + 1)
        var count = 0
        while count < buffer.count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + count, $0.count - count) }
            if n < 0 { throw fail }
            if n == 0 { break }
            count += n
        }
        guard count > 0, count <= markerLimit else { throw fail }
        return Marker(data: Data(buffer.prefix(count)), info: opened)
    }

    /// Exactly one line: optional single trailing newline, no other control bytes.
    private static func singleLine(_ data: Data, path: String) throws -> String {
        var bytes = Array(data)
        if bytes.last == 0x0a { bytes.removeLast() }
        guard !bytes.contains(where: { $0 < 0x20 || $0 == 0x7f }),
              let text = String(bytes: bytes, encoding: .utf8) else { throw GitWorktreeError.notWorktree(path) }
        return text
    }

    private static func join(_ reference: String, to base: String) -> String {
        reference.hasPrefix("/") ? reference : (base as NSString).appendingPathComponent(reference)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func lstatInfo(_ path: String) throws -> stat {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else { throw CleanupPathError.unavailable(path, errno) }
        return info
    }

    /// Metadata of what `path` finally names, symlinks resolved.
    private static func statInfo(_ path: String) throws -> stat {
        guard let resolved = realPath(path) else { throw CleanupPathError.missing(path) }
        return try lstatInfo(resolved)
    }

    private static func identity(_ file: String, path: String) throws -> CleanupIdentity {
        guard let info = try? lstatInfo(file) else { throw GitWorktreeError.notWorktree(path) }
        return CleanupIdentity(device: UInt64(truncatingIfNeeded: info.st_dev),
                               inode: UInt64(truncatingIfNeeded: info.st_ino),
                               type: UInt16(truncatingIfNeeded: info.st_mode) & UInt16(S_IFMT))
    }

    /// True when present, false only when lstat says it does not exist.
    private static func exists(_ file: String, path: String) throws -> Bool {
        var info = stat()
        if Darwin.lstat(file, &info) == 0 { return true }
        let code = errno
        if code == ENOENT { return false }
        throw GitWorktreeError.gitFailed(path, "cannot inspect \(file) (errno \(code))")
    }

    private static func isMissing(_ file: String) -> Bool {
        var info = stat()
        return Darwin.lstat(file, &info) != 0 && errno == ENOENT
    }

    private static func modificationDate(_ file: String) -> Date? {
        guard let info = try? lstatInfo(file) else { return nil }
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }

    private final class Settings: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: GitLookup
        init(_ initial: GitLookup) { stored = initial }
        var value: GitLookup {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}

/// Runs a program with an argument array (no shell), stdin closed, a fixed
/// environment, a time limit and an output cap. Both pipes are drained while
/// it runs, so a chatty child cannot stall on a full pipe.
nonisolated enum BoundedProcess {
    struct Outcome: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
        let timedOut: Bool
        /// Stdout went past the cap; what was kept is only a prefix.
        let overflow: Bool

        var text: String {
            String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Nil when the program could not be started.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    timeout: TimeInterval, cap: Int) -> Outcome? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let outBuffer = Capped(cap: cap), errBuffer = Capped(cap: 64 * 1024)
        let drained = DispatchGroup()
        for (pipe, buffer) in [(out, outBuffer), (err, errBuffer)] {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if buffer.finish() { drained.leave() }
                } else {
                    buffer.append(data)
                }
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        var timedOut = false
        if exited.wait(timeout: .now() + max(0, timeout)) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        // A descendant left running can hold the pipes open; do not wait on it.
        if drained.wait(timeout: .now() + 2) == .timedOut {
            timedOut = true
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }
        let status = process.isRunning ? -1 : process.terminationStatus
        return Outcome(status: status, stdout: outBuffer.data, stderr: errBuffer.data,
                       timedOut: timedOut, overflow: outBuffer.overflow)
    }

    private final class Capped: @unchecked Sendable {
        private let lock = NSLock()
        private let cap: Int
        private var stored = Data()
        private var over = false
        private var done = false
        init(cap: Int) { self.cap = cap }

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            let room = cap - stored.count
            if chunk.count > room { over = true }
            if room > 0 { stored.append(chunk.prefix(room)) }
        }

        /// True exactly once, on the first end of file.
        func finish() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }

        var data: Data { lock.lock(); defer { lock.unlock() }; return stored }
        var overflow: Bool { lock.lock(); defer { lock.unlock() }; return over }
    }
}
