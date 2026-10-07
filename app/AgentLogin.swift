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

    /// Runs the CLI on a terminal when the system can allocate one, reads
    /// everything it prints, and opens the first allowlisted authorize URL.
    /// `onStart` runs on the main actor once the process is up, so cancel can
    /// still terminate it.
    @MainActor
    static func run(executable: String, arguments: [String], environmentPath: String,
                    currentDirectory: String, open: @escaping @Sendable (URL) -> Void,
                    onStart: ((Process) -> Void)? = nil) async -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = environmentPath
        // A traced or CI shell must not change the sign-in transcript.
        environment["SHELLOPTS"] = nil
        environment["BASH_ENV"] = nil
        environment["ENV"] = nil
        environment["CI"] = nil
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        let session = AgentLoginSession(process: process, open: open)
        session.start()
        do {
            try process.run()
        } catch {
            session.abort()
            return Result(status: -1, detail: error.localizedDescription)
        }
        onStart?(process)
        session.afterLaunch()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session.wait()
                c.resume()
            }
        }
        return session.result
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

/// Stdio for one sign-in. A terminal makes `isatty` true, which is what the
/// CLIs check before they will open a browser themselves; pipes still carry
/// the URL when a terminal cannot be allocated.
private nonisolated final class AgentLoginSession: @unchecked Sendable {
    private let process: Process
    private let tail = LoginTail()
    private let transcript: LoginTranscript
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var master: Int32 = -1
    /// Parent's copy of the terminal. Closed after launch so the child's copy
    /// is the one that keeps the session open.
    private var slaveHandle: FileHandle?
    private var pipes: [Pipe] = []
    private var streams = 0
    private var finished = false
    private var started = false

    init(process: Process, open: @escaping @Sendable (URL) -> Void) {
        self.process = process
        self.transcript = LoginTranscript(open: open)
        if let pty = PTY.open() {
            master = pty.master
            let handle = FileHandle(fileDescriptor: pty.slave, closeOnDealloc: false)
            slaveHandle = handle
            process.standardInput = handle
            process.standardOutput = handle
            process.standardError = handle
            streams = 1
        } else {
            let out = Pipe()
            let err = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = err
            pipes = [out, err]
            streams = 2
        }
        group.enter()
    }

    func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        let master = master
        let pipes = pipes
        lock.unlock()
        if master >= 0 {
            read(master)
        } else {
            for pipe in pipes {
                let fd = Darwin.dup(pipe.fileHandleForReading.fileDescriptor)
                if fd >= 0 { read(fd) }
                else { streamEnded() }
            }
        }
    }

    /// The child has the terminal (or the pipe write ends) now. Closing the
    /// parent's copies is what lets the reader see EOF when the CLI exits.
    func afterLaunch() {
        let handle = slaveHandle
        slaveHandle = nil
        handle?.closeFile()
        for pipe in pipes {
            try? pipe.fileHandleForWriting.close()
        }
    }

    func wait() {
        process.waitUntilExit()
        group.wait()
    }

    func abort() {
        afterLaunch()
        group.wait()
    }

    var result: AgentLogin.Result {
        let status = process.terminationStatus
        return AgentLogin.Result(status: status, detail: AgentLogin.detail(from: tail.last, status: status))
    }

    private func read(_ fd: Int32) {
        let transcript = transcript
        let tail = tail
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            defer {
                handle.closeFile()
                self.streamEnded()
            }
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    transcript.flush()
                    break
                }
                transcript.feed(data)
                tail.feed(data)
            }
        }
    }

    private func streamEnded() {
        lock.lock()
        streams -= 1
        let done = streams <= 0 && !finished
        if done { finished = true }
        lock.unlock()
        if done { group.leave() }
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

private nonisolated enum PTY {
    struct Ends { var master: Int32; var slave: Int32 }

    static func open() -> Ends? {
        let master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard master >= 0 else { return nil }
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            Darwin.close(master)
            return nil
        }
        let slaveName = String(cString: name)
        let slave = Darwin.open(slaveName, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            Darwin.close(master)
            return nil
        }
        let flags = fcntl(slave, F_GETFD)
        if flags >= 0 { _ = fcntl(slave, F_SETFD, flags | FD_CLOEXEC) }
        return Ends(master: master, slave: slave)
    }
}
