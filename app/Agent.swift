import AppKit
import Foundation
import Observation
import os
import SwiftUI

// "Clean up with Claude Code / Codex / MANVI": the agent runs headless in the
// background, read-only, and only writes a plan from the scan BlitzTree
// already has. Its steps and plan cards stream into the side panel as they
// happen. BlitzTree then does the cleanup itself, behind its own guards:
// moving folders to the Trash or running the owning tool's cleanup command.

// MARK: - Agents on this Mac

nonisolated enum AgentKind: String, CaseIterable, Sendable {
    case claude, codex, manvi

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .manvi: "MANVI"
        }
    }

    /// BlitzTree can install it and sign it in with one click. MANVI is set
    /// up by the user (a model in Settings), never downloaded by BlitzTree.
    var installable: Bool { self != .manvi }

    /// The one-line pitch of the setup offer.
    var setupNote: String {
        switch self {
        case .claude: String(localized: "Needs a Claude Pro plan.")
        case .codex: String(localized: "Free with a ChatGPT account.")
        case .manvi: String(localized: "Runs with a local model or your own API key.")
        }
    }
}

nonisolated struct InstalledAgent: Identifiable, Hashable, Sendable {
    let kind: AgentKind
    /// Absolute path to the CLI.
    let path: String
    /// Signed in to an account, so a run can start right away.
    let signedIn: Bool
    var id: String { kind.rawValue }
}

nonisolated struct AgentEnvironment: Sendable {
    var agents: [InstalledAgent] = []
    /// The user's shell PATH: cleanup tools live in Homebrew, ~/.local/bin,
    /// nvm… none of which an app's PATH has.
    var path: String = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// Set once the lookup has finished (an empty list then means none).
    var loaded = false
    /// MANVI's credentials and model choices as the login shell exports them
    /// (`Manvi.shellVariables` only). Passed to MANVI, never logged.
    var shell: [String: String] = [:]
    /// The ways MANVI can run right now, in the order a run tries them
    /// (Settings' choice: local, then the cloud, in automatic mode).
    var manviRoutes: [Manvi.Route] = []
    /// Absolute path to `anthropic-account`, which MANVI's Claude API route
    /// starts through (`Manvi.Account`); nil when it isn't installed.
    var accountLauncher: String?

    var ready: [InstalledAgent] { agents.filter(\.signedIn) }
}

nonisolated enum AgentLocator {
    nonisolated(unsafe) private static var qaFaked = false

    /// Asks the user's interactive login shell once where the CLIs are and
    /// what its PATH is, falls back to the usual install locations, then
    /// checks each one is signed in.
    static func find() async -> AgentEnvironment {
        await onBackgroundThread { locate() }
    }

    /// Runs blocking work (a probe that waits on a child) on a dispatch
    /// thread. A Task.detached would park one of the few cooperative
    /// threads that search, types and Clean Up discovery share.
    static func onBackgroundThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    private static func locate() -> AgentEnvironment {
        var env = AgentEnvironment(loaded: true)
        // QA: pretend neither agent is installed, to see the setup offer.
        if ProcessInfo.processInfo.environment["BZ_QA_NO_AGENTS"] != nil, !qaFaked {
            qaFaked = true
            return env
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let launcher = Manvi.Account.launcherName
        let lookups = (AgentKind.allCases.map(\.rawValue) + [launcher]).map { "command -v \($0)" }.joined(separator: "; ")
        let text = run(shell, ["-lic", "echo \"BZPATH=$PATH\"; \(lookups); \(Manvi.shellProbe)"]).out
        var fromShell: [AgentKind: String] = [:]
        var launcherFromShell: String?
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("BZPATH=") { env.path = String(line.dropFirst(7)) }
            if line.hasPrefix("BZENV_"), let eq = line.firstIndex(of: "=") {
                let name = String(line[line.index(line.startIndex, offsetBy: 6)..<eq])
                let value = String(line[line.index(after: eq)...])
                if Manvi.shellVariables.contains(name), !value.isEmpty { env.shell[name] = value }
                continue
            }
            guard line.hasPrefix("/") else { continue }
            if line.hasSuffix("/\(launcher)") { launcherFromShell = launcherFromShell ?? line; continue }
            for kind in AgentKind.allCases where line.hasSuffix("/\(kind.rawValue)") {
                fromShell[kind] = fromShell[kind] ?? line
            }
        }
        let home = NSHomeDirectory()
        // Where BlitzTree's own setup installs them, even if no shell knows yet.
        if !env.path.split(separator: ":").contains("\(home)/.local/bin"[...]) {
            env.path += ":\(home)/.local/bin"
        }
        let fallbacks: [AgentKind: [String]] = [
            .claude: ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                      "/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
            .codex: ["\(home)/.nvm/current/bin/codex", "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex",
                     "/usr/local/bin/codex", "\(home)/.bun/bin/codex"],
            // MANVI's release install and `go install`.
            .manvi: ["\(home)/.local/bin/manvi", "\(home)/go/bin/manvi", "/opt/homebrew/bin/manvi",
                     "/usr/local/bin/manvi"],
        ]
        let found: [(AgentKind, String)] = AgentKind.allCases.compactMap { kind in
            let candidates = [fromShell[kind]].compactMap { $0 } + (fallbacks[kind] ?? [])
            guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            else { return nil }
            return (kind, path)
        }
        // Where MANVI's `go install` and its release install put the launcher.
        let launcherCandidates = [launcherFromShell].compactMap { $0 }
            + ["\(home)/.local/bin/\(launcher)", "\(home)/go/bin/\(launcher)", "/opt/homebrew/bin/\(launcher)",
               "/usr/local/bin/\(launcher)"]
        env.accountLauncher = launcherCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        // All checks at once; each takes a fraction of a second. MANVI is
        // ready when at least one of its routes is.
        // The probes share one lock-guarded result. The lock is a Sendable
        // value, so the compiler can see that the concurrent writes are safe.
        let results = OSAllocatedUnfairLock(
            initialState: (signedIn: [Bool](repeating: false, count: found.count), routes: [Manvi.Route]()))
        let probe = env
        DispatchQueue.concurrentPerform(iterations: found.count) { i in
            let (kind, path) = found[i]
            let ready = kind == .manvi
                ? Manvi.readyRoutes(path: path, envPath: probe.path, shell: probe.shell, launcher: probe.accountLauncher) : []
            let ok = kind == .manvi ? !ready.isEmpty : isSignedIn(kind, path: path, envPath: probe.path)
            results.withLock { state in
                state.signedIn[i] = ok
                if kind == .manvi { state.routes = ready }
            }
        }
        let outcome = results.withLock { $0 }
        env.manviRoutes = outcome.routes
        env.agents = found.enumerated().map { i, pair in
            InstalledAgent(kind: pair.0, path: pair.1, signedIn: outcome.signedIn[i])
        }
        return env
    }

    /// Signed in, or for MANVI: a route it can run now (`Manvi.readyRoutes`).
    static func isSignedIn(_ kind: AgentKind, path: String, envPath: String,
                           shell: [String: String] = [:], launcher: String? = nil) -> Bool {
        switch kind {
        case .claude:
            let r = run(path, ["auth", "status"], envPath: envPath)
            return r.out.contains("\"loggedIn\": true") || r.out.contains("\"loggedIn\":true")
        case .codex:
            return run(path, ["login", "status"], envPath: envPath).status == 0
        case .manvi:
            return !Manvi.readyRoutes(path: path, envPath: envPath, shell: shell, launcher: launcher).isEmpty
        }
    }

    /// `environment` replaces the whole environment; `envPath` only PATH.
    /// For the synchronous probes (shell lookups, `security`, `simctl`). A
    /// slow shell profile shouldn't hold the panel up, so a run that hit its
    /// limit (or never started) reports nothing; a descendant that keeps the
    /// pipe open costs at most the helper's drain grace and no thread.
    static func run(_ exe: String, _ args: [String], envPath: String? = nil,
                    environment: [String: String]? = nil, directory: URL? = nil, input: Data? = nil,
                    timeout: TimeInterval = 5) -> (out: String, status: Int32) {
        let spec = Subprocess.Spec(exe, args, environment: environment ?? envPath.map(Subprocess.environment(path:)),
                                   directory: directory?.path, input: input.map { .data($0) } ?? .none)
        let outcome = Subprocess.runBlocking(spec, stdout: .capture(cap: 8 << 20), timeout: timeout)
        return outcome.finished ? (outcome.output, outcome.status) : ("", -1)
    }
}

nonisolated final class OutputText: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ new: Data) { lock.lock(); data = new; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

// MARK: - One-click setup

/// Installs an agent into ~/.local/bin and signs it in through the browser,
/// all in the background; the panel shows where it is.
@Observable
@MainActor
final class AgentSetup {
    enum Step: Equatable { case installing, signingIn, failed(String) }

    /// What an install downloads and runs. An install that is not pinned to
    /// a checksum is shown to the user, URL and exact command, and only runs
    /// after they agree (`needsConfirmation`).
    nonisolated struct InstallPlan: Sendable, Equatable {
        let source: String
        let script: String
        let needsConfirmation: Bool
    }

    /// Anthropic's installer. It changes between releases, so no hash can be
    /// pinned here; the URL is the only thing that is.
    nonisolated static let claudeInstallerURL = "https://claude.ai/install.sh"

    let kind: AgentKind
    private(set) var step: Step
    private var task: Task<Void, Never>?
    private var cancelled = false

    /// `confirm` is asked before an unpinned installer runs; the default is
    /// an alert (`installAlert`). Returning false installs nothing.
    init(kind: AgentKind, installed: InstalledAgent?, envPath: String,
         confirm: @escaping @MainActor (InstallPlan) -> Bool = AgentSetup.askToInstall,
         done: @escaping (AgentEnvironment) -> Void) {
        self.kind = kind
        guard let plan = Self.installPlan(kind) else {
            // ScanModel.setUp sends MANVI to Settings instead; never reached.
            step = .failed(String(localized: "Choose a model for MANVI in Settings → Model Providers."))
            return
        }
        step = installed == nil ? .installing : .signingIn
        task = Task {
            var path = installed?.path
            if path == nil {
                let target = NSHomeDirectory() + "/.local/bin/" + kind.rawValue
                if plan.needsConfirmation, !confirm(plan) {
                    step = .failed(String(localized: "Installation was cancelled. Nothing was downloaded or run."))
                    return
                }
                if let error = await Self.runInstall(plan.script) {
                    if !cancelled { step = .failed(String(localized: "Couldn't install \(kind.name): \(error)")) }
                    return
                }
                path = target
            }
            guard let path, !cancelled else { return }
            // The probe waits on the CLI for seconds; keep it off the main actor.
            if await !AgentLocator.onBackgroundThread({ AgentLocator.isSignedIn(kind, path: path, envPath: envPath) }) {
                guard !cancelled else { return }
                step = .signingIn
                // The CLI prints the authorize URL and opens a browser only when
                // its stdout is a terminal. Read that URL and open it here; the
                // CLI stays up until the sign-in comes back. Cancelling this
                // task terminates the CLI.
                let outcome = await AgentLogin.run(
                    executable: path,
                    arguments: kind == .claude ? ["auth", "login"] : ["login"],
                    environmentPath: envPath,
                    currentDirectory: NSHomeDirectory(),
                    open: { url in
                        Task { @MainActor in NSWorkspace.shared.open(url) }
                    })
                guard !cancelled else { return }
                if await !AgentLocator.onBackgroundThread({ AgentLocator.isSignedIn(kind, path: path, envPath: envPath) }) {
                    if let detail = outcome.detail {
                        step = .failed(String(localized: "Sign-in didn't finish (\(detail)). Try again."))
                    } else {
                        step = .failed(String(localized: "Sign-in didn't finish. Try again."))
                    }
                    return
                }
            }
            guard !cancelled else { return }
            done(await AgentLocator.find())
        }
    }

    func cancel() {
        cancelled = true
        task?.cancel()
    }

    /// Nil for an agent BlitzTree does not install (`installable`).
    nonisolated static func installPlan(_ kind: AgentKind) -> InstallPlan? {
        switch kind {
        case .manvi:
            return nil
        case .claude:
            return InstallPlan(source: claudeInstallerURL, script: claudeInstallScript(url: claudeInstallerURL),
                               needsConfirmation: true)
        case .codex:
            // OpenAI's standalone build: no Node needed. The version and its
            // SHA-256 are pinned so a new upstream release cannot change what
            // gets installed silently (S5). To update the pin: set VER to the
            // wanted release tag (github.com/openai/codex/releases), download
            // the codex-aarch64-apple-darwin.tar.gz of that release once,
            // run `shasum -a 256` on it, and paste the hash below.
            let script = """
            set -e; t=$(mktemp -d); mkdir -p "$HOME/.local/bin"
            VER="0.157.1"
            URL="https://github.com/openai/codex/releases/download/rust-v$VER/codex-aarch64-apple-darwin.tar.gz"
            curl -fsSL "$URL" -o "$t/codex.tar.gz"
            # SHA-256 of codex-aarch64-apple-darwin.tar.gz for $VER.
            echo "3c45b162b7a76f51325015b1d0a8112c73219b7a9b59cd5762c37c9ba55894fa  $t/codex.tar.gz" | shasum -a 256 -c - || { echo "Codex download failed the checksum check; nothing was installed." >&2; rm -rf "$t"; exit 1; }
            tar -xzf "$t/codex.tar.gz" -C "$t"
            mv "$t/codex-aarch64-apple-darwin" "$HOME/.local/bin/codex"; rm -rf "$t"
            """
            return InstallPlan(source: "https://github.com/openai/codex/releases", script: script,
                               needsConfirmation: false)
        }
    }

    /// Anthropic's own installer (everything under ~/.local, no sudo),
    /// downloaded to a temporary file first and run only if the download
    /// succeeded. Piping curl into bash would run whatever prefix of a
    /// broken download arrived and report the shell's exit status, not curl's.
    nonisolated static func claudeInstallScript(url: String) -> String {
        """
        set -e; t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
        curl -fsSL "\(url)" -o "$t/install.sh"
        [ -s "$t/install.sh" ] || { echo "The installer download was empty; nothing was run." >&2; exit 1; }
        bash "$t/install.sh"
        """
    }

    /// The question asked before an unpinned installer runs. Cancel is the
    /// default button.
    static func installAlert(_ plan: InstallPlan) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Run the Claude Code installer?")
        alert.informativeText = String(localized: "BlitzTree will download \(plan.source) and run it with bash, as you. It is Anthropic's own installer, but it isn't pinned to a checksum and can change between releases. This is the exact command:\n\n\(plan.script)")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Download and Run"))
        return alert
    }

    static func askToInstall(_ plan: InstallPlan) -> Bool {
        installAlert(plan).runModal() == .alertSecondButtonReturn
    }

    /// Runs an install script; returns the last error line on failure. Bounded
    /// (a stalled download is cut off) and cancellable with the calling task.
    nonisolated static func runInstall(_ script: String, timeout: TimeInterval = 600) async -> String? {
        let tail = ErrTail()
        let spec = Subprocess.Spec("/bin/bash", ["-c", script],
                                   environment: Subprocess.environment(path: "/usr/bin:/bin:/usr/sbin:/sbin"),
                                   directory: NSHomeDirectory())
        let outcome = await Subprocess.run(spec, stdout: .discard, stderr: .stream { tail.feed($0) }, timeout: timeout)
        if let error = outcome.launchError { return error }
        if outcome.cancelled { return String(localized: "The installation was cancelled.") }
        if outcome.timedOut {
            return String(localized: "The installation timed out after \(Int(timeout)) seconds.")
        }
        guard outcome.status != 0 else { return nil }
        if tail.last.isEmpty {
            return String(localized: "The installer exited with status \(Int(outcome.status)).")
        }
        return tail.last
    }
}

// MARK: - Run model

/// One file or folder the user right-clicked and asked about. The run then
/// plans for that item alone: its summary is the verdict, and every card
/// must stay at or inside the item.
nonisolated struct AgentFocus: Sendable, Equatable {
    let node: Int
    /// Absolute, without the Data-volume prefix (what the agent can `ls`).
    let path: String
    let name: String
    let isDir: Bool

    /// What the right-click names, nothing more: cheap enough for the main
    /// actor. The judgement (`verdict`) reads files and runs the path guards,
    /// so the prompt builder makes it, away from the main actor.
    init(node: Int, tree: Tree) {
        self.node = node
        path = tree.displayPath(node)
        name = node == 0 ? path : tree.name(node)
        isDir = tree.isDir(node)
    }

    /// BlitzTree's own check before any agent sees the item, once in English
    /// for the prompt and once in the user's language for the screen.
    struct Verdict: Sendable, Equatable {
        let english: String
        let display: String
    }

    /// Why BlitzTree's guards would refuse the item, or the rebuildable folder
    /// it was recognised as. Nil when nothing is worth telling. Reads session
    /// logs and runs the git and process checks of a worktree: never call it
    /// on the main actor.
    func verdict(tree: Tree, known: [CleanupItem], home: String = NSHomeDirectory()) -> Verdict? {
        let ancestry = Set(tree.ancestry(node))
        if let item = known.first(where: { ancestry.contains($0.node) }) {
            let englishReason = item.englishBlocked ?? item.blocked
            return Verdict(
                english: englishReason.map { "Recognised as \(item.kind), but BlitzTree won't remove it: \($0)" }
                    ?? (item.node == node ? "Recognised by BlitzTree as \(item.kind)"
                        : "Inside \(item.display), recognised by BlitzTree as \(item.kind)"),
                display: item.blocked.map { String(localized: "Recognised as \(item.kind), but BlitzTree won't remove it: \($0)") }
                    ?? (item.node == node ? String(localized: "Recognised by BlitzTree as \(item.kind)")
                        : String(localized: "Inside \(item.display), recognised by BlitzTree as \(item.kind)")))
        }
        do {
            let root = CleanupPathSafety.plannerRoot(for: tree.path(node), home: home)
            _ = try CleanupPathSafety.capture(path: tree.path(node), root: root, home: home, check: .policyOnly)
            // A scratchpad's session check ran in the capture above.
            guard root == home, CleanupGuard.recentlyUsed(path) else { return nil }
            return Verdict(english: "In a project used in the last 2 days",
                           display: String(localized: "In a project used in the last 2 days"))
        } catch let error as CleanupPathError {
            return Verdict(english: "BlitzTree won't remove this: \(error.englishDescription)",
                           display: String(localized: "BlitzTree won't remove this: \(error.errorDescription ?? error.englishDescription)"))
        } catch {
            return Verdict(english: "BlitzTree won't remove this: \(error.localizedDescription)",
                           display: String(localized: "BlitzTree won't remove this: \(error.localizedDescription)"))
        }
    }
}

@Observable
@MainActor
final class PlanItem: Identifiable {
    /// `inTrash`: step one done, put back or deleted in step two.
    enum Status: Equatable { case waiting, running, inTrash, done, failed(String), skipped }

    let id = UUID()
    let spec: PlanItemSpec
    let paths: [String]
    /// Why BlitzTree won't do this one (protected folder, bad command…).
    let blocked: String?
    var selected: Bool
    var status: Status = .waiting
    /// Space this item gave back to the disk (commands, emptied Trash).
    var freed: UInt64 = 0
    /// Where its folders went in the Trash, for "Empty Trash".
    var trashed: [CleanupReceipt] = []
    let cleanupTargets: [CleanupTarget]
    var trashedBytes: UInt64 = 0
    var stagingError: String?
    /// Things that were left as they were when the folders were deleted (a
    /// worktree's git metadata that changed meanwhile): not failures, but the
    /// person should know.
    var notices: [String] = []

    /// Measured size from the scan; never trust a size supplied by the agent.
    let bytes: UInt64
    /// Its folders in the scan the plan was made from, for the treemap.
    let nodes: [Int]

    /// Why some of its folders were left out, shown under the card.
    let note: String?
    /// A tool cache that is only a folder: trashed and deleted like one.
    let viaTrash: Bool

    /// What judging one card decides. It reads files and may run git and
    /// lsof (a worktree), so `evaluate` makes it away from the main actor and
    /// the card is only assembled from it here.
    nonisolated struct Evaluation: Sendable {
        let blocked: String?
        let selected: Bool
        let cleanupTargets: [CleanupTarget]
        let paths: [String]
        let nodes: [Int]
        let bytes: UInt64
        let note: String?
        let viaTrash: Bool
    }

    init(spec: PlanItemSpec, evaluation: Evaluation) {
        self.spec = spec
        blocked = evaluation.blocked
        selected = evaluation.selected
        cleanupTargets = evaluation.cleanupTargets
        paths = evaluation.paths
        nodes = evaluation.nodes
        bytes = evaluation.bytes
        note = evaluation.note
        viaTrash = evaluation.viaTrash
    }

    /// Judges a card on the calling thread. For tests and benchmarks; the app
    /// goes through `make`, which keeps the main actor free.
    convenience init(spec: PlanItemSpec, tree: Tree, home: String = NSHomeDirectory(), scope: Int? = nil) {
        self.init(spec: spec, evaluation: Self.evaluate(spec: spec, tree: tree, home: home, scope: scope,
                                                        apps: RunningApps.current()))
    }

    /// A card judged on a dispatch thread (see `AgentLocator.onBackgroundThread`),
    /// so a long run of them streaming in never stalls the window.
    static func make(spec: PlanItemSpec, tree: Tree, home: String = NSHomeDirectory(),
                     scope: Int? = nil) async -> PlanItem {
        let apps = RunningApps.current()
        let evaluation = await AgentLocator.onBackgroundThread {
            evaluate(spec: spec, tree: tree, home: home, scope: scope, apps: apps)
        }
        return PlanItem(spec: spec, evaluation: evaluation)
    }

    /// `scope`: the node a focused run asked about. Any path outside it
    /// blocks the whole item, so a command that would reach past it can't run.
    nonisolated static func evaluate(spec: PlanItemSpec, tree: Tree, home: String, scope: Int?,
                                     apps: RunningApps) -> Evaluation {
        var asked = spec.paths.map { ($0 as NSString).expandingTildeInPath }
        let command = spec.action == "command" ? CleanupCommand.parse(spec.command) : nil
        var reason: String?
        var folderCache = false
        if !["trash", "command"].contains(spec.action) {
            reason = String(localized: "Unknown cleanup action")
        } else if spec.action == "trash", !spec.command.isEmpty {
            reason = String(localized: "A Trash action cannot contain a command")
        } else if spec.action == "command" {
            if let command {
                if let relative = command.cacheRelativePath {
                    let expected = home + "/" + relative
                    // The command selects its own known folder. Model paths
                    // cannot redirect a cache command into arbitrary deletion.
                    if asked.isEmpty { asked = [expected] }
                    do {
                        let target = try CleanupPathSafety.capture(path: expected, root: home, home: home, check: .policyOnly)
                        let supplied = try asked.map {
                            try CleanupPathSafety.capture(path: $0, root: home, home: home, check: .policyOnly).identity
                        }
                        guard Set(supplied) == [target.identity] else {
                            throw CleanupOperations.failure(String(localized: "The supplied paths do not match this tool's cache"))
                        }
                        asked = [target.path]
                        folderCache = true
                    } catch { reason = error.localizedDescription }
                }
            } else { reason = String(localized: "Command or arguments not allowed") }
        }
        if reason == nil, let scope, asked.contains(where: { path in
            tree.node(at: path).map { !tree.ancestry($0).contains(scope) } ?? true
        }) {
            reason = String(localized: "Outside the item you asked about")
        }
        // Every per-path guard and the pre-selection live in CleanupGuard.vet.
        let vetting = reason == nil && (spec.action == "trash" || folderCache)
            ? CleanupGuard.vet(asked: asked, tree: tree, home: home, folderCache: folderCache,
                               specGroup: spec.group, apps: apps)
            : nil
        if let vetting {
            reason = vetting.blocked
        } else if reason == nil && spec.action == "command" {
            // Paths only describe a tool command. They never become deletion
            // targets, but must still belong to the scan being reviewed.
            if asked.isEmpty || asked.contains(where: { tree.node(at: $0).map { $0 == 0 } ?? true }) {
                reason = String(localized: "A supplied path is not in this scan")
            } else if let app = apps.owner(of: asked) {
                reason = String(localized: "Quit \(app) to clean this")
            }
        }
        let kept = vetting?.kept ?? []
        let candidateNodes = Set(kept.compactMap { tree.node(at: $0.path) })
        let outer = candidateNodes.filter { node in
            !tree.ancestry(node).dropLast().contains(where: candidateNodes.contains)
        }
        let cleanupTargets: [CleanupTarget] = kept.filter { target in tree.node(at: target.path).map(outer.contains) ?? false }
            .reduce(into: []) { targets, target in
                if !targets.contains(where: { $0.identity == target.identity }) { targets.append(target) }
            }
        let paths = spec.action == "command" && !folderCache ? asked : cleanupTargets.map(\.path)
        let note: String?
        if spec.action == "command" && !folderCache && reason == nil {
            note = String(localized: "Runs the tool's cleanup, which may affect data outside the listed paths")
        } else if let vetting, vetting.excluded > 0 && !kept.isEmpty {
            note = String(localized: "Leaves \(vetting.excluded) path(s) unchanged: \(vetting.firstExclusion ?? String(localized: "not eligible"))")
        } else {
            note = nil
        }
        let found = Set(paths.compactMap { tree.node(at: $0) })
        let nodes = Array(found.filter { node in !tree.ancestry(node).dropLast().contains(where: found.contains) })
        return Evaluation(blocked: reason, selected: vetting?.preselect ?? false, cleanupTargets: cleanupTargets,
                          paths: paths, nodes: nodes, bytes: nodes.reduce(UInt64(0)) { $0 + tree.alloc[$1] },
                          note: note, viaTrash: folderCache)
    }

    var isCommand: Bool { spec.action == "command" && !viaTrash }

    /// What deleting this item's Trash copies came to (`AgentRun.deleteTrashed`).
    func recordDeletion(remaining: [CleanupReceipt], notices: [String], error: String?, stagedBytes: UInt64, tree: Tree) {
        trashed = remaining
        self.notices = notices
        trashedBytes = remaining.reduce(UInt64(0)) { total, receipt in
            total + (tree.node(at: receipt.sourcePath).map { tree.alloc[$0] } ?? 0)
        }
        if error == nil { freed = stagedBytes }
        withAnimation(.snappy) { status = (error ?? stagingError).map { .failed($0) } ?? .done }
    }

    /// Keep running commands visible in the countdown; folder sizes only
    /// include actual Trash moves, including receipts retained after failure.
    var pendingBytes: UInt64 {
        if isCommand { return status == .waiting || status == .running ? bytes : 0 }
        return trashedBytes
    }

    /// Retain a reviewed action and its captured identities only when its full
    /// specification is unchanged. New or changed final actions need selection.
    /// What is new is judged off the main actor, one card after another.
    static func reconcile(_ specs: [PlanItemSpec], previous: [PlanItem], tree: Tree,
                          scope: Int? = nil) async -> [PlanItem] {
        var remaining = previous
        var result: [PlanItem] = []
        for spec in specs {
            if let index = remaining.firstIndex(where: { $0.spec == spec }) {
                result.append(remaining.remove(at: index))
                continue
            }
            let fresh = await make(spec: spec, tree: tree, scope: scope)
            fresh.selected = false
            result.append(fresh)
        }
        return result
    }
}

@Observable
@MainActor
final class AgentRun {
    /// Two decisions from the user: `planned` → Move to Trash (can be undone)
    /// → `staged` → Delete for good → `done`.
    enum Phase: Equatable { case thinking, planned, trashing, staged, deleting, done, failed(String) }

    /// Nil when the plan comes from a custom provider over HTTP.
    let agent: InstalledAgent?
    /// Nil when the plan comes from a CLI agent. The endpoint never runs
    /// tools — it only writes the plan; the guards and the two-step delete
    /// below are identical for both sources.
    let provider: LLMProvider?
    /// What the panel calls the planner: the CLI agent's or the provider's name.
    var displayName: String { agent?.kind.name ?? provider?.displayName ?? "The assistant" }
    /// Set when the user asked about one item rather than the whole scan.
    let focus: AgentFocus?
    /// BlitzTree's own check of that item, once made (with the prompt).
    private(set) var focusVerdict: AgentFocus.Verdict?
    private(set) var phase: Phase = .thinking
    /// What the agent has done so far, in plain words; the last one is live.
    private(set) var steps: [String] = [String(localized: "Reading your scan")]
    private(set) var summary = ""
    private(set) var items: [PlanItem] = []
    private(set) var startedAt = Date()
    private(set) var planSeconds: Double?
    private(set) var current: UUID?

    /// MANVI only: the routes this run tries, in order. When one ends without
    /// a single plan card (local server down, model too slow, no answer),
    /// the next takes over with the same prompt.
    let routes: [Manvi.Route]
    private var routeIndex = 0
    /// The route the MANVI process running now uses.
    var route: Manvi.Route? { routes.indices.contains(routeIndex) ? routes[routeIndex] : nil }

    private var job: Subprocess.Job?
    private let scanRoot: String
    private let tree: Tree
    private let onFinish: () -> Void
    private var preparationTask: Task<Void, Never>?
    private let env: AgentEnvironment
    /// The prompt, kept for a switch to the next route.
    private var input = ""
    /// Bumped by every launch and by cancel; a process's events and its end
    /// only count while it is still the current launch.
    private var launch = 0
    private var cancelled = false

    init(agent: InstalledAgent?, env: AgentEnvironment, tree: Tree, scanRoot: String,
         known: [CleanupItem], provider: LLMProvider? = nil, focus: AgentFocus? = nil,
         routes: [Manvi.Route] = [], onFinish: @escaping () -> Void) {
        self.agent = agent
        self.provider = provider
        self.focus = focus
        self.scanRoot = scanRoot
        self.tree = tree
        self.onFinish = onFinish
        self.env = env
        self.routes = agent?.kind == .manvi ? routes : []
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.localizedName.map { "\($0) (\(app.bundleIdentifier ?? "?"))" } }
        preparationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            // appData waits on `simctl`; a dispatch thread, not a cooperative one.
            // Judging a right-clicked item reads logs and may run the worktree
            // checks; it is done here once, for the prompt and for the panel.
            let (input, verdict) = await AgentLocator.onBackgroundThread {
                let verdict = focus?.verdict(tree: tree, known: known)
                return (AgentPrompt.build(tree: tree, scanRoot: scanRoot, known: known, running: running, focus: focus, verdict: verdict)
                        + AgentPrompt.appData(tree: tree, focus: focus?.path), verdict)
            }
            // Closing or replacing a run while its prompt was being built
            // must not launch an agent after cancellation.
            guard !Task.isCancelled, let self else { return }
            preparationTask = nil
            focusVerdict = verdict
            self.input = input
            step(asking)
            start()
        }
    }

    /// Folders to light up on the treemap: what the plan would remove.
    func highlights(in shown: Tree?) -> [Int] {
        guard shown === tree, phase != .done else { return [] }
        return items.filter { $0.selected && $0.blocked == nil && $0.status != .done }
            .flatMap(\.nodes)
    }

    /// What step one moves to the Trash (tool caches wait for step two).
    var trashBytes: UInt64 { targets.filter { !$0.isCommand }.reduce(0) { $0 + $1.bytes } }
    /// What step two deletes for good; while it runs, what is still going,
    /// so the number counts down as each item finishes.
    var pendingBytes: UInt64 {
        targets.reduce(0) { $0 + $1.pendingBytes }
    }
    /// The items the user chose and BlitzTree may touch.
    var targets: [PlanItem] { items.filter { $0.selected && $0.blocked == nil } }

    /// Space the disk actually got back (statfs), set when deleting ends.
    private(set) var reclaimed: UInt64?

    var selectedBytes: UInt64 { items.filter(\.selected).reduce(0) { $0 + $1.bytes } }
    var freed: UInt64 { items.reduce(0) { $0 + $1.freed } }
    var inTrash: UInt64 { items.reduce(0) { $0 + $1.trashedBytes } }

    private func step(_ text: String) {
        guard steps.last != text else { return }
        withAnimation(.snappy) { steps.append(text) }
    }

    /// `defaults write dev.ahmed.blitztree bz.claudeModel haiku` to try another.
    private static var claudeModel: String {
        ProcessInfo.processInfo.environment["BZ_CLAUDE_MODEL"]
            ?? UserDefaults.standard.string(forKey: "bz.claudeModel") ?? "sonnet"
    }

    func cancel() {
        cancelled = true
        launch += 1
        preparationTask?.cancel()
        preparationTask = nil
        job?.terminate()
        job = nil
        planClient?.cancel()
        planClient = nil
    }

    /// Custom endpoint runs need no process: the client streams SSE straight
    /// from the HTTP response into the same event pipeline.
    private var planClient: LLMPlanClient?

    // MARK: Agent process

    private func start() {
        if let provider { startProvider(input: input, provider: provider); return }
        guard let agent, !cancelled else { return }
        if agent.kind == .manvi {
            guard let route else {
                phase = .failed(String(localized: "Choose a model for MANVI in Settings → Model Providers."))
                return
            }
            // Which side answers, local or cloud, is part of what the user sees.
            step(String(localized: "Using \(route.label)"))
        }
        launch += 1
        let generation = launch
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlitzTree", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // An empty working folder: no project settings, hooks or memory load.
        var directory = folder
        var environment = Subprocess.environment(path: env.path)
        var executable = agent.path
        let arguments: [String]

        switch agent.kind {
        case .claude:
            arguments = [
                "-p", "--setting-sources", "project", "--output-format", "stream-json", "--verbose",
                "--include-partial-messages", "--model", Self.claudeModel, "--effort", "low",
                "--tools", "Bash,Read", "--permission-mode", "dontAsk", "--no-session-persistence",
                "--allowedTools", "Bash(du:*)", "Bash(ls:*)", "Bash(stat:*)", "Bash(docker system df:*)",
                "Bash(xcrun simctl list:*)", "Bash(ollama list:*)", "Read",
                "--json-schema", planSchema,
            ]
        case .codex:
            // The app server, not `codex exec`: only it streams the answer as
            // it is written, so cards can appear one by one.
            arguments = ["app-server"]
        case .manvi:
            // `manvi serve` never calls a model; `run --json` streams the
            // turn as NDJSON events. Strict posture, empty folder, pinned
            // environment: see Manvi.environment. The Claude API route starts
            // through anthropic-account, given the scanned folder so a marker
            // there can pin the account; it sets the key, BlitzTree never does.
            guard let route else { return }
            guard let launch = Manvi.launch(route: route, manvi: agent.path, launcher: env.accountLauncher,
                                            repo: scanRoot,
                                            arguments: Manvi.runArguments(fallbackAfter: routeIndex + 1 < routes.count))
            else {
                phase = .failed(String(localized: "anthropic-account isn't installed. The Claude API route needs it in ~/.local/bin."))
                return
            }
            executable = launch.executable
            arguments = launch.arguments
            directory = Manvi.prepared().work
            environment = Manvi.environment(base: ProcessInfo.processInfo.environment,
                                            path: env.path, shell: env.shell, route: route)
            Manvi.pruneSessions()
        }

        // Codex is spoken to over stdin for the whole run; the others get the
        // prompt once and then end of input.
        let prompt = Data((agent.kind == .manvi ? input + Manvi.promptSuffix : input).utf8)
        let spec = Subprocess.Spec(executable, arguments, environment: environment, directory: directory.path,
                                   input: agent.kind == .codex ? .open : .data(prompt))

        // The reader writes back through the job it is read from.
        let jobRef = JobRef()
        let errTail = ErrTail()
        // Main queue, not Tasks: events must land in the order they were read.
        let reader = AgentStreamReader(kind: agent.kind, prompt: input, folder: folder.path,
                                       write: { jobRef.job?.write($0) },
                                       done: { jobRef.job?.terminate() }) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.launch == generation else { return }
                    self.handle(event)
                }
            }
        }
        // The run ends once the process has exited and all its output is read.
        let job = Subprocess.Job(spec, stdout: .stream { reader.feed($0) }, stderr: .stream { errTail.feed($0) })
        jobRef.job = job
        job.onFinish = { [weak self] outcome in
            let tail = errTail.last
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.launch == generation else { return }
                    self.processEnded(status: outcome.status, stderr: tail)
                }
            }
        }
        do {
            try job.start()
        } catch {
            let reason = job.failure(error).launchError ?? error.localizedDescription
            phase = .failed(String(localized: "Couldn't start \(displayName): \(reason)"))
            return
        }
        self.job = job
        if agent.kind == .codex { reader.begin() }
    }

    /// Lets the stream reader reach the job it feeds from.
    private nonisolated final class JobRef: @unchecked Sendable {
        weak var job: Subprocess.Job?
    }

    /// Custom provider: stream the plan over HTTP. No process, no PATH, no
    /// working folder — the endpoint only ever sees the prompt text (folder
    /// paths and sizes, never file contents) and answers with plan JSON.
    private func startProvider(input: String, provider: LLMProvider) {
        let key = ProviderStore.getKey(for: provider.id) ?? ""
        let client = LLMPlanClient(provider: provider, apiKey: key)
        planClient = client
        let name = displayName
        client.plan(input) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleProvider(event, name: name) } }
        }
        step(asking)
    }

    private var asking: String {
        focus.map { String(localized: "Asking \(displayName) about \($0.name)") }
            ?? String(localized: "Asking \(displayName) what can go")
    }

    /// The tail of the cards being judged. Judging a card reads files and may
    /// run git and lsof, so it happens away from the main actor; what the
    /// stream said is applied here strictly in the order it was read, each
    /// step waiting for the one before it.
    private var applying: Task<Void, Never>?

    private func inOrder(_ step: @escaping @MainActor (AgentRun) async -> Void) {
        let previous = applying
        applying = Task { [weak self] in
            await previous?.value
            guard let self, !self.cancelled else { return }
            await step(self)
        }
    }

    /// Every card goes through the same guards; a focused run also keeps
    /// them inside the item it asked about.
    private func plan(_ spec: PlanItemSpec) async -> PlanItem {
        await PlanItem.make(spec: spec, tree: tree, scope: focus?.node)
    }

    private func handleProvider(_ event: LLMEvent, name: String) {
        guard phase == .thinking else { return }
        switch event {
        case .item(let spec):
            inOrder { run in
                guard run.phase == .thinking else { return }
                let item = await run.plan(spec)
                guard run.phase == .thinking, !run.cancelled else { return }
                withAnimation(.snappy) { run.items.append(item) }
            }
        case .plan(let summary, let specs):
            inOrder { run in
                guard run.phase == .thinking else { return }
                run.summary = summary
                // The final JSON is authoritative; keep the cards already shown
                // (and their checkboxes) when they match.
                if specs.map(\.title) != run.items.map(\.spec.title) {
                    var final: [PlanItem] = []
                    for spec in specs { final.append(await run.plan(spec)) }
                    guard run.phase == .thinking, !run.cancelled else { return }
                    withAnimation(.snappy) { run.items = final }
                }
                run.finishPlanning()
            }
        case .failed(let message):
            NSLog("[bz] provider \(name) failed: \(message)")
            inOrder { run in
                guard run.phase == .thinking else { return }
                if !run.items.isEmpty { run.finishPlanning() } else { run.phase = .failed(message) }
            }
        }
    }

    /// Takes what the stream read. The cards are judged off the main actor and
    /// land in `items` in order, so `items` lags the stream by the cards still
    /// being judged: anything that decides from `items` goes through `inOrder`.
    private func handle(_ event: AgentStreamReader.Event) {
        guard phase == .thinking else { return }
        switch event {
        case .activity(let text):
            step(text)
        case .item(let spec):
            inOrder { run in
                guard run.phase == .thinking else { return }
                let item = await run.plan(spec)
                guard run.phase == .thinking, !run.cancelled else { return }
                withAnimation(.snappy) { run.items.append(item) }
            }
        case .restart:
            inOrder { run in
                guard run.phase == .thinking else { return }
                withAnimation(.snappy) { run.items = [] }
            }
        case .plan(let summary, let specs):
            inOrder { run in
                guard run.phase == .thinking else { return }
                run.summary = summary
                // The final JSON is authoritative; keep the cards already shown
                // (and their checkboxes) when they match.
                if specs != run.items.map(\.spec) {
                    let final = await PlanItem.reconcile(specs, previous: run.items, tree: run.tree,
                                                         scope: run.focus?.node)
                    guard run.phase == .thinking, !run.cancelled else { return }
                    withAnimation(.snappy) { run.items = final }
                }
                run.finishPlanning()
            }
        case .failed(let message):
            // A CLI run that dies after streaming cards still finishes
            // planning with what arrived; a provider whose JSON never
            // decoded strictly gets the same grace.
            inOrder { run in
                guard run.phase == .thinking else { return }
                if !run.items.isEmpty { run.finishPlanning() } else { run.phase = .failed(message) }
            }
        }
    }

    private func processEnded(status: Int32, stderr: String) {
        job = nil
        guard phase == .thinking, !cancelled else { return }
        // After every card the stream delivered has landed.
        inOrder { run in run.decideAfterExit(status: status, stderr: stderr) }
    }

    private func decideAfterExit(status: Int32, stderr: String) {
        guard phase == .thinking, !cancelled else { return }
        if !items.isEmpty {
            finishPlanning()
        } else if routeIndex + 1 < routes.count {
            // No card from this route: the next one gets the same prompt.
            let failed = routes[routeIndex]
            NSLog("[bz] MANVI on \(failed.label) gave no plan (exit \(status)): \(stderr)")
            routeIndex += 1
            step(String(localized: "\(failed.label) gave no plan; switching to \(routes[routeIndex].label)"))
            start()
        } else if status != 0 {
            // MANVI's exit codes 2-5 each name why the turn ended.
            let known = agent?.kind == .manvi ? Manvi.exitMessage(status) : nil
            phase = .failed(known ?? (stderr.isEmpty ? String(localized: "\(displayName) stopped (exit \(String(status))).") : stderr))
        } else {
            phase = .failed(String(localized: "\(displayName) didn't return a plan."))
        }
    }

    private func finishPlanning() {
        planSeconds = -startedAt.timeIntervalSinceNow
        items.sort { $0.bytes > $1.bytes }
        if summary.isEmpty {
            summary = String(localized: "About \(Fmt.size(items.filter { $0.blocked == nil }.reduce(0) { $0 + $1.bytes })) can go.")
        }
        withAnimation(.snappy) { phase = .planned }
    }

    // MARK: Cleaning (BlitzTree does this, not the agent)

    /// Demo recordings only: walk through both steps without touching disk.
    private let dryRun = ProcessInfo.processInfo.environment["BZ_DEMO_DRYRUN"] != nil

    /// Step one: move the chosen folders to the Trash. Nothing is deleted.
    func moveToTrash() {
        guard phase == .planned else { return }
        phase = .trashing
        for item in items where !(item.selected && item.blocked == nil) { item.status = .skipped }
        let work = targets.filter { !$0.isCommand }
        for item in work { item.status = .running }
        Task {
            // Moving to the Trash is a rename; all of them at once, off the main thread.
            await withTaskGroup(of: Void.self) { group in
                for item in work {
                    let paths = item.cleanupTargets
                    let dryRun = dryRun
                    group.addTask {
                        let result = dryRun ? (moved: [CleanupReceipt](), error: String?.none) : await Self.trash(paths)
                        await MainActor.run {
                            item.trashed = result.moved
                            item.stagingError = result.error
                            item.trashedBytes = dryRun ? item.bytes : result.moved.reduce(UInt64(0)) { total, receipt in
                                total + (self.tree.node(at: receipt.sourcePath).map { self.tree.alloc[$0] } ?? 0)
                            }
                            withAnimation(.snappy) { item.status = result.error.map { .failed($0) } ?? .inTrash }
                        }
                    }
                }
            }
            withAnimation(.snappy) { phase = .staged }
        }
    }

    /// Step two: delete for good what step one trashed, and run the tools'
    /// own cache cleanups. Only this run's items; the rest of the Trash stays.
    /// Everything runs at once: folder deletes spread over every core.
    func deleteForGood(env: AgentEnvironment) {
        guard phase == .staged else { return }
        phase = .deleting
        let work = targets.filter { $0.status == .inTrash || !$0.trashed.isEmpty || ($0.isCommand && $0.status == .waiting) }
        for item in work { item.status = .running }
        let before = Self.freeBytes()
        Task {
            await withTaskGroup(of: Void.self) { group in
                for item in work {
                    let urls = item.trashed
                    let command = item.isCommand ? item.spec.command : nil
                    let bytes = item.bytes
                    let dryRun = dryRun
                    let stagedBytes = item.isCommand ? item.bytes : item.trashedBytes
                    group.addTask {
                        var error: String?
                        var remaining: [CleanupReceipt] = []
                        var notices: [String] = []
                        if dryRun {
                            // Roughly as long as the real delete: bigger items finish later.
                            let gb = Double(bytes) / 1e9
                            try? await Task.sleep(for: .seconds(min(3.5, 0.3 + gb / 4)))
                        } else if let command {
                            error = await Self.runCommand(command, path: env.path)?.text
                        } else {
                            (remaining, notices, error) = await Self.deleteTrashed(urls)
                        }
                        let failedReceipts = remaining
                        let leftInPlace = notices
                        let failure = error
                        await MainActor.run {
                            item.recordDeletion(remaining: failedReceipts, notices: leftInPlace, error: failure,
                                                stagedBytes: stagedBytes, tree: self.tree)
                        }
                    }
                }
            }
            // What the disk really got back: APFS frees a moment after the
            // delete, and blocks shared with clones (bun installs packages as
            // clones of its cache) stay in use, so wait for it to settle.
            if !dryRun {
                var last = Self.freeBytes()
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(300))
                    let now = Self.freeBytes()
                    if now == last { break }
                    last = now
                }
                reclaimed = last > before ? last - before : 0
            }
            withAnimation(.snappy) { phase = .done }
            if !dryRun { onFinish() }
        }
    }

    /// Deletes what step one moved to the Trash. `remaining` failed and can be
    /// retried; `notices` are things left as they were (a worktree's git
    /// metadata that changed meanwhile), which the card shows.
    nonisolated static func deleteTrashed(_ receipts: [CleanupReceipt])
        async -> (remaining: [CleanupReceipt], notices: [String], error: String?) {
        let result = await CleanupOperations.remove(receipts)
        return (result.remaining, result.notices, result.errors.isEmpty ? nil : result.errors.joined(separator: "\n"))
    }

    /// Revalidate captured targets at the actual operation boundary.
    nonisolated static func trash(_ targets: [CleanupTarget], move: @escaping @Sendable (URL) throws -> URL = CleanupOperations.systemTrash)
        async -> (moved: [CleanupReceipt], error: String?) {
        // Each move re-verifies its target (git, lsof): a dispatch thread,
        // not one of the few cooperative ones.
        await AgentLocator.onBackgroundThread {
            var moved: [CleanupReceipt] = []
            var errors: [String] = []
            for target in targets {
                do { moved.append(try CleanupOperations.trash(target, move: move)) }
                catch { errors.append("\(target.path): \(error.localizedDescription)") }
            }
            return (moved, errors.isEmpty ? nil : errors.joined(separator: "\n"))
        }
    }

    /// Plain available space (statfs), exact to the block.
    nonisolated static func freeBytes() -> UInt64 {
        var fs = statfs()
        guard statfs(NSHomeDirectory(), &fs) == 0 else { return 0 }
        return UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
    }

    /// Runs a vetted cleanup command; returns an error message on failure.
    /// Waits without holding a thread (so a dozen of them at once cannot
    /// use up the concurrency pool), gives up after `timeout`, and when the
    /// calling task is cancelled terminates the tool and waits for it to exit.
    nonisolated static func runCommand(_ command: String, path: String, timeout: TimeInterval = 600) async -> StepFailure? {
        guard let vetted = CleanupCommand.parse(command) else { return StepFailure("Command or arguments not allowed") }
        let executable = path.split(separator: ":", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(vetted.executable) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let executable else { return StepFailure("Cleanup tool not found in an absolute PATH directory") }
        // Some tools only run inside a project (`bun pm cache rm` wants a
        // package.json), so they run in an empty stand-in one.
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlitzTree/tools", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = folder.appendingPathComponent("package.json")
        if !FileManager.default.fileExists(atPath: manifest.path) {
            try? #"{"name":"blitztree-cleanup","private":true}"#.write(to: manifest, atomically: true, encoding: .utf8)
        }
        // Read as it comes: a chatty tool must never fill the pipe and stall.
        let tail = ErrTail()
        let spec = Subprocess.Spec(executable.path, vetted.arguments, environment: Subprocess.environment(path: path),
                                   directory: folder.path)
        let outcome = await Subprocess.run(spec, stdout: .discard, stderr: .stream { tail.feed($0) }, timeout: timeout)
        if let error = outcome.launchError { return StepFailure(verbatim: error) }
        if outcome.timedOut { return StepFailure("Took too long") }
        if outcome.cancelled { return StepFailure("Cancelled") }
        guard outcome.status != 0 else { return nil }
        return tail.last.isEmpty ? StepFailure("Exited with \(String(outcome.status))") : StepFailure(verbatim: tail.last)
    }
}

/// Why a cleanup step failed, as its card shows it. A message written in code
/// can only be made from a `LocalizedStringResource`, so a bare string cannot
/// reach the card in English; text that came from a tool is `verbatim`.
nonisolated struct StepFailure: Sendable, Equatable {
    let text: String
    init(_ message: LocalizedStringResource) { text = String(localized: message) }
    init(verbatim text: String) { self.text = text }
}

/// Keeps the last line of an agent's stderr for error messages.
nonisolated final class ErrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func feed(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        text = String((text + String(decoding: data, as: UTF8.self)).suffix(2000))
    }
    var last: String {
        lock.lock(); defer { lock.unlock() }
        let lines = text.split(separator: "\n").map(String.init)
        // anthropic-account refused to start MANVI: its first line says why,
        // and the lines after it are how to fix that. Its warnings come from
        // runs it did start, so they never stand for the failure.
        let launcher = "\(Manvi.Account.launcherName): "
        if let refusal = lines.first(where: { $0.hasPrefix(launcher) && !$0.hasPrefix(launcher + "warning:") }) {
            return refusal
        }
        return lines
            .last(where: { line in
                // Codex's MCP client noise, and MANVI's "session <id> saved"
                // notes, which it prints on every run, failed or not.
                !line.contains("rmcp::") && !line.hasPrefix("manvi: session ")
                    && !line.trimmingCharacters(in: .whitespaces).isEmpty
            }) ?? ""
    }
}

// MARK: - Reading the agent's event stream

/// Turns Claude Code's stream-json or Codex's --json lines into a few events.
nonisolated final class AgentStreamReader: @unchecked Sendable {
    enum Event: Sendable {
        case activity(String)
        case item(PlanItemSpec)
        /// The agent started the plan over (its first try failed validation).
        case restart
        case plan(summary: String, items: [PlanItemSpec])
        case failed(String)
    }

    private let kind: AgentKind
    private let prompt: String
    private let folder: String
    private let write: @Sendable (Data) -> Void
    private let done: @Sendable () -> Void
    private let emit: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var pending = Data()
    /// Bytes already checked for a newline in the unfinished final record.
    private var searchedBytes = 0
    private var parser = PartialPlanParser()
    private var inPlan = false
    /// MANVI: the answer text since its last tool call. It has no
    /// final-answer event; the text after the last tool call is the answer.
    private var answer = ""
    /// MANVI: set once `session.start` confirmed the strict posture.
    private var readOnly = false

    init(kind: AgentKind, prompt: String, folder: String, write: @escaping @Sendable (Data) -> Void,
         done: @escaping @Sendable () -> Void, emit: @escaping @Sendable (Event) -> Void) {
        self.kind = kind
        self.prompt = prompt
        self.folder = folder
        self.write = write
        self.done = done
        self.emit = emit
    }

    /// Codex app server: say hello; the rest follows its replies.
    func begin() {
        send(["id": 1, "method": "initialize",
              "params": ["clientInfo": ["name": "blitztree", "title": "BlitzTree", "version": "1"]]])
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(UInt8(ascii: "\n"))
        write(data)
    }

    func feed(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lineStart = pending.startIndex
        var searchStart = pending.index(lineStart, offsetBy: searchedBytes)
        while let nl = pending[searchStart...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[lineStart..<nl]
            lineStart = pending.index(after: nl)
            searchStart = lineStart
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch kind {
            case .claude: claude(obj)
            case .codex: codex(obj)
            case .manvi: manvi(obj)
            }
        }
        // Consume a batch once, after its line slices are gone. Removing the
        // prefix per record copied the remaining Data for every line.
        pending.removeSubrange(pending.startIndex..<lineStart)
        searchedBytes = pending.count
    }

    private func claude(_ e: [String: Any]) {
        switch e["type"] as? String {
        case "stream_event":
            guard let ev = e["event"] as? [String: Any] else { return }
            if ev["type"] as? String == "content_block_start",
               let block = ev["content_block"] as? [String: Any] {
                if block["type"] as? String == "tool_use" {
                    inPlan = block["name"] as? String == "StructuredOutput"
                    if inPlan {
                        if parser.hasInput { emit(.restart) }
                        parser = PartialPlanParser()
                        emit(.activity(String(localized: "Writing the plan")))
                    }
                } else if block["type"] as? String == "thinking" {
                    emit(.activity(String(localized: "Thinking")))
                }
            } else if ev["type"] as? String == "content_block_delta", inPlan,
                      let delta = ev["delta"] as? [String: Any],
                      let chunk = delta["partial_json"] as? String {
                for item in parser.append(chunk) { emit(.item(item)) }
            }
        case "assistant":
            guard let content = (e["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
            for c in content where c["type"] as? String == "tool_use" && c["name"] as? String != "StructuredOutput" {
                let input = c["input"] as? [String: Any] ?? [:]
                emit(.activity(Self.describe(tool: c["name"] as? String ?? "", input: input)))
            }
        case "result":
            if let plan = e["structured_output"] as? [String: Any], let decoded = Self.decodePlan(plan) {
                emit(.plan(summary: decoded.0, items: decoded.1))
            } else if e["is_error"] as? Bool == true || e["subtype"] as? String != "success" {
                emit(.failed((e["result"] as? String) ?? String(localized: "Claude Code stopped without a plan.")))
            }
        default:
            break
        }
    }

    /// Codex app-server JSON-RPC: replies to our requests, then notifications.
    private func codex(_ e: [String: Any]) {
        if let id = e["id"] as? Int, e["method"] == nil {
            if let error = e["error"] as? [String: Any] {
                emit(.failed((error["message"] as? String) ?? String(localized: "Codex refused the request.")))
                done()
                return
            }
            let result = e["result"] as? [String: Any] ?? [:]
            switch id {
            case 1:
                send(["method": "initialized"])
                send(["id": 2, "method": "thread/start", "params": [
                    "cwd": folder, "sandbox": "read-only", "approvalPolicy": "never", "ephemeral": true,
                ]])
            case 2:
                guard let thread = (result["thread"] as? [String: Any])?["id"] as? String else { return }
                let schema = (try? JSONSerialization.jsonObject(with: Data(planSchema.utf8))) ?? [:]
                send(["id": 3, "method": "turn/start", "params": [
                    "threadId": thread, "effort": "low", "outputSchema": schema,
                    "input": [["type": "text", "text": prompt, "text_elements": []]],
                ]])
            default:
                break
            }
            return
        }
        let params = e["params"] as? [String: Any] ?? [:]
        let item = params["item"] as? [String: Any] ?? [:]
        switch (e["method"] as? String, item["type"] as? String) {
        case ("item/started", "commandExecution"):
            emit(.activity(Self.describe(tool: "Bash", input: ["command": item["command"] ?? ""])))
        case ("item/started", "reasoning"):
            emit(.activity(String(localized: "Thinking")))
        case ("item/started", "agentMessage"):
            parser = PartialPlanParser()
        case ("item/agentMessage/delta", _):
            if let delta = params["delta"] as? String {
                if !inPlan, delta.contains("{") || parser.hasInput {
                    inPlan = true
                    emit(.activity(String(localized: "Writing the plan")))
                }
                for item in parser.append(delta) { emit(.item(item)) }
            }
        case ("item/completed", "agentMessage"):
            if let text = item["text"] as? String,
               let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
               let decoded = Self.decodePlan(obj) {
                emit(.plan(summary: decoded.0, items: decoded.1))
            }
        case ("turn/completed", _):
            let turn = params["turn"] as? [String: Any] ?? [:]
            if let error = turn["error"] as? [String: Any], let message = error["message"] as? String {
                emit(.failed(message))
            }
            done()
        case ("error", _):
            if let error = params["error"] as? [String: Any], let message = error["message"] as? String,
               params["willRetry"] as? Bool != true {
                emit(.failed(message))
                done()
            }
        default:
            break
        }
    }

    /// `manvi run --json`: one `ui.Event` per line, told apart by `kind`.
    private func manvi(_ e: [String: Any]) {
        let kind = e["kind"] as? String
        // Nothing counts before MANVI says it runs read-only: its write and
        // shell tools are refused only in the strict posture.
        guard readOnly || kind == "session.start" else { return }
        switch kind {
        case "session.start":
            guard e["posture"] as? String == "strict" else {
                emit(.failed(String(localized: "MANVI didn't start read-only, so BlitzTree stopped it.")))
                done()
                return
            }
            readOnly = true
        case "assistant.reasoning":
            if !inPlan { emit(.activity(String(localized: "Thinking"))) }
        case "assistant.text":
            guard let delta = e["text"] as? String else { return }
            answer += delta
            if !inPlan, delta.contains("{") || parser.hasInput {
                inPlan = true
                emit(.activity(String(localized: "Writing the plan")))
            }
            for item in parser.append(delta) { emit(.item(item)) }
        case "tool.start":
            // Text before a tool call was not the answer; start over.
            if parser.hasInput { emit(.restart) }
            parser = PartialPlanParser()
            answer = ""
            inPlan = false
            emit(.activity(Self.describe(manviTool: e["tool"] as? String ?? "", arguments: e["arguments"])))
        case "policy.decision":
            // The strict posture at work: a write or command was refused.
            if let tool = e["tool"] as? String, (e["text"] as? String)?.contains("\"allowed\":false") == true {
                emit(.activity(String(localized: "Kept read-only: \(Self.manviToolName(tool)) was refused")))
            }
        case "turn.end":
            if let plan = PlanJSON.decode(text: answer) {
                emit(.plan(summary: plan.0, items: plan.1))
            }
        default:
            break
        }
    }

    /// "devcouncil_read_file" → "read_file".
    static func manviToolName(_ tool: String) -> String {
        tool.hasPrefix("devcouncil_") ? String(tool.dropFirst("devcouncil_".count)) : tool
    }

    /// MANVI's read tools, in the same plain words as the CLI agents' steps.
    static func describe(manviTool tool: String, arguments: Any?) -> String {
        let args = (arguments as? [String: Any])
            ?? (arguments as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            ?? [:]
        let name = ((args["path"] as? String) ?? "").split(separator: "/").last.map(String.init) ?? ""
        switch manviToolName(tool) {
        case "read_file":
            return name.isEmpty ? String(localized: "Looking around") : String(localized: "Reading \(name)")
        case "list_dir":
            return name.isEmpty ? String(localized: "Looking around") : String(localized: "Looking in \(name)")
        case "grep", "find_files":
            return String(localized: "Looking around")
        default:
            return String(localized: "Checking \(manviToolName(tool))")
        }
    }

    static func decodePlan(_ obj: [String: Any]) -> (String, [PlanItemSpec])? {
        PlanJSON.decode(obj)
    }

    /// "du -sk ~/a ~/b" → "Measuring a, b"; the rest in a few plain words.
    static func describe(tool: String, input: [String: Any]) -> String {
        if tool == "Read", let path = input["file_path"] as? String {
            return String(localized: "Reading \((path as NSString).lastPathComponent)")
        }
        let command = (input["command"] as? String) ?? ""
        let words = command.split(separator: " ").map(String.init)
        let targets = words.dropFirst().filter { !$0.hasPrefix("-") && $0.contains("/") }
            .map { ($0 as NSString).lastPathComponent }
        let names = targets.prefix(3).joined(separator: ", ") + (targets.count > 3 ? "…" : "")
        switch words.first ?? "" {
        case "du": return names.isEmpty ? String(localized: "Measuring folders") : String(localized: "Measuring \(names)")
        case "ls", "stat": return names.isEmpty ? String(localized: "Looking around") : String(localized: "Looking in \(names)")
        case "docker": return String(localized: "Checking Docker")
        case "xcrun": return String(localized: "Checking Xcode simulators")
        case "ollama": return String(localized: "Checking Ollama models")
        default: return String(localized: "Checking \(words.first ?? "")")
        }
    }
}

// MARK: - What the agent is told

nonisolated enum AgentPrompt {
    /// The flat tree orders siblings by size and includes descendants in
    /// each directory's total. Small subtrees cannot contribute a row.
    /// A focused question passes its own node and cutoffs scaled to it.
    static func largestNodes(in tree: Tree, under root: Int = 0, minFolder: UInt64 = 100_000_000,
                             minFile: UInt64 = 250_000_000) -> (folders: [Int], files: [Int]) {
        var folders: [Int] = []
        var files: [Int] = []
        var stack = [root]
        while let parent = stack.popLast() {
            for raw in tree.children(parent) {
                let i = Int(raw), size = tree.alloc[i]
                guard size >= minFolder else { break }
                if tree.isDir(i) {
                    stack.append(i)
                    // Still descend through pass-through folders: only their
                    // redundant table row is omitted.
                    if let first = tree.children(i).first, tree.isDir(Int(first)),
                       Double(tree.alloc[Int(first)]) >= 0.95 * Double(size) { continue }
                    folders.append(i)
                } else if size >= minFile {
                    files.append(i)
                }
            }
        }
        // The original scan-order sort was stable. Preserve its node-ID
        // order for ties even though traversal now follows the hierarchy.
        func larger(_ a: Int, _ b: Int) -> Bool {
            tree.alloc[a] == tree.alloc[b] ? a < b : tree.alloc[a] > tree.alloc[b]
        }
        folders.sort(by: larger)
        files.sort(by: larger)
        return (Array(folders.prefix(250)), Array(files.prefix(80)))
    }

    /// The whole-scan cleanup, or with `focus` the question "is this one item
    /// safe to clean?" Both share the plan rules; a focus only narrows the
    /// tables to the item and asks for a verdict as the summary.
    static func build(tree: Tree, scanRoot: String, known: [CleanupItem], running: [String],
                      focus: AgentFocus? = nil, verdict: AgentFocus.Verdict? = nil,
                      home: String = NSHomeDirectory()) -> String {
        func shown(_ i: Int) -> String { tree.displayPath(i) }

        var md: String
        let folders: [Int], files: [Int], rebuildable: [CleanupItem]
        if let focus {
            // Scaled to the item: a 40 MB folder still gets a useful breakdown.
            let cutoff = max(1_000_000, tree.alloc[focus.node] / 100)
            (folders, files) = largestNodes(in: tree, under: focus.node, minFolder: cutoff, minFile: cutoff)
            rebuildable = known.filter { tree.ancestry($0.node).contains(focus.node) }
            let kind = focus.isDir ? "folder" : "file"
            md = """
            You are the cleanup agent inside BlitzTree, a macOS disk-space app. The user right-clicked \
            one \(kind) and asked whether it is safe to clean: \(focus.path) (\(Fmt.size(tree.alloc[focus.node]))\
            \(focus.isDir ? ", \(Fmt.num(UInt64(tree.nFiles[focus.node]))) files" : "")). They are watching a \
            live view of your steps, so be fast. Their home folder is \(home).
            \(verdict.map { "\nBlitzTree's own check: \($0.english)\n" } ?? "")
            Below is BlitzTree's scan of that \(kind) (allocated sizes, measured seconds ago). Use it; do \
            not re-scan the disk. Only check what you really cannot judge from the tables, batched (one \
            `du -sk a b c` beats several), at most 3 commands.

            Answer about this \(kind) only. Every path in items must be \(focus.path) itself or inside \
            it; BlitzTree ignores any other path. If it should be kept, say so and return no items.

            Return a cleanup plan as JSON (the schema is enforced):
            - summary: your verdict in one or two plain sentences, under 220 characters: what it is, and \
            whether removing it loses anything or it is rebuilt, e.g. "npm packages for one project; \
            npm install brings them back, so it is safe to remove."
            - items, largest first, at most 12. Each item:
            """
        } else {
            (folders, files) = largestNodes(in: tree)
            rebuildable = known
            md = """
            You are the cleanup agent inside BlitzTree, a macOS disk-space app. The user clicked \
            "Clean up" and is watching a live view of your steps, so be fast. Their home folder is \(home).

            Below is BlitzTree's scan (\(scanRoot == "/System/Volumes/Data" ? "whole disk" : scanRoot), \
            allocated sizes, measured seconds ago). Use it; do not re-scan the disk. Most plans need no \
            commands at all. Only check what you really cannot judge from the tables, batched (one \
            `du -sk a b c` beats several), at most 3 commands.

            Return a cleanup plan as JSON (the schema is enforced):
            - summary: one short sentence, e.g. "About 44 GB of caches and build output can go."
            - items, largest first, at most 12. Each item:
            """
        }
        // Outside the home, plans may only name a Claude Code scratchpad's
        // recognised build output; say so only when the scan has some.
        let scratchRoots = Set(rebuildable.compactMap { item in
            CleanupPathSafety.claudeTemp(item.path).flatMap { $0.inScratchpad ? $0.root : nil }
        })
        let scratchNote = scratchRoots.isEmpty ? "" : """
         Build output in Claude Code scratchpads \
        (\(scratchRoots.sorted().joined(separator: ", "))/<project>/<session>/scratchpad/...) that \
        BlitzTree recognised below is fine too: action "trash", group "safe", one item per project \
        folder; BlitzTree keeps the ones whose session is still running.
        """
        md += "\n" + """
          - title: 2-5 plain words ("uv package cache", "Old Playwright browsers").
          - detail: why it is safe, under 90 characters, plain English.
          - group: "safe" = rebuilt or re-downloaded automatically, nothing lost; "ask" = probably \
        fine but the user should decide (old downloads, models, whole old projects).
          - bytes: size in bytes.
          - paths: the absolute paths it covers.
          - action: "command" when the owning tool has its own cleanup and the item is that tool's \
        cache, otherwise "trash" (BlitzTree moves the paths to the Trash itself). BlitzTree only runs \
        these exact commands: \(CleanupCommand.promptExamples). No additional options or paths, \
        shell syntax or globbing; the command must not prompt.
          - command: the exact command for "command", "" for "trash".
        `npm cache clean` only empties ~/.npm/_cacache; ~/.npm/_npx is a separate "trash" item. Only \
        list caches that appear in the tables above with their real size; skip ones that are not there.
        Name specific folders. Never a whole ~/Library, ~/Library/Caches, ~/Library/Application \
        Support, ~/Library/Containers, ~/Downloads or ~/.config: list the large subfolders instead.
        Never include: ~/Documents, ~/Desktop, ~/Pictures, the Photos library, ~/Movies, ~/Music, Mail, \
        Messages, iCloud Drive (~/Library/Mobile Documents), keychains, ~/.ssh, dotfile configs, source \
        code, git repositories themselves, or files of the running apps below. Build output inside \
        projects (node_modules, target, .next, dist, DerivedData) is fine, and so are the Codex chat \
        folders and Xcode simulators listed at the end.\(scratchNote)

        ## Apps running now
        \(running.joined(separator: ", "))

        """
        if !rebuildable.isEmpty {
            md += "\n## Recognised by BlitzTree as rebuildable\n\n| Size | Path | What |\n|---:|---|---|\n"
            for item in rebuildable.prefix(120) {
                md += "| \(Fmt.size(item.bytes)) | \(item.path) | \(item.kind) |\n"
            }
        }
        if let focus, !focus.isDir {
            md += "\n## The file\n\n| Size | Path |\n|---:|---|\n| \(Fmt.size(tree.alloc[focus.node])) | \(focus.path) |\n"
            return md
        }
        if focus == nil || !folders.isEmpty {
            md += "\n## Largest folders\(focus == nil ? "" : " inside it")\n\n| Size | Files | Path |\n|---:|---:|---|\n"
            for i in folders.prefix(250) {
                md += "| \(Fmt.size(tree.alloc[i])) | \(Fmt.num(UInt64(tree.nFiles[i]))) | \(shown(i))/ |\n"
            }
        }
        if !files.isEmpty {
            md += "\n## Largest files\(focus == nil ? "" : " inside it")\n\n| Size | Path |\n|---:|---|\n"
            for i in files.prefix(80) { md += "| \(Fmt.size(tree.alloc[i])) | \(shown(i)) |\n" }
        }
        return md
    }

    /// Whether an app-data section is worth its lookup for this question:
    /// always for the whole scan, else only when the focus and the section's
    /// folder contain one another.
    static func relevant(_ folder: String, to focus: String?) -> Bool {
        guard let focus else { return true }
        let f = focus.hasSuffix("/") ? String(focus.dropLast()) : focus
        return f == folder || folder.hasPrefix(f + "/") || f.hasPrefix(folder + "/") || f.isEmpty
    }

    /// Big folders the scan alone can't explain: Xcode's simulators (runtime
    /// images live outside the home folder and go only through `simctl`) and
    /// the Codex app's chat folders, which sit in the otherwise off-limits
    /// ~/Documents. Listed with what the agent needs to plan them.
    /// A focused question only gets the sections its item overlaps.
    static func appData(tree: Tree, focus: String? = nil) -> String {
        let home = NSHomeDirectory()
        // Device data lives in the home folder, runtime images outside it.
        let wantSims = relevant(home + "/Library/Developer/CoreSimulator", to: focus)
            || relevant("/Library/Developer/CoreSimulator", to: focus)
        // simctl and Codex's logs are independent: look them up side by side.
        let sims = OutputText()
        let done = DispatchGroup()
        if wantSims {
            DispatchQueue.global(qos: .userInitiated).async(group: done) { sims.set(Data(simulators().utf8)) }
        }
        let chats = relevant(home + "/Documents/Codex", to: focus) ? codexChats(tree: tree) : ""
        done.wait()
        return sims.value + chats
    }

    private static func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        let days = Int(Date().timeIntervalSince(date) / 86400)
        return days < 1 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
    }

    private static func simulators() -> String {
        // Run simctl straight from the selected Xcode: /usr/bin/xcrun would
        // offer to install the command line tools on a Mac without them.
        let developer = AgentLocator.run("/usr/bin/xcode-select", ["-p"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let simctl = developer + "/usr/bin/simctl"
        guard !developer.isEmpty, FileManager.default.isExecutableFile(atPath: simctl) else { return "" }
        func json(_ args: [String]) -> [String: Any] {
            let text = AgentLocator.run(simctl, args, timeout: 10).out
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        }
        func date(_ any: Any?) -> Date? { (any as? String).flatMap { try? Date($0, strategy: .iso8601) } }

        var runtimes = ""
        let images = json(["runtime", "list", "-j"]).values.compactMap { $0 as? [String: Any] }
        for image in images.sorted(by: { ($0["sizeBytes"] as? Int64 ?? 0) > ($1["sizeBytes"] as? Int64 ?? 0) }) {
            guard let id = image["identifier"] as? String, image["deletable"] as? Bool ?? true,
                  let size = image["sizeBytes"] as? Int64, size >= 100_000_000 else { continue }
            // "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS"
            let platform = (image["runtimeIdentifier"] as? String)?.split(separator: ".").last?
                .split(separator: "-").first.map(String.init) ?? "Simulator"
            let version = image["version"] as? String ?? ""
            runtimes += "| \(Fmt.size(UInt64(size))) | \(platform) \(version) | \(ago(date(image["lastUsedAt"]))) "
                + "| \(id) | \(image["path"] as? String ?? "") |\n"
        }

        var devices = ""
        let byRuntime = json(["list", "devices", "-j"])["devices"] as? [String: Any] ?? [:]
        let all = byRuntime.values.flatMap { $0 as? [[String: Any]] ?? [] }
        for device in all.sorted(by: { ($0["dataPathSize"] as? Int64 ?? 0) > ($1["dataPathSize"] as? Int64 ?? 0) }) {
            guard let udid = device["udid"] as? String, let data = device["dataPath"] as? String,
                  let size = device["dataPathSize"] as? Int64, size >= 100_000_000 else { continue }
            let folder = (data as NSString).deletingLastPathComponent
            let state = device["state"] as? String ?? ""
            devices += "| \(Fmt.size(UInt64(size))) | \(device["name"] as? String ?? "") (\(state)) "
                + "| \(ago(date(device["lastUsedAt"]))) | \(udid) | \(folder) |\n"
        }
        guard !runtimes.isEmpty || !devices.isEmpty else { return "" }

        var md = """

        ## Xcode simulators

        Simulator runtimes are system images Xcode downloads again when a simulator needs one. Plan \
        each as its own item: action "command", command `xcrun simctl runtime delete <id>`, paths = \
        [its path], group "safe" if unused for 30+ days, else "ask". Device data is one simulator's \
        installed apps and files: action "command", command `xcrun simctl erase <udid>` (empties it, \
        the device stays), paths = [its folder], group "ask". Never trash simulator folders directly.

        """
        if !runtimes.isEmpty {
            md += "\n| Size | Runtime | Last used | Id | Path |\n|---:|---|---|---|---|\n" + runtimes
        }
        if !devices.isEmpty {
            md += "\n| Size | Device | Last used | UDID | Folder |\n|---:|---|---|---|---|\n" + devices
        }
        return md
    }

    private static func codexChats(tree: Tree) -> String {
        let root = NSHomeDirectory() + "/Documents/Codex"
        guard let codex = tree.node(at: root) else { return "" }
        var chats: [(node: Int, path: String)] = []
        for day in tree.children(codex).map(Int.init) {
            guard tree.alloc[day] >= 100_000_000 else { break }
            let dayPath = root + "/" + tree.name(day)
            for chat in tree.children(day).map(Int.init) {
                guard tree.alloc[chat] >= 100_000_000 else { break }
                let path = dayPath + "/" + tree.name(chat)
                if tree.isDir(chat), CleanupGuard.codexChat(path) == path { chats.append((chat, path)) }
            }
        }
        guard !chats.isEmpty else { return "" }
        chats.sort { tree.alloc[$0.node] > tree.alloc[$1.node] }

        var md = """

        ## Codex chat folders

        The Codex app keeps each chat's files in ~/Documents/Codex/<date>/<chat>: `outputs` holds what \
        the chat produced (exports, downloads, renders), `work` its scratch files. Nothing recreates \
        them, so group "ask", action "trash". One item per chat over 1 GB, titled from the chat name \
        with its date in the detail; smaller ones may share one item. The chat folder or its \
        `outputs`/`work` subfolders are valid paths. BlitzTree keeps chats used in the last 2 days.

        | Size | Chat | Last used | Inside |
        |---:|---|---|---|

        """
        let sessions = AgentSessions.lastActive(in: AgentSessions.codex)
        for (node, path) in chats.prefix(40) {
            let used = sessions.filter { $0.key == path || $0.key.hasPrefix(path + "/") }.values.max()
            let inside = tree.children(node).prefix(3).map { "\(tree.name(Int($0))) \(Fmt.size(tree.alloc[Int($0)]))" }
            md += "| \(Fmt.size(tree.alloc[node])) | \(path) | \(used.map(ago) ?? "unknown") | \(inside.joined(separator: ", ")) |\n"
        }
        return md
    }
}
