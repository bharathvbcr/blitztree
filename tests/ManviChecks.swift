import Foundation

/// MANVI as a planner, offline: its `run --json` event stream becomes the
/// same activity, card and plan events as the CLI agents', nothing counts
/// until MANVI confirms the strict posture, and the environment BlitzTree
/// gives it pins that posture whatever the surroundings say.
@main
struct ManviChecks {
    /// Events as `manvi run --json` writes them (shapes from a recorded run).
    static func line(_ event: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: event.merging(["at": "2026-10-10T09:00:00Z"]) { a, _ in a })
        data.append(UInt8(ascii: "\n"))
        return data
    }

    nonisolated final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AgentStreamReader.Event] = []
        private var stops = 0
        func add(_ event: AgentStreamReader.Event) { lock.lock(); stored.append(event); lock.unlock() }
        func stop() { lock.lock(); stops += 1; lock.unlock() }
        var events: [AgentStreamReader.Event] { lock.lock(); defer { lock.unlock() }; return stored }
        var stopped: Int { lock.lock(); defer { lock.unlock() }; return stops }
    }

    static func reader(_ sink: Sink) -> AgentStreamReader {
        AgentStreamReader(kind: .manvi, prompt: "", folder: "/", write: { _ in }, done: { sink.stop() },
                          emit: { sink.add($0) })
    }

    static let item = #"{"title":"Rust build output","detail":"Rebuilt by cargo","group":"safe","bytes":1000,"paths":["/a/target"],"action":"trash","command":""}"#

    @MainActor
    static func main() async {
        // A whole run: noise before the posture, a refused write, a fenced answer in pieces.
        let sink = Sink()
        let r = reader(sink)
        r.feed(line(["kind": "assistant.text", "text": "{\"items\":[" + item + "]}"]))
        precondition(sink.events.isEmpty, "nothing counts before session.start")
        let answer = "```json\n{\"summary\":\"About 1 KB can go.\",\"items\":[" + item + ",\n" + item + "]}\n```"
        var stream = Data()
        stream += line(["kind": "session.start", "posture": "strict", "model": "local/qwen3.8:27b-mlx"])
        stream += line(["kind": "turn.start", "text": "prompt"])
        stream += line(["kind": "assistant.reasoning", "text": "Let me look"])
        stream += line(["kind": "tool.start", "tool": "devcouncil_read_file", "arguments": ["path": "notes/plan.md"]])
        stream += line(["kind": "tool.start", "tool": "devcouncil_write_file", "arguments": ["path": "x", "content": "y"]])
        stream += line(["kind": "policy.decision", "tool": "devcouncil_write_file", "rule": "task.absent", "severity": "soft",
                        "text": #"{"action":"deny","allowed":false}"#])
        stream += line(["kind": "tool.result", "text": "denied", "is_error": true])
        for piece in stride(from: 0, to: answer.count, by: 7) {
            let start = answer.index(answer.startIndex, offsetBy: piece)
            let end = answer.index(start, offsetBy: min(7, answer.count - piece))
            stream += line(["kind": "assistant.text", "text": String(answer[start..<end])])
        }
        stream += line(["kind": "turn.end"])
        stream += line(["kind": "turn.usage", "input_tokens": 10, "output_tokens": 5])
        // Split the bytes at an awkward place: the reader buffers partial lines.
        let cut = stream.count / 3
        r.feed(stream.prefix(cut))
        r.feed(stream.dropFirst(cut))
        let events = sink.events
        let steps = events.compactMap { if case .activity(let text) = $0 { return text }; return nil }
        precondition(steps.contains("Thinking"), "reasoning shows as Thinking: \(steps)")
        precondition(steps.contains("Reading plan.md"), "a read tool in plain words: \(steps)")
        precondition(steps.contains("Kept read-only: write_file was refused"), "a refused write shows: \(steps)")
        precondition(steps.last == "Writing the plan", "the answer shows as the plan being written: \(steps)")
        let cards = events.filter { if case .item = $0 { return true }; return false }
        precondition(cards.count == 2, "both cards stream before the end: \(cards.count)")
        guard case .plan(let summary, let items)? = events.last else { preconditionFailure("ends with the plan: \(events)") }
        precondition(summary == "About 1 KB can go." && items.count == 2 && items[0].paths == ["/a/target"],
                     "the fenced final answer decodes")
        precondition(sink.stopped == 0, "a normal run is not stopped")

        // A tool call after the plan started: what came before was not the answer.
        let restart = Sink()
        let r2 = reader(restart)
        r2.feed(line(["kind": "session.start", "posture": "strict"]))
        r2.feed(line(["kind": "assistant.text", "text": "{\"summary\":\"x\",\"items\":[" + item]))
        r2.feed(line(["kind": "tool.start", "tool": "devcouncil_list_dir", "arguments": #"{"path":"/tmp/cache"}"#]))
        r2.feed(line(["kind": "turn.end"]))
        let afterRestart = restart.events
        precondition(afterRestart.contains { if case .restart = $0 { return true }; return false }, "restart emitted")
        precondition(afterRestart.contains { if case .activity("Looking in cache") = $0 { return true }; return false },
                     "string arguments decode too: \(afterRestart)")
        precondition(!afterRestart.contains { if case .plan = $0 { return true }; return false },
                     "text before the tool call is never decoded as the plan")

        // Any posture but strict: stopped, and nothing after it counts.
        let loose = Sink()
        let r3 = reader(loose)
        r3.feed(line(["kind": "session.start", "posture": "dev"]))
        r3.feed(line(["kind": "assistant.text", "text": "{\"summary\":\"x\",\"items\":[" + item + "]}"]))
        r3.feed(line(["kind": "turn.end"]))
        guard case .failed(let why)? = loose.events.first, loose.events.count == 1 else {
            preconditionFailure("a non-strict session fails alone: \(loose.events)")
        }
        precondition(why.contains("read-only") && loose.stopped == 1, "and the process is stopped")
        let missing = Sink()
        let r4 = reader(missing)
        r4.feed(line(["kind": "session.start"]))
        precondition(missing.stopped == 1, "a session.start without a posture is not strict")

        environment()
        localScan()
        shellProbe()
        await fallback()

        let tail = ErrTail()
        tail.feed(Data("manvi: the turn failed: no credential for anthropic: set one of ANTHROPIC_API_KEY\nmanvi: session c1bedc2562c27593 saved (12 event(s)) — continue it with: manvi run --resume c1bedc2562c27593\n".utf8))
        precondition(tail.last.hasPrefix("manvi: the turn failed"), "the session note never hides the failure: \(tail.last)")
        precondition(Manvi.exitMessage(2) != nil && Manvi.exitMessage(5) != nil && Manvi.exitMessage(1) == nil,
                     "exit 1 keeps MANVI's own stderr")
        precondition(Manvi.promptSuffix.contains(planSchema), "the schema travels in the prompt")
        print("PASS: ManviChecks (event stream, posture gate, pinned environment, local models)")
    }

    static func environment() {
        let suite = "blitztree.manvi-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let none: (String) -> Bool = { _ in false }
        let noKey: (String) -> String? = { _ in nil }
        let base = ["HOME": "/Users/u", "MANVI_HARNESS_POSTURE": "dev", "MANVI_FETCH_HOSTS": "example.com",
                    "MANVI_MCP_ENABLED": "true", "MANVI_PROJECT_ROOT": "/Users/u/repo", "DEVHARNESS_X": "1",
                    "ANTHROPIC_API_KEY": "ambient-key"]
        let shell = ["MANVI_MODEL": "shell-model", "MANVI_LLM_PROVIDER_DEFAULT": "anthropic",
                     "ANTHROPIC_API_KEY": "shell-key", "MANVI_LLM_LOCAL_BASE_URL": "http://127.0.0.1:1234/v1"]

        // With nothing in Settings, the shell's exports decide: it names the
        // cloud side, so MANVI_MODEL is the cloud model; automatic by default.
        var choice = Manvi.Choice.load(shell: shell, defaults: defaults, keychainHas: none)
        precondition(choice == Manvi.Choice(mode: "auto", localModel: nil, cloud: "anthropic", cloudModel: "shell-model"),
                     "shell defaults: \(choice)")
        precondition(choice.routes == [Manvi.Route(provider: "local", model: nil),
                                       Manvi.Route(provider: "anthropic", model: "shell-model")], "local first, then cloud")
        precondition(Manvi.Choice.load(shell: ["XAI_API_KEY": "k"], defaults: defaults, keychainHas: none).cloud == "xai",
                     "the first cloud provider with a key")

        let cloud = Manvi.Route(provider: "anthropic", model: "shell-model")
        var env = Manvi.environment(base: base, path: "/bin", shell: shell, route: cloud, defaults: defaults, keychain: noKey)
        precondition(env["MANVI_HARNESS_POSTURE"] == "strict", "posture pinned over the ambient dev")
        precondition(env["MANVI_HARNESS_INIT_ENABLED"] == "false" && env["MANVI_MCP_ENABLED"] == "false")
        precondition(env["MANVI_FETCH_HOSTS"] == nil && env["MANVI_PROJECT_ROOT"] == nil && env["DEVHARNESS_X"] == nil,
                     "nothing ambient widens MANVI")
        precondition(env["MANVI_STATE_DIR"] == Manvi.folders.state.path && env["PATH"] == "/bin" && env["HOME"] == "/Users/u")
        precondition(env["MANVI_LLM_PROVIDER_DEFAULT"] == "anthropic" && env["MANVI_MODEL"] == "shell-model")
        precondition(env["ANTHROPIC_API_KEY"] == "shell-key", "the login shell's key wins over the app's environment")
        precondition(env["MANVI_LLM_LOCAL_BASE_URL"] == nil, "a local URL only for the local provider")
        env = Manvi.environment(base: base, path: "/bin", shell: shell, route: Manvi.Route(provider: "local", model: nil), defaults: defaults, keychain: noKey)
        precondition(env["MANVI_LLM_PROVIDER_DEFAULT"] == "local" && env["MANVI_MODEL"] == nil,
                     "no model: MANVI picks the only one the server has")
        precondition(env["MANVI_LLM_LOCAL_BASE_URL"] == "http://127.0.0.1:1234/v1")

        // Settings win, trimmed, and each mode tries only its side.
        Manvi.Choice(mode: "cloud", localModel: "  gemma4:e4b \n", cloud: "gemini", cloudModel: "g-model").save(defaults: defaults)
        choice = Manvi.Choice.load(shell: shell, defaults: defaults, keychainHas: none)
        precondition(choice.localModel == "gemma4:e4b" && choice.cloud == "gemini" && choice.cloudModel == "g-model")
        precondition(choice.routes == [Manvi.Route(provider: "gemini", model: "g-model")], "cloud only")
        choice.mode = "local"
        precondition(choice.routes == [Manvi.Route(provider: "local", model: "gemma4:e4b")], "local only")
        defaults.set("openai", forKey: Manvi.Choice.cloudKey)
        defaults.set("both", forKey: Manvi.Choice.modeKey)
        choice = Manvi.Choice.load(shell: [:], defaults: defaults, keychainHas: none)
        precondition(choice.cloud == "anthropic" && choice.mode == "auto", "unknown values fall back")
        precondition(Manvi.Route(provider: "anthropic", model: "m").label == "Claude API · m")

        // A key kept in the Keychain, as `security add-generic-password -s
        // anthropic-api-key` stores it: read for a cloud route only, under
        // the name MANVI reads, with the workspace an unscoped key needs.
        var asked: [String] = []
        let keychain: (String) -> String? = { item in asked.append(item); return item == "anthropic-api-key" ? "kc-key" : nil }
        defaults.set("wrkspc_test", forKey: Manvi.workspaceKey)
        let claude = Manvi.Route(provider: "anthropic", model: "claude-sonnet-5-5")
        env = Manvi.environment(base: [:], path: "/bin", shell: [:], route: claude, defaults: defaults, keychain: keychain)
        precondition(env["ANTHROPIC_API_KEY"] == "kc-key" && env["ANTHROPIC_WORKSPACE_ID"] == "wrkspc_test"
                     && env["MANVI_MODEL"] == "claude-sonnet-5-5", "Keychain key, workspace and model")
        precondition(asked == ["anthropic-api-key"])
        asked = []
        env = Manvi.environment(base: [:], path: "/bin", shell: ["ANTHROPIC_API_KEY": "shell-key"], route: claude,
                                defaults: defaults, keychain: keychain)
        precondition(env["ANTHROPIC_API_KEY"] == "shell-key" && asked.isEmpty, "a shell export needs no Keychain read")
        env = Manvi.environment(base: [:], path: "/bin", shell: [:], route: Manvi.Route(provider: "local", model: "m"),
                                defaults: defaults, keychain: keychain)
        precondition(env["ANTHROPIC_API_KEY"] == nil && env["ANTHROPIC_WORKSPACE_ID"] == nil && asked.isEmpty,
                     "a local run never reads a cloud key")
        defaults.set("my-claude-key", forKey: "bz.manviKeychain.anthropic")
        precondition(Manvi.keychainItem("anthropic", defaults: defaults) == "my-claude-key", "the item name is the user's")
        precondition(Manvi.hasKey("anthropic", shell: [:], defaults: defaults, keychainHas: { $0 == "my-claude-key" }))
        precondition(Manvi.workspace(shell: ["ANTHROPIC_WORKSPACE_ID": "wrkspc_shell"], defaults: UserDefaults(suiteName: "\(suite).empty")!)
                     == "wrkspc_shell", "the shell's workspace when Settings has none")

        // Anthropic's model list, in the shape `GET /v1/models` returns.
        let page = #"{"data":[{"type":"model","id":"claude-sonnet-5-5","display_name":"Claude Sonnet 5.5","created_at":"2026-01-01T00:00:00Z"},{"type":"model","id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5"}],"has_more":true,"first_id":"claude-sonnet-5-5","last_id":"claude-haiku-5-5"}"#
        let parsed = try! Manvi.parseClaudeModels(Data(page.utf8), status: 200)
        precondition(parsed.models == [Manvi.CloudModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
                                       Manvi.CloudModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5")] && parsed.more)
        let refused = #"{"type":"error","error":{"type":"invalid_request_error","message":"This API key is not scoped to a workspace"}}"#
        do {
            _ = try Manvi.parseClaudeModels(Data(refused.utf8), status: 400)
            preconditionFailure("a refusal is an error")
        } catch {
            precondition(error.localizedDescription == "HTTP 400: This API key is not scoped to a workspace", "\(error)")
        }
    }

    /// The probe runs in the user's own shell; each one must print the set
    /// variable and an empty value for the unset ones, never a parse error.
    static func shellProbe() {
        let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first { FileManager.default.isExecutableFile(atPath: $0) }
        for shell in ["/bin/zsh", "/bin/bash"] + [fish].compactMap({ $0 }) {
            var env = ProcessInfo.processInfo.environment.filter { !Manvi.shellVariables.contains($0.key) }
            env["XAI_API_KEY"] = "probe value"
            let out = AgentLocator.run(shell, ["-c", "echo BZPATH=x; " + Manvi.shellProbe], environment: env).out
            let lines = out.split(separator: "\n").map(String.init)
            precondition(lines.contains("BZENV_XAI_API_KEY=probe value"), "\(shell): the set variable: \(out)")
            precondition(lines.contains("BZENV_ANTHROPIC_API_KEY="), "\(shell): an unset one prints empty: \(out)")
            precondition(lines.filter { $0.hasPrefix("BZENV_") }.count == Manvi.shellVariables.count, "\(shell): \(out)")
        }
        if fish == nil { print("SKIP fish shell probe (fish not installed)") }
    }

    private static func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

    /// The local-to-cloud switch, end to end through AgentRun, against a
    /// stand-in `manvi` that logs each launch and answers per provider.
    @MainActor
    static func fallback() async {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("blitztree-manvi-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let fake = base.appendingPathComponent("fake"), project = base.appendingPathComponent("scan/proj")
        try! fm.createDirectory(at: fake, withIntermediateDirectories: true)
        try! fm.createDirectory(at: project.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try! Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        try! Data(repeating: 1, count: 2_000_000).write(to: project.appendingPathComponent("node_modules/blob"))
        let script = fake.appendingPathComponent("manvi")
        try! Data("""
        #!/bin/sh
        cat >/dev/null
        d="$BZ_FAKE_DIR/$MANVI_LLM_PROVIDER_DEFAULT"
        echo "$MANVI_LLM_PROVIDER_DEFAULT $MANVI_HARNESS_POSTURE $MANVI_MODEL" >> "$BZ_FAKE_DIR/log"
        sleep "$(cat "$d.sleep" 2>/dev/null || echo 0)"
        cat "$d.ndjson"
        cat "$d.stderr" >&2 2>/dev/null
        exit "$(cat "$d.exit")"

        """.utf8).write(to: script)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        func answer(_ provider: String, _ lines: [[String: Any]], exit: Int, stderr: String = "", sleep: Int = 0) {
            let body = lines.map { String(decoding: line($0), as: UTF8.self) }.joined()
            try! Data(body.utf8).write(to: fake.appendingPathComponent("\(provider).ndjson"))
            try! Data("\(exit)".utf8).write(to: fake.appendingPathComponent("\(provider).exit"))
            try! Data(stderr.utf8).write(to: fake.appendingPathComponent("\(provider).stderr"))
            try! Data("\(sleep)".utf8).write(to: fake.appendingPathComponent("\(provider).sleep"))
        }
        let blobs = project.appendingPathComponent("node_modules").path
        let plan = "{\"summary\":\"Some can go.\",\"items\":[{\"title\":\"npm packages\",\"detail\":\"Reinstallable\","
            + "\"group\":\"safe\",\"bytes\":1,\"paths\":[\"\(blobs)\"],\"action\":\"trash\",\"command\":\"\"}]}"
        answer("local", [["kind": "session.start", "posture": "strict"]], exit: 1,
               stderr: "manvi: the turn failed: dial tcp 127.0.0.1:11434: connection refused\n")
        answer("anthropic", [["kind": "session.start", "posture": "strict"],
                             ["kind": "assistant.text", "text": plan], ["kind": "turn.end"]], exit: 0)
        setenv("BZ_FAKE_DIR", fake.path, 1)
        func log() -> [String] {
            (try? String(contentsOf: fake.appendingPathComponent("log"), encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
        }

        guard let handle = bz_scan_start(base.appendingPathComponent("scan").path) else { fatalError("scan") }
        var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0, done: Int32 = 0
        while done == 0 {
            bz_progress(handle, &files, &dirs, &bytes, &done)
            if done == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        }
        guard let tree = Tree(handle: handle) else { fatalError("tree") }
        let agent = InstalledAgent(kind: .manvi, path: script.path, signedIn: true)
        // A shell key, so no route here ever reads the real Keychain.
        let env = AgentEnvironment(agents: [agent], path: "/usr/bin:/bin", loaded: true,
                                   shell: ["ANTHROPIC_API_KEY": "test-key"])
        let local = Manvi.Route(provider: "local", model: "gemma4:e4b")
        let claude = Manvi.Route(provider: "anthropic", model: "claude-sonnet-5-5")
        func run(_ routes: [Manvi.Route], until stop: @MainActor (AgentRun) -> Bool) async -> AgentRun {
            try? fm.removeItem(at: fake.appendingPathComponent("log"))
            let run = AgentRun(agent: agent, env: env, tree: tree, scanRoot: tree.path(0), known: [], routes: routes) {}
            let start = Date()
            while !stop(run), Date().timeIntervalSince(start) < 60 {
                pump()
                try? await Task.sleep(for: .milliseconds(1))
            }
            return run
        }

        // Automatic: local fails before any card, the cloud answers.
        var r = await run([local, claude]) { $0.phase != .thinking }
        precondition(r.phase == .planned && r.items.count == 1 && r.summary == "Some can go.", "\(r.phase) \(r.steps)")
        precondition(log() == ["local strict gemma4:e4b", "anthropic strict claude-sonnet-5-5"], "\(log())")
        precondition(r.steps.contains("Using Local · gemma4:e4b")
                     && r.steps.contains("Local · gemma4:e4b gave no plan; switching to Claude API · claude-sonnet-5-5")
                     && r.steps.contains("Using Claude API · claude-sonnet-5-5"), "the switch is shown: \(r.steps)")

        // Local only (forced from the menu): no switch, MANVI's own reason.
        r = await run([local]) { $0.phase != .thinking }
        guard case .failed(let why) = r.phase else { preconditionFailure("local only fails: \(r.phase)") }
        precondition(why.contains("connection refused") && log() == ["local strict gemma4:e4b"], "\(why) \(log())")

        // Cancelled while local runs: the cloud is never started.
        answer("local", [["kind": "session.start", "posture": "strict"]], exit: 1, sleep: 2)
        r = await run([local, claude]) { _ in log() == ["local strict gemma4:e4b"] }
        r.cancel()
        let until = Date().addingTimeInterval(3)
        while Date() < until { pump(); try? await Task.sleep(for: .milliseconds(5)) }
        precondition(log() == ["local strict gemma4:e4b"] && !r.steps.contains { $0.contains("switching") },
                     "a cancelled run never switches: \(log())")
    }

    static func localScan() {
        // Recorded from `manvi serve` with Ollama running.
        let reply = """
        {"id":"1","ok":true,"result":{"protocol":1,"ops":["hello","local.scan"],"posture":"host"}}
        {"id":"2","ok":true,"result":{"servers":[{"base_url":"http://127.0.0.1:11434/v1","runtime":"ollama","version":"0.35.1","models":[{"id":"gemma4:31b-mlx","capabilities_known":false},{"id":"qwen3.8:27b-mlx","capabilities_known":false}]},{"base_url":"http://127.0.0.1:1234/v1","runtime":"lmstudio","models":[{"id":"qwen3.8:27b-mlx"},{"id":"phi"}]}],"scanned":5,"capabilities":false}}
        """
        precondition(Manvi.parseLocalScan(reply) == ["gemma4:31b-mlx", "qwen3.8:27b-mlx", "phi"], "ids in order, once each")
        precondition(Manvi.parseLocalScan(#"{"id":"2","ok":false,"error":{"code":"E_INTERNAL"}}"#).isEmpty)
        precondition(Manvi.parseLocalScan("not json").isEmpty)
    }
}
