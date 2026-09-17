// TmuxServerFixture.swift
// Limpid — a throwaway tmux server for the suites that drive a real one.

import Foundation
import Testing
@testable import Limpid

/// A tmux server on a socket under a temp directory, so the user's own
/// server is never touched and two tests cannot share state. `-f /dev/null`
/// keeps the developer's `~/.tmux.conf` out as well: a private socket does
/// not stop tmux from loading it, and options such as `aggressive-resize`
/// or `default-command` change what these suites measure.
struct TmuxServerFixture {
    let executable: String
    let directory: URL
    let socketPath: String

    static let commandTimeout: TimeInterval = 10

    /// Whether a missing tmux fails the real-tmux suites instead of
    /// skipping them. CI asks for it so a runner without tmux cannot pass
    /// by skipping. xcodebuild hands the test process only the variables
    /// prefixed `TEST_RUNNER_`, with the prefix removed, so the workflow
    /// sets `TEST_RUNNER_LIMPID_REQUIRE_TMUX_TESTS=1`.
    static var isTmuxRequired: Bool {
        ProcessInfo.processInfo.environment["LIMPID_REQUIRE_TMUX_TESTS"] == "1"
    }

    /// Whether the real-tmux suites skip. When tmux is required, a missing
    /// one fails the fixture's `#require` instead, as it does for
    /// `TmuxClientProbeSmokeTests`.
    static var isUnavailable: Bool {
        TmuxClientProbe.locateTmux() == nil && !isTmuxRequired
    }

    /// Launches session `t` at 80×24 with `windows` windows, each running a
    /// plain `sh` with a `$ ` prompt. The status line is off because tmux's
    /// default takes a row from every window's height.
    static func launch(windows: Int = 1) throws -> TmuxServerFixture {
        let executable = try #require(TmuxClientProbe.locateTmux())
        // A short name: the socket path must stay under the 104-byte
        // `sun_path` limit, and the per-user temporary directory is long.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = TmuxServerFixture(
            executable: executable,
            directory: directory,
            socketPath: directory.appendingPathComponent("sock").path
        )
        // A server whose setup failed halfway may already be running, and
        // the caller never receives the fixture that would tear it down.
        do {
            try fixture.startServer(windows: windows)
        } catch {
            fixture.tearDown()
            throw error
        }
        return fixture
    }

    /// Launches a server and hands it to `setUp`, which builds whatever
    /// the test holds on to. A harness that fails halfway is never
    /// returned, so the caller's `defer { tearDown() }` cannot run for it;
    /// the server is torn down here instead, before the error propagates.
    static func launch<Value>(
        windows: Int = 1,
        isolation: isolated (any Actor)? = #isolation,
        setUp: (TmuxServerFixture) async throws -> Value
    ) async throws -> Value {
        let server = try launch(windows: windows)
        do {
            return try await setUp(server)
        } catch {
            server.tearDown()
            throw error
        }
    }

    /// Setup must not fail quietly: a window missing here surfaces later
    /// as an index out of range in whichever test asked for it.
    private func startServer(windows: Int) throws {
        try #require(run(["new-session", "-d", "-s", "t", "-x", "80", "-y", "24", "sh", "-c", "PS1='$ ' exec sh"]) != nil)
        try #require(run(["set-option", "-g", "status", "off"]) != nil)
        for _ in 1..<max(windows, 1) {
            try #require(run(["new-window", "-t", "t", "sh", "-c", "PS1='$ ' exec sh"]) != nil)
        }
    }

    /// The server run now on the socket, as a binding records it.
    func generation() throws -> TmuxServerGeneration.Recorded {
        try TmuxServerGeneration.Recorded(pid: format("#{pid}"), startedAt: format("#{start_time}"))
    }

    /// Stop the server and wait until its process is gone, leaving the
    /// socket file behind as tmux does. `kill-server` returns before the
    /// server has exited, and a command sent meanwhile can still reach it.
    /// The server is not our child; the kernel reports it gone once it has
    /// exited.
    func killServer() async throws {
        let pid = try #require(Int32(format("#{pid}")))
        run(["kill-server"])
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(Self.commandTimeout)
        while kill(pid, 0) == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(kill(pid, 0) != 0)
    }

    /// Replace the server with a new one on the same socket, set up as
    /// `launch` sets it up: session `t` again, most likely with the same
    /// session and window ids, which is what makes a restart dangerous to
    /// a binding that trusts ids alone.
    func restartServer(windows: Int = 1) async throws {
        try await killServer()
        try startServer(windows: windows)
    }

    /// Freeze the server process (`SIGSTOP`) without ending it: a client
    /// still connects, since the kernel accepts on the listening socket,
    /// but never hears back, which is how a hung server looks. Returns the
    /// server's pid; the caller hands it to `resumeServer` before
    /// `tearDown`, which cannot reach a frozen server.
    func suspendServer() throws -> pid_t {
        let pid = try #require(Int32(format("#{pid}")))
        try #require(kill(pid, SIGSTOP) == 0)
        return pid
    }

    func resumeServer(_ pid: pid_t) {
        kill(pid, SIGCONT)
    }

    /// `-f` only matters when this call starts the server; passing it on
    /// every call keeps that true whichever command comes first.
    ///
    /// The timeout is the fixture's, not the app's half-second query
    /// budget: under a full parallel test run, starting a server alone can
    /// take longer than that.
    @discardableResult
    func run(_ arguments: [String]) -> String? {
        let prefix = ["-S", socketPath, "-f", "/dev/null"]
        let result = TmuxCommand().run(executable: executable, arguments: prefix + arguments, timeout: Self.commandTimeout)
        if case let .success(output) = result {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    func format(_ format: String, target: String = "t") throws -> String {
        try #require(run(["display-message", "-p", "-t", target, format]))
    }

    /// The window ids of session `t` in index order.
    func windowIDs() throws -> [String] {
        let listed = try #require(run(["list-windows", "-t", "t", "-F", "#{window_id}"]))
        return listed.split(separator: "\n").map(String.init)
    }

    func paneID(inWindow window: String) throws -> String {
        try #require(run(["list-panes", "-t", window, "-F", "#{pane_id}"]))
    }

    /// The size tmux currently holds for `window`, read from outside the
    /// control clients so the answer is the server's view, not a client's.
    func windowSize(_ window: String) -> String? {
        run(["display-message", "-p", "-t", window, "#{window_width}x#{window_height}"])
    }

    /// The panes of session `t`'s current window as `id WxH left,top`.
    func panes() -> [String] {
        (run(["list-panes", "-t", "t", "-F", "#{pane_id} #{pane_width}x#{pane_height} #{pane_left},#{pane_top}"]) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// A `tmux` that runs the real one with LC_ALL, LC_CTYPE, and LANG
    /// removed, for passing as the app's `tmuxPath`. The test host inherits
    /// the LANG libghostty sets, so only a separate environment shows what a
    /// client does without a UTF-8 locale.
    func localeFreeExecutable() throws -> String {
        let script = directory.appendingPathComponent("tmux-no-locale")
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try "#!/bin/sh\nunset LC_ALL LC_CTYPE LANG\nexec \(quoted) \"$@\"\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    func tearDown() {
        run(["kill-server"])
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Polls `condition` on the main actor, where the connection delivers,
/// until it holds or `timeout` passes. Returns the final answer.
/// The default is generous on purpose: these suites run in parallel with
/// the rest of the target, each with a tmux server of its own, and a wait
/// that only covers an idle machine turns a slow moment into a failure.
@MainActor
func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// A terminal client attached to a fixture's session through a pty, the way
/// a shell in a terminal app attaches. `tty` is what tmux lists as
/// `#{client_tty}` and `#{client_name}`.
///
/// No controlling terminal is set up: `tmux attach` only needs its standard
/// streams to be a terminal, which the pty's secondary side is.
final class TmuxPTYClient {
    let tty: String
    private let process = Process()
    private let secondary: Int32
    private let reader: any DispatchSourceRead

    init(fixture: TmuxServerFixture, session: String = "t") throws {
        var primary: Int32 = -1
        var secondary: Int32 = -1
        try #require(openpty(&primary, &secondary, nil, nil, nil) == 0)
        self.secondary = secondary
        tty = try String(cString: #require(ttyname(secondary)))
        // tmux writes a full screen on attach and redraws after that. Nobody
        // reading the primary side would fill the pty and stall the client.
        reader = DispatchSource.makeReadSource(fileDescriptor: primary, queue: .global())
        reader.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 16384)
            _ = read(primary, &buffer, buffer.count)
        }
        reader.setCancelHandler { close(primary) }
        reader.resume()

        let stream = FileHandle(fileDescriptor: secondary, closeOnDealloc: false)
        process.executableURL = URL(fileURLWithPath: fixture.executable)
        process.arguments = ["-S", fixture.socketPath, "attach", "-t", session]
        process.standardInput = stream
        process.standardOutput = stream
        process.standardError = stream
        var environment = ProcessInfo.processInfo.environment
        // Without a terminal type tmux refuses to open the terminal.
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        try process.run()
    }

    var isRunning: Bool {
        process.isRunning
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        reader.cancel()
        close(secondary)
    }
}
