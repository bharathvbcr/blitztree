import Foundation

// MANVI as a Clean Up planner. It runs as `manvi run --json`, headless, in
// the strict posture: with no DevCouncil task checked out, MANVI's own gate
// refuses its file-writing and shell tools (rules `task.absent` and
// `command.no_lease`), so it can only answer. BlitzTree checks the posture
// MANVI reports and stops a run that started any other way. As with Claude
// Code and Codex, BlitzTree does the cleanup itself, behind its own guards.

nonisolated enum Manvi {
    /// What MANVI can call: a local server (Ollama, LM Studio, vLLM,
    /// llama.cpp, MLX, Jan) or a hosted API.
    static let providers = ["local", "anthropic", "gemini", "xai"]

    /// The shell-exported credential variables of the hosted providers whose
    /// key BlitzTree passes on, in MANVI's order. Anthropic is not one: its
    /// key and organisation are `anthropic-account`'s to choose (`Account`).
    static let credentials: [String: [String]] = [
        "gemini": ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
        "xai": ["XAI_API_KEY", "GROK_API_KEY"],
    ]

    /// Anthropic credentials no MANVI process gets from BlitzTree, whatever
    /// its own environment or the shell holds: the Claude API route has them
    /// set by `anthropic-account`, and every other route goes without.
    static let anthropicCredentials = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_WORKSPACE_ID",
        "ANTHROPIC_API_KEY_FALLBACK", "ANTHROPIC_WORKSPACE_ID_FALLBACK",
    ]

    /// Read from the user's login shell along with its PATH: MANVI takes
    /// credentials and model choices only from its environment, and an app
    /// started from the Dock has none of the shell's exports.
    static let shellVariables = [
        "ANTHROPIC_BASE_URL", "GEMINI_API_KEY", "GOOGLE_API_KEY",
        "XAI_API_KEY", "GROK_API_KEY", "LOCAL_API_KEY", "OPENAI_API_KEY",
        "MANVI_LLM_PROVIDER_DEFAULT", "MANVI_MODEL", "MANVI_LLM_LOCAL_BASE_URL",
    ]

    /// A shell snippet printing `BZENV_<name>=<value>` for each variable, one
    /// plain `printf` apiece: zsh, bash and fish all accept that (fish has no
    /// `for … do`, and one parse error would lose the whole lookup). An unset
    /// variable prints an empty value, which the parser drops.
    static var shellProbe: String {
        shellVariables.map { "printf 'BZENV_\($0)=%s\\n' \"$\($0)\"" }.joined(separator: "; ")
    }

    /// The hosted providers, the "cloud" side of the switch.
    static var cloudProviders: [String] { providers.filter { $0 != "local" } }

    /// Posted by Settings when the choice changes; the window then looks for
    /// agents again, so the panel's MANVI readiness follows.
    static let settingsChanged = Notification.Name("bz.manviSettingsChanged")

    /// What Settings calls each provider.
    static func label(_ provider: String) -> String {
        switch provider {
        case "local": String(localized: "Local model (Ollama, LM Studio, vLLM…)")
        case "anthropic": "Anthropic (Claude API)"
        case "gemini": "Google Gemini"
        case "xai": "xAI"
        default: provider
        }
    }

    /// One way to run MANVI: a provider and the model it uses there. Nil
    /// leaves the model to MANVI: its main tier on a hosted API, the only
    /// model a local server serves.
    struct Route: Sendable, Hashable {
        let provider: String
        let model: String?
        var isLocal: Bool { provider == "local" }

        /// "Local · gemma4:e4b", "Claude API · claude-sonnet-5-5".
        var label: String {
            let side = isLocal ? String(localized: "Local")
                : provider == "anthropic" ? "Claude API" : Manvi.label(provider)
            return model.map { "\(side) · \($0)" } ?? side
        }
    }

    /// Where MANVI runs: `auto` tries the local model first and switches to
    /// the cloud provider when the local one is not running or gives no plan;
    /// `local` and `cloud` use one side only.
    struct Choice: Equatable {
        static let modes = ["auto", "local", "cloud"]
        static let modeKey = "bz.manviMode"
        static let localModelKey = "bz.manviLocalModel"
        static let cloudKey = "bz.manviCloud"
        static let cloudModelKey = "bz.manviCloudModel"

        var mode: String
        var localModel: String?
        var cloud: String
        var cloudModel: String?

        /// Settings first; else what the shell exports for MANVI
        /// (MANVI_LLM_PROVIDER_DEFAULT names the side MANVI_MODEL is for);
        /// else automatic, and the first cloud provider with a key. Settings
        /// an older BlitzTree kept for picking a key are dropped here.
        static func load(shell: [String: String], defaults: UserDefaults = .standard,
                         anthropicReady: () -> Bool) -> Choice {
            Account.retire(defaults)
            func setting(_ key: String) -> String? {
                defaults.string(forKey: key).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
            }
            let shellProvider = shell["MANVI_LLM_PROVIDER_DEFAULT"] ?? "local"
            let shellModel = shell["MANVI_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            let shellCloud = cloudProviders.contains(shellProvider) ? shellProvider : nil
            // Only looked up when nothing else names the cloud provider.
            let cloud = setting(cloudKey).flatMap { cloudProviders.contains($0) ? $0 : nil } ?? shellCloud
                ?? cloudProviders.first { hasKey($0, shell: shell, anthropicReady: anthropicReady) }
                ?? "anthropic"
            return Choice(
                mode: setting(modeKey).flatMap { modes.contains($0) ? $0 : nil } ?? "auto",
                localModel: setting(localModelKey) ?? (shellProvider == "local" ? shellModel : nil),
                cloud: cloud,
                cloudModel: setting(cloudModelKey) ?? (shellCloud == cloud ? shellModel : nil))
        }

        func save(defaults: UserDefaults = .standard) {
            defaults.set(mode, forKey: Self.modeKey)
            defaults.set(cloud, forKey: Self.cloudKey)
            for (key, value) in [(Self.localModelKey, localModel), (Self.cloudModelKey, cloudModel)] {
                if let value, !value.isEmpty { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }

        /// The routes this choice tries, in order, ready or not.
        var routes: [Route] {
            let local = Route(provider: "local", model: localModel)
            let remote = Route(provider: cloud, model: cloudModel)
            switch mode {
            case "local": return [local]
            case "cloud": return [remote]
            default: return [local, remote]
            }
        }
    }

    /// A cloud provider BlitzTree can run: Gemini and xAI on a key the shell
    /// exports; Anthropic when `anthropic-account` has a key for the account
    /// it would pick (asked without reading the secret).
    static func hasKey(_ provider: String, shell: [String: String], anthropicReady: () -> Bool) -> Bool {
        provider == "anthropic" ? anthropicReady() : shellKey(provider, shell: shell) != nil
    }

    static func shellKey(_ provider: String, shell: [String: String]) -> String? {
        (credentials[provider] ?? []).lazy.compactMap { shell[$0] }.first { !$0.isEmpty }
    }

    /// The Claude API route's key and organisation are chosen by
    /// `anthropic-account` (MANVI's cmd/anthropic-account), the one launcher
    /// every host starts MANVI through for Anthropic. It picks the account
    /// (Settings' choice as --account, else ANTHROPIC_ACCOUNT, else a
    /// `.anthropic-account` marker at or above the scanned folder, else the
    /// first line of ~/.anthropic-accounts), reads that account's Keychain
    /// item, and execs MANVI with the key and the account's workspace set.
    /// BlitzTree only asks it questions that read no secret.
    enum Account {
        static let launcherName = "anthropic-account"
        /// Settings' account; none leaves the choice to the launcher.
        static let settingKey = "bz.manviAnthropicAccount"
        /// What BlitzTree stored when it read keys itself. The workspace
        /// could name another organisation than the key's, which Anthropic
        /// answers with 404 "Workspace not found".
        static let retiredKeys = ["bz.manviKeychain.anthropic", "bz.manviKeychain.gemini", "bz.manviKeychain.xai",
                                  "bz.manviAnthropicWorkspace"]

        static func retire(_ defaults: UserDefaults) {
            for key in retiredKeys where defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
        }

        static func setting(_ defaults: UserDefaults = .standard) -> String? {
            defaults.string(forKey: settingKey).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }

        static func save(_ name: String?, defaults: UserDefaults = .standard) {
            if let name, !name.isEmpty { defaults.set(name, forKey: settingKey) } else { defaults.removeObject(forKey: settingKey) }
        }

        /// `--account <name>` when Settings names one.
        static func selector(_ defaults: UserDefaults = .standard) -> [String] {
            setting(defaults).map { ["--account", $0] } ?? []
        }

        /// The account a launch would bill and its workspace, from `which --json`.
        struct Pick: Sendable, Equatable {
            let account: String
            let workspace: String?
        }

        enum Status: Sendable, Equatable {
            /// No `anthropic-account` on this Mac.
            case missing
            /// It would refuse to launch; its own words.
            case refused(String)
            case ready(Pick)

            var isReady: Bool { if case .ready = self { return true }; return false }
        }

        /// One launcher call: stdout, stderr, exit status.
        typealias Probe = @Sendable (_ arguments: [String]) -> (out: String, err: String, status: Int32)

        static func probe(_ launcher: String, envPath: String) -> Probe {
            { arguments in
                let spec = Subprocess.Spec(launcher, arguments, environment: Subprocess.environment(path: envPath))
                let outcome = Subprocess.runBlocking(spec, stdout: .capture(cap: 1 << 20), stderr: .capture(cap: 64 << 10),
                                                     timeout: 10)
                guard outcome.finished else { return ("", "\(launcherName) did not answer", -1) }
                return (outcome.output, String(decoding: outcome.stderr, as: UTF8.self), outcome.status)
            }
        }

        /// Ready when `which` names an account and `doctor` finds its
        /// Keychain item. Neither reads a secret, and doctor's exit status
        /// is not used: it also fails for a missing fallback key, which
        /// costs a run its failover, not the run.
        static func status(launcher: String?, envPath: String, defaults: UserDefaults = .standard,
                           probe: Probe? = nil) -> Status {
            guard let launcher else { return .missing }
            let run = probe ?? Self.probe(launcher, envPath: envPath)
            let which = run(["which", "--json"] + selector(defaults))
            guard which.status == 0, let pick = parseWhich(which.out) else {
                return .refused(refusal(which.err, status: which.status))
            }
            let doctor = run(["doctor"])
            let rows = doctor.out.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            if rows.contains(where: { $0.count >= 2 && $0[0] == "ok" && $0[1] == pick.account }) { return .ready(pick) }
            if let row = rows.first(where: { $0.count >= 2 && $0[1] == pick.account }) {
                return .refused(row.joined(separator: " "))
            }
            return .refused(refusal(doctor.err, status: doctor.status))
        }

        /// The launcher's own message, or its exit status when it said nothing.
        static func refusal(_ stderr: String, status: Int32) -> String {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "\(launcherName) exited with status \(status)" : String(text.prefix(1500))
        }

        static func parseWhich(_ out: String) -> Pick? {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any],
                  let account = obj["account"] as? String, !account.isEmpty else { return nil }
            let workspace = (obj["workspace"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Pick(account: account, workspace: workspace)
        }

        /// The account names `list --json` reports, the default first.
        static func list(launcher: String?, envPath: String, probe: Probe? = nil) -> [String] {
            guard let launcher else { return [] }
            let listed = (probe ?? Self.probe(launcher, envPath: envPath))(["list", "--json"])
            return listed.status == 0 ? parseList(listed.out) : []
        }

        static func parseList(_ out: String) -> [String] {
            let entries = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]] ?? []
            return entries.compactMap { $0["name"] as? String }
        }
    }

    /// The program and arguments that start one MANVI run. The Claude API
    /// route starts through `anthropic-account exec`, nil when it is not
    /// installed; `--repo` lets a marker above the scanned folder pin the
    /// account. exec replaces itself with MANVI, so the process BlitzTree
    /// holds, streams and stops is MANVI's. `manvi` is an absolute path: the
    /// launcher looks a bare name up on the PATH it was given.
    static func launch(route: Route, manvi: String, launcher: String?, repo: String?, arguments: [String],
                       defaults: UserDefaults = .standard) -> (executable: String, arguments: [String])? {
        guard route.provider == "anthropic" else { return (manvi, arguments) }
        guard let launcher else { return nil }
        let repoFlag = repo.map { ["--repo", $0] } ?? []
        return (launcher, ["exec"] + repoFlag + Account.selector(defaults) + ["--", manvi] + arguments)
    }

    /// A model a cloud provider offers: its id and the name to show.
    struct CloudModel: Sendable, Hashable, Identifiable {
        let id: String
        let name: String
    }

    /// Claude models the chosen account may use, newest first, from
    /// Anthropic's `GET /v1/models` (paged by `after_id`). Throws with
    /// Anthropic's, curl's or the launcher's own message when refused.
    static func claudeModels(launcher: String, pick: Account.Pick, envPath: String, baseURL: String?,
                             defaults: UserDefaults = .standard) async throws -> [CloudModel] {
        var base = (baseURL ?? "https://api.anthropic.com").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // The key goes in a header of every request below, so the shell's
        // ANTHROPIC_BASE_URL gets the same https-or-loopback rule as a
        // custom provider's.
        if case .failure(let problem) = ProviderURL.validate(base) {
            throw ModelListError(message: problem.errorDescription ?? "ANTHROPIC_BASE_URL is not allowed")
        }
        if !base.hasSuffix("/v1") { base += "/v1" }
        var models: [CloudModel] = []
        var after: String?
        for _ in 0..<10 {
            var components = URLComponents(string: base + "/models")
            components?.queryItems = [URLQueryItem(name: "limit", value: "100")]
                + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            guard let url = components?.url else { throw CocoaError(.fileReadInvalidFileName) }
            let spec = Subprocess.Spec(launcher, modelRequest(url: url, workspace: pick.workspace != nil, defaults: defaults),
                                       environment: Subprocess.environment(path: envPath))
            let outcome = await Subprocess.run(spec, stderr: .capture(cap: 64 << 10), timeout: 30)
            guard outcome.finished, outcome.status == 0 else {
                let said = String(decoding: outcome.stderr, as: UTF8.self)
                throw ModelListError(message: outcome.timedOut ? "timed out" : Account.refusal(said, status: outcome.status))
            }
            let reply = splitStatus(outcome.stdout)
            let page = try parseClaudeModels(reply.body, status: reply.status)
            models += page.models
            guard page.more, let last = page.models.last?.id else { break }
            after = last
        }
        return models
    }

    /// One models request: curl, started by `anthropic-account` the way a
    /// run is, so the key is only ever in curl's environment. curl's
    /// arguments name it as a variable (`--variable %NAME`, curl 8.3+); the
    /// workspace header is sent only when the account has one, because
    /// curl refuses a variable its environment lacks.
    static func modelRequest(url: URL, workspace: Bool, defaults: UserDefaults = .standard) -> [String] {
        ["exec", "--no-fallback"] + Account.selector(defaults) + [
            "--", "/usr/bin/curl", "--silent", "--show-error", "--max-time", "20",
            "--variable", "%ANTHROPIC_API_KEY", "--expand-header", "x-api-key: {{ANTHROPIC_API_KEY}}",
            "--header", "anthropic-version: 2023-06-01",
        ] + (workspace ? ["--variable", "%ANTHROPIC_WORKSPACE_ID",
                          "--expand-header", "anthropic-workspace-id: {{ANTHROPIC_WORKSPACE_ID}}"] : [])
            + ["--write-out", "\\n%{http_code}", url.absoluteString]
    }

    /// curl's body and the HTTP status `--write-out` put on the last line.
    static func splitStatus(_ out: Data) -> (body: Data, status: Int) {
        guard let newline = out.lastIndex(of: UInt8(ascii: "\n")) else { return (out, 0) }
        let code = Int(String(decoding: out[out.index(after: newline)...], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return (Data(out[..<newline]), code)
    }

    struct ModelListError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// One page of `GET /v1/models`: `data[].id/display_name` and `has_more`.
    static func parseClaudeModels(_ data: Data, status: Int) throws -> (models: [CloudModel], more: Bool) {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status), let list = obj["data"] as? [[String: Any]] else {
            let message = (obj["error"] as? [String: Any])?["message"] as? String
            throw ModelListError(message: message.map { "HTTP \(status): \($0)" } ?? "HTTP \(status)")
        }
        let models = list.compactMap { entry -> CloudModel? in
            guard let id = entry["id"] as? String else { return nil }
            return CloudModel(id: id, name: entry["display_name"] as? String ?? id)
        }
        return (models, obj["has_more"] as? Bool == true)
    }

    /// App-owned folders: an empty working folder, so no project's settings
    /// load and MANVI's tools see nothing, and MANVI's state (its store and
    /// one saved session log per run).
    static var folders: (work: URL, state: URL) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlitzTree/manvi", isDirectory: true)
        return (base.appendingPathComponent("work", isDirectory: true),
                base.appendingPathComponent("state", isDirectory: true))
    }

    /// The whole environment of every MANVI process BlitzTree starts. Every
    /// MANVI_ and stale DEVHARNESS_ variable from outside is dropped, so
    /// nothing ambient can loosen the posture, enable MCP or the fetch tool,
    /// or point MANVI at a project; only the settings below are set. No
    /// Anthropic credential is ever in it (see `anthropicCredentials`).
    static func environment(base: [String: String], path: String, shell: [String: String],
                            route: Route) -> [String: String] {
        var env = base.filter {
            !$0.key.hasPrefix("MANVI_") && !$0.key.hasPrefix("DEVHARNESS_") && !anthropicCredentials.contains($0.key)
        }
        for name in shellVariables where !name.hasPrefix("MANVI_") {
            if let value = shell[name] { env[name] = value }
        }
        env["PATH"] = path
        env["NO_COLOR"] = "1"
        env["MANVI_HARNESS_INIT_ENABLED"] = "false"
        env["MANVI_HARNESS_POSTURE"] = "strict"
        env["MANVI_MCP_ENABLED"] = "false"
        env["MANVI_STATE_DIR"] = folders.state.path
        env["MANVI_LLM_PROVIDER_DEFAULT"] = route.provider
        if let model = route.model { env["MANVI_MODEL"] = model }
        if route.isLocal, let url = shell["MANVI_LLM_LOCAL_BASE_URL"] { env["MANVI_LLM_LOCAL_BASE_URL"] = url }
        return env
    }

    /// The routes the saved choice can run now, in the order to try them: a
    /// cloud provider needs its credential (for Anthropic, the launcher and
    /// a key for its account, asked once); a local server must serve the
    /// model a run would use (`manvi local --resolve` exits 0 only then).
    static func readyRoutes(path: String, envPath: String, shell: [String: String], launcher: String?,
                            defaults: UserDefaults = .standard) -> [Route] {
        var asked: Bool?
        let anthropicReady = {
            if asked == nil { asked = Account.status(launcher: launcher, envPath: envPath, defaults: defaults).isReady }
            return asked ?? false
        }
        return Choice.load(shell: shell, defaults: defaults, anthropicReady: anthropicReady).routes.filter { route in
            guard route.isLocal else { return hasKey(route.provider, shell: shell, anthropicReady: anthropicReady) }
            let env = environment(base: ProcessInfo.processInfo.environment, path: envPath, shell: shell, route: route)
            return AgentLocator.run(path, ["local", "--resolve"], environment: env, directory: prepared().work).status == 0
        }
    }

    /// Creates both folders; returns them.
    @discardableResult
    static func prepared() -> (work: URL, state: URL) {
        let folders = folders
        for folder in [folders.work, folders.state] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folders
    }

    /// MANVI saves a session log per run; keep the newest `keep`.
    static func pruneSessions(keep: Int = 10) {
        let fm = FileManager.default
        let sessions = folders.state.appendingPathComponent("sessions", isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: keys) else { return }
        let dated = entries.map { url in
            (url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) {
            try? fm.removeItem(at: url)
        }
    }

    /// Models the local servers offer, through `manvi serve`'s `local.scan`
    /// (the only JSON listing MANVI has). Empty when none answer.
    static func localModels(path: String, envPath: String, shell: [String: String]) async -> [String] {
        let env = environment(base: ProcessInfo.processInfo.environment, path: envPath, shell: shell,
                              route: Route(provider: "local", model: nil))
        let request = #"{"id":"1","op":"hello","params":{"protocol":1}}"# + "\n"
            + #"{"id":"2","op":"local.scan","params":{}}"# + "\n"
        let spec = Subprocess.Spec(path, ["serve"], environment: env, directory: prepared().work.path,
                                   input: .data(Data(request.utf8)))
        let outcome = await Subprocess.run(spec, timeout: 10)
        return outcome.finished ? parseLocalScan(outcome.output) : []
    }

    /// The model ids in a `local.scan` reply, in server order, without repeats.
    static func parseLocalScan(_ out: String) -> [String] {
        var models: [String] = []
        for line in out.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["id"] as? String == "2", obj["ok"] as? Bool == true,
                  let servers = (obj["result"] as? [String: Any])?["servers"] as? [[String: Any]] else { continue }
            for server in servers {
                for model in server["models"] as? [[String: Any]] ?? [] {
                    if let id = model["id"] as? String, !models.contains(id) { models.append(id) }
                }
            }
        }
        return models
    }

    /// The run itself. The prompt goes on stdin (MANVI reads up to 1 MiB);
    /// a dozen steps is ample for a plan that needs no tools. A local run
    /// with the cloud still to try gets 6 minutes rather than 10: a large
    /// local reasoning model on a busy Mac can take longer than that, and
    /// the user is watching.
    static func runArguments(fallbackAfter: Bool) -> [String] {
        ["run", "--json", "--max-steps", "12", "--timeout", fallbackAfter ? "6m" : "10m"]
    }

    /// MANVI has no structured-output option, so the shape goes in the
    /// prompt, and its tools are pointless here: its working folder is empty.
    static let promptSuffix = """


    ## How to answer

    Everything you need is above: do not call any tools. Reply with only the JSON object, no \
    prose and no code fence, matching this JSON Schema: \(planSchema)
    """

    /// What a non-zero `manvi run` exit means, when stderr says nothing better.
    static func exitMessage(_ status: Int32) -> String? {
        switch status {
        case 2: return String(localized: "MANVI ran out of steps before writing a plan.")
        case 3: return String(localized: "MANVI's answer was cut off by its output limit.")
        case 4: return String(localized: "MANVI stopped without an answer.")
        case 5: return String(localized: "MANVI's answer didn't finish.")
        default: return nil
        }
    }
}
