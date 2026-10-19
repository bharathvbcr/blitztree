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
        let notReady: () -> Bool = { false }
        let base = ["HOME": "/Users/u", "MANVI_HARNESS_POSTURE": "dev", "MANVI_FETCH_HOSTS": "example.com",
                    "MANVI_MCP_ENABLED": "true", "MANVI_PROJECT_ROOT": "/Users/u/repo", "DEVHARNESS_X": "1",
                    "ANTHROPIC_API_KEY": "ambient-key", "ANTHROPIC_WORKSPACE_ID": "wrkspc_ambient",
                    "ANTHROPIC_AUTH_TOKEN": "ambient-token", "ANTHROPIC_API_KEY_FALLBACK": "ambient-fallback",
                    "ANTHROPIC_WORKSPACE_ID_FALLBACK": "wrkspc_fallback"]
        // A shell that still exports a key and a workspace, as ~/.zshrc did:
        // BlitzTree no longer reads them, and never passes them on.
        let shell = ["MANVI_MODEL": "shell-model", "MANVI_LLM_PROVIDER_DEFAULT": "anthropic",
                     "ANTHROPIC_API_KEY": "shell-key", "ANTHROPIC_WORKSPACE_ID": "wrkspc_shell",
                     "MANVI_LLM_LOCAL_BASE_URL": "http://127.0.0.1:1234/v1"]
        precondition(!Manvi.shellVariables.contains { Manvi.anthropicCredentials.contains($0) },
                     "the login shell is never asked for an Anthropic credential")

        // With nothing in Settings, the shell's exports decide: it names the
        // cloud side, so MANVI_MODEL is the cloud model; automatic by default.
        var choice = Manvi.Choice.load(shell: shell, defaults: defaults, anthropicReady: notReady)
        precondition(choice == Manvi.Choice(mode: "auto", localModel: nil, cloud: "anthropic", cloudModel: "shell-model"),
                     "shell defaults: \(choice)")
        precondition(choice.routes == [Manvi.Route(provider: "local", model: nil),
                                       Manvi.Route(provider: "anthropic", model: "shell-model")], "local first, then cloud")
        precondition(Manvi.Choice.load(shell: ["XAI_API_KEY": "k"], defaults: defaults, anthropicReady: notReady).cloud == "xai",
                     "the first cloud provider with a key")
        precondition(Manvi.Choice.load(shell: ["XAI_API_KEY": "k"], defaults: defaults, anthropicReady: { true }).cloud == "anthropic",
                     "Anthropic first once anthropic-account has a key for its account")

        let cloud = Manvi.Route(provider: "anthropic", model: "shell-model")
        var env = Manvi.environment(base: base, path: "/bin", shell: shell, route: cloud)
        precondition(env["MANVI_HARNESS_POSTURE"] == "strict", "posture pinned over the ambient dev")
        precondition(env["MANVI_HARNESS_INIT_ENABLED"] == "false" && env["MANVI_MCP_ENABLED"] == "false")
        precondition(env["MANVI_FETCH_HOSTS"] == nil && env["MANVI_PROJECT_ROOT"] == nil && env["DEVHARNESS_X"] == nil,
                     "nothing ambient widens MANVI")
        precondition(env["MANVI_STATE_DIR"] == Manvi.folders.state.path && env["PATH"] == "/bin" && env["HOME"] == "/Users/u")
        precondition(env["MANVI_LLM_PROVIDER_DEFAULT"] == "anthropic" && env["MANVI_MODEL"] == "shell-model")
        for name in Manvi.anthropicCredentials {
            precondition(env[name] == nil, "BlitzTree puts no \(name) in a Claude run's environment: \(env[name] ?? "")")
        }
        precondition(env["MANVI_LLM_LOCAL_BASE_URL"] == nil, "a local URL only for the local provider")
        env = Manvi.environment(base: base, path: "/bin", shell: shell, route: Manvi.Route(provider: "local", model: nil))
        precondition(env["MANVI_LLM_PROVIDER_DEFAULT"] == "local" && env["MANVI_MODEL"] == nil,
                     "no model: MANVI picks the only one the server has")
        precondition(env["MANVI_LLM_LOCAL_BASE_URL"] == "http://127.0.0.1:1234/v1")
        precondition(Manvi.anthropicCredentials.allSatisfy { env[$0] == nil }, "a local run gets no Anthropic credential")

        // Gemini and xAI run on a key the shell exports, and only then.
        let gemini = Manvi.Route(provider: "gemini", model: nil)
        precondition(!Manvi.hasKey("gemini", shell: [:], anthropicReady: { true }), "no shell key, no Gemini")
        env = Manvi.environment(base: [:], path: "/bin", shell: [:], route: gemini)
        precondition(env["GEMINI_API_KEY"] == nil && env["GOOGLE_API_KEY"] == nil, "no key appears from anywhere else")
        precondition(Manvi.hasKey("gemini", shell: ["GEMINI_API_KEY": "g"], anthropicReady: notReady))
        env = Manvi.environment(base: [:], path: "/bin", shell: ["GEMINI_API_KEY": "g"], route: gemini)
        precondition(env["GEMINI_API_KEY"] == "g", "the shell's Gemini key is passed on")
        precondition(!Manvi.hasKey("anthropic", shell: ["ANTHROPIC_API_KEY": "shell-key"], anthropicReady: notReady),
                     "a shell-exported Anthropic key does not make the Claude route ready")

        // Settings win, trimmed, and each mode tries only its side.
        Manvi.Choice(mode: "cloud", localModel: "  gemma4:e4b \n", cloud: "gemini", cloudModel: "g-model").save(defaults: defaults)
        choice = Manvi.Choice.load(shell: shell, defaults: defaults, anthropicReady: notReady)
        precondition(choice.localModel == "gemma4:e4b" && choice.cloud == "gemini" && choice.cloudModel == "g-model")
        precondition(choice.routes == [Manvi.Route(provider: "gemini", model: "g-model")], "cloud only")
        choice.mode = "local"
        precondition(choice.routes == [Manvi.Route(provider: "local", model: "gemma4:e4b")], "local only")
        defaults.set("openai", forKey: Manvi.Choice.cloudKey)
        defaults.set("both", forKey: Manvi.Choice.modeKey)
        choice = Manvi.Choice.load(shell: [:], defaults: defaults, anthropicReady: notReady)
        precondition(choice.cloud == "anthropic" && choice.mode == "auto", "unknown values fall back")
        precondition(Manvi.Route(provider: "anthropic", model: "m").label == "Claude API · m")

        // What an older BlitzTree stored to read keys itself goes on the
        // next load: the workspace in it belonged to another organisation.
        defaults.set("wrkspc_01WrongOrg", forKey: "bz.manviAnthropicWorkspace")
        defaults.set("my-claude-key", forKey: "bz.manviKeychain.anthropic")
        defaults.set("my-xai-key", forKey: "bz.manviKeychain.xai")
        _ = Manvi.Choice.load(shell: [:], defaults: defaults, anthropicReady: notReady)
        for key in ["bz.manviAnthropicWorkspace", "bz.manviKeychain.anthropic", "bz.manviKeychain.xai"] {
            precondition(defaults.object(forKey: key) == nil, "\(key) is removed on upgrade")
        }

        // The Claude API route starts anthropic-account, which execs the
        // absolute manvi path with the run's own arguments after `--`.
        let claude = Manvi.Route(provider: "anthropic", model: "claude-sonnet-5-5")
        let runArgs = Manvi.runArguments(fallbackAfter: false)
        var launch = Manvi.launch(route: claude, manvi: "/opt/m/manvi", launcher: "/l/anthropic-account",
                                  repo: "/Users/u/scan", arguments: runArgs, defaults: defaults)
        precondition(launch?.executable == "/l/anthropic-account"
                     && launch?.arguments == ["exec", "--repo", "/Users/u/scan", "--", "/opt/m/manvi"] + runArgs,
                     "no Settings account: the launcher picks: \(String(describing: launch))")
        Manvi.Account.save("  personal ", defaults: defaults)
        launch = Manvi.launch(route: claude, manvi: "/opt/m/manvi", launcher: "/l/anthropic-account",
                              repo: "/Users/u/scan", arguments: runArgs, defaults: defaults)
        precondition(launch?.arguments == ["exec", "--repo", "/Users/u/scan", "--account", "personal", "--", "/opt/m/manvi"] + runArgs,
                     "Settings' account, trimmed: \(String(describing: launch))")
        precondition(Manvi.launch(route: claude, manvi: "/opt/m/manvi", launcher: nil, repo: "/r", arguments: runArgs,
                                  defaults: defaults) == nil, "no launcher, no Claude run")
        for route in [Manvi.Route(provider: "local", model: "m"), gemini] {
            let direct = Manvi.launch(route: route, manvi: "/opt/m/manvi", launcher: "/l/anthropic-account", repo: "/r",
                                      arguments: runArgs, defaults: defaults)
            precondition(direct?.executable == "/opt/m/manvi" && direct?.arguments == runArgs, "\(route.provider) runs MANVI directly")
        }
        Manvi.Account.save(nil, defaults: defaults)
        precondition(Manvi.Account.setting(defaults) == nil, "an empty choice leaves it to the launcher")

        // The models request names the key as a curl variable, never as a value.
        let url = URL(string: "https://api.anthropic.com/v1/models?limit=100")!
        var request = Manvi.modelRequest(url: url, workspace: false, defaults: defaults)
        precondition(Array(request.prefix(4)) == ["exec", "--no-fallback", "--", "/usr/bin/curl"], "\(request)")
        precondition(request.contains("x-api-key: {{ANTHROPIC_API_KEY}}") && !request.contains { $0.contains("anthropic-workspace-id") }
                     && request.last == url.absoluteString, "\(request)")
        Manvi.Account.save("work", defaults: defaults)
        request = Manvi.modelRequest(url: url, workspace: true, defaults: defaults)
        precondition(Array(request.prefix(5)) == ["exec", "--no-fallback", "--account", "work", "--"]
                     && request.contains("anthropic-workspace-id: {{ANTHROPIC_WORKSPACE_ID}}"), "\(request)")
        let split = Manvi.splitStatus(Data("{\"data\":[]}\n404".utf8))
        precondition(split.status == 404 && split.body == Data("{\"data\":[]}".utf8), "the status line is curl's last line")
        precondition(Manvi.splitStatus(Data()).status == 0)

        account(defaults: defaults)

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

    nonisolated final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[String]] = []
        func add(_ args: [String]) { lock.lock(); stored.append(args); lock.unlock() }
        var all: [[String]] { lock.lock(); defer { lock.unlock() }; return stored }
        func reset() { lock.lock(); stored = []; lock.unlock() }
    }

    /// What readiness and Settings ask anthropic-account: `which`, `doctor`
    /// and `list`, none of which reads a secret.
    static func account(defaults: UserDefaults) {
        Manvi.Account.save(nil, defaults: defaults)
        precondition(Manvi.Account.status(launcher: nil, envPath: "/bin", defaults: defaults) == .missing)
        typealias Reply = (out: String, err: String, status: Int32)
        let calls = Calls()
        func probe(which: Reply, doctor: Reply) -> Manvi.Account.Probe {
            { args in
                calls.add(args)
                return args.first == "which" ? which : args.first == "doctor" ? doctor : (out: "", err: "", status: 2)
            }
        }
        let which: Reply = (out: #"{"account":"work","source":"default","registry":"/h/.anthropic-accounts","fallback":{"name":"personal"},"workspace":"wrkspc_1"}"#,
                            err: "", status: 0)
        let healthy: Reply = (out: "registry  /h/.anthropic-accounts (2 accounts)\nok    work  anthropic-api-key-work\nok    personal  anthropic-api-key-personal\n",
                              err: "", status: 0)
        var status = Manvi.Account.status(launcher: "/l", envPath: "/bin", defaults: defaults, probe: probe(which: which, doctor: healthy))
        precondition(status == .ready(Manvi.Account.Pick(account: "work", workspace: "wrkspc_1")), "\(status)")
        precondition(calls.all == [["which", "--json"], ["doctor"]], "\(calls.all)")

        calls.reset()
        Manvi.Account.save("personal", defaults: defaults)
        _ = Manvi.Account.status(launcher: "/l", envPath: "/bin", defaults: defaults, probe: probe(which: which, doctor: healthy))
        precondition(calls.all.first == ["which", "--json", "--account", "personal"], "Settings' account is asked about: \(calls.all)")
        Manvi.Account.save(nil, defaults: defaults)

        let noRegistry: Reply = (out: "", err: "anthropic-account: no account registry at /h/.anthropic-accounts.\nFor each Console organisation, store its key under a name\n",
                                 status: 1)
        status = Manvi.Account.status(launcher: "/l", envPath: "/bin", defaults: defaults, probe: probe(which: noRegistry, doctor: healthy))
        guard case .refused(let why) = status else { preconditionFailure("no registry is a refusal: \(status)") }
        precondition(why.hasPrefix("anthropic-account: no account registry") && why.contains("store its key"), why)

        // doctor's exit fails for a missing fallback key too; only the
        // chosen account's row decides.
        let fallbackMissing: Reply = (out: "registry  /h/.anthropic-accounts (2 accounts)\nok    work  anthropic-api-key-work\nFAIL  personal  no Keychain item anthropic-api-key-personal\n",
                                      err: "anthropic-account: 1 of 2 accounts have no usable Keychain item\n", status: 1)
        status = Manvi.Account.status(launcher: "/l", envPath: "/bin", defaults: defaults, probe: probe(which: which, doctor: fallbackMissing))
        precondition(status.isReady, "a missing fallback key does not stop the run: \(status)")
        let chosenMissing: Reply = (out: "registry  /h/.anthropic-accounts (1 accounts)\nFAIL  work  no Keychain item anthropic-api-key-work\n",
                                    err: "anthropic-account: 1 of 1 accounts have no usable Keychain item\n", status: 1)
        status = Manvi.Account.status(launcher: "/l", envPath: "/bin", defaults: defaults, probe: probe(which: which, doctor: chosenMissing))
        precondition(status == .refused("FAIL work no Keychain item anthropic-api-key-work"), "\(status)")
        status = Manvi.Account.status(launcher: "/l", envPath: "/bin", defaults: defaults,
                                      probe: probe(which: (out: "not json", err: "", status: 0), doctor: healthy))
        precondition(status == .refused("anthropic-account exited with status 0"), "\(status)")
        precondition(Manvi.Account.parseList(#"[{"name":"work","workspace":"wrkspc_1"},{"name":"personal"}]"#) == ["work", "personal"])
        precondition(Manvi.Account.parseList("anthropic-account: no account registry").isEmpty)

        // The same questions through a real process: stdout and stderr both come back.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("blitztree-account-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("anthropic-account")
        try! Data("""
        #!/bin/sh
        case "$1" in
        which) echo '{"account":"work","source":"default","registry":"/h/.anthropic-accounts","fallback":null}' ;;
        doctor) printf 'registry  /h/.anthropic-accounts (1 accounts)\\nok    work  anthropic-api-key-work\\n' ;;
        list) echo '[{"name":"work"}]' ;;
        *) echo "anthropic-account: unknown command" >&2; exit 2 ;;
        esac

        """.utf8).write(to: script)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        status = Manvi.Account.status(launcher: script.path, envPath: "/usr/bin:/bin", defaults: defaults)
        precondition(status == .ready(Manvi.Account.Pick(account: "work", workspace: nil)), "a real launcher: \(status)")
        precondition(Manvi.Account.list(launcher: script.path, envPath: "/usr/bin:/bin") == ["work"])
        let unknown = Manvi.Account.probe(script.path, envPath: "/usr/bin:/bin")(["bogus"])
        precondition(unknown.status == 2 && unknown.err.hasPrefix("anthropic-account: unknown command"), "\(unknown)")

        // A launcher refusal is the line a failed run shows; its warnings never are.
        let tail = ErrTail()
        tail.feed(Data("anthropic-account: no account registry at /h/.anthropic-accounts.\nFor each Console organisation, store its key under a name (security prompts for it):\n  echo '<name>' >> /h/.anthropic-accounts\n".utf8))
        precondition(tail.last == "anthropic-account: no account registry at /h/.anthropic-accounts.", tail.last)
        let warned = ErrTail()
        warned.feed(Data("anthropic-account: warning: no fallback key, continuing on work alone: missing\nmanvi: the turn failed: HTTP 529\n".utf8))
        precondition(warned.last == "manvi: the turn failed: HTTP 529", warned.last)
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
            precondition(lines.contains("BZENV_ANTHROPIC_BASE_URL="), "\(shell): an unset one prints empty: \(out)")
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
        echo "$MANVI_LLM_PROVIDER_DEFAULT $MANVI_HARNESS_POSTURE $MANVI_MODEL ${ANTHROPIC_API_KEY:-nokey}" >> "$BZ_FAKE_DIR/log"
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
        // A stand-in anthropic-account: it logs what it was asked, then does
        // what exec does, the key set in the command's environment only.
        let launcher = fake.appendingPathComponent("anthropic-account")
        try! Data("""
        #!/bin/sh
        echo "$*" >> "$BZ_FAKE_DIR/launcher.log"
        if [ -e "$BZ_FAKE_DIR/refuse" ]; then
          echo "anthropic-account: no account registry at /h/.anthropic-accounts." >&2
          echo "For each Console organisation, store its key under a name" >&2
          exit 1
        fi
        [ "$1" = exec ] || exit 2
        while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
        shift
        ANTHROPIC_API_KEY=launcher-key exec "$@"

        """.utf8).write(to: launcher)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        func launches() -> [String] {
            (try? String(contentsOf: fake.appendingPathComponent("launcher.log"), encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
        }
        // No shell key: the only key any run sees is the one the launcher sets.
        var env = AgentEnvironment(agents: [agent], path: "/usr/bin:/bin", loaded: true, shell: [:])
        env.accountLauncher = launcher.path
        let local = Manvi.Route(provider: "local", model: "gemma4:e4b")
        let claude = Manvi.Route(provider: "anthropic", model: "claude-sonnet-5-5")
        func run(_ routes: [Manvi.Route], until stop: @MainActor (AgentRun) -> Bool) async -> AgentRun {
            try? fm.removeItem(at: fake.appendingPathComponent("log"))
            try? fm.removeItem(at: fake.appendingPathComponent("launcher.log"))
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
        precondition(log() == ["local strict gemma4:e4b nokey", "anthropic strict claude-sonnet-5-5 launcher-key"], "\(log())")
        let expected = (["exec", "--repo", tree.path(0), "--", script.path] + Manvi.runArguments(fallbackAfter: false))
            .joined(separator: " ")
        precondition(launches() == [expected], "only the Claude run goes through the launcher: \(launches())")
        precondition(r.steps.contains("Using Local · gemma4:e4b")
                     && r.steps.contains("Local · gemma4:e4b gave no plan; switching to Claude API · claude-sonnet-5-5")
                     && r.steps.contains("Using Claude API · claude-sonnet-5-5"), "the switch is shown: \(r.steps)")

        // Local only (forced from the menu): no switch, MANVI's own reason.
        r = await run([local]) { $0.phase != .thinking }
        guard case .failed(let why) = r.phase else { preconditionFailure("local only fails: \(r.phase)") }
        precondition(why.contains("connection refused") && log() == ["local strict gemma4:e4b nokey"] && launches().isEmpty,
                     "\(why) \(log())")

        // The launcher refuses (no account registry): MANVI never starts, and
        // the run says why in the launcher's first line.
        try! Data().write(to: fake.appendingPathComponent("refuse"))
        r = await run([claude]) { $0.phase != .thinking }
        try! fm.removeItem(at: fake.appendingPathComponent("refuse"))
        guard case .failed(let refused) = r.phase else { preconditionFailure("a refusal fails the run: \(r.phase)") }
        precondition(refused.contains("anthropic-account: no account registry") && log().isEmpty && launches().count == 1,
                     "\(refused) \(log())")

        // No launcher installed: the Claude route fails before anything starts.
        env.accountLauncher = nil
        r = await run([claude]) { $0.phase != .thinking }
        guard case .failed(let missing) = r.phase else { preconditionFailure("no launcher fails the run: \(r.phase)") }
        precondition(missing.contains("anthropic-account isn't installed") && log().isEmpty && launches().isEmpty, missing)
        env.accountLauncher = launcher.path

        // Cancelled while local runs: the cloud is never started.
        answer("local", [["kind": "session.start", "posture": "strict"]], exit: 1, sleep: 2)
        r = await run([local, claude]) { _ in log() == ["local strict gemma4:e4b nokey"] }
        r.cancel()
        let until = Date().addingTimeInterval(3)
        while Date() < until { pump(); try? await Task.sleep(for: .milliseconds(5)) }
        precondition(log() == ["local strict gemma4:e4b nokey"] && launches().isEmpty && !r.steps.contains { $0.contains("switching") },
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
