// TmuxCommandTests.swift
// Weir — real child processes pin timeout, pipe, and cancellation contracts.

import Foundation
import Testing
@testable import Weir

@Suite("Bounded tmux command")
struct TmuxCommandTests {
    @Test func exitStatusAndLaunchFailure_areToldApart_andEmptyOutputIsSuccess() {
        // A timeout no run here reaches. Under the half-second default, one
        // local run reported `/usr/bin/true` as `.timedOut`, most likely
        // because a loaded machine started it late; the timeout is not what
        // this test is about.
        #expect(TmuxCommand().run(executable: "/usr/bin/true", arguments: [], timeout: 30) == .success(""))
        #expect(TmuxCommand().run(executable: "/usr/bin/false", arguments: [], timeout: 30) == .failed(1))
        #expect(TmuxCommand().run(executable: "/nonexistent/weir-tmux", arguments: [], timeout: 30) == .launchFailed)
    }

    @Test func ignoredTermination_isKilledWithinTotalDeadline() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = TmuxCommand().run(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.05)
        #expect(result == .timedOut)
        // The timeout and both graces come to under half a second. A run
        // that never sent SIGKILL would not return at all, so the bound only
        // has to stand well past the graces, and leaves room for a busy CI
        // runner, as the drain test's below does.
        #expect(ProcessInfo.processInfo.systemUptime - start < 10)
    }

    @Test func descendantHoldingWriter_doesNotKeepReaderAlive() throws {
        try withTempDir { folder in
            let descendant = folder.appendingPathComponent("descendant.pid")
            defer { killRecordedProcess(in: descendant) }
            let start = ProcessInfo.processInfo.systemUptime
            // The fixture descendant exits independently; the runner owns only
            // its client and must not signal arbitrary descendant processes.
            let result = TmuxCommand().run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 30 & echo $! > \"$1\"; exit 0", "sh", descendant.path],
                timeout: 0.05
            )
            #expect(result == .timedOut)
            // The exit and the 0.2-second drain grace, against the 30 seconds
            // the descendant holds the pipe. The bound is well short of that
            // and leaves room for a busy CI runner.
            #expect(ProcessInfo.processInfo.systemUptime - start < 10, "the drain grace, not the descendant's own end")
        }
    }

    @Test func cancellationBeforeAndDuringLaunch_isDistinct() {
        let cancelled = TmuxCommand()
        cancelled.cancel()
        #expect(cancelled.run(executable: "/usr/bin/true", arguments: []) == .cancelled)
        let running = TmuxCommand()
        let cancel = DispatchWorkItem { @Sendable in running.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05, execute: cancel)
        // Neither the child nor the timeout may end the run before the
        // cancel does. Under the short default timeout, a cancel that a busy
        // machine ran late lost to it, and the run said `.timedOut`.
        #expect(running.run(executable: "/bin/sleep", arguments: ["60"], timeout: 60) == .cancelled)
    }

    @Test func outputLimitAndInvalidEncoding_areNotPartialSuccess() {
        // A timeout no run here reaches, as in the first test: the half-second
        // default could report a late start as `.timedOut`.
        #expect(TmuxCommand().run(executable: "/usr/bin/printf", arguments: ["abcdef"], timeout: 30, outputLimit: 3) == .outputLimit)
        #expect(TmuxCommand().run(executable: "/usr/bin/printf", arguments: ["\\377"], timeout: 30) == .invalidOutput)
    }
}
