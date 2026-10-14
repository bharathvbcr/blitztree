import Foundation

/// A deleted or invalid custom provider in `bz.engine` must not hide the
/// ready CLI agents from the Clean Up planner.
@main
struct PlannerFallbackChecks {
    @MainActor
    static func main() async {
        let defaults = UserDefaults.standard
        let savedEngine = defaults.object(forKey: "bz.engine")
        let savedAgent = defaults.object(forKey: "bz.agent")
        defer {
            defaults.set(savedEngine, forKey: "bz.engine")
            defaults.set(savedAgent, forKey: "bz.agent")
        }
        defaults.removeObject(forKey: "bz.agent")

        let model = ScanModel()
        model.agentEnv = AgentEnvironment(
            agents: [InstalledAgent(kind: .codex, path: "/bin/codex", signedIn: true),
                     InstalledAgent(kind: .claude, path: "/bin/claude", signedIn: true)],
            loaded: true)

        defaults.set("provider:deleted-provider", forKey: "bz.engine")
        precondition(model.preferredProvider == nil, "the stale provider must not resolve")
        precondition(model.preferredAgent?.kind == .claude,
                     "a stale provider must fall back to a ready agent, preferring Claude Code")
        precondition(model.plannerName == "Claude Code", "the planner must not be nil with a ready agent")
        precondition(defaults.string(forKey: "bz.engine") == nil, "the stale bz.engine key must be cleared")

        defaults.set("provider:deleted-provider", forKey: "bz.engine")
        defaults.set("codex", forKey: "bz.agent")
        precondition(model.preferredAgent?.kind == .codex, "the last-used agent wins over Claude Code")

        // MANVI is a planner like the others once ready, and only when picked
        // or when it is the only one ready.
        model.agentEnv = AgentEnvironment(
            agents: [InstalledAgent(kind: .manvi, path: "/bin/manvi", signedIn: true),
                     InstalledAgent(kind: .claude, path: "/bin/claude", signedIn: true)],
            loaded: true)
        defaults.removeObject(forKey: "bz.agent")
        defaults.set("manvi", forKey: "bz.engine")
        precondition(model.preferredAgent?.kind == .manvi && model.plannerName == "MANVI", "MANVI when picked")
        defaults.removeObject(forKey: "bz.engine")
        precondition(model.preferredAgent?.kind == .claude, "Claude Code stays the default")
        model.agentEnv = AgentEnvironment(
            agents: [InstalledAgent(kind: .manvi, path: "/bin/manvi", signedIn: false)], loaded: true)
        defaults.set("manvi", forKey: "bz.engine")
        precondition(model.preferredAgent == nil, "a MANVI without a model is not a planner")
        model.setUp(.manvi)
        precondition(model.agentSetup == nil, "BlitzTree never installs MANVI")

        model.agentEnv = AgentEnvironment(loaded: true)
        defaults.set("provider:deleted-provider", forKey: "bz.engine")
        precondition(model.plannerName == nil, "with no ready agent there is still no planner")

        providerURLs()
        planErrors()
        await requestTimeURLCheck()
        keychainFailures()
        realKeychainRoundTrip()
        print("PlannerFallbackChecks passed")
    }

    /// The real login Keychain under a throwaway provider id, so the item is
    /// `dev.ahmed.blitztree.bz-test-<uuid>`, never one a user has. Every
    /// Keychain call is made and its result kept before anything is asserted,
    /// and the item is removed before the first assertion: a trap skips defers.
    /// Where the Keychain can't be used (CI without an unlocked login keychain)
    /// it says SKIP and checks nothing; it never reports a pass.
    @MainActor
    private static func realKeychainRoundTrip() {
        let id = "bz-test-" + UUID().uuidString.lowercased()
        let suite = "dev.ahmed.blitztree.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = ProviderStore(defaults: defaults)
        let provider = LLMProvider(id: id, displayName: "Round trip", baseURL: URL(string: "https://gw.example/v1")!,
                                   api: .anthropic, model: "m")
        func items() -> Int {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "dev.ahmed.blitztree." + id,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            var found: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess else { return 0 }
            return (found as? [[String: Any]])?.count ?? 0
        }

        var failure: Error?
        var first: String?, second: String?, keptWithoutKey: String?
        var itemsAfterTwoSaves = 0
        do {
            try store.save(provider, key: "first-key", keychain: .system)
            first = store.key(for: id)
            try store.save(provider, key: "second-key-é-日本", keychain: .system)
            second = store.key(for: id)
            itemsAfterTwoSaves = items()
            try store.save(provider, key: nil)
            keptWithoutKey = store.key(for: id)
        } catch { failure = error }
        let reloaded = ProviderStore(defaults: defaults).providers
        let before = store.key(for: id)
        store.delete(provider)
        let afterDelete = ProviderStore.getKey(for: id)
        ProviderStore.deleteKey(for: id)
        let leftBehind = items()
        defaults.removePersistentDomain(forName: suite)

        if let failure = failure as? KeychainFailure,
           [errSecInteractionNotAllowed, errSecNotAvailable, errSecNoSuchKeychain, errSecAuthFailed].contains(failure.status) {
            print("SKIP real Keychain round trip: the Keychain is not usable here (OSStatus \(failure.status)); nothing was checked")
            return
        }
        precondition(failure == nil, "the Keychain refused a test key: \(String(describing: failure))")
        precondition(first == "first-key", "a saved key reads back: \(String(describing: first))")
        precondition(second == "second-key-é-日本", "saving again replaces the key (UTF-8 intact): \(String(describing: second))")
        precondition(itemsAfterTwoSaves == 1, "replacing a key updates the item, never adds a second: \(itemsAfterTwoSaves)")
        precondition(keptWithoutKey == "second-key-é-日本", "saving a provider without a key keeps the stored one")
        precondition(reloaded == [provider], "the provider persisted without its key")
        precondition(before != nil && store.providers.isEmpty && afterDelete == nil, "delete removes the provider and its key")
        precondition(leftBehind == 0, "no Keychain item left behind: \(leftBehind)")
        print("PASS real Keychain: save, replace, keep, delete under a throwaway service")
    }

    // MARK: Custom provider base URL

    /// https anywhere; http only for this Mac. Every spelling that merely
    /// looks local (a name that starts with localhost, a name that contains
    /// 127.0.0.1, odd address forms) is refused.
    private static func providerURLs() {
        let allowed = [
            "https://api.example.com/v1", "HTTPS://API.Example.com/v1", "https://localhost.evil.com",
            "http://localhost", "http://localhost:11434/v1", "http://LOCALHOST:8080", "HTTP://localhost/v1",
            "http://127.0.0.1:8080", "http://127.0.0.1", "http://127.255.255.254:9", "HTTP://127.0.0.1:1234/v1",
            "http://[::1]", "http://[::1]:8080/v1", "http://[0:0:0:0:0:0:0:1]:80",
        ]
        for text in allowed {
            guard case .success = ProviderURL.validate(text) else {
                preconditionFailure("should be allowed: \(text) -> \(ProviderURL.validate(text))")
            }
        }
        let refused: [(String, ProviderURL.Problem)] = [
            ("http://example.com", .insecure(host: "example.com")),
            ("http://example.com:8080/v1", .insecure(host: "example.com")),
            ("HTTP://Example.com", .insecure(host: "example.com")),
            ("http://localhost.evil.com", .insecure(host: "localhost.evil.com")),
            ("http://127.0.0.1.nip.io", .insecure(host: "127.0.0.1.nip.io")),
            ("http://127.0.0.1.evil.com:8080", .insecure(host: "127.0.0.1.evil.com")),
            ("http://128.0.0.1", .insecure(host: "128.0.0.1")),
            ("http://10.0.0.5:11434", .insecure(host: "10.0.0.5")),
            ("http://0.0.0.0", .insecure(host: "0.0.0.0")),
            ("http://127.1", .insecure(host: "127.1")),
            ("http://0x7f.0.0.1", .insecure(host: "0x7f.0.0.1")),
            ("http://0177.0.0.1", .insecure(host: "0177.0.0.1")),
            ("http://127.0.0.256", .insecure(host: "127.0.0.256")),
            ("http://localhost@evil.com", .insecure(host: "evil.com")),
            ("http://127.0.0.1@evil.com", .insecure(host: "evil.com")),
            ("https://user:secret@api.example.com/v1", .credentials),
            ("https://user@api.example.com/v1", .credentials),
            ("https://:secret@api.example.com/v1", .credentials),
            ("http://localhost/v1?token=1", .query),
            ("https://api.example.com/v1?x=1", .query),
            ("http://[::2]", .insecure(host: "::2")),
            ("http://[::ffff:127.0.0.1]", .insecure(host: "::ffff:127.0.0.1")),
            ("http://localhost.", .insecure(host: "localhost.")),
            ("file:///etc/passwd", .unsupportedScheme("file")),
            ("ftp://example.com/x", .unsupportedScheme("ftp")),
            ("FTP://localhost", .unsupportedScheme("ftp")),
            ("ws://localhost:8080", .unsupportedScheme("ws")),
            ("https://", .noHost),
            ("http:///v1", .noHost),
            ("", .empty),
            ("   ", .empty),
            ("example.com/v1", .unreadable),
            ("not a url", .unreadable),
        ]
        for (text, expected) in refused {
            guard case .failure(let problem) = ProviderURL.validate(text) else {
                preconditionFailure("should be refused: \(text)")
            }
            precondition(problem == expected, "\(text): \(problem), expected \(expected)")
            precondition(problem.errorDescription?.isEmpty == false, "\(text): the reason is shown")
        }
        // The reason names what to do.
        precondition(ProviderURL.Problem.insecure(host: "example.com").errorDescription?.contains("https://") == true)
        guard case .failure(let queried) = ProviderURL.validate("https://api.example.com/v1?x=1#notes") else {
            preconditionFailure("a query is refused before a fragment can be stored")
        }
        precondition(queried == .query, "\(queried)")
        guard case .success(let canonical) = ProviderURL.validate("https://api.example.com:8443/v1#notes") else {
            preconditionFailure("a fragment is not part of the base URL")
        }
        let parts = URLComponents(url: canonical, resolvingAgainstBaseURL: false)
        precondition(canonical.scheme == "https" && canonical.host == "api.example.com"
                     && canonical.port == 8443 && canonical.path == "/v1"
                     && parts?.user == nil && parts?.password == nil
                     && parts?.query == nil && parts?.fragment == nil,
                     "stored URL keeps scheme, host, port and path: \(canonical)")
        print("PASS provider base URL: \(allowed.count) allowed, \(refused.count) refused with a reason")
    }

    private static func planErrors() {
        let empty = PlanError.http(503, "").errorDescription
        precondition(empty == String(localized: "HTTP \(503)"), "\(empty ?? "nil")")
        let body = PlanError.http(429, "slow down\nmore").errorDescription
        precondition(body == String(localized: "HTTP \(429): \("slow down")"), "\(body ?? "nil")")
        let long = String(repeating: "a", count: 250)
        let clipped = PlanError.http(400, long).errorDescription
        precondition(clipped == String(localized: "HTTP \(400): \(String(long.prefix(200)))"), "\(clipped ?? "nil")")
        print("PASS plan HTTP errors are localized")
    }

    /// A provider saved by an older build may still hold an http URL; the key
    /// must not leave on it, and the reason reaches the panel.
    @MainActor
    private static func requestTimeURLCheck() async {
        let provider = LLMProvider(id: "old", displayName: "old", baseURL: URL(string: "http://example.com/v1")!,
                                   api: .openAIChat, model: "m")
        let client = LLMPlanClient(provider: provider, apiKey: "secret")
        let message: String = await withCheckedContinuation { continuation in
            client.plan("prompt") { event in
                if case .failed(let text) = event { continuation.resume(returning: text) }
            }
        }
        precondition(message.contains("plain http"), message)
        print("PASS a saved http provider is refused before any request")
    }

    // MARK: Keychain

    private static func keychainFailures() {
        func make(update: OSStatus, add: OSStatus) -> (KeychainClient, KeychainCalls) {
            let calls = KeychainCalls()
            return (KeychainClient(
                update: { query, _ in calls.record("update", query); return update },
                add: { attributes in calls.record("add", attributes); return add }), calls)
        }

        var (client, calls) = make(update: errSecSuccess, add: errSecParam)
        try! ProviderStore.setKey("k", for: "acme", keychain: client)
        precondition(calls.names == ["update"], "an existing item is updated in place, never deleted first: \(calls.names)")
        precondition(calls.services == ["dev.ahmed.blitztree.acme"])

        (client, calls) = make(update: errSecItemNotFound, add: errSecSuccess)
        try! ProviderStore.setKey("k", for: "acme", keychain: client)
        precondition(calls.names == ["update", "add"], "a new item is added: \(calls.names)")

        (client, calls) = make(update: errSecItemNotFound, add: errSecInteractionNotAllowed)
        do {
            try ProviderStore.setKey("k", for: "acme", keychain: client)
            preconditionFailure("a refused SecItemAdd must propagate")
        } catch let failure as KeychainFailure {
            precondition(failure.status == errSecInteractionNotAllowed)
            precondition(failure.localizedDescription.contains(String(errSecInteractionNotAllowed)), failure.localizedDescription)
        } catch { preconditionFailure("wrong error: \(error)") }

        // Another writer added the item between the update and the add: update once more.
        let sequence = KeychainSequence(updates: [errSecItemNotFound, errSecSuccess], adds: [errSecDuplicateItem])
        try! ProviderStore.setKey("k", for: "acme", keychain: sequence.client)
        precondition(sequence.log == ["update", "add", "update"], "duplicate on add retries as an update: \(sequence.log)")
        let stillFailing = KeychainSequence(updates: [errSecItemNotFound, errSecAuthFailed], adds: [errSecDuplicateItem])
        do {
            try ProviderStore.setKey("k", for: "acme", keychain: stillFailing.client)
            preconditionFailure("a failed retry must propagate")
        } catch let failure as KeychainFailure {
            precondition(failure.status == errSecAuthFailed && stillFailing.log == ["update", "add", "update"], "\(stillFailing.log)")
        } catch { preconditionFailure("\(error)") }

        (client, calls) = make(update: errSecAuthFailed, add: errSecSuccess)
        do {
            try ProviderStore.setKey("k", for: "acme", keychain: client)
            preconditionFailure("a refused SecItemUpdate must propagate")
        } catch let failure as KeychainFailure {
            precondition(failure.status == errSecAuthFailed)
            precondition(calls.names == ["update"], "no add after an update that failed for another reason")
        } catch { preconditionFailure("wrong error: \(error)") }

        // The store: a refused key or a refused URL changes nothing.
        MainActor.assumeIsolated {
            let suite = "dev.ahmed.blitztree.test.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = ProviderStore(defaults: defaults)
            let good = LLMProvider(id: "acme", displayName: "Acme", baseURL: URL(string: "https://gw.example/v1")!,
                                   api: .openAIChat, model: "m")
            let failing = make(update: errSecItemNotFound, add: errSecDuplicateItem)
            do {
                try store.save(good, key: "k", keychain: failing.0)
                preconditionFailure("the provider form needs the Keychain error")
            } catch is KeychainFailure {}
            catch { preconditionFailure("\(error)") }
            precondition(store.providers.isEmpty && defaults.data(forKey: "bz.providers") == nil,
                         "a provider is not saved without the key that was given for it")

            let insecure = LLMProvider(id: "bad", displayName: "Bad", baseURL: URL(string: "http://example.com/v1")!,
                                       api: .openAIChat, model: "m")
            let untouched = make(update: errSecSuccess, add: errSecSuccess)
            do {
                try store.save(insecure, key: "k", keychain: untouched.0)
                preconditionFailure("http to a remote host must not be saved")
            } catch let problem as ProviderURL.Problem {
                precondition(problem == .insecure(host: "example.com"))
            } catch { preconditionFailure("\(error)") }
            precondition(untouched.1.names.isEmpty && store.providers.isEmpty, "no Keychain write for a refused URL")

            let ok = make(update: errSecSuccess, add: errSecSuccess)
            try! store.save(good, key: "k", keychain: ok.0)
            precondition(store.providers == [good] && ProviderStore(defaults: defaults).providers == [good])

            let decorated = LLMProvider(id: "noted", displayName: "Noted",
                                        baseURL: URL(string: "https://gw.example/v1#notes")!,
                                        api: .openAIChat, model: "m")
            try! store.save(decorated, key: nil, keychain: ok.0)
            let kept = store.providers.first { $0.id == "noted" }
            precondition(kept?.baseURL.fragment == nil && kept?.baseURL.query == nil
                         && kept?.baseURL.path == "/v1" && kept?.baseURL.host == "gw.example",
                         "a saved provider keeps scheme, host, port and path: \(kept?.baseURL.absoluteString ?? "nil")")
        }
        print("PASS Keychain failures propagate; a refused key or URL saves nothing")
    }
}

/// A Keychain stand-in that answers each call from a script, in order.
private nonisolated final class KeychainSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [OSStatus], adds: [OSStatus]
    private var calls: [String] = []

    init(updates: [OSStatus], adds: [OSStatus]) {
        self.updates = updates
        self.adds = adds
    }

    var log: [String] { lock.lock(); defer { lock.unlock() }; return calls }

    var client: KeychainClient {
        KeychainClient(
            update: { [self] _, _ in lock.lock(); defer { lock.unlock() }; calls.append("update"); return updates.removeFirst() },
            add: { [self] _ in lock.lock(); defer { lock.unlock() }; calls.append("add"); return adds.removeFirst() })
    }
}

private nonisolated final class KeychainCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, [String: Any])] = []

    func record(_ name: String, _ query: CFDictionary) {
        lock.lock(); defer { lock.unlock() }
        entries.append((name, query as? [String: Any] ?? [:]))
    }

    var names: [String] { lock.lock(); defer { lock.unlock() }; return entries.map(\.0) }
    var services: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.compactMap { $0.1[kSecAttrService as String] as? String }
    }
}
