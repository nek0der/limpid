// TmuxClientProbeTests.swift
// Limpid — pins how we read a pane's tmux binding out of
// `tmux list-clients`. The parsing tests fix the contract; the smoke
// test asks a real tmux whether we read it correctly, because the
// format string is the part no unit test can validate.

import Foundation
import Testing
@testable import Limpid

private let installedTmux: String? = {
    for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        where FileManager.default.isExecutableFile(atPath: candidate)
    {
        return candidate
    }
    return nil
}()

@Suite("TmuxClientProbe parsing")
struct TmuxClientProbeParsingTests {
    @Test(arguments: ["", ".", "../socket", "relative/socket", "/tmp/socket\u{0}suffix"])
    func socketIdentity_invalidPaths_areRejected(path: String) {
        #expect(TmuxSocketPath(path) == nil)
    }

    @Test("dot-dot follows symlink semantics instead of lexical URL shortening")
    func socketIdentity_symlinkThenParent_matchesPhysicalParent() throws {
        try withTempDir { directory in
            let nested = directory.appendingPathComponent("physical/child")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let alias = directory.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
            #expect(TmuxSocketPath(alias.path + "/../socket") == TmuxSocketPath(directory.path + "/physical/socket"))
        }
    }

    @Test("an existing socket path keeps the same identity on every pass")
    func normalizeSocketPath_existingPath_isIdempotent() throws {
        try withTempDir { directory in
            let path = directory.appendingPathComponent("socket").path
            FileManager.default.createFile(atPath: path, contents: Data())
            let canonical = TmuxClientProbe.normalizeSocketPath(path)
            var repeated = canonical
            for _ in 0..<5 {
                repeated = TmuxClientProbe.normalizeSocketPath(repeated)
            }
            #expect(repeated == canonical)
            #expect(TmuxClientProbe.normalizeSocketPath(canonical) == canonical)
        }
    }

    @Test("custom symlinked directories and their physical paths identify one socket")
    func normalizeSocketPath_customSymlinkAndMissingLeaf_areStable() throws {
        try withTempDir { directory in
            let physical = directory.appendingPathComponent("physical")
            let alias = directory.appendingPathComponent("alias")
            try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
            let physicalPath = physical.appendingPathComponent("socket, with spaces").path
            let aliasPath = alias.appendingPathComponent("socket, with spaces").path
            let before = TmuxClientProbe.normalizeSocketPath(aliasPath)
            #expect(before == TmuxClientProbe.normalizeSocketPath(physicalPath))
            FileManager.default.createFile(atPath: physicalPath, contents: Data())
            #expect(TmuxClientProbe.normalizeSocketPath(aliasPath) == before)
            #expect(TmuxClientProbe.normalizeSocketPath(before) == before)
            try FileManager.default.removeItem(atPath: physicalPath)
            #expect(TmuxClientProbe.normalizeSocketPath(aliasPath) == before)
        }
    }

    @Test("normalizes the macOS /tmp symlink used by tmux")
    func normalizeSocketPath_tmpAndPrivateTmpMatch() {
        #expect(
            TmuxClientProbe.normalizeSocketPath("/tmp/tmux-501/default")
                == TmuxClientProbe.normalizeSocketPath("/private/tmp/tmux-501/default")
        )
    }

    @Test("reads one client per line, keyed by tty")
    func parseClients_singleClient_bindsToItsTTY() {
        let bindings = TmuxClientProbe.parseClients(
            "/dev/ttys016\t$0\tprobe\n",
            socketPath: "/tmp/tmux-501/default"
        )
        #expect(bindings == [
            "/dev/ttys016": TmuxBinding(
                socketPath: "/tmp/tmux-501/default",
                sessionID: "$0",
                sessionName: "probe"
            )
        ])
    }

    /// tmux allows spaces in a session name, so the fields are
    /// tab-separated and only the first two splits are structural.
    @Test("keeps a session name that contains spaces intact")
    func parseClients_nameWithSpaces_isNotSplit() {
        let bindings = TmuxClientProbe.parseClients(
            "/dev/ttys1\t$3\tmy work session\n",
            socketPath: "/tmp/s"
        )
        #expect(bindings["/dev/ttys1"]?.sessionName == "my work session")
    }

    @Test("carries every attached client")
    func parseClients_multipleClients_areAllReturned() {
        let bindings = TmuxClientProbe.parseClients(
            "/dev/ttys1\t$0\ta\n/dev/ttys2\t$1\tb\n",
            socketPath: "/tmp/s"
        )
        #expect(bindings.count == 2)
        #expect(bindings["/dev/ttys2"]?.sessionName == "b")
    }

    @Test("ignores blank and malformed lines rather than failing the batch")
    func parseClients_malformedLines_areSkipped() {
        let bindings = TmuxClientProbe.parseClients(
            "\nnot-a-record\n/dev/ttys1\t$0\tok\n\n",
            socketPath: "/tmp/s"
        )
        #expect(bindings.count == 1)
        #expect(bindings["/dev/ttys1"]?.sessionName == "ok")
    }

    @Test("returns nothing when no client is attached")
    func parseClients_emptyOutput_isEmpty() {
        #expect(TmuxClientProbe.parseClients("", socketPath: "/tmp/s").isEmpty)
    }

    @Test("keeps spaces in an absolute pane path")
    func parsePanePath_absolutePathWithSpaces_isPreserved() {
        #expect(TmuxClientProbe.parsePanePath("/tmp/a project\n") == "/tmp/a project")
        #expect(TmuxClientProbe.parsePanePath("relative/path\n") == nil)
        #expect(TmuxClientProbe.parsePanePath("\n") == nil)
    }
}

@Suite("TmuxClientProbe server directory")
struct TmuxClientProbeServerDirectoryTests {
    @Test("defaults to /tmp, where tmux puts sockets")
    func defaultServerDirectory_noOverride_isUnderTmp() {
        let url = TmuxClientProbe.defaultServerDirectory(environment: [:], uid: 501)
        #expect(url.path == "/tmp/tmux-501")
    }

    @Test("honors TMUX_TMPDIR when we can see one")
    func defaultServerDirectory_override_isHonored() {
        let url = TmuxClientProbe.defaultServerDirectory(
            environment: ["TMUX_TMPDIR": "/var/folders/x"], uid: 42
        )
        #expect(url.path == "/var/folders/x/tmux-42")
    }

    /// Launched from Finder we inherit launchd's environment, where the
    /// variable is absent rather than empty — but a login shell that
    /// exports it blank would otherwise send us to `/tmux-<uid>`.
    @Test("treats an empty TMUX_TMPDIR as unset")
    func defaultServerDirectory_emptyOverride_fallsBackToTmp() {
        let url = TmuxClientProbe.defaultServerDirectory(
            environment: ["TMUX_TMPDIR": ""], uid: 501
        )
        #expect(url.path == "/tmp/tmux-501")
    }
}

@Suite("TmuxClientProbe socket discovery")
struct TmuxClientProbeSocketTests {
    @Test("lists the sockets a tmux server would create")
    func socketPaths_serverDirectory_listsItsSockets() throws {
        try withTempDir { dir in
            let home = dir.appendingPathComponent("tmux-501", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            for name in ["default", "work"] {
                FileManager.default.createFile(
                    atPath: home.appendingPathComponent(name).path, contents: Data()
                )
            }
            let found = TmuxClientProbe.socketPaths(inServerDirectory: home)
                .map(\.lastPathComponent).sorted()
            #expect(found == ["default", "work"])
        }
    }

    @Test("is empty when the user has never started a server")
    func socketPaths_missingDirectory_isEmpty() throws {
        try withTempDir { dir in
            let absent = dir.appendingPathComponent("tmux-501", isDirectory: true)
            #expect(TmuxClientProbe.socketPaths(inServerDirectory: absent).isEmpty)
        }
    }
}

@Suite("TmuxClientProbe tmux discovery")
struct TmuxClientProbeLocateTests {
    /// Existence is not the bar. A `tmux` we cannot execute — a
    /// Homebrew install mid-upgrade, a path the sandbox denies — would
    /// make every probe fail at spawn time instead of being skipped for
    /// the next candidate.
    @Test("skips a candidate that exists but cannot be executed")
    func locateTmux_nonExecutableCandidate_isSkipped() throws {
        try withTempDir { dir in
            let missing = dir.appendingPathComponent("missing").path
            let unrunnable = dir.appendingPathComponent("not-runnable")
            FileManager.default.createFile(
                atPath: unrunnable.path, contents: Data(), attributes: [.posixPermissions: 0o644]
            )
            let real = dir.appendingPathComponent("tmux")
            FileManager.default.createFile(
                atPath: real.path, contents: Data(), attributes: [.posixPermissions: 0o755]
            )
            #expect(
                TmuxClientProbe.locateTmux(
                    candidates: [missing, unrunnable.path, real.path]
                ) == real.path
            )
        }
    }

    /// The user has no tmux, which is the common case; nothing to probe
    /// and nothing to record.
    @Test("is nil when no candidate exists")
    func locateTmux_notInstalled_isNil() {
        #expect(TmuxClientProbe.locateTmux(candidates: ["/nonexistent/tmux"]) == nil)
    }

    /// A GUI app launched from Finder inherits launchd's `PATH`
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), which has no Homebrew in it,
    /// so resolving by name would find nothing on most Macs.
    @Test("looks where package managers actually install tmux")
    func locateTmux_defaults_coverHomebrew() {
        #expect(TmuxClientProbe.tmuxCandidates.contains("/opt/homebrew/bin/tmux"))
        #expect(TmuxClientProbe.tmuxCandidates.contains("/usr/local/bin/tmux"))
    }
}

@Suite(
    "TmuxClientProbe smoke",
    .tags(.smoke),
    .disabled(if: installedTmux == nil && ProcessInfo.processInfo.environment["LIMPID_REQUIRE_TMUX_TESTS"] != "1", "no tmux installed")
)
struct TmuxClientProbeSmokeTests {
    @Test("an unresponsive real server cannot block a later probe")
    func stoppedServer_returnsWithinDeadlineAndRecovers() throws {
        let tmux = try #require(installedTmux)
        let socket = "/private/tmp/limpid-deadline-\(UUID().uuidString.prefix(8)).sock"
        _ = try run(tmux, ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "deadline", "sleep 30"])
        let rawPID = try run(tmux, ["-S", socket, "display-message", "-p", "#{pid}"])
        let pid = try #require(Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)))
        let rescue = DispatchWorkItem { @Sendable in kill(pid, SIGCONT) }
        defer {
            rescue.cancel()
            kill(pid, SIGCONT)
            _ = try? run(tmux, ["-S", socket, "kill-server"])
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: rescue)
        kill(pid, SIGSTOP)
        let start = ProcessInfo.processInfo.systemUptime
        let stopped = TmuxClientProbe.topology(tmuxPath: tmux, socketPaths: [URL(fileURLWithPath: socket)], timeout: 0.1)
        #expect(ProcessInfo.processInfo.systemUptime - start < 1.5)
        #expect(stopped.outcomes[socket] == .timedOut)
        kill(pid, SIGCONT)
        let recovered = TmuxClientProbe.topology(tmuxPath: tmux, socketPaths: [URL(fileURLWithPath: socket)])
        #expect(recovered.panes.count == 1)
    }

    @Test("a real socket survives discovery, parsing, and endpoint matching")
    func topology_realSocket_roundTripsThroughEveryBoundary() throws {
        let tmux = try #require(installedTmux)
        let socket = "/private/tmp/limpid-runtime-\(UUID().uuidString.prefix(8)).sock"
        defer { _ = try? run(tmux, ["-S", socket, "kill-server"]) }
        _ = try run(tmux, ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "runtime", "sleep 120"])
        let raw = try run(tmux, ["-S", socket, "display-message", "-p", "#{pid}\t#{start_time}\t#{pane_id}"])
        let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t").map(String.init)
        #expect(fields.count == 3)
        guard fields.count == 3 else { return }
        let endpoint = TmuxRuntimeEndpoint(socketPath: socket, serverPID: fields[0], serverStartedAt: fields[1], paneID: fields[2])
        let discovered = TmuxClientProbe.normalizeSocketPath(socket)
        let snapshot = TmuxClientProbe.topology(tmuxPath: tmux, socketPaths: [URL(fileURLWithPath: discovered)])
        #expect(snapshot.locations(for: endpoint).count == 1)
        #expect(TmuxClientProbe.normalizeSocketPath(discovered) == discovered)
        #expect(
            TmuxClientProbe.activePanePath(
                tmuxPath: tmux,
                socketPath: socket,
                sessionID: "runtime"
            ) == FileManager.default.currentDirectoryPath
        )
    }

    /// The format string is the whole contract with tmux, and a typo in
    /// it yields empty output rather than an error. Only a real server
    /// can say whether we asked for the right fields.
    @Test("a real tmux answers in the shape the parser expects")
    func listClients_realServer_parsesIntoABinding() throws {
        let tmux = try #require(installedTmux)
        // `sun_path` caps a unix socket at 104 bytes on macOS, so this
        // cannot live under the test's temp directory.
        let socket = "/tmp/limpid-probe-\(ProcessInfo.processInfo.processIdentifier).sock"
        defer { _ = try? run(tmux, ["-S", socket, "kill-server"]) }

        _ = try run(tmux, ["-S", socket, "new-session", "-d", "-s", "probe", "sleep 120"])
        // Two things a client needs that the test host does not provide:
        // stdin held open, or it reads EOF and detaches at once, and a
        // `TERM`, without which `attach` exits with "open terminal
        // failed" and leaves the server with no clients at all.
        let client = Process()
        client.executableURL = URL(fileURLWithPath: "/bin/sh")
        client.arguments = [
            "-c", "sleep 20 | script -q /dev/null \(tmux) -S \(socket) attach -t probe"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        client.environment = environment
        client.standardOutput = Pipe()
        let clientErrors = Pipe()
        client.standardError = clientErrors
        try client.run()
        defer { client.terminate() }
        Thread.sleep(forTimeInterval: 3)

        let output = try run(tmux, ["-S", socket] + TmuxClientProbe.listClientsArguments)
        let bindings = TmuxClientProbe.parseClients(output, socketPath: socket)
        #expect(bindings.count == 1, "raw: \(output.debugDescription)")
        if bindings.isEmpty {
            let stderr = clientErrors.fileHandleForReading.availableData
            Issue.record("client stderr: \(String(data: stderr, encoding: .utf8) ?? "")")
        }
        #expect(bindings.values.first?.sessionName == "probe")
        #expect(bindings.values.first?.sessionID.hasPrefix("$") == true)
        #expect(bindings.keys.first?.hasPrefix("/dev/") == true)
        let surfaceTTY = try #require(bindings.keys.first)
        let binding = try #require(bindings.values.first)
        #expect(
            ReviewTerminalProbe.hostedWorkingDirectory(
                surfaceTTY: surfaceTTY,
                surfaceForeground: TmuxClientProbe.clientProcessName,
                knownBinding: binding
            ) == FileManager.default.currentDirectoryPath
        )
    }

    /// The end-to-end read: discover the socket, ask the server, and
    /// come back with a binding — the same path `applicationWillTerminate`
    /// takes, minus libghostty supplying the tty.
    @Test("discovers a running server and reports its client")
    func attachedClients_runningServer_findsTheBinding() throws {
        let tmux = try #require(installedTmux)
        // `sun_path` caps a socket at 104 bytes, so the server directory
        // stands in for `${TMUX_TMPDIR}/tmux-<uid>` under /tmp.
        let dir = URL(
            fileURLWithPath: "/tmp/limpid-srv-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let socket = dir.appendingPathComponent("default").path
        defer {
            _ = try? run(tmux, ["-S", socket, "kill-server"])
            try? FileManager.default.removeItem(at: dir)
        }

        _ = try run(tmux, ["-S", socket, "new-session", "-d", "-s", "srv", "sleep 120"])
        let client = try attachClient(tmux: tmux, socket: socket, session: "srv")
        defer { client.terminate() }
        Thread.sleep(forTimeInterval: 3)

        let clients = TmuxClientProbe.attachedClients(tmuxPath: tmux, serverDirectory: dir)
        #expect(clients.count == 1)
        #expect(clients.values.first?.sessionName == "srv")
        // `/tmp` is a symlink to `/private/tmp` on macOS, and directory
        // enumeration hands back the resolved form while Foundation
        // standardizes it back. Both address the same socket, so compare
        // them through the same normalization rather than picking one.
        let found = try #require(clients.values.first?.socketPath)
        #expect(
            URL(fileURLWithPath: found).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: socket).resolvingSymlinksInPath().path
        )
    }

    @Test("returns nothing when the server directory does not exist")
    func attachedClients_noServerDirectory_isEmpty() throws {
        let tmux = try #require(installedTmux)
        let absent = URL(fileURLWithPath: "/tmp/limpid-absent-\(UUID().uuidString)")
        #expect(TmuxClientProbe.attachedClients(tmuxPath: tmux, serverDirectory: absent).isEmpty)
    }

    /// A client needs stdin held open, or it reads EOF and detaches at
    /// once, and a `TERM`, without which `attach` exits with "open
    /// terminal failed" and the server is left with no clients at all.
    private func attachClient(tmux: String, socket: String, session: String) throws -> Process {
        let client = Process()
        client.executableURL = URL(fileURLWithPath: "/bin/sh")
        client.arguments = [
            "-c", "sleep 20 | script -q /dev/null \(tmux) -S \(socket) attach -t \(session)"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        client.environment = environment
        client.standardOutput = Pipe()
        client.standardError = Pipe()
        try client.run()
        return client
    }

    private func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
