// ReviewProbeScenarios.swift
// Limpid — the review scenarios that need a real terminal, kept on their own.

import Foundation
@testable import Limpid

/// The one part of the review core that cannot run inside the test target.
///
/// It spawns processes and opens a pty, and the suite runs in parallel: the
/// descriptors it takes reuse the numbers `SettingsFileWatcherTests` asserts
/// are closed, failing a test that is correct about its own subject. So this
/// runs from `scripts/validate-review-core.sh` instead, which is also why it
/// lives apart from the scenarios that do run in the suite — the script then
/// compiles the terminal probe and its two dependencies rather than the whole
/// review core.
enum ReviewProbeScenarios {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw ReviewValidationFailure(message: message)
        }
    }

    /// What review reports about the terminal it writes to.
    ///
    /// It has to be exercised against a real terminal. The first implementation
    /// asked the terminal for its foreground group, which XNU answers only for
    /// the caller's own controlling terminal — a windowed app has none — so it
    /// answered "no" everywhere, and the scenarios here only ever asserted
    /// refusals and stayed green. It is no longer a gate, but a chip that
    /// always says "nothing there" is just as useless.
    static func foreground() throws {
        let host = Process()
        // `script` allocates a pty, puts the command in its own session and
        // hands it the terminal: the shortest route to a real foreground job.
        host.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        host.arguments = ["-q", "/dev/null", "/bin/cat"]
        host.standardInput = Pipe()
        host.standardOutput = FileHandle.nullDevice
        host.standardError = FileHandle.nullDevice
        try host.run()
        defer {
            host.terminate()
        }
        guard let child = childOnTTY(of: host.processIdentifier) else {
            throw ReviewValidationFailure(message: "No pty child appeared: " + run("/bin/ps", ["-o", "pid,ppid,tty,comm", "-ax"]))
        }
        defer {
            kill(child.pid, SIGKILL)
        }
        guard let found = ReviewTerminalProbe.foregroundProcess(on: child.tty) else {
            throw ReviewValidationFailure(message: "No foreground process found on a live pty")
        }
        try require(found.pid == child.pid, "Wrong process named as the foreground one")
        try require(found.name == "cat", "Foreground command name: \(found.name)")
        try require(ReviewTerminalProbe.foregroundProcess(on: "/dev/null") == nil, "A non-terminal answered")
        // Without tmux in front of it the delivery target is the tty itself.
        try require(
            ReviewTerminalProbe.deliveryTTY(surfaceTTY: child.tty) == child.tty,
            "A tty with no tmux client on it was rewritten"
        )
        // What the kernel calls a process is not always what to show. Claude
        // Code reports `claude.exe`, and a login shell reports `-zsh`.
        try require(ReviewTerminalProbe.displayName("claude.exe") == "claude", "A packed name kept its suffix")
        try require(ReviewTerminalProbe.displayName("-zsh") == "zsh", "A login shell kept its dash")
        try require(ReviewTerminalProbe.displayName("cat") == "cat", "A plain name was rewritten")
    }

    /// The child takes a moment to reach its pty, so we poll rather than sleep
    /// once and hope.
    private static func childOnTTY(of parent: Int32) -> (pid: Int32, tty: String)? {
        for _ in 0..<200 {
            for line in run("/usr/bin/pgrep", ["-P", String(parent)]).split(separator: "\n") {
                guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)) else { continue }
                let tty = run("/bin/ps", ["-o", "tty=", "-p", String(pid)])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !tty.isEmpty, tty != "??" {
                    return (pid, "/dev/" + tty)
                }
            }
            usleep(50000)
        }
        return nil
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
