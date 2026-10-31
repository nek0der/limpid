// ProcessDrainTests.swift
// Limpid — the shared runner's cap on stdout and its report of an output left unfinished, on real child processes.

import Foundation
import Testing
@testable import Limpid

@Suite("Shared process runner")
struct ProcessDrainTests {
    /// Starts `script` under `/bin/sh` with both pipes, and runs it on the
    /// shared runner.
    private func run(
        _ script: String,
        stdoutLimitBytes: Int? = nil,
        timeout: Duration = .seconds(5),
        timing: ProcessDrainTiming = .standard
    ) throws -> DrainedOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return drainAndWait(process, stdout: stdout, stderr: stderr, timeout: timeout, stdoutLimitBytes: stdoutLimitBytes, timing: timing)
    }

    @Test func aChildWritingPastTheCap_isEnded_andKeepsNoMoreThanTheCap() throws {
        let start = SuspendingClock.now
        // `yes` never stops on its own: only the cap ends it, or else the
        // timeout, 30 seconds.
        let output = try run("exec /usr/bin/yes", stdoutLimitBytes: 4096, timeout: .seconds(30))
        #expect(output.ending == .outputLimit)
        #expect(output.stdout.count <= 4096)
        // `yes` ends on the SIGTERM the cap sends, a fraction of a second.
        // The bound is well short of the timeout and leaves room for a busy
        // CI runner.
        #expect(SuspendingClock.now - start < .seconds(15), "the cap, not the timeout")
    }

    @Test func aChildThatExitedOverTheCap_isStillReportedOverIt() throws {
        let output = try run("printf abcdef", stdoutLimitBytes: 3)
        #expect(output.ending == .outputLimit)
    }

    @Test func outputUnderTheCap_isWhole() throws {
        let output = try run("printf abc; printf oops >&2", stdoutLimitBytes: 3)
        #expect(output.ending == .exited)
        #expect(output.isStdoutComplete)
        #expect(String(data: output.stdout, encoding: .utf8) == "abc")
        #expect(String(data: output.stderr, encoding: .utf8) == "oops")
    }

    /// The grandchild holds stdout until the test lets it go, after the
    /// run returned, so the output is unfinished unless the run outlasts
    /// the grandchild. It gives up on its own after 600 polls 0.05 s apart,
    /// about half a minute, and the test's one-minute time limit stands
    /// watch over a run that would not return.
    @Test(.timeLimit(.minutes(1)))
    func aGrandchildHoldingStdout_leavesTheOutputUnfinished_afterTheDrainGrace() throws {
        try withTempDir { directory in
            let release = directory.appendingPathComponent("release")
            defer { FileManager.default.createFile(atPath: release.path, contents: nil) }
            let timing = ProcessDrainTiming(terminationGrace: .milliseconds(200), drainGrace: .milliseconds(200), pollMilliseconds: 10)
            let script = "(i=0; while [ ! -e '\(release.path)' ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done) & exit 0"
            let output = try run(script, timing: timing)
            #expect(output.ending == .exited)
            #expect(!output.isStdoutComplete)
            #expect(!output.hasStdoutReadFailed)
        }
    }

    /// Both ends are closed on `exec`, so a process another thread starts
    /// holds neither, and the child the pipe is for still writes to it.
    @Test func aPipeForAChild_staysOutOfOtherProcesses_andStillCarriesItsChildsOutput() throws {
        let pipe = Pipe.forChildProcess()
        #expect(fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf abc"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = drainAndWait(process, stdout: pipe, stderr: nil, timeout: .seconds(30))
        #expect(output.stdout == Data("abc".utf8))
        #expect(output.isStdoutComplete)
    }

    /// A long-lived process a test starts must not hold another test's pipe:
    /// that made a Git query running beside it read as timed out on CI.
    @Test(.timeLimit(.minutes(1)))
    func aProcessGroupATestStarts_holdsNoPipeOfTheTestHost() throws {
        // A plain pipe on purpose: its descriptors stay open across `exec`.
        let pipe = Pipe()
        let group = try spawnProcessGroup(["/bin/sleep", "30"])
        defer {
            kill(group, SIGKILL)
            var status: Int32 = 0
            waitpid(group, &status, 0)
        }
        try pipe.fileHandleForWriting.close()
        var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        #expect(poll(&descriptor, 1, 5000) == 1, "the pipe stayed open while the process ran")
    }
}
