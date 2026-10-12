import Foundation

// Custom model providers: any OpenAI- or Anthropic-compatible endpoint by its
// base URL, protocol, API key and model — relays, self-hosted servers (Ollama,
// LM Studio, vLLM) or hosted gateways. The plan these endpoints return is just
// a proposal: CleanupGuard re-checks everything, exactly as for the CLI agents,
// and BlitzTree itself performs every deletion. The endpoint never runs tools;
// it only writes the plan, which is a strictly smaller surface than a CLI
// agent's harness — there is nothing for it to escalate.

// MARK: - Provider model

/// Wire format of the endpoint. `rawValue` is the settings identifier.
nonisolated enum APIProtocol: String, Codable, CaseIterable, Identifiable {
    case openAIChat
    case openAIResponses
    case anthropic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAIChat: return "OpenAI Chat Completions"
        case .openAIResponses: return "OpenAI Responses"
        case .anthropic: return "Anthropic Messages"
        }
    }

    /// Endpoint path appended to the provider's base URL. A base URL that
    /// already ends in /v1 (the common convention) is not doubled.
    func path(for baseURL: URL) -> URL {
        let endsInV1 = baseURL.path.hasSuffix("/v1")
        switch self {
        case .openAIChat: return baseURL.appending(path: "chat/completions")
        case .openAIResponses: return baseURL.appending(path: "responses")
        case .anthropic: return baseURL.appending(path: endsInV1 ? "messages" : "v1/messages")
        }
    }
}

/// Where a base URL may point. The API key and the scan's folder paths go to
/// it, so it has to be https; plain http is for a server on this Mac only
/// (`localhost`, `127.0.0.0/8`, `::1`), where nothing crosses a network.
nonisolated enum ProviderURL {
    enum Problem: Error, Equatable, LocalizedError {
        case empty
        case unreadable
        case noHost
        /// A scheme that is neither http nor https (file, ftp…).
        case unsupportedScheme(String)
        /// http to a host that is not on this Mac.
        case insecure(host: String)
        /// The server answered with a redirect to another origin (or to an
        /// address this rule refuses); the request was stopped before it was
        /// repeated there.
        case redirected(host: String)

        var errorDescription: String? {
            switch self {
            case .redirected(let host):
                return String(localized: "The server redirected the request to “\(host)”, which is a different address, so it was stopped before your API key and folder paths were sent there. Use the final address as the base URL.")
            case .empty, .unreadable:
                return String(localized: "Enter a full URL, such as https://gateway.example/v1.")
            case .noHost:
                return String(localized: "The URL needs a host name, such as gateway.example.")
            case .unsupportedScheme(let scheme):
                return String(localized: "“\(scheme)://” isn't supported. Use https://.")
            case .insecure(let host):
                return String(localized: "“\(host)” is reached over plain http, so your API key and folder paths would cross the network unencrypted. Use https://. Plain http is allowed only for localhost, 127.0.0.1 and ::1.")
            }
        }
    }

    /// The URL if it may be used, else why not.
    static func validate(_ text: String) -> Result<URL, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let url = URL(string: trimmed) else { return .failure(.unreadable) }
        if let problem = problem(for: url) { return .failure(problem) }
        return .success(url)
    }

    static func problem(for url: URL) -> Problem? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), !scheme.isEmpty else { return .unreadable }
        guard scheme == "https" || scheme == "http" else { return .unsupportedScheme(scheme) }
        guard let rawHost = parts.host, !rawHost.isEmpty else { return .noHost }
        let host = bareHost(rawHost)
        if scheme == "http", !isLoopback(host) { return .insecure(host: host) }
        return nil
    }

    /// Same scheme, host and (effective) port: a redirect inside this origin
    /// repeats the request, key header included, to the same place.
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let x = URLComponents(url: a, resolvingAgainstBaseURL: false),
              let y = URLComponents(url: b, resolvingAgainstBaseURL: false),
              let schemeA = x.scheme?.lowercased(), let schemeB = y.scheme?.lowercased(),
              let hostA = x.host, let hostB = y.host else { return false }
        func port(_ c: URLComponents, _ scheme: String) -> Int { c.port ?? (scheme == "https" ? 443 : 80) }
        return schemeA == schemeB && bareHost(hostA) == bareHost(hostB) && port(x, schemeA) == port(y, schemeB)
    }

    /// URLComponents keeps the brackets of an IPv6 literal; the name is
    /// compared in lower case without them.
    private static func bareHost(_ host: String) -> String {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        return name
    }

    /// Exactly `localhost`, a dotted-quad address in 127.0.0.0/8, or `::1`.
    /// `localhost.evil.com` and `127.0.0.1.nip.io` are names, not loopback,
    /// and the odd spellings of 127.0.0.1 (octal, hex, short forms) are
    /// refused rather than guessed at.
    static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4 {
            let numbers = octets.compactMap { octet -> Int? in
                guard !octet.isEmpty, octet.count <= 3, octet.allSatisfy(\.isASCII), octet.allSatisfy(\.isNumber),
                      octet == "0" || !octet.hasPrefix("0") else { return nil }
                return Int(octet).flatMap { $0 <= 255 ? $0 : nil }
            }
            return numbers.count == 4 && numbers[0] == 127
        }
        var address = in6_addr()
        guard host.contains(":"), inet_pton(AF_INET6, host, &address) == 1 else { return false }
        var loopback = in6addr_loopback
        return memcmp(&address, &loopback, MemoryLayout<in6_addr>.size) == 0
    }
}

/// Refuses every redirect that leaves the origin it started on, and any that
/// lands on an address `ProviderURL` refuses. URLSession drops Authorization
/// when it follows a redirect but repeats custom headers such as `x-api-key`,
/// and the body, so following one would hand the key and the prompt to
/// whoever the server named. Refusing returns the 3xx itself.
nonisolated final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var host: String?

    /// The host a redirect was refused for, once one has been.
    var refused: String? { lock.lock(); defer { lock.unlock() }; return host }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if let from = response.url, let to = request.url, ProviderURL.sameOrigin(from, to),
           ProviderURL.problem(for: to) == nil {
            completionHandler(request)
            return
        }
        lock.lock()
        host = request.url?.host ?? "?"
        lock.unlock()
        completionHandler(nil)
    }
}

/// The requests that carry a provider's key. Every one goes through here so
/// none follows a redirect off its origin.
nonisolated enum ProviderHTTP {
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let guardian = RedirectGuard()
        let result = try await URLSession.shared.data(for: request, delegate: guardian)
        if let host = guardian.refused { throw ProviderURL.Problem.redirected(host: host) }
        return result
    }

    static func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let guardian = RedirectGuard()
        let result = try await URLSession.shared.bytes(for: request, delegate: guardian)
        if let host = guardian.refused { throw ProviderURL.Problem.redirected(host: host) }
        return result
    }
}

nonisolated struct LLMProvider: Identifiable, Codable, Sendable, Equatable {
    /// Lowercase identifier, a letter first; names the provider in requests
    /// and its credential in the Keychain.
    var id: String
    var displayName: String
    var baseURL: URL
    var api: APIProtocol
    /// The model to ask for plans. The picker lists fetched IDs; unlisted IDs
    /// can be typed directly.
    var model: String
}

/// The Keychain calls `setKey` makes, so a test can make them fail without
/// touching the real login keychain.
nonisolated struct KeychainClient: Sendable {
    var update: @Sendable (_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
    var add: @Sendable (_ attributes: CFDictionary) -> OSStatus

    static let system = KeychainClient(
        update: { SecItemUpdate($0, $1) },
        add: { SecItemAdd($0, nil) })
}

/// The Keychain refused to store a key.
nonisolated struct KeychainFailure: Error, Equatable, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return String(localized: "Couldn't save the API key to the Keychain: \(reason) (\(String(status))).")
    }
}

/// Providers and their API keys. Providers live in UserDefaults; keys live in
/// the Keychain, keyed `dev.ahmed.blitztree.<provider id>` — never in prefs.
@MainActor
@Observable
final class ProviderStore {
    static let shared = ProviderStore()

    private(set) var providers: [LLMProvider] = []

    private static let defaultsKey = "bz.providers"
    nonisolated private static let servicePrefix = "dev.ahmed.blitztree."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([LLMProvider].self, from: data) {
            providers = saved
        }
    }

    /// Stores the provider and, when given, its key. Throws without changing
    /// anything when the URL is not allowed or the Keychain refuses the key:
    /// a provider saved without its key would only fail later as a 401.
    func save(_ provider: LLMProvider, key: String?, keychain: KeychainClient = .system) throws {
        if let problem = ProviderURL.problem(for: provider.baseURL) { throw problem }
        if let key, !key.isEmpty { try Self.setKey(key, for: provider.id, keychain: keychain) }
        providers.removeAll { $0.id == provider.id }
        providers.append(provider)
        persist()
    }

    func delete(_ provider: LLMProvider) {
        providers.removeAll { $0.id == provider.id }
        persist()
        Self.deleteKey(for: provider.id)
    }

    func key(for id: String) -> String? { Self.getKey(for: id) }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(providers), forKey: Self.defaultsKey)
    }

    // MARK: Keychain

    /// Updates the stored key in place, adding the item when there is none
    /// yet. The old key is never deleted first, so a refused write leaves
    /// what was there. Any other status is thrown for the form to show.
    nonisolated static func setKey(_ key: String, for id: String, keychain: KeychainClient = .system) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix + id,
            kSecAttrAccount as String: "api-key",
        ]
        let value = Data(key.utf8)
        let updated = keychain.update(base as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainFailure(status: updated) }
        var add = base
        add[kSecValueData as String] = value
        let added = keychain.add(add as CFDictionary)
        if added == errSecSuccess { return }
        // The item appeared between the update and the add (another writer):
        // update it once more rather than fail.
        guard added == errSecDuplicateItem else { throw KeychainFailure(status: added) }
        let retried = keychain.update(base as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        guard retried == errSecSuccess else { throw KeychainFailure(status: retried) }
    }

    nonisolated static func getKey(for id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix + id,
            kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func deleteKey(for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix + id,
            kSecAttrAccount as String: "api-key",
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - The streaming plan request

/// What a provider run reports, mapped 1:1 onto the CLI agents' event
/// pipeline by the caller: cards as they are written, then the plan.
nonisolated enum LLMEvent: Sendable {
    case item(PlanItemSpec)
    case plan(summary: String, items: [PlanItemSpec])
    case failed(String)
}

/// Speaks one of the three wire protocols above and turns the answer into
/// events. Streaming SSE is the happy path; a plain (non-streaming) JSON
/// body and fenced/prose-wrapped JSON are both handled, because real
/// endpoints and real models do all of it. MainActor: runs are driven from
/// AgentRun, and the network Task inherits the isolation so mutable parsing
/// state stays in one place.
@MainActor
final class LLMPlanClient {
    private let provider: LLMProvider
    private let apiKey: String
    private var task: Task<Void, Never>?

    init(provider: LLMProvider, apiKey: String) {
        self.provider = provider
        self.apiKey = apiKey
    }

    func cancel() { task?.cancel() }

    func plan(_ prompt: String, emit: @escaping @Sendable (LLMEvent) -> Void) {
        task = Task { [provider, apiKey] in
            var parser = PartialPlanParser()
            do {
                // The network layer yields deltas; the parser mutates only
                // here, in the task body, where the isolation checker can
                // follow it.
                var full = ""
                for try await event in Self.streamEvents(provider: provider, apiKey: apiKey, prompt: prompt) {
                    switch event {
                    case .delta(let delta):
                        full += delta
                        for item in parser.append(delta) { emit(.item(item)) }
                    case .done:
                        // The finished text is authoritative when it decodes —
                        // strict JSON, fenced JSON, or prose around the object.
                        if let decoded = PlanJSON.decode(text: full) {
                            emit(.plan(summary: decoded.0, items: decoded.1))
                        } else if parser.hasInput {
                            // Deltas streamed but the strict JSON never closed
                            // (or a non-SSE body never arrived): the partial
                            // cards stand.
                            emit(.failed(String(localized: "The reply was not valid plan JSON.")))
                        } else {
                            emit(.failed(String(localized: "The endpoint returned no plan.")))
                        }
                        return
                    }
                }
            } catch is CancellationError {
            } catch let error as PlanError {
                emit(.failed(error.errorDescription ?? String(localized: "The request failed.")))
            } catch {
                emit(.failed(error.localizedDescription))
            }
        }
    }

    /// What the network layer reports: one text delta per SSE event, then
    /// `done` once the body is exhausted (non-SSE bodies surface their whole
    /// message as one delta).
    nonisolated private enum StreamEvent: Sendable {
        case delta(String)
        case done
    }

    /// One request as a stream of deltas.
    private static func streamEvents(provider: LLMProvider, apiKey: String, prompt: String) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [provider, apiKey] in
                do {
                    try await Self.stream(provider: provider, apiKey: apiKey, prompt: prompt) { delta in
                        continuation.yield(.delta(delta))
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func stream(provider: LLMProvider, apiKey: String, prompt: String,
                               onDelta: @escaping @Sendable (String) -> Void) async throws {
        // A provider saved by an older build may still point at plain http;
        // its key and the scan's paths must not leave on that.
        if let problem = ProviderURL.problem(for: provider.baseURL) { throw PlanError.baseURL(problem) }
        let url = provider.api.path(for: provider.baseURL)
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        switch provider.api {
        case .openAIChat:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            // json_mode is the widely supported floor for OpenAI-compatible
            // endpoints (Ollama, vLLM, gateways); the schema text in the
            // prompt carries the structure.
            body = [
                "model": provider.model, "stream": true,
                "response_format": ["type": "json_object"],
                "messages": [["role": "user", "content": prompt]],
            ]
        case .openAIResponses:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = ["model": provider.model, "stream": true, "input": prompt]
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": provider.model, "stream": true, "max_tokens": 8192,
                "messages": [["role": "user", "content": prompt]],
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await ProviderHTTP.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Read the error body for the message endpoints usually send.
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 4096 { break }
            }
            throw PlanError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }

        var sawSSE = false
        var rawBody = ""
        // Server-sent events: `data:` lines, JSON payloads per protocol.
        for try await line in bytes.lines {
            rawBody += line + "\n"
            guard line.hasPrefix("data:") else { continue }
            sawSSE = true
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let delta = Self.delta(in: obj, api: provider.api) {
                onDelta(delta)
            }
        }
        // Endpoints that ignore `stream: true` answer with one plain JSON
        // body. Chat shape: the plan is inside choices[0].message.content.
        if !sawSSE {
            if let obj = try? JSONSerialization.jsonObject(with: Data(rawBody.utf8)) as? [String: Any],
               let choices = obj["choices"] as? [[String: Any]],
               let content = (choices.first?["message"] as? [String: Any])?["content"] as? String {
                onDelta(content)
            } else {
                // Some relays answer with the plan object itself.
                onDelta(rawBody)
            }
        }
    }

    /// The one text delta of an event, whatever the wire format.
    private static func delta(in obj: [String: Any], api: APIProtocol) -> String? {
        switch api {
        case .openAIChat:
            let choices = obj["choices"] as? [[String: Any]] ?? []
            return (choices.first?["delta"] as? [String: Any])?["content"] as? String
        case .openAIResponses:
            return obj["delta"] as? String
        case .anthropic:
            guard (obj["type"] as? String) == "content_block_delta" else { return nil }
            return (obj["delta"] as? [String: Any])?["text"] as? String
        }
    }
}

enum PlanError: Error { case http(Int, String), baseURL(ProviderURL.Problem) }

extension PlanError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .baseURL(problem):
            return problem.errorDescription
        case let .http(code, body):
            let line = body.split(separator: "\n").first ?? ""
            return "HTTP \(code)\(line.isEmpty ? "" : ": \(line.prefix(200))")"
        }
    }
}
