import Foundation

/// When a coding agent last worked in each folder, from its session logs:
/// every log is a .jsonl file that names the working folder ("cwd") near its
/// start and is appended to as the session goes on.
nonisolated enum AgentSessions {
    /// Codex rollouts: $CODEX_HOME/sessions/<date>/*.jsonl.
    static var codex: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        return URL(fileURLWithPath: home + "/sessions")
    }

    /// Claude Code transcripts: $CLAUDE_CONFIG_DIR/projects/<folder>/*.jsonl.
    static var claude: URL {
        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude"
        return URL(fileURLWithPath: home + "/projects")
    }

    /// `folders`, when given, picks which top-level folders of `root` to read;
    /// every folder is read otherwise.
    static func lastActive(in root: URL, since: Date? = nil, folders: ((String) -> Bool)? = nil) -> [String: Date] {
        let fm = FileManager.default
        let roots = folders.map { keep in
            ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter(keep).map { root.appendingPathComponent($0) }
        } ?? [root]
        var active: [String: Date] = [:]
        for folder in roots {
            guard let files = fm.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for case let url as URL in files where url.pathExtension == "jsonl" {
                note(url, since: since, in: &active)
            }
        }
        return active
    }

    private static func note(_ url: URL, since: Date?, in active: inout [String: Date]) {
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              since.map({ date > $0 }) ?? true,
              let file = try? FileHandle(forReadingFrom: url) else { return }
        let head = String(decoding: (try? file.read(upToCount: 8192)) ?? Data(), as: UTF8.self)
        try? file.close()
        guard let match = head.firstMatch(of: /"cwd":"((?:[^"\\]|\\.)*)"/) else { return }
        let cwd = String(match.1).replacingOccurrences(of: "\\/", with: "/")
        active[cwd] = max(active[cwd] ?? date, date)
    }

    /// Whether a session in `root` worked at or inside `folder` since `since`.
    static func worked(in folder: String, root: URL, since: Date, folders: ((String) -> Bool)? = nil) -> Bool {
        lastActive(in: root, since: since, folders: folders).keys.contains { $0 == folder || $0.hasPrefix(folder + "/") }
    }

    /// Whether Claude Code worked at or inside `folder` since `since`. Claude
    /// Code files each session under a folder named after the working folder
    /// it started in, with separators turned into "-"; subagent and worktree
    /// sessions go under their parent's folder. So only folders naming
    /// `folder`, one inside it, or one around it are read (thousands of logs
    /// otherwise, on every card). Both sides are folded the same way, so this
    /// only narrows what is read; the "cwd" inside each log still decides.
    static func claudeWorked(in folder: String, since: Date) -> Bool {
        let key = claudeFolderKey(folder)
        return worked(in: folder, root: claude, since: since) {
            let name = claudeFolderKey($0)
            return name.hasPrefix(key) || key.hasPrefix(name)
        }
    }

    enum SessionState: Equatable { case running, ended, unknown }

    /// Claude Code's registry of running sessions: one `<pid>.json` per
    /// process in $CLAUDE_CONFIG_DIR/sessions, naming its `sessionId`.
    static var claudeRegistry: URL {
        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude"
        return URL(fileURLWithPath: home + "/sessions")
    }

    /// How recently a session's temp folder may have been written to and
    /// still count as ended: a headless or crashed-but-alive run that never
    /// registered itself is still writing.
    static let quietPeriod: TimeInterval = 15 * 60

    /// Whether the Claude Code session owning `temp` still runs: a registry
    /// entry for its id whose process is alive, or a write inside its session
    /// or scratchpad folder within `quietPeriod`. Fails closed: a registry
    /// that cannot be listed, or an entry that cannot be read, is `.unknown`.
    static func claudeSessionState(_ temp: ClaudeTemp, registry: URL = claudeRegistry,
                                   now: Date = Date()) -> SessionState {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: registry.path) else { return .unknown }
        for name in entries where name.hasSuffix(".json") {
            guard let data = fm.contents(atPath: registry.appendingPathComponent(name).path),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unknown
            }
            guard (entry["sessionId"] as? String)?.lowercased() == temp.sessionID else { continue }
            let pid = (entry["pid"] as? Int).flatMap { pid_t(exactly: $0) }
                ?? pid_t(name.split(separator: ".").first ?? "")
            guard let pid, pid > 0 else { return .unknown }
            // EPERM: the process exists but belongs to someone else.
            if kill(pid, 0) == 0 || errno == EPERM { return .running }
        }
        let cutoff = now.addingTimeInterval(-quietPeriod)
        let scratch = (temp.sessionFolder as NSString).appendingPathComponent("scratchpad")
        // The entries only, never the two folders holding them: cleaning one
        // folder out of a scratchpad changes the scratchpad's own date, and
        // the next folder of that ended session must not read as in use. A
        // new file still shows by its own date; a running session that
        // registered is caught above.
        var stamps: [String] = []
        for folder in [temp.sessionFolder, scratch] {
            stamps += ((try? fm.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { !(folder == temp.sessionFolder && $0 == "scratchpad") }
                .map { (folder as NSString).appendingPathComponent($0) }
        }
        let recent = stamps.contains { path in
            ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date).map { $0 > cutoff } ?? false
        }
        return recent ? .running : .ended
    }

    private static func claudeFolderKey(_ path: String) -> String {
        String(String.UnicodeScalarView(path.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? $0 : "-"
        }))
    }
}
