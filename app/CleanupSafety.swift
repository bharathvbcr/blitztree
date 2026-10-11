import Darwin
import Foundation

/// Stable metadata used to detect a path replacement between planning and an
/// operation.  This deliberately uses lstat: a symlink is a different object
/// from its target and is never silently followed by the guard.
nonisolated struct CleanupIdentity: Sendable, Equatable, Hashable {
    let device: UInt64
    let inode: UInt64
    let type: UInt16

    static func capture(path: String) throws -> CleanupIdentity {
        let normalized = try CleanupPathSafety.normalize(path)
        return try CleanupPathSafety.identity(of: normalized)
    }
}

nonisolated enum CleanupPathError: Error, LocalizedError, Equatable, Sendable {
    case invalidPath(String)
    case unavailable(String, Int32)
    case missing(String)
    case notDirectory(String)
    case symlink(String)
    case cloudOnly(String)
    case outsideRoot(String)
    case differentVolume(String)
    case changed(String)
    case protectedPath(String)
    case tooBroad(String)
    case gitPath(String)
    /// A linked git worktree that was recognised but did not pass verification.
    case gitWorktree(GitWorktreeError)
    /// Inside the temp folder of a Claude Code session that is still running.
    case sessionRunning(String)
    /// Inside a Claude Code session's temp folder, and whether that session
    /// still runs could not be read.
    case sessionUnverified(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return String(localized: "Invalid cleanup path: \(path)")
        case .unavailable(let path, let code): return String(localized: "Cannot inspect \(path) (errno \(code))")
        case .missing(let path): return String(localized: "Path is missing: \(path)")
        case .notDirectory(let path): return String(localized: "Path component is not a directory: \(path)")
        case .symlink(let path): return String(localized: "Symlinks are not allowed in cleanup paths: \(path)")
        case .cloudOnly(let path): return String(localized: "Cloud-only path is not available locally: \(path)")
        case .outsideRoot(let path): return String(localized: "Path is outside the authorized scan root: \(path)")
        case .differentVolume(let path): return String(localized: "Path is on a different volume: \(path)")
        case .changed(let path): return String(localized: "Path changed since it was checked: \(path)")
        case .protectedPath(let path): return String(localized: "Protected path: \(path)")
        case .tooBroad(let path): return String(localized: "Path is too broad to clean: \(path)")
        case .gitPath(let path): return String(localized: "Git metadata path is protected: \(path)")
        case .gitWorktree(let error): return error.errorDescription
        case .sessionRunning(let path): return String(localized: "A Claude Code session that is still running uses this: \(path)")
        case .sessionUnverified(let path): return String(localized: "Couldn't check whether the Claude Code session using this has ended: \(path)")
        }
    }

    var englishDescription: String {
        switch self {
        case .invalidPath(let path): return "Invalid cleanup path: \(path)"
        case .unavailable(let path, let code): return "Cannot inspect \(path) (errno \(code))"
        case .missing(let path): return "Path is missing: \(path)"
        case .notDirectory(let path): return "Path component is not a directory: \(path)"
        case .symlink(let path): return "Symlinks are not allowed in cleanup paths: \(path)"
        case .cloudOnly(let path): return "Cloud-only path is not available locally: \(path)"
        case .outsideRoot(let path): return "Path is outside the authorized scan root: \(path)"
        case .differentVolume(let path): return "Path is on a different volume: \(path)"
        case .changed(let path): return "Path changed since it was checked: \(path)"
        case .protectedPath(let path): return "Protected path: \(path)"
        case .tooBroad(let path): return "Path is too broad to clean: \(path)"
        case .gitPath(let path): return "Git metadata path is protected: \(path)"
        case .gitWorktree(let error): return error.englishDescription
        case .sessionRunning(let path): return "A Claude Code session that is still running uses this: \(path)"
        case .sessionUnverified(let path): return "Couldn't check whether the Claude Code session using this has ended: \(path)"
        }
    }
}

/// A path inside a Claude Code session's temp folder,
/// `/private/tmp/claude-<uid>/<project>/<session id>/...`. The same shape the
/// Rust rule `agent_scratch` recognises (`in_claude_scratchpad`).
nonisolated struct ClaudeTemp: Sendable, Equatable {
    /// `/private/tmp/claude-<uid>`, in the spelling the path used.
    let root: String
    let sessionID: String
    /// `<root>/<project>/<session id>`.
    let sessionFolder: String
    /// How many components the path has below `<session>/scratchpad`; nil
    /// when it is not inside the scratchpad.
    let scratchDepth: Int?

    /// A path strictly inside the scratchpad, where planners may clean.
    var inScratchpad: Bool { (scratchDepth ?? 0) >= 1 }
}

/// A captured path plus the roots and identity against which it can be
/// revalidated immediately before an operation.  Capturing and validating
/// perform metadata reads only; this type never moves, removes, or opens files.
nonisolated struct CleanupTarget: Sendable, Equatable {
    let path: String
    let root: String
    let home: String
    let identity: CleanupIdentity

    // These are intentionally kept with the target so replacing an authorized
    // root or home directory also invalidates an old plan.
    let rootIdentity: CleanupIdentity
    let homeIdentity: CleanupIdentity

    func validate() throws {
        _ = try CleanupPathSafety.validate(self)
    }
}

/// Shared path policy for the agent and the manual Clean Up panel.
nonisolated enum CleanupPathSafety {
    private static let dataRoot = "/System/Volumes/Data"
    private static let modeMask: UInt16 = 0o170000
    private static let modeDirectory: UInt16 = 0o040000
    private static let modeSymlink: UInt16 = 0o120000
    private static let modeRegular: UInt16 = 0o100000
    private static let dataLessFlag: UInt64 = 0x4000_0000

    /// Rebuildable names are shared with the agent's recent-use policy.
    static let rebuildable: Set<String> = [
        "node_modules", ".venv", "venv", "target", ".next", ".turbo", ".nuxt", ".svelte-kit",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", "DerivedData", ".gradle",
        ".parcel-cache", ".expo", "Pods",
    ]

    private static let protectedRelative = [
        "Documents", "Desktop", "Pictures", "Movies", "Music", ".ssh", ".gnupg", ".Trash",
        "Library/Mobile Documents", "Library/Mail", "Library/Messages", "Library/Keychains",
        "Library/Photos", "Library/CloudStorage",
    ]

    private static let broadRelative: Set<String> = [
        "Library", "Library/Caches", "Library/Application Support", "Library/Containers",
        "Library/Group Containers", "Library/Developer", "Library/Preferences", ".config", ".cache",
        "Library/Developer/CoreSimulator", "Library/Developer/CoreSimulator/Devices",
        ".local", ".local/share", "Downloads",
    ]

    /// Folders that alter app behavior or persistence (launch agents, fonts,
    /// keychain helpers…): the folder and everything inside it is off limits.
    /// Unlike `Library/Caches`, no named subfolder of these is a rebuildable
    /// cache, so they block recursively.
    private static let neverCleanRelative = [
        "Library/LaunchAgents", "Library/LaunchDaemons", "Library/Cookies", "Library/Logs",
        "Library/Saved Application State", "Library/Spelling", "Library/Frameworks",
        "Library/PrivilegedHelperTools", "Library/ScriptingAdditions",
        "Library/Internet Plug-Ins", "Library/PreferencePanes", "Library/Input Methods",
        "Library/Fonts", "Library/Services", "Library/StartupItems", "Library/Tokens",
        "Library/Widgets", "Library/Metadata", "Library/Desktop Pictures",
        "Library/Screen Savers", "Library/Workflows", "Library/Automator",
        "Library/Contextual Menu Items", "Library/Compositions", "Library/DirectoryServices",
        "Library/Calendars", "Library/Accounts", "Library/Application Scripts",
    ]

    static func capture(
        path: String,
        root: String = NSHomeDirectory(),
        home: String = NSHomeDirectory()
    ) throws -> CleanupTarget {
        let p = try normalize(path)
        let r = try normalize(root)
        let h = try normalize(home)
        let rootObserved = try inspect(r, requireDirectory: true)
        let homeObserved = try inspect(h, requireDirectory: true)
        let targetObserved = try inspect(p, requireDirectory: false)
        let target = CleanupTarget(
            path: p, root: r, home: h, identity: targetObserved.identity,
            rootIdentity: rootObserved.identity, homeIdentity: homeObserved.identity
        )
        _ = try enforce(target, targetObserved: targetObserved, rootObserved: rootObserved,
                        homeObserved: homeObserved)
        return target
    }

    /// Revalidates `target` like `CleanupTarget.validate()` and returns the
    /// worktree verification that allowed it, when it is a linked git worktree.
    static func validatedWorktree(_ target: CleanupTarget) throws -> WorktreeInfo? {
        try validate(target)
    }

    static func normalize(_ raw: String) throws -> String {
        guard !raw.isEmpty, !raw.utf8.contains(0) else {
            throw CleanupPathError.invalidPath(raw)
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw CleanupPathError.invalidPath(raw) }
        // Do not collapse a symlinked component followed by ".." before the
        // component-by-component lstat walk gets to inspect it.
        if (expanded as NSString).pathComponents.dropFirst().contains("..") {
            throw CleanupPathError.invalidPath(raw)
        }
        let components = (expanded as NSString).pathComponents
        guard components.first == "/" else { throw CleanupPathError.invalidPath(raw) }
        var normalized = "/"
        for component in components.dropFirst() where component != "." {
            normalized = (normalized as NSString).appendingPathComponent(component)
        }
        return normalized
    }

    /// The same narrow Documents exception used by the planner and path
    /// policy. Home aliases are accepted only when their identity matches.
    static func codexChat(_ path: String, home: String = NSHomeDirectory()) -> String? {
        guard let p = try? normalize(path), let h = try? normalize(home),
              let homeIdentity = try? identity(of: h),
              let homePath = homeAlias(p, home: h, homeIdentity: homeIdentity),
              let relative = relativePath(homePath, under: h) else { return nil }
        let parts = relative.split(separator: "/")
        guard parts.count >= 4,
              parts[0].caseInsensitiveCompare("Documents") == .orderedSame,
              parts[1].caseInsensitiveCompare("Codex") == .orderedSame,
              parts[2].wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return nil }
        return h + "/" + parts.prefix(4).joined(separator: "/")
    }

    fileprivate static func identity(of path: String) throws -> CleanupIdentity {
        let info = try readStat(path)
        return CleanupIdentity(
            device: UInt64(truncatingIfNeeded: info.st_dev),
            inode: UInt64(truncatingIfNeeded: info.st_ino),
            type: UInt16(truncatingIfNeeded: info.st_mode) & modeMask
        )
    }

    fileprivate static func validate(_ target: CleanupTarget) throws -> WorktreeInfo? {
        let rootObserved = try inspect(target.root, requireDirectory: true)
        guard rootObserved.identity == target.rootIdentity else {
            throw CleanupPathError.changed(target.root)
        }
        let homeObserved = try inspect(target.home, requireDirectory: true)
        guard homeObserved.identity == target.homeIdentity else {
            throw CleanupPathError.changed(target.home)
        }
        let targetObserved = try inspect(target.path, requireDirectory: false)
        guard targetObserved.identity == target.identity else {
            throw CleanupPathError.changed(target.path)
        }
        return try enforce(target, targetObserved: targetObserved, rootObserved: rootObserved,
                           homeObserved: homeObserved)
    }

    private struct Observed {
        let identity: CleanupIdentity
        let isDirectory: Bool
    }

    private static func inspect(_ path: String, requireDirectory: Bool) throws -> Observed {
        let components = (path as NSString).pathComponents
        guard components.first == "/" else { throw CleanupPathError.invalidPath(path) }
        var current = "/"
        for (offset, component) in components.dropFirst().enumerated() {
            current = (current as NSString).appendingPathComponent(component)
            let info = try readStat(current)
            let mode = UInt16(truncatingIfNeeded: info.st_mode) & modeMask
            if mode == modeSymlink { throw CleanupPathError.symlink(current) }
            if UInt64(truncatingIfNeeded: info.st_flags) & dataLessFlag != 0 {
                throw CleanupPathError.cloudOnly(current)
            }
            if offset < components.dropFirst().count - 1 && mode != modeDirectory {
                throw CleanupPathError.notDirectory(current)
            }
            if offset == components.dropFirst().count - 1 {
                let observed = Observed(
                    identity: CleanupIdentity(
                        device: UInt64(truncatingIfNeeded: info.st_dev),
                        inode: UInt64(truncatingIfNeeded: info.st_ino),
                        type: mode
                    ),
                    isDirectory: mode == modeDirectory
                )
                if requireDirectory && !observed.isDirectory {
                    throw CleanupPathError.notDirectory(path)
                }
                return observed
            }
        }
        // The root path itself is the only path without a non-root component.
        let info = try readStat("/")
        return Observed(
            identity: CleanupIdentity(
                device: UInt64(truncatingIfNeeded: info.st_dev),
                inode: UInt64(truncatingIfNeeded: info.st_ino),
                type: UInt16(truncatingIfNeeded: info.st_mode) & modeMask
            ),
            isDirectory: true
        )
    }

    private static func readStat(_ path: String) throws -> stat {
        var info = stat()
        let result = path.withCString { Darwin.lstat($0, &info) }
        guard result == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { throw CleanupPathError.missing(path) }
            throw CleanupPathError.unavailable(path, code)
        }
        return info
    }

    private static func enforce(
        _ target: CleanupTarget,
        targetObserved: Observed,
        rootObserved: Observed,
        homeObserved: Observed
    ) throws -> WorktreeInfo? {
        // A scan root is a boundary, never an actionable target.  Identity
        // also catches the equivalent /System/Volumes/Data spelling.
        guard targetObserved.identity != rootObserved.identity else {
            throw CleanupPathError.outsideRoot(target.path)
        }
        guard targetObserved.identity.device == rootObserved.identity.device else {
            throw CleanupPathError.differentVolume(target.path)
        }
        guard isWithinRoot(path: target.path, identity: targetObserved.identity,
                           root: target.root, rootIdentity: rootObserved.identity) else {
            throw CleanupPathError.outsideRoot(target.path)
        }
        _ = homeObserved // The identity check is part of the root policy below.
        try protectedPolicy(path: target.path, identity: targetObserved.identity,
                            home: target.home, homeIdentity: homeObserved.identity)
        try claudeTempPolicy(target.path)
        return try rejectGitPaths(target.path)
    }

    /// Parses a Claude Code temp path for the current user. Component names
    /// compare case-insensitively: APFS would accept `/private/TMP/...` for
    /// the same folder, and a different spelling must not skip the session
    /// check. `/tmp` itself is a symlink, which `inspect` already refuses.
    static func claudeTemp(_ path: String, uid: uid_t = getuid()) -> ClaudeTemp? {
        guard let normalized = try? normalize(path) else { return nil }
        var parts = Array((normalized as NSString).pathComponents.dropFirst())
        var prefix = "/"
        let data = Array((dataRoot as NSString).pathComponents.dropFirst())
        if parts.count > data.count,
           zip(parts, data).allSatisfy({ $0.caseInsensitiveCompare($1) == .orderedSame }) {
            prefix = appendComponents(["/"] + parts.prefix(data.count))
            parts.removeFirst(data.count)
        }
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        guard parts.count >= 5, same(parts[0], "private"), same(parts[1], "tmp"),
              same(parts[2], "claude-\(uid)"), !parts[3].isEmpty,
              UUID(uuidString: parts[4]) != nil else { return nil }
        let root = appendPath(prefix, Array(parts.prefix(3)))
        let session = appendPath(root, [parts[3], parts[4]])
        let depth = parts.count >= 6 && same(parts[5], "scratchpad") ? parts.count - 6 : nil
        return ClaudeTemp(root: root, sessionID: parts[4].lowercased(), sessionFolder: session, scratchDepth: depth)
    }

    /// The root a planner's path is captured under. Plans stay inside the
    /// home, with one exception: build output in a Claude Code session's temp
    /// scratchpad is captured under that user's `claude-<uid>` temp folder,
    /// where `claudeTempPolicy` refuses it while its session still runs.
    static func plannerRoot(for path: String, home: String) -> String {
        claudeTemp(path).flatMap { $0.inScratchpad ? $0.root : nil } ?? home
    }

    /// Inside a Claude Code session's temp folder only the scratchpad's
    /// contents may go, and only once that session has stopped running.
    /// Every cleanup path passes here, whatever rule or planner named it.
    private static func claudeTempPolicy(_ path: String) throws {
        guard let temp = claudeTemp(path) else { return }
        guard temp.inScratchpad else { throw CleanupPathError.tooBroad(path) }
        switch AgentSessions.claudeSessionState(temp) {
        case .ended: return
        case .running: throw CleanupPathError.sessionRunning(path)
        case .unknown: throw CleanupPathError.sessionUnverified(path)
        }
    }

    private static func isWithinRoot(
        path: String, identity: CleanupIdentity, root: String, rootIdentity: CleanupIdentity
    ) -> Bool {
        if let match = matchingPrefix(path, under: root, insensitive: true),
           (try? self.identity(of: match.prefix)) == rootIdentity {
            return true
        }
        // macOS exposes the Data volume both at /System/Volumes/Data and via
        // firmlinked paths such as /Users.  Permit an alias only when lstat
        // proves that both spellings name the same object.
        if root == dataRoot {
            let alias = path.hasPrefix(dataRoot + "/") ? path : dataRoot + path
            return sameObject(path, identity, alias)
        }
        if path.hasPrefix(dataRoot + "/") {
            let dataRootAlias = root.hasPrefix(dataRoot + "/") ? root : dataRoot + root
            if matchingPrefix(path, under: dataRootAlias, insensitive: true) == nil { return false }
            return sameObject(root, rootIdentity, dataRootAlias)
        }
        if root.hasPrefix(dataRoot + "/") {
            let pathAlias = dataRoot + path
            return matchingPrefix(pathAlias, under: root, insensitive: true) != nil
                && sameObject(path, identity, pathAlias)
        }
        return false
    }

    private static func sameObject(_ first: String, _ firstIdentity: CleanupIdentity, _ second: String) -> Bool {
        guard let secondIdentity = try? identity(of: second) else { return false }
        return firstIdentity == secondIdentity && first != second
    }

    private static func protectedPolicy(
        path: String, identity: CleanupIdentity, home: String, homeIdentity: CleanupIdentity
    ) throws {
        // Retain the released app's exclusion for caches and containers
        // managed by macOS, including the Data-volume spelling.
        let lower = path.lowercased()
        if lower.contains("/library/containers/com.apple.")
            || lower.contains("/library/caches/com.apple.")
            || lower.contains("/library/group containers/group.com.apple.") {
            throw CleanupPathError.protectedPath(path)
        }
        guard let homePath = homeAlias(path, home: home, homeIdentity: homeIdentity),
              let relative = relativePath(homePath, under: home) else { return }
        if relative.isEmpty || (relative.split(separator: "/").count < 2 && !relative.hasPrefix(".")) {
            throw CleanupPathError.tooBroad(path)
        }
        if broadRelative.contains(where: { $0.caseInsensitiveCompare(relative) == .orderedSame }) {
            throw CleanupPathError.tooBroad(path)
        }
        let lowerRelative = relative.lowercased()
        if neverCleanRelative.contains(where: {
            lowerRelative == $0.lowercased() || lowerRelative.hasPrefix($0.lowercased() + "/")
        }) {
            throw CleanupPathError.tooBroad(path)
        }
        for protected in protectedRelative {
            let protectedMatch = relative.caseInsensitiveCompare(protected) == .orderedSame
                || relative.lowercased().hasPrefix(protected.lowercased() + "/")
            guard protectedMatch else { continue }
            let suffix = relative.caseInsensitiveCompare(protected) == .orderedSame
                ? [] : relative.dropFirst(protected.count + 1).split(separator: "/")
            if protected == "Documents", codexChat(homePath, home: home) != nil { continue }
            if protected.caseInsensitiveCompare("Documents") == .orderedSame
                || protected.caseInsensitiveCompare("Desktop") == .orderedSame {
                guard suffix.count >= 2,
                      rebuildable.contains(where: { $0.caseInsensitiveCompare(String(suffix.last!)) == .orderedSame }) else {
                    throw CleanupPathError.protectedPath(path)
                }
            } else {
                throw CleanupPathError.protectedPath(path)
            }
        }
    }

    private static func homeAlias(
        _ path: String, home: String, homeIdentity: CleanupIdentity
    ) -> String? {
        if let match = matchingPrefix(path, under: home, insensitive: true),
           (try? self.identity(of: match.prefix)) == homeIdentity {
            return appendPath(home, match.suffix)
        }
        let aliasHome = home.hasPrefix(dataRoot + "/")
            ? String(home.dropFirst(dataRoot.count))
            : dataRoot + home
        if let match = matchingPrefix(path, under: aliasHome, insensitive: true),
           (try? self.identity(of: match.prefix)) == homeIdentity {
            return appendPath(home, match.suffix)
        }
        return nil
    }

    /// Any `.git` component or marker blocks, except a target whose own `.git`
    /// is a regular file and which `GitWorktree.verify` accepts as a clean,
    /// unused linked worktree. That verification runs at capture and again at
    /// every validation, so a worktree changed after planning is refused.
    private static func rejectGitPaths(_ path: String) throws -> WorktreeInfo? {
        let components = (path as NSString).pathComponents
        var current = "/"
        for component in components.dropFirst() {
            current = (current as NSString).appendingPathComponent(component)
            if component.caseInsensitiveCompare(".git") == .orderedSame {
                throw CleanupPathError.gitPath(current)
            }
        }
        let marker = (path as NSString).appendingPathComponent(".git")
        return try rejectGitMarker(marker, worktree: path)
    }

    private static func rejectGitMarker(_ marker: String, worktree: String) throws -> WorktreeInfo? {
        let info: stat
        do {
            info = try readStat(marker)
        } catch let error as CleanupPathError {
            if case .missing = error { return nil }
            throw error
        }
        guard UInt16(truncatingIfNeeded: info.st_mode) & modeMask == modeRegular else {
            throw CleanupPathError.gitPath(marker)
        }
        do {
            return try GitWorktree.verify(worktree)
        } catch GitWorktreeError.notWorktree {
            throw CleanupPathError.gitPath(marker)
        } catch let error as GitWorktreeError {
            throw CleanupPathError.gitWorktree(error)
        }
    }

    private static func isPath(_ path: String, under root: String) -> Bool {
        path == root || (root == "/" ? path.hasPrefix("/") : path.hasPrefix(root + "/"))
    }

    private static func matchingPrefix(
        _ path: String, under root: String, insensitive: Bool
    ) -> (prefix: String, suffix: [String])? {
        let pathComponents = (path as NSString).pathComponents
        let rootComponents = (root as NSString).pathComponents
        guard pathComponents.count >= rootComponents.count else { return nil }
        for (lhs, rhs) in zip(pathComponents.prefix(rootComponents.count), rootComponents) {
            if insensitive {
                guard lhs.caseInsensitiveCompare(rhs) == .orderedSame else { return nil }
            } else {
                guard lhs == rhs else { return nil }
            }
        }
        let prefix = appendComponents(Array(pathComponents.prefix(rootComponents.count)))
        return (prefix, Array(pathComponents.dropFirst(rootComponents.count)))
    }

    private static func appendComponents(_ components: [String]) -> String {
        guard let first = components.first else { return "/" }
        var path = first
        for component in components.dropFirst() {
            path = (path as NSString).appendingPathComponent(component)
        }
        return path
    }

    private static func appendPath(_ root: String, _ suffix: [String]) -> String {
        var path = root
        for component in suffix {
            path = (path as NSString).appendingPathComponent(component)
        }
        return path
    }

    private static func relativePath(_ path: String, under root: String) -> String? {
        guard isPath(path, under: root) else { return nil }
        if path == root { return "" }
        return String(path.dropFirst(root.count + (root == "/" ? 0 : 1)))
    }
}
