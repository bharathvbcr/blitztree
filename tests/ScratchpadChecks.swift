import Darwin
import Foundation

/// Build output in a Claude Code session's temp scratchpad may go only once
/// that session has stopped: the path shape, the registry reading, and the
/// path policy that enforces it at every capture.
@main
enum ScratchpadChecks {
    private static let fm = FileManager.default
    private static let session = "CE907F81-C909-44A2-BCF7-70370FA492B7"

    static func main() throws {
        shape()
        let base = fm.temporaryDirectory
            .appendingPathComponent("blitztree-scratchpad-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try registry(base: base)
        try capture(base: base)
        print("PASS ScratchpadChecks")
    }

    private static func shape() {
        let uid: uid_t = 501
        let scratch = "/private/tmp/claude-501/-Users-u-p/\(session)/scratchpad"
        let target = CleanupPathSafety.claudeTemp(scratch + "/devmap-target", uid: uid)
        precondition(target?.root == "/private/tmp/claude-501", "root of a scratchpad path")
        precondition(target?.sessionID == session.lowercased(), "session id, lowercased")
        precondition(target?.sessionFolder == "/private/tmp/claude-501/-Users-u-p/\(session)")
        precondition(target?.scratchDepth == 1 && target?.inScratchpad == true, "one level inside")
        let data = CleanupPathSafety.claudeTemp("/System/Volumes/Data" + scratch + "/a/b", uid: uid)
        precondition(data?.root == "/System/Volumes/Data/private/tmp/claude-501" && data?.scratchDepth == 2,
                     "the Data-volume spelling keeps its prefix")
        let shouted = CleanupPathSafety.claudeTemp("/private/TMP/Claude-501/-p/\(session)/SCRATCHPAD/t", uid: uid)
        precondition(shouted?.inScratchpad == true, "another case spelling is the same folder on APFS")
        precondition(CleanupPathSafety.claudeTemp(scratch, uid: uid)?.inScratchpad == false,
                     "the scratchpad itself is not inside it")
        precondition(CleanupPathSafety.claudeTemp("/private/tmp/claude-501/-p/\(session)/tasks/t", uid: uid)?
            .scratchDepth == nil, "the session's tasks are outside the scratchpad")
        precondition(CleanupPathSafety.claudeTemp(scratch + "/t", uid: 502) == nil, "another user's temp folder")
        precondition(CleanupPathSafety.claudeTemp("/private/tmp/claude-501/-p/not-a-session/scratchpad/t", uid: uid) == nil,
                     "a session folder is named by a UUID")
        precondition(CleanupPathSafety.claudeTemp("/private/var/claude-501/-p/\(session)/scratchpad/t", uid: uid) == nil)
        precondition(CleanupPathSafety.claudeTemp("/private/tmp/claude-501/-p/\(session)/scratchpad/../../x", uid: uid) == nil,
                     "`..` never parses")
    }

    /// Writes `entries` as the registry's `<pid>.json` files.
    private static func writeRegistry(_ folder: URL, _ entries: [(pid: pid_t, session: String)]) throws {
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in entries {
            let json = try JSONSerialization.data(withJSONObject: ["pid": Int(entry.pid), "sessionId": entry.session])
            try json.write(to: folder.appendingPathComponent("\(entry.pid).json"))
        }
    }

    /// Ages the session folder, the scratchpad and their direct children.
    private static func age(_ temp: ClaudeTemp) throws {
        let old = Date().addingTimeInterval(-3600)
        let scratch = temp.sessionFolder + "/scratchpad"
        var paths = [temp.sessionFolder, scratch]
        for folder in [temp.sessionFolder, scratch] {
            paths += try fm.contentsOfDirectory(atPath: folder).map { folder + "/" + $0 }
        }
        for path in paths { try fm.setAttributes([.modificationDate: old], ofItemAtPath: path) }
    }

    /// A pid that is certainly not running: a child that has exited and been reaped.
    private static func deadPID() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private static func registry(base: URL) throws {
        let folder = base.appendingPathComponent("p/\(session)", isDirectory: true)
        try fm.createDirectory(at: folder.appendingPathComponent("scratchpad/target"), withIntermediateDirectories: true)
        let temp = ClaudeTemp(root: base.path, sessionID: session.lowercased(), sessionFolder: folder.path, scratchDepth: 1)
        let sessions = base.appendingPathComponent("config/sessions", isDirectory: true)

        precondition(AgentSessions.claudeSessionState(temp, registry: sessions) == .unknown,
                     "no registry to read: unknown, never ended")
        try writeRegistry(sessions, [(getpid(), session)])
        try age(temp)
        precondition(AgentSessions.claudeSessionState(temp, registry: sessions) == .running,
                     "a live process registered for the session")
        try writeRegistry(sessions, [(try deadPID(), session), (getpid(), UUID().uuidString)])
        precondition(AgentSessions.claudeSessionState(temp, registry: sessions) == .ended,
                     "its process is gone and only another session runs")
        // Cleaning one folder out of a scratchpad bumps the scratchpad's own
        // date; the next folder of that ended session must still read ended.
        try fm.createDirectory(at: folder.appendingPathComponent("scratchpad/target-b"), withIntermediateDirectories: true)
        try age(temp)
        try fm.moveItem(at: folder.appendingPathComponent("scratchpad/target-b"), to: base.appendingPathComponent("moved"))
        precondition(AgentSessions.claudeSessionState(temp, registry: sessions) == .ended,
                     "moving a sibling out is not activity")
        try Data("x".utf8).write(to: folder.appendingPathComponent("scratchpad/fresh.txt"))
        precondition(AgentSessions.claudeSessionState(temp, registry: sessions) == .running,
                     "a write within the quiet period counts as running without any registry entry")
        try age(temp)
        try Data("{".utf8).write(to: sessions.appendingPathComponent("1.json"))
        precondition(AgentSessions.claudeSessionState(temp, registry: sessions) == .unknown,
                     "an unreadable registry entry could be this session")
    }

    /// The path policy itself, on a real `/private/tmp/claude-<uid>` folder.
    private static func capture(base: URL) throws {
        let root = "/private/tmp/claude-\(getuid())"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            print("SKIP scratchpad capture (no \(root) on this Mac)")
            return
        }
        let id = UUID().uuidString.lowercased()
        let project = URL(fileURLWithPath: root).appendingPathComponent("blitztree-checks-\(id)", isDirectory: true)
        defer { try? fm.removeItem(at: project) }
        let scratch = project.appendingPathComponent("\(id)/scratchpad", isDirectory: true)
        let target = scratch.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data((CleanupVerify.cacheSignature + "\n").utf8).write(to: target.appendingPathComponent("CACHEDIR.TAG"))
        try fm.createDirectory(at: project.appendingPathComponent("\(id)/tasks/t"), withIntermediateDirectories: true)

        let config = base.appendingPathComponent("claude", isDirectory: true)
        let saved = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        setenv("CLAUDE_CONFIG_DIR", config.path, 1)
        defer { if let saved { setenv("CLAUDE_CONFIG_DIR", saved, 1) } else { unsetenv("CLAUDE_CONFIG_DIR") } }
        precondition(AgentSessions.claudeRegistry.path == config.path + "/sessions", "the registry follows CLAUDE_CONFIG_DIR")

        let home = NSHomeDirectory()
        let planned = CleanupPathSafety.plannerRoot(for: target.path, home: home)
        precondition(planned == root, "a scratchpad path is planned under the claude-<uid> folder")
        precondition(CleanupPathSafety.plannerRoot(for: project.path + "/\(id)/tasks/t", home: home) == home,
                     "the rest of the session folder stays outside every plan")
        let temp = try require(CleanupPathSafety.claudeTemp(target.path))

        try writeRegistry(AgentSessions.claudeRegistry, [(getpid(), id)])
        try age(temp)
        expectRejected("running session", .sessionRunning(target.path)) {
            _ = try CleanupPathSafety.capture(path: target.path, root: root, home: home)
        }
        precondition(CleanupVerify.blockReason(verify: "agent_session", path: target.path) != nil)

        try writeRegistry(AgentSessions.claudeRegistry, [(try deadPID(), id)])
        try age(temp)
        let captured = try CleanupPathSafety.capture(path: target.path, root: root, home: home)
        precondition(captured.path == target.path, "an ended session's build output is cleanable")
        precondition(CleanupVerify.blockReason(verify: "agent_session", path: target.path) == nil,
                     "signed tag, ended session")
        precondition(CleanupVerify.blockReason(verify: "agent_session", path: scratch.path) != nil,
                     "the scratchpad itself has no tag and is not inside itself")
        expectRejected("the scratchpad itself", .tooBroad(scratch.path)) {
            _ = try CleanupPathSafety.capture(path: scratch.path, root: root, home: home)
        }
        let tasks = project.path + "/\(id)/tasks/t"
        expectRejected("outside the scratchpad", .tooBroad(tasks)) {
            _ = try CleanupPathSafety.capture(path: tasks, root: root, home: home)
        }
        expectRejected("a scratchpad path under the home root", .outsideRoot(target.path)) {
            _ = try CleanupPathSafety.capture(path: target.path, root: home, home: home)
        }

        // Validated again at the operation: the session coming back blocks it.
        try writeRegistry(AgentSessions.claudeRegistry, [(getpid(), id)])
        do {
            try captured.validate()
            preconditionFailure("validate must refuse once the session runs again")
        } catch let error as CleanupPathError {
            precondition(error == .sessionRunning(target.path), "validate: \(error)")
        }
        try fm.removeItem(at: AgentSessions.claudeRegistry)
        expectRejected("registry gone", .sessionUnverified(target.path)) {
            _ = try CleanupPathSafety.capture(path: target.path, root: root, home: home)
        }
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.fileNoSuchFile) }
        return value
    }

    private static func expectRejected(_ label: String, _ expected: CleanupPathError, _ operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure("\(label): expected \(expected), got success")
        } catch let error as CleanupPathError {
            precondition(error == expected, "\(label): expected \(expected), got \(error)")
        } catch {
            preconditionFailure("\(label): unexpected \(error)")
        }
    }
}
