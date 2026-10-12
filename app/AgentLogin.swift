import Darwin
import Foundation

/// The authorize page a Claude or Codex CLI prints while it waits for the
/// browser to come back. Anything else in that transcript stays closed.
nonisolated enum AgentLogin {
    struct Result: Sendable, Equatable {
        var status: Int32
        /// A short CLI error with the authorize URL removed. Nil when it exited 0.
        var detail: String?
    }

    private static let hosts = ["claude.com", "claude.ai", "anthropic.com", "openai.com", "chatgpt.com"]
    private static let segments: Set<String> = ["oauth", "authorize", "device"]

    /// First https authorize URL in `transcript`.
    /// While more output may still arrive, pass `requireTerminator` so a URL
    /// cut off mid-query is not opened early.
    nonisolated static func url(in transcript: String, requireTerminator: Bool = false) -> URL? {
        // CRLF is one Swift character, so turn it into a newline before scanning.
        let text = stripANSI(transcript)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var search = text.startIndex
        while let range = text.range(of: "https://", range: search..<text.endIndex) {
            var end = range.lowerBound
            var terminated = false
            while end < text.endIndex {
                if isTerminator(text[end]) {
                    terminated = true
                    break
                }
                end = text.index(after: end)
            }
            // The tail may be a URL the next read will finish.
            if !terminated, requireTerminator { return nil }
            var raw = String(text[range.lowerBound..<end])
            while let last = raw.last, ".,;\"')>]".contains(last) { raw.removeLast() }
            if let url = allowlisted(raw) { return url }
            guard terminated, end < text.endIndex else { break }
            search = text.index(after: end)
        }
        return nil
    }

    nonisolated static func detail(from last: String, status: Int32) -> String? {
        guard status != 0 else { return nil }
        var line = stripANSI(last).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return "exit \(status)" }
        if line.contains("https://") || line.contains("http://") {
            line = withoutURLs(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { return "exit \(status)" }
        }
        if line.count > 180 { line = String(line.prefix(180)) }
        return line
    }

    /// Runs the CLI on a terminal when the system can allocate one (pipes
    /// otherwise), reads everything it prints, and opens the first
    /// allowlisted authorize URL. The wait is bounded by `timeout` and by the
    /// shared helper's drain grace once the CLI has exited (a grandchild that
    /// keeps the terminal open cannot hold the sign-in up), and cancelling the
    /// calling task terminates the CLI.
    @MainActor
    static func run(executable: String, arguments: [String], environmentPath: String,
                    currentDirectory: String, open: @escaping @Sendable (URL) -> Void,
                    timeout: TimeInterval = 900) async -> Result {
        var environment = Subprocess.environment(path: environmentPath)
        // A traced or CI shell must not change the sign-in transcript.
        environment["SHELLOPTS"] = nil
        environment["BASH_ENV"] = nil
        environment["ENV"] = nil
        environment["CI"] = nil
        let transcript = LoginTranscript(open: open)
        let tail = LoginTail()
        let sink = Subprocess.Sink.stream { data in
            transcript.feed(data)
            tail.feed(data)
        }
        let spec = Subprocess.Spec(executable, arguments, environment: environment,
                                   directory: currentDirectory, terminal: true)
        let outcome = await Subprocess.run(spec, stdout: sink, stderr: sink, timeout: timeout)
        transcript.flush()
        if let error = outcome.launchError { return Result(status: -1, detail: error) }
        if outcome.cancelled { return Result(status: -1, detail: "cancelled") }
        if outcome.timedOut { return Result(status: -1, detail: "timed out after \(Int(timeout)) seconds") }
        return Result(status: outcome.status, detail: detail(from: tail.last, status: outcome.status))
    }

    private nonisolated static func allowlisted(_ raw: String) -> URL? {
        guard (1...8192).contains(raw.count), raw.hasPrefix("https://") else { return nil }
        guard let parts = URLComponents(string: raw), parts.scheme == "https" else { return nil }
        if parts.user != nil || parts.password != nil { return nil }
        guard let host = parts.host?.lowercased(), hostAllowed(host) else { return nil }
        let partsOfPath = parts.path.lowercased().split(separator: "/").map(String.init)
        guard partsOfPath.contains(where: { segments.contains($0) }) else { return nil }
        return parts.url
    }

    private nonisolated static func hostAllowed(_ host: String) -> Bool {
        hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private nonisolated static func isTerminator(_ ch: Character) -> Bool {
        ch.isWhitespace || "\"'<>`".contains(ch)
    }

    private nonisolated static func stripANSI(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\u{1B}" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "[" {
                    var cursor = text.index(after: next)
                    while cursor < text.endIndex {
                        let ch = text[cursor]
                        cursor = text.index(after: cursor)
                        if ch.isLetter { break }
                    }
                    index = cursor
                    continue
                }
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        return out
    }

    /// Drops http(s) tokens so a failure line can be shown without a URL.
    private nonisolated static func withoutURLs(_ text: String) -> String {
        var out = ""
        var search = text.startIndex
        while search < text.endIndex {
            let http = text.range(of: "http://", range: search..<text.endIndex)
            let https = text.range(of: "https://", range: search..<text.endIndex)
            let range: Range<String.Index>?
            switch (http, https) {
            case let (a?, b?): range = a.lowerBound <= b.lowerBound ? a : b
            case let (a?, nil): range = a
            case let (nil, b?): range = b
            default: range = nil
            }
            guard let range else {
                out += text[search...]
                break
            }
            out += text[search..<range.lowerBound]
            var end = range.upperBound
            while end < text.endIndex, !isTerminator(text[end]) { end = text.index(after: end) }
            search = end
        }
        return out
    }
}
/// Keeps the sign-in transcript and opens the first allowlisted URL once.
private nonisolated final class LoginTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var opened = false
    private let open: @Sendable (URL) -> Void
    private let cap = 256 * 1024

    init(open: @escaping @Sendable (URL) -> Void) { self.open = open }

    func feed(_ chunk: Data) { consume(chunk, flushed: false) }

    func flush() { consume(Data(), flushed: true) }

    private func consume(_ chunk: Data, flushed: Bool) {
        let found: URL? = {
            lock.lock()
            defer { lock.unlock() }
            if !chunk.isEmpty, data.count < cap {
                data.append(chunk.prefix(cap - data.count))
            }
            guard !opened else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            guard let url = AgentLogin.url(in: text, requireTerminator: !flushed) else { return nil }
            opened = true
            return url
        }()
        if let found { open(found) }
    }
}

/// Last non-empty line of a sign-in transcript, for the failure message.
private nonisolated final class LoginTail: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func feed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        text = String((text + String(decoding: data, as: UTF8.self)).suffix(2000))
    }

    /// The last line a person can read. Authorize URLs are not the error.
    /// A terminal writes CRLF, and Swift treats that pair as one character, so
    /// splitting on a line feed alone would keep the whole transcript as one line.
    var last: String {
        lock.lock()
        defer { lock.unlock() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { continue }
            if trimmed.contains("Paste code here") { continue }
            return trimmed
        }
        return ""
    }
}
