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

    /// Each hosted provider's credential variables, in MANVI's order.
    static let credentials: [String: [String]] = [
        "anthropic": ["ANTHROPIC_API_KEY"],
        "gemini": ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
        "xai": ["XAI_API_KEY", "GROK_API_KEY"],
    ]

    /// Read from the user's login shell along with its PATH: MANVI takes
    /// credentials and model choices only from its environment, and an app
    /// started from the Dock has none of the shell's exports.
    static let shellVariables = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "GEMINI_API_KEY", "GOOGLE_API_KEY",
        "XAI_API_KEY", "GROK_API_KEY", "LOCAL_API_KEY", "OPENAI_API_KEY",
        "ANTHROPIC_WORKSPACE_ID", "MANVI_LLM_PROVIDER_DEFAULT", "MANVI_MODEL", "MANVI_LLM_LOCAL_BASE_URL",
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
        /// else automatic, and the first cloud provider with a key.
        static func load(shell: [String: String], defaults: UserDefaults = .standard,
                         keychainHas: (String) -> Bool = Keychain.has) -> Choice {
            func setting(_ key: String) -> String? {
                defaults.string(forKey: key).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
            }
            let shellProvider = shell["MANVI_LLM_PROVIDER_DEFAULT"] ?? "local"
            let shellModel = shell["MANVI_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            let shellCloud = cloudProviders.contains(shellProvider) ? shellProvider : nil
            // Only looked up when nothing else names the cloud provider.
            let cloud = setting(cloudKey).flatMap { cloudProviders.contains($0) ? $0 : nil } ?? shellCloud
                ?? cloudProviders.first { hasKey($0, shell: shell, defaults: defaults, keychainHas: keychainHas) }
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

    /// A cloud provider BlitzTree has a key for: exported by the shell, or a
    /// Keychain item (checked without reading the secret).
    static func hasKey(_ provider: String, shell: [String: String], defaults: UserDefaults = .standard,
                       keychainHas: (String) -> Bool = Keychain.has) -> Bool {
        shellKey(provider, shell: shell) != nil || keychainHas(keychainItem(provider, defaults: defaults))
    }

    static func shellKey(_ provider: String, shell: [String: String]) -> String? {
        (credentials[provider] ?? []).lazy.compactMap { shell[$0] }.first { !$0.isEmpty }
    }

    /// Where a cloud key may live besides the shell: a generic-password item
    /// for this user, `<provider>-api-key` unless Settings names another
    /// (the convention `security add-generic-password -s anthropic-api-key`).
    static func keychainItem(_ provider: String, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: "bz.manviKeychain.\(provider)")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(provider)-api-key"
    }

    /// Anthropic keys not scoped to a workspace need its id on every
    /// request; MANVI sends ANTHROPIC_WORKSPACE_ID as that header.
    static let workspaceKey = "bz.manviAnthropicWorkspace"
    static func workspace(shell: [String: String], defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: workspaceKey).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? shell["ANTHROPIC_WORKSPACE_ID"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The key for a cloud route: the shell's export, else the Keychain
    /// item. Read only when a run starts or models are listed.
    static func key(_ provider: String, shell: [String: String], defaults: UserDefaults = .standard,
                    keychain: (String) -> String? = Keychain.read) -> String? {
        shellKey(provider, shell: shell) ?? keychain(keychainItem(provider, defaults: defaults))
    }

    /// The login keychain through `/usr/bin/security`, as a shell wrapper
    /// around `manvi` would read it: an item `security add-generic-password`
    /// made trusts that tool, so no prompt appears.
    enum Keychain {
        static func has(_ item: String) -> Bool {
            AgentLocator.run("/usr/bin/security", ["find-generic-password", "-a", NSUserName(), "-s", item]).status == 0
        }

        static func read(_ item: String) -> String? {
            let r = AgentLocator.run("/usr/bin/security", ["find-generic-password", "-a", NSUserName(), "-s", item, "-w"])
            let value = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.status == 0 && !value.isEmpty ? value : nil
        }
    }

    /// A model a cloud provider offers: its id and the name to show.
    struct CloudModel: Sendable, Hashable, Identifiable {
        let id: String
        let name: String
    }

    /// Claude models this key may use, newest first, from Anthropic's
    /// `GET /v1/models` (paged by `after_id`). Throws with Anthropic's own
    /// message when the request is refused.
    static func claudeModels(key: String, workspace: String?, baseURL: String?) async throws -> [CloudModel] {
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
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let workspace { request.setValue(workspace, forHTTPHeaderField: "anthropic-workspace-id") }
            let (data, response) = try await URLSession.shared.data(for: request)
            let page = try parseClaudeModels(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            models += page.models
            guard page.more, let last = page.models.last?.id else { break }
            after = last
        }
        return models
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
    /// or point MANVI at a project; only the settings below are set.
    static func environment(base: [String: String], path: String, shell: [String: String],
                            route: Route, defaults: UserDefaults = .standard,
                            keychain: (String) -> String? = Keychain.read) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("MANVI_") && !$0.key.hasPrefix("DEVHARNESS_") }
        for name in shellVariables where !name.hasPrefix("MANVI_") {
            if let value = shell[name] { env[name] = value }
        }
        // A cloud route's key under the name MANVI reads, from the Keychain
        // when the shell has none; a local route never touches the Keychain.
        if !route.isLocal, shellKey(route.provider, shell: shell) == nil,
           let name = credentials[route.provider]?.first,
           let key = keychain(keychainItem(route.provider, defaults: defaults)) {
            env[name] = key
        }
        if route.provider == "anthropic", let workspace = workspace(shell: shell, defaults: defaults) {
            env["ANTHROPIC_WORKSPACE_ID"] = workspace
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
    /// cloud provider needs its credential; a local server must serve the
    /// model a run would use (`manvi local --resolve` exits 0 only then).
    static func readyRoutes(path: String, envPath: String, shell: [String: String],
                            defaults: UserDefaults = .standard) -> [Route] {
        Choice.load(shell: shell, defaults: defaults).routes.filter { route in
            guard route.isLocal else { return hasKey(route.provider, shell: shell, defaults: defaults) }
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
