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

    /// Whether the real-tmux suites skip. CI sets
    /// `LIMPID_REQUIRE_TMUX_TESTS=1`, so a missing tmux there fails the
    /// fixture's `#require` instead of skipping the suite silently, as
    /// `TmuxClientProbeSmokeTests` does.
    static let commandTimeout: TimeInterval = 10

    static var isUnavailable: Bool {
        TmuxClientProbe.locateTmux() == nil
            && ProcessInfo.processInfo.environment["LIMPID_REQUIRE_TMUX_TESTS"] != "1"
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
        // Setup must not fail quietly: a window missing here surfaces later
        // as an index out of range in whichever test asked for it.
        try #require(fixture.run(["new-session", "-d", "-s", "t", "-x", "80", "-y", "24", "sh", "-c", "PS1='$ ' exec sh"]) != nil)
        try #require(fixture.run(["set-option", "-g", "status", "off"]) != nil)
        for _ in 1..<max(windows, 1) {
            try #require(fixture.run(["new-window", "-t", "t", "sh", "-c", "PS1='$ ' exec sh"]) != nil)
        }
        return fixture
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

    func tearDown() {
        run(["kill-server"])
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Polls `condition` on the main actor, where the connection delivers,
/// until it holds or `timeout` passes. Returns the final answer.
@MainActor
func waitUntil(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
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
