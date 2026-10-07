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

    private static func claudeFolderKey(_ path: String) -> String {
        String(String.UnicodeScalarView(path.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? $0 : "-"
        }))
    }
}
