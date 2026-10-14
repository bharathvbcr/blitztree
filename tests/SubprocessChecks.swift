import Darwin
import Foundation

/// The shared subprocess helper and what is built on it: SIGPIPE, a bounded
/// and cancellable wait that reaps the child, no leaked reader thread or
/// descriptor when a grandchild holds a pipe, the install script, and many
/// children at once. Real children throughout; nothing outside a temp folder
/// is touched except the cleanup tool's stand-in project folder that
/// runCommand always uses.
@main
struct SubprocessChecks {
    static func main() async {
        // The app ignores SIGPIPE in Main.swift, which these binaries never
        // run: the default disposition is what proves the helper is safe alone.
        signal(SIGPIPE, SIG_DFL)
        raiseDescriptorLimit()
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("blitztree-subprocess-\(UUID().uuidString)")
        try! fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        readSteps()
        await sigpipe()
        await cancelReapsChild(base)
        await commandCancelAndTimeout(base)
        await timeoutIsBounded(base)
        await descendantsStop(base)
        await failedStartLeavesNoDanglingInput(base)
        await terminalTakesNoInput()
        await outputs(base)
        await grandchildHoldingPipe()
        await terminal()
        await installScript(base)
        await declinedInstall()
        await stress()
        print("SubprocessChecks passed")
    }

    // MARK: Measuring

    private static func descriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    private static func threadCount() -> Int {
        var list: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                      vm_size_t(Int(count) * MemoryLayout<thread_act_t>.size))
        return Int(count)
    }

    private static func raiseDescriptorLimit() {
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        limit.rlim_cur = min(limit.rlim_max, 4096)
        setrlimit(RLIMIT_NOFILE, &limit)
    }

    private static func gone(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    /// Polls for the process to disappear (a worker killed with its group is
    /// reparented and reaped by launchd a moment later).
    private static func goneSoon(_ pid: pid_t, seconds: Double = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if gone(pid) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return gone(pid)
    }

    private static func waitForFile(_ url: URL, seconds: Double = 5) async -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    // MARK: Reads

    /// A terminal master reports the child's exit as EIO; that is the end of
    /// the stream, not an error to raise.
    private static func readSteps() {
        precondition(Subprocess.readStep(7, errno: 0) == .data)
        precondition(Subprocess.readStep(0, errno: 0) == .end, "EOF")
        precondition(Subprocess.readStep(-1, errno: EIO) == .end, "EIO on a pty master is end of file")
        precondition(Subprocess.readStep(-1, errno: EAGAIN) == .wouldBlock)
        precondition(Subprocess.readStep(-1, errno: EINTR) == .retry)
        precondition(Subprocess.readStep(-1, errno: EBADF) == .end, "a broken descriptor ends the stream")
    }

    // MARK: SIGPIPE

    private static func sigpipe() async {
        let prompt = Data(repeating: 0x41, count: 256 * 1024)
        // The old probe path: a >64 KB input to a child that exits at once.
        let legacy = AgentLocator.run("/usr/bin/true", [], input: prompt)
        precondition(legacy.status == 0, "legacy run survived a prompt the child never read")
        let one = await Subprocess.run(Subprocess.Spec("/usr/bin/true", input: .data(prompt)))
        precondition(one.started && one.status == 0, "a prompt the child never reads must not kill us: \(one)")
        // A child that outlives the write for a moment, then exits with data still queued.
        let slow = await Subprocess.run(
            Subprocess.Spec("/bin/sh", ["-c", "sleep 0.3"], input: .data(Data(repeating: 0x42, count: 4 << 20))),
            timeout: 10)
        precondition(slow.started && slow.finished && slow.status == 0, "unread megabytes then exit: \(slow)")
        // Streaming input, written after the child is already gone.
        let box = FinishBox()
        let job = Subprocess.Job(Subprocess.Spec("/usr/bin/true", input: .open))
        job.onFinish = { box.set($0) }
        try! job.start()
        let finished = await box.wait()
        precondition(finished != nil, "the job finished")
        job.write(prompt)
        job.closeInput()
        try? await Task.sleep(for: .milliseconds(100))
        // A child that never reads and never exits cannot hold the writer or the wait forever.
        let began = Date()
        let stuck = await Subprocess.run(
            Subprocess.Spec("/bin/sh", ["-c", "sleep 30"], input: .data(Data(repeating: 0x43, count: 4 << 20))),
            timeout: 1)
        precondition(stuck.timedOut && Date().timeIntervalSince(began) < 6, "bounded: \(stuck)")
        print("PASS SIGPIPE: >64 KB written to children that exit or never read")
    }

    // MARK: Cancellation

    private static func cancelReapsChild(_ base: URL) async {
        for (name, script) in [
            ("term", "echo $$ > PIDFILE; exec sleep 60"),
            // Ignores SIGTERM: only the SIGKILL escalation ends it.
            ("stubborn", "trap '' TERM; echo $$ > PIDFILE; while :; do sleep 0.2; done"),
            // A shell with two background workers: they must die with it.
            ("group", "echo $$ > PIDFILE; /bin/sleep 60 & echo $! > GPID1; /bin/sleep 61 & echo $! > GPID2; wait"),
            // Workers that also ignore SIGTERM (inherited), killed with the group.
            ("stubborn group", "trap '' TERM; echo $$ > PIDFILE; /bin/sleep 62 & echo $! > GPID1; /bin/sleep 63 & echo $! > GPID2; while :; do /bin/sleep 0.2; done"),
        ] {
            let tag = name.replacingOccurrences(of: " ", with: "-")
            let pidFile = base.appendingPathComponent("pid-\(tag)")
            let grand1 = base.appendingPathComponent("gpid1-\(tag)"), grand2 = base.appendingPathComponent("gpid2-\(tag)")
            let task = Task {
                await Subprocess.run(
                    Subprocess.Spec("/bin/sh", ["-c", script.replacingOccurrences(of: "PIDFILE", with: pidFile.path)
                        .replacingOccurrences(of: "GPID1", with: grand1.path)
                        .replacingOccurrences(of: "GPID2", with: grand2.path)]),
                    timeout: 120)
            }
            let text = await waitForFile(pidFile)
            precondition(text != nil, "\(name): the child started")
            let pid = pid_t(text!.trimmingCharacters(in: .whitespacesAndNewlines))!
            precondition(kill(pid, 0) == 0, "\(name): running before cancel")
            var grandchildren: [pid_t] = []
            if name.contains("group") {
                for file in [grand1, grand2] {
                    let text = await waitForFile(file)
                    precondition(text != nil, "\(name): a worker started")
                    grandchildren.append(pid_t(text!.trimmingCharacters(in: .whitespacesAndNewlines))!)
                }
                precondition(grandchildren.allSatisfy { kill($0, 0) == 0 }, "\(name): workers running before cancel")
            }
            let began = Date()
            task.cancel()
            let outcome = await task.value
            let took = Date().timeIntervalSince(began)
            precondition(outcome.cancelled && outcome.started, "\(name): reported cancelled: \(outcome)")
            precondition(gone(pid), "\(name): the child is gone and reaped, not a zombie (kill 0 -> ESRCH)")
            precondition(took < 6, "\(name): cancellation is bounded, took \(took)s")
            for worker in grandchildren {
                let dead = await goneSoon(worker)
                precondition(dead, "\(name): worker \(worker) outlived its cancelled parent")
            }
            print("PASS cancel \(name): child \(pid) \(grandchildren.isEmpty ? "" : "and workers \(grandchildren) ")terminated and reaped in \(String(format: "%.2f", took))s")
        }
        // Cancelled before it ever started: nothing is spawned.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Subprocess.run(Subprocess.Spec("/bin/sh", ["-c", "sleep 30"]))
        }
        let outcome = await early.value
        precondition(outcome.cancelled && !outcome.started && outcome.pid == 0, "no spawn when already cancelled: \(outcome)")
    }

    /// runCommand: the path the Clean Up delete step uses, with a stand-in
    /// `uv` that sleeps. Its limit is injected so the 600 s path can be tested.
    private static func commandCancelAndTimeout(_ base: URL) async {
        let tools = base.appendingPathComponent("tools")
        try! FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let pidFile = base.appendingPathComponent("pid-command")
        let uv = tools.appendingPathComponent("uv")
        try! "#!/bin/sh\necho $$ > \(pidFile.path)\nexec /bin/sleep 60\n".write(to: uv, atomically: true, encoding: .utf8)
        chmod(uv.path, 0o755)

        let began = Date()
        let timedOut = await AgentRun.runCommand("uv cache clean", path: tools.path, timeout: 1)
        let took = Date().timeIntervalSince(began)
        precondition(timedOut?.text == String(localized: "Took too long"), "the limit ends it: \(timedOut?.text ?? "nil")")
        precondition(took < 5, "bounded by the injected timeout, took \(took)s")
        let stalled = pid_t(try! String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        precondition(gone(stalled), "the timed-out tool is reaped")
        try? FileManager.default.removeItem(at: pidFile)

        let task = Task { await AgentRun.runCommand("uv cache clean", path: tools.path) }
        let pid = pid_t((await waitForFile(pidFile))!.trimmingCharacters(in: .whitespacesAndNewlines))!
        let cancelAt = Date()
        task.cancel()
        let result = await task.value
        precondition(result?.text == String(localized: "Cancelled"), "a cancelled delete says so: \(result?.text ?? "nil")")
        precondition(gone(pid), "cancelling runCommand terminates and reaps the tool")
        precondition(Date().timeIntervalSince(cancelAt) < 5, "prompt cancellation")
        print("PASS runCommand: injected timeout bounded (\(String(format: "%.2f", took))s), cancel reaps \(pid)")
    }

    /// The limit and Cancel stop the whole tree, not just the shell: an
    /// installer's `curl`, a tool's workers.
    private static func descendantsStop(_ base: URL) async {
        let g1 = base.appendingPathComponent("tree-1"), g2 = base.appendingPathComponent("tree-2")
        let script = "/bin/sleep 30 & echo $! > \(g1.path); /bin/sleep 31 & echo $! > \(g2.path); wait"
        let began = Date()
        let timed = await Subprocess.run(Subprocess.Spec("/bin/sh", ["-c", script]), timeout: 1)
        precondition(timed.timedOut && Date().timeIntervalSince(began) < 5, "\(timed)")
        for file in [g1, g2] {
            let pid = pid_t((try! String(contentsOf: file, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))!
            let dead = await goneSoon(pid)
            precondition(dead, "a worker (\(pid)) outlived the timeout of its parent shell")
        }
        // The install script is the same kind of tree (curl under bash).
        let g3 = base.appendingPathComponent("tree-3")
        let install = Task { await AgentSetup.runInstall("/bin/sleep 40 & echo $! > \(g3.path); wait") }
        let text = await waitForFile(g3)
        precondition(text != nil)
        let worker = pid_t(text!.trimmingCharacters(in: .whitespacesAndNewlines))!
        install.cancel()
        let error = await install.value
        precondition(error == String(localized: "The installation was cancelled."), "\(error ?? "nil")")
        let dead = await goneSoon(worker)
        precondition(dead, "cancelling an install left its download running (\(worker))")
        print("PASS timeout and cancel stop the whole process tree, installer included")
    }

    /// A start that fails halfway closes what it opened; nothing may later
    /// write to a descriptor number that now belongs to someone else.
    private static func failedStartLeavesNoDanglingInput(_ base: URL) async {
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        var original = limit
        let highest = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []).compactMap { Int($0) }.max() ?? 3
        // The old spare loop only lowered the soft limit. Holes below the
        // highest live descriptor still let pipe() succeed, so the check
        // never ran. Fill every free slot under a small ceiling instead.
        var ceiling = original
        ceiling.rlim_cur = min(original.rlim_max, rlim_t(highest + 16))
        precondition(setrlimit(RLIMIT_NOFILE, &ceiling) == 0,
                     "could not lower RLIMIT_NOFILE to \(ceiling.rlim_cur) (errno \(errno))")
        var fillers: [Int32] = []
        defer {
            for fd in fillers { Darwin.close(fd) }
            setrlimit(RLIMIT_NOFILE, &original)
        }
        while true {
            let fd = Darwin.open("/dev/null", O_RDONLY)
            if fd < 0 { break }
            fillers.append(fd)
        }
        // Two free numbers: the input pipe is created, the stdout pipe is not,
        // and start() has to drop the write end it just kept.
        precondition(fillers.count >= 2, "the descriptor table had no free slot to fill")
        Darwin.close(fillers.removeLast())
        Darwin.close(fillers.removeLast())

        let job = Subprocess.Job(Subprocess.Spec("/bin/cat", input: .open), stdout: .capture(cap: 100))
        var failed = false
        do { try job.start() } catch { failed = true }
        if !failed { job.terminate() }
        precondition(failed, "start succeeded with only one pipe's worth of descriptors left")

        // Room for the files that reuse the numbers the failed start closed.
        setrlimit(RLIMIT_NOFILE, &original)
        var files: [(URL, FileHandle)] = []
        for index in 0..<4 {
            let file = base.appendingPathComponent("reused-\(index)")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            files.append((file, try! FileHandle(forWritingTo: file)))
        }
        job.write(Data("intruder".utf8))
        job.closeInput()
        try? await Task.sleep(for: .milliseconds(100))
        for (file, handle) in files {
            precondition(fcntl(handle.fileDescriptor, F_GETFD) != -1, "the dead job closed someone else's descriptor")
            try? handle.close()
            let content = try! String(contentsOf: file, encoding: .utf8)
            precondition(content.isEmpty, "the dead job wrote into a reused descriptor: \(content)")
        }
        print("PASS a failed start leaves no input descriptor to misuse")
    }

    private static func terminalTakesNoInput() async {
        let outcome = await Subprocess.run(
            Subprocess.Spec("/bin/cat", input: .data(Data("x".utf8)), terminal: true), timeout: 5)
        precondition(!outcome.started && outcome.launchError?.contains("no separate input") == true,
                     "terminal plus input is refused loudly: \(outcome)")
        print("PASS a terminal run with separate input is refused, not silently ignored")
    }

    private static func timeoutIsBounded(_ base: URL) async {
        let began = Date()
        let outcome = await Subprocess.run(Subprocess.Spec("/bin/sh", ["-c", "sleep 30"]), timeout: 1)
        precondition(outcome.timedOut && !outcome.cancelled, "\(outcome)")
        precondition(Date().timeIntervalSince(began) < 5)
        precondition(gone(outcome.pid), "reaped after the timeout")
        let stubborn = Date()
        let hard = await Subprocess.run(
            Subprocess.Spec("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 0.2; done"]), timeout: 1)
        precondition(hard.timedOut && gone(hard.pid), "SIGKILL after the grace: \(hard)")
        precondition(Date().timeIntervalSince(stubborn) < 6)
        let sync = Date()
        let blocking = Subprocess.runBlocking(Subprocess.Spec("/bin/sh", ["-c", "sleep 30"]), timeout: 1)
        precondition(blocking.timedOut && Date().timeIntervalSince(sync) < 5, "the synchronous face is bounded too")
        print("PASS timeouts bounded: terminate, then kill")
    }

    /// Output edge cases: more than the cap, binary, stdout closed early,
    /// the environment and folder passed through.
    private static func outputs(_ base: URL) async {
        let flood = await Subprocess.run(
            Subprocess.Spec("/bin/sh", ["-c", "/usr/bin/yes | /usr/bin/head -c 20000000"]),
            stdout: .capture(cap: 1024), timeout: 20)
        precondition(flood.finished && flood.status == 0 && flood.overflow && flood.stdout.count == 1024,
                     "a flood is capped, flagged, and never stalls the child: \(flood.stdout.count) bytes, \(flood)")
        let binary = await Subprocess.run(Subprocess.Spec("/usr/bin/printf", ["\\377\\376ok"]))
        precondition(binary.stdout == Data([0xFF, 0xFE, 0x6F, 0x6B]) && !binary.overflow, "bytes arrive untouched")
        let closed = await Subprocess.run(Subprocess.Spec("/bin/sh", ["-c", "exec >&-; sleep 0.5; exit 3"]), timeout: 10)
        precondition(closed.status == 3 && closed.finished && !closed.leaked, "stdout closed early, exit still seen: \(closed)")
        let env = await Subprocess.run(
            Subprocess.Spec("/bin/sh", ["-c", "echo $BZ_PROBE; pwd -P"], environment: ["PATH": "/usr/bin:/bin", "BZ_PROBE": "seen"],
                            directory: base.path))
        precondition(env.output.hasPrefix("seen\n") && env.output.hasSuffix(base.lastPathComponent + "\n"), "environment replaced, folder honoured: \(env.output.debugDescription)")
        let missing = await Subprocess.run(Subprocess.Spec(base.path + "/no-such-program"))
        precondition(!missing.started && missing.launchError != nil && missing.pid == 0, "\(missing)")
        let failing = await Subprocess.run(Subprocess.Spec("/bin/sh", ["-c", "echo oops >&2; exit 7"]), stderr: .capture(cap: 100))
        precondition(failing.status == 7 && String(decoding: failing.stderr, as: UTF8.self) == "oops\n", "\(failing)")
        let killed = await Subprocess.run(Subprocess.Spec("/bin/sh", ["-c", "kill -KILL $$"]))
        precondition(killed.signaled && killed.status == SIGKILL, "a signal death is reported as such: \(killed)")
        print("PASS output: capped flood, raw bytes, early close, environment, folder, launch failure, signal death")
    }

    // MARK: Leaks

    /// A shell that leaves a background child holding the pipe: the old
    /// reader parked a thread and an fd on it for as long as it lived.
    private static func grandchildHoldingPipe() async {
        let jobs = 20
        let fdsBefore = descriptorCount(), threadsBefore = threadCount()

        let legacyBegan = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<jobs {
                group.addTask {
                    let result = await AgentLocator.onBackgroundThread { AgentLocator.run("/bin/sh", ["-c", "sleep 4 & echo x"]) }
                    precondition(result.out == "x\n", "output before the leak: \(result.out.debugDescription)")
                }
            }
        }
        let fdsLegacy = descriptorCount(), threadsLegacy = threadCount()
        precondition(fdsLegacy <= fdsBefore + 2,
                     "AgentLocator.run leaked descriptors: \(fdsBefore) -> \(fdsLegacy) after \(jobs) calls")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<jobs {
                group.addTask {
                    let outcome = await Subprocess.run(Subprocess.Spec("/bin/sh", ["-c", "sleep 4 & echo x"]))
                    precondition(outcome.output == "x\n" && outcome.leaked && outcome.status == 0, "\(outcome)")
                }
            }
        }
        let fdsAfter = descriptorCount(), threadsAfter = threadCount()
        precondition(fdsAfter <= fdsBefore + 2, "Subprocess.run leaked descriptors: \(fdsBefore) -> \(fdsAfter)")
        precondition(threadsAfter <= threadsLegacy + 4, "the async wave grew the thread count: \(threadsLegacy) -> \(threadsAfter)")
        print("PASS grandchild holds the pipe: \(jobs) x2 calls, fds \(fdsBefore) -> \(fdsLegacy) -> \(fdsAfter), "
              + "threads \(threadsBefore) -> \(threadsLegacy) -> \(threadsAfter), "
              + "first wave \(String(format: "%.1f", Date().timeIntervalSince(legacyBegan)))s")
    }

    private static func terminal() async {
        let tty = await Subprocess.run(
            Subprocess.Spec("/bin/sh", ["-c", "if [ -t 0 ] && [ -t 1 ] && [ -t 2 ]; then echo tty; else echo pipe; fi"], terminal: true),
            timeout: 10)
        precondition(tty.output.contains("tty"), "terminal mode gives the child a terminal on all three: \(tty.output)")
        let began = Date()
        let held = await Subprocess.run(
            Subprocess.Spec("/bin/sh", ["-c", "sleep 4 & echo hi"], terminal: true), timeout: 10)
        precondition(held.output.contains("hi") && held.status == 0, "\(held)")
        precondition(Date().timeIntervalSince(began) < 3.9, "a grandchild holding the terminal does not hold the wait")
        print("PASS terminal: tty on all three, a grandchild holding it is not waited for")
    }

    // MARK: Install script

    private static func installScript(_ base: URL) async {
        let plan = AgentSetup.installPlan(.claude)!
        precondition(plan.needsConfirmation && plan.source == "https://claude.ai/install.sh")
        precondition(plan.script.contains(plan.source), "the confirmation shows the URL it will fetch")
        precondition(!plan.script.contains("| bash") && !plan.script.contains("|bash"), "never piped into a shell")
        precondition(plan.script.contains("-o \"$t/install.sh\""), "downloaded to a temp file")
        precondition(AgentSetup.installPlan(.codex)?.needsConfirmation == false, "Codex stays checksum-pinned")
        precondition(AgentSetup.installPlan(.manvi) == nil)

        let source = base.appendingPathComponent("installer.sh")
        let marker = base.appendingPathComponent("ran")
        try! "echo ran > \(marker.path)\n".write(to: source, atomically: true, encoding: .utf8)
        let ok = await AgentSetup.runInstall(AgentSetup.claudeInstallScript(url: "file://" + source.path))
        precondition(ok == nil && FileManager.default.fileExists(atPath: marker.path), "a good download runs: \(ok ?? "nil")")
        try? FileManager.default.removeItem(at: marker)

        // A failed download must not run anything, and must be reported as failed.
        let missing = await AgentSetup.runInstall(AgentSetup.claudeInstallScript(url: "file://" + base.path + "/missing.sh"))
        precondition(missing != nil && !FileManager.default.fileExists(atPath: marker.path), "failed download: \(missing ?? "nil")")
        let empty = base.appendingPathComponent("empty.sh")
        try! Data().write(to: empty)
        let blank = await AgentSetup.runInstall(AgentSetup.claudeInstallScript(url: "file://" + empty.path))
        precondition(blank?.contains("empty") == true, "an empty download is refused: \(blank ?? "nil")")
        let slow = await AgentSetup.runInstall("sleep 30", timeout: 1)
        precondition(slow == String(localized: "The installation timed out after \(1) seconds."),
                     "a stalled install is cut off: \(slow ?? "nil")")
        let status = await AgentSetup.runInstall("exit 9")
        precondition(status == String(localized: "The installer exited with status \(Int(9))."),
                     "a silent failure names the status: \(status ?? "nil")")
        let noisy = await AgentSetup.runInstall("echo 'disk full' >&2; exit 1")
        precondition(noisy == "disk full", "tool output stays as the installer wrote it: \(noisy ?? "nil")")
        print("PASS install script: temp file, no pipe, failures reported, bounded")
    }

    @MainActor
    private static func declinedInstall() async {
        let asked = FinishBox2()
        let setup = AgentSetup(kind: .claude, installed: nil, envPath: "/usr/bin:/bin",
                               confirm: { plan in asked.plan = plan; return false }, done: { _ in
            preconditionFailure("a declined install must not finish")
        })
        let deadline = Date().addingTimeInterval(5)
        while setup.step == .installing, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        guard case .failed(let message) = setup.step else { preconditionFailure("declined: \(setup.step)") }
        precondition(message == String(localized: "Installation was cancelled. Nothing was downloaded or run."), message)
        precondition(asked.plan?.source == "https://claude.ai/install.sh", "asked with the exact URL")
        let alert = AgentSetup.installAlert(asked.plan!)
        precondition(alert.informativeText.contains("https://claude.ai/install.sh")
                     && alert.informativeText.contains(asked.plan!.script), "the alert shows the URL and the command")
        precondition(alert.buttons.map(\.title) == [String(localized: "Cancel"), String(localized: "Download and Run")],
                     "Cancel is the default button")
        print("PASS declined install runs nothing; the alert shows the URL and the exact command")
    }

    // MARK: Many at once

    private static func stress() async {
        let count = 200
        _ = await Subprocess.run(Subprocess.Spec("/bin/echo", ["warm"]))
        let fdsBefore = descriptorCount(), threadsBefore = threadCount()
        let began = Date()
        let ok = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<count {
                group.addTask {
                    let outcome = await Subprocess.run(
                        Subprocess.Spec("/bin/sh", ["-c", "echo out\(i); echo err\(i) >&2"]), stderr: .capture(cap: 1024))
                    return outcome.finished && outcome.status == 0 && !outcome.leaked
                        && outcome.output == "out\(i)\n" && String(decoding: outcome.stderr, as: UTF8.self) == "err\(i)\n"
                }
            }
            var all = true
            for await good in group { all = all && good }
            return all
        }
        precondition(ok, "every one of \(count) concurrent children returned its own output")
        DispatchQueue.concurrentPerform(iterations: count) { i in
            let outcome = Subprocess.runBlocking(Subprocess.Spec("/bin/echo", ["n\(i)"]), timeout: 20)
            precondition(outcome.finished && outcome.text == "n\(i)", "\(outcome)")
        }
        try? await Task.sleep(for: .milliseconds(500))
        let fdsAfter = descriptorCount(), threadsAfter = threadCount()
        precondition(fdsAfter == fdsBefore, "descriptors grew: \(fdsBefore) -> \(fdsAfter)")
        precondition(threadsAfter <= threadsBefore + 40, "threads grew: \(threadsBefore) -> \(threadsAfter)")
        print("PASS stress: 2 x \(count) children, fds \(fdsBefore) -> \(fdsAfter), threads \(threadsBefore) -> \(threadsAfter), "
              + "\(String(format: "%.1f", began.timeIntervalSinceNow * -1))s")
    }
}

private nonisolated final class FinishBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Subprocess.Outcome?
    func set(_ value: Subprocess.Outcome) { lock.lock(); outcome = value; lock.unlock() }
    var value: Subprocess.Outcome? { lock.lock(); defer { lock.unlock() }; return outcome }
    func wait() async -> Subprocess.Outcome? {
        for _ in 0..<500 {
            if let value { return value }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

@MainActor
private final class FinishBox2 {
    var plan: AgentSetup.InstallPlan?
}
