// TestProcess.swift
// Limpid — runs a short command a test or a scenario asks about the system, on the app's own bounded runner.

import Foundation
@testable import Limpid

/// This is the one way a test runs `ps`, `pgrep`, or `tmux` to read the answer.
///
/// Each copy before this waited in its own order, and each order could
/// hang: reading stdout to its end before waiting never reached the
/// timeout while the child held stdout open, and waiting before reading
/// left stderr undrained and then read stdout with no limit at all, which
/// blocks for as long as anything the child started holds the pipe. So we
/// run on `drainAndWait`, which drains both pipes together, ends the child
/// past `timeout` with SIGTERM and then SIGKILL, and stops reading a moment
/// after the child has exited.
///
/// The timeout is on `drainAndWait`'s `ContinuousClock`, which keeps
/// running while the Mac sleeps, unlike the `SuspendingClock` `pollUntil`
/// waits on. We keep it: that choice in `pollUntil` matches the timers of
/// the code under test, and nothing here races one. A child asked about
/// the system answers in milliseconds, so a sleep in the middle of a run
/// at worst ends that child early and fails its caller's expectation; it
/// never makes a run hang. It is also the clock the app's own tmux client
/// (`TmuxCommand`) is ended on, so a test of tmux waits as the app does.
///
/// This file must not import `Testing`: `scripts/validate-review-core.sh`
/// compiles it outside the test target. What a caller asserts about a run,
/// that it exited in time or said something, stays with the caller.
enum TestProcess {
    /// Runs `executable` with `arguments`, its stdin the null device, and
    /// answers what it wrote and how it ended. `environment` replaces the
    /// test's own when given, as `ps` needs to answer in UTC and the C
    /// locale. Throws only when the child cannot be started.
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(10)
    ) throws -> DrainedOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        let stdout = Pipe.forChildProcess()
        let stderr = Pipe.forChildProcess()
        defer {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Our copies of the write ends would keep the pipes from ever
        // reaching EOF once the child has exited.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        return drainAndWait(process, stdout: stdout, stderr: stderr, timeout: timeout)
    }
}

extension DrainedOutput {
    /// This is what the run wrote to stdout, as UTF-8 text, or empty when
    /// the output is not UTF-8.
    var stdoutText: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }
}
