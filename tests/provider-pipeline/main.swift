import Foundation

func collect(_ client: LLMPlanClient, _ prompt: String) async -> (String, Int, Int, String) {
    await withCheckedContinuation { cont in
        var before = 0
        let emit: @Sendable (LLMEvent) -> Void = { event in
            switch event {
            case .item: before += 1
            case .plan(let s, let items): cont.resume(returning: (s, items.count, before, ""))
            case .failed(let m): cont.resume(returning: ("", 0, before, m))
            }
        }
        Task { @MainActor in
            client.plan(prompt, emit: emit)
        }
    }
}

@main struct H {
    @MainActor
    static func main() async {
        // server.py picks free ports and writes them to the file named here.
        guard CommandLine.arguments.count > 1,
              let data = FileManager.default.contents(atPath: CommandLine.arguments[1]),
              let ports = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
              let mainPort = ports["main"], let capturePort = ports["capture"] else {
            fatalError("usage: harness PORTS_FILE (written by server.py)")
        }
        func provider() -> LLMProvider {
            LLMProvider(id: "t", displayName: "t",
                        baseURL: URL(string: "http://127.0.0.1:\(mainPort)/v1")!,
                        api: .openAIChat, model: "m")
        }
        /// What the second listener has received, as the mock recorded it.
        func captured() async -> [[String: Any]] {
            let url = URL(string: "http://127.0.0.1:\(capturePort)/seen")!
            let (body, _) = (try? await URLSession.shared.data(from: url)) ?? (Data(), URLResponse())
            return (try? JSONSerialization.jsonObject(with: body) as? [[String: Any]]) ?? [["unreadable": true]]
        }
        let r1 = await collect(LLMPlanClient(provider: provider(), apiKey: "k"), "sse")
        assert(r1.0 == "3.2 GB can go" && r1.1 == 2, "SSE strict: \(r1)")
        print("PASS SSE strict (summary, 2 items)")
        assert(r1.2 == 2, "partial items streamed first: \(r1)")
        print("PASS partial items stream before plan")

        let r2 = await collect(LLMPlanClient(provider: provider(), apiKey: "k"), "fenced")
        assert(r2.0 == "3.2 GB can go" && r2.1 == 2, "fenced: \(r2)")
        print("PASS fenced JSON decodes")

        let r3 = await collect(LLMPlanClient(provider: provider(), apiKey: "k"), "plain")
        assert(r3.0 == "3.2 GB can go" && r3.1 == 2, "plain: \(r3)")
        print("PASS non-SSE body decodes")

        let r4 = await collect(LLMPlanClient(provider: provider(), apiKey: "k"), "401")
        assert(r4.3.contains("HTTP 401"), "401: \(r4)")
        print("PASS HTTP error surfaces")

        // A remote http endpoint is refused before any request leaves; the
        // loopback http mock above is the one allowed exception.
        let remote = LLMProvider(id: "r", displayName: "r", baseURL: URL(string: "http://example.com/v1")!,
                                 api: .openAIChat, model: "m")
        let r5 = await collect(LLMPlanClient(provider: remote, apiKey: "k"), "sse")
        assert(r5.3.contains("plain http"), "http to a remote host: \(r5)")
        print("PASS plain http to a remote host is refused")

        // A redirect must never carry the key or the prompt to another origin
        // (URLSession repeats custom headers like x-api-key and the body).
        let secret = "SECRET-KEY-12345"
        // Anthropic's protocol puts the key in x-api-key, which URLSession does
        // not strip on a redirect the way it does Authorization.
        var keyed = provider()
        keyed.api = .anthropic
        for prompt in ["redirect", "redirect-port"] {
            let refused = await collect(LLMPlanClient(provider: keyed, apiKey: secret), prompt)
            precondition(refused.3.contains("redirected"), "\(prompt) must be refused with a reason: \(refused)")
            let seen = await captured()
            precondition(seen.isEmpty, "\(prompt): the second listener received a request: \(seen)")
        }
        // The same for the key-bearing GET the form and MANVI make.
        var listing = URLRequest(url: URL(string: "http://127.0.0.1:\(mainPort)/redirect/v1/models")!)
        listing.setValue(secret, forHTTPHeaderField: "x-api-key")
        listing.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        do {
            _ = try await ProviderHTTP.data(for: listing)
            preconditionFailure("a redirected model listing must fail")
        } catch let problem as ProviderURL.Problem {
            precondition(problem == .redirected(host: "localhost."), "\(problem)")
        } catch {
            preconditionFailure("wrong error: \(error)")
        }
        let afterListing = await captured()
        precondition(afterListing.isEmpty, "the listing's key reached the second listener: \(afterListing)")
        print("PASS a redirect to another origin is refused; the key and prompt never reach it")

        // Inside the origin a redirect is fine.
        let same = await collect(LLMPlanClient(provider: provider(), apiKey: secret), "redirect-same")
        precondition(same.0 == "3.2 GB can go" && same.1 == 2, "same-origin redirect: \(same)")
        print("PASS a same-origin redirect is followed")

        // Origin comparison: scheme, host and effective port.
        func url(_ s: String) -> URL { URL(string: s)! }
        precondition(ProviderURL.sameOrigin(url("https://a.example/x"), url("HTTPS://A.example:443/y")))
        precondition(!ProviderURL.sameOrigin(url("https://a.example"), url("http://a.example")))
        precondition(!ProviderURL.sameOrigin(url("http://127.0.0.1:1"), url("http://127.0.0.1:2")))
        precondition(!ProviderURL.sameOrigin(url("http://127.0.0.1"), url("http://localhost")))
        precondition(!ProviderURL.sameOrigin(url("http://localhost"), url("http://localhost.")))
        print("PASS origin comparison")

        // Malformed replies must return nil, not crash (the bounds of the
        // brace span can invert; this regressed once).
        let junk: [String] = ["}{", "}", "{", "", "no braces here", "{\"items\":[]", "}items{"]
        for text in junk {
            assert(PlanJSON.decode(text: text) == nil, "junk decoded: \(text)")
        }
        print("PASS malformed replies return nil")

        print("ALL OK")
    }
}
