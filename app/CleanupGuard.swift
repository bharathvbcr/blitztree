import AppKit
import Foundation

// MARK: - Guards (enforced here, never left to the model)

nonisolated enum CleanupGuard {
    static let home = NSHomeDirectory()

    static var rebuildable: Set<String> { CleanupPathSafety.rebuildable }

    static func blockReason(path: String) -> String? {
        do { _ = try CleanupPathSafety.capture(path: path); return nil }
        catch { return error.localizedDescription }
    }

    static func blockReason(command: String) -> String? {
        CleanupCommand.parse(command) == nil ? "Command or arguments not allowed" : nil
    }

    /// The Codex app keeps each chat's files in ~/Documents/Codex/<date>/<chat>
    /// (outputs, work). Returns that chat folder for a path at or inside one.
    static func codexChat(_ path: String) -> String? {
        CleanupPathSafety.codexChat(path)
    }

    /// Whether the project owning this build folder was used in the last two
    /// days: its git index (touched by every status, commit or checkout), the
    /// project folder or the folder itself changed recently, or Claude Code
    /// worked in the project since. A Codex chat
    /// counts as used when it started or Codex worked in it since (folder
    /// dates are no help there: Finder's .DS_Store writes bump them).
    static func recentlyUsed(_ path: String, within: TimeInterval = 2 * 86400) -> Bool {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-within)
        if let chat = codexChat(path) {
            let day = ((chat as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if let started = try? Date(day + "T23:59:59Z", strategy: .iso8601), started > cutoff { return true }
            return AgentSessions.worked(in: chat, root: AgentSessions.codex, since: cutoff)
        }
        let url = URL(fileURLWithPath: path)
        guard rebuildable.contains(url.lastPathComponent) else { return false }
        let project = url.deletingLastPathComponent()
        var stamps = [path, project.path]
        let git = project.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
            if isDir.boolValue {
                stamps.append(git.appendingPathComponent("index").path)
            } else if let text = try? String(contentsOf: git, encoding: .utf8),
                      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                // A worktree: its index lives in the main repository.
                let dir = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                stamps.append(URL(fileURLWithPath: dir, relativeTo: project).appendingPathComponent("index").path)
            }
        }
        return stamps.contains { p in
            ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date).map { $0 > cutoff } ?? false
        } || AgentSessions.claudeWorked(in: project.path, since: cutoff)
    }

    /// An app that must be quit before its files go, when one is running.
    @MainActor
    static func runningOwner(of paths: [String]) -> String? {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let id = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            for path in paths {
                let parts = path.split(separator: "/").map(String.init)
                if !id.isEmpty, parts.contains(where: { $0 == id || $0.hasPrefix(id + ".") }) { return name }
                if name.count > 2, parts.contains(name) { return name }
            }
        }
        return nil
    }

    /// The outcome of vetting the paths of one agent plan card.
    struct Vetting {
        /// Targets that passed every guard, in the order they were asked.
        let kept: [CleanupTarget]
        /// How many asked paths were refused.
        let excluded: Int
        /// Why the first refused path was refused.
        let firstExclusion: String?
        /// Why the whole card is refused: nothing asked, or nothing kept.
        let blocked: String?
        /// Whether the card starts ticked.
        let preselect: Bool
    }

    /// Vet the folders a Trash card (or a cache command that only clears its
    /// own folder) asks to remove: each must pass the path policy, be an item
    /// in this scan (a directory when `folderCache`), not belong to a running
    /// app and not be in recent use. Refused paths are counted, not kept; the
    /// card is blocked only when none are left. It starts ticked only when
    /// something is kept and the model put it in the "safe" group.
    @MainActor
    static func vet(asked: [String], tree: Tree, home: String, folderCache: Bool, specGroup: String) -> Vetting {
        var kept: [CleanupTarget] = []
        var excluded = 0
        var firstExclusion: String?
        var reason: String?
        if asked.isEmpty { reason = String(localized: "Nothing to remove") }
        for path in asked {
            do {
                let target = try CleanupPathSafety.capture(path: path, root: home, home: home)
                guard let node = tree.node(at: target.path), node != 0 else {
                    throw CleanupOperations.failure(String(localized: "Path is not an item in this scan"))
                }
                if folderCache && !tree.isDir(node) {
                    throw CleanupOperations.failure(String(localized: "The cache path is not a scanned directory"))
                }
                if codexChat(target.path) == nil,
                   let app = runningOwner(of: [target.path]) {
                    throw CleanupOperations.failure(String(localized: "Quit \(app) to clean this"))
                }
                if recentlyUsed(target.path) {
                    throw CleanupOperations.failure(codexChat(target.path) != nil
                        ? String(localized: "A Codex chat you used in the last 2 days") : String(localized: "In a project used in the last 2 days"))
                }
                kept.append(target)
            } catch {
                excluded += 1
                firstExclusion = firstExclusion ?? error.localizedDescription
            }
        }
        if kept.isEmpty { reason = reason ?? firstExclusion ?? String(localized: "Nothing to remove") }
        return Vetting(kept: kept, excluded: excluded, firstExclusion: firstExclusion,
                       blocked: reason, preselect: reason == nil && specGroup == "safe")
    }
}
