// TmuxCommandTests.swift
// Limpid — real child processes pin timeout, pipe, and cancellation contracts.

import Foundation
import Testing
@testable import Limpid

@Suite("Bounded tmux command")
struct TmuxCommandTests {
    @Test func successfulEmptyOutput_isNotFailure() {
        #expect(TmuxCommand().run(executable: "/usr/bin/true", arguments: []) == .success(""))
        #expect(TmuxCommand().run(executable: "/usr/bin/false", arguments: []) == .failed(1))
        #expect(TmuxCommand().run(executable: "/nonexistent/limpid-tmux", arguments: []) == .launchFailed)
    }

    @Test func ignoredTermination_isKilledWithinTotalDeadline() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = TmuxCommand().run(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.05)
        #expect(result == .timedOut)
        #expect(ProcessInfo.processInfo.systemUptime - start < 1.5)
    }

    @Test func descendantHoldingWriter_doesNotKeepReaderAlive() {
        let start = ProcessInfo.processInfo.systemUptime
        // The fixture descendant exits independently; the runner owns only
        // its client and must not signal arbitrary descendant processes.
        let result = TmuxCommand().run(executable: "/bin/sh", arguments: ["-c", "sleep 1 & exit 0"], timeout: 0.05)
        #expect(result == .timedOut)
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.9)
    }

    @Test func cancellationBeforeAndDuringLaunch_isDistinct() {
        let cancelled = TmuxCommand()
        cancelled.cancel()
        #expect(cancelled.run(executable: "/usr/bin/true", arguments: []) == .cancelled)
        let running = TmuxCommand()
        let cancel = DispatchWorkItem { @Sendable in running.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05, execute: cancel)
        #expect(running.run(executable: "/bin/sleep", arguments: ["2"]) == .cancelled)
    }

    @Test func outputLimitAndInvalidEncoding_areNotPartialSuccess() {
        #expect(TmuxCommand().run(executable: "/usr/bin/printf", arguments: ["abcdef"], outputLimit: 3) == .outputLimit)
        #expect(TmuxCommand().run(executable: "/usr/bin/printf", arguments: ["\\377"]) == .invalidOutput)
    }
}
