// ToolProcessTests.swift
// Limpid — locating optional CLIs and bounding how long they may run.
//
// These cover the two defects that made the pull-request feature
// fail in ways no synthetic fixture would have caught:
//
//   - A Finder-launched app inherits launchd's `PATH`
//     (`/usr/bin:/bin:/usr/sbin:/sbin`), which holds neither Homebrew
//     nor `~/.local/bin`. Resolving `gh` through that `PATH` alone
//     silently disabled the whole feature for anyone who did not
//     launch Limpid from a terminal. What is pinned here is the
//     search primitive and that gap; the well-known-prefix and
//     login-shell tiers read the real machine, so they are verified
//     by running the app, not from here.
//   - `withTaskGroup` waits for its children, and a `Process` wrapped
//     in a continuation never observes cancellation on its own, so the
//     original timeout could not fire at all: one hung CLI stalled
//     every worktree's sync behind it.

import Foundation
import Testing
@testable import Limpid

@Suite("ToolProcess", .tags(.smoke))
struct ToolProcessTests {

    // MARK: - Locating

    /// Drop an executable stub into `directory`, so the search tiers
    /// can be exercised without depending on whatever the test machine
    /// happens to have installed. Callers get the directory from
    /// `withTempDir`, which removes it afterwards.
    private func writeStub(named name: String, into directory: URL, executable: Bool = true) throws {
        let file = directory.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: file.path
        )
    }

    @Test("finds an executable on a supplied PATH")
    func searchPathVariable_findsExecutable() throws {
        try withTempDir { directory in
            try writeStub(named: "faketool", into: directory)
            let found = ToolLocator.searchPathVariable(directory.path, for: "faketool")
            #expect(found?.path == directory.appendingPathComponent("faketool").path)
        }
    }

    /// A tool that exists is reachable or not purely by which `PATH`
    /// it is looked up on — the same stub, found on one and missed on
    /// launchd's. That is the shape of the Finder-launch defect, and
    /// the reason the well-known-prefix tier exists; the real gap it
    /// closes (Homebrew, `~/.local/bin`) is a property of the machine
    /// and is verified by running the app, not from here.
    @Test("reachability follows the supplied PATH, not the tool's existence")
    func searchPathVariable_launchdPathMissesUserInstalls() throws {
        try withTempDir { directory in
            try writeStub(named: "faketool", into: directory)
            #expect(ToolLocator.searchPathVariable(directory.path, for: "faketool") != nil)
            #expect(
                ToolLocator.searchPathVariable("/usr/bin:/bin:/usr/sbin:/sbin", for: "faketool") == nil
            )
        }
    }

    @Test("a present but non-executable file is not a match")
    func firstExecutable_skipsNonExecutable() throws {
        try withTempDir { directory in
            try writeStub(named: "faketool", into: directory, executable: false)
            #expect(ToolLocator.firstExecutable(named: "faketool", in: [directory.path]) == nil)
        }
    }

    @Test("earlier directories win")
    func firstExecutable_respectsOrder() throws {
        try withTempDir { first in
            try withTempDir { second in
                try writeStub(named: "faketool", into: first)
                try writeStub(named: "faketool", into: second)
                let found = ToolLocator.firstExecutable(named: "faketool", in: [first.path, second.path])
                #expect(found?.path == first.appendingPathComponent("faketool").path)
            }
        }
    }

    @Test("missing and empty directories are skipped rather than fatal")
    func firstExecutable_toleratesUnusableEntries() throws {
        try withTempDir { directory in
            try writeStub(named: "faketool", into: directory)
            let found = ToolLocator.firstExecutable(
                named: "faketool",
                in: ["", "/nonexistent-\(UUID().uuidString)", directory.path]
            )
            #expect(found != nil)
        }
    }

    // MARK: - Running

    @Test("captures stdout and a zero exit")
    func runTool_capturesSuccess() async {
        let result = await runTool(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"],
            workingDirectory: nil,
            timeout: .seconds(10)
        )
        #expect(result?.isSuccess == true)
        #expect(result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test("reports a non-zero exit rather than treating it as failure to run")
    func runTool_reportsNonZeroExit() async {
        let result = await runTool(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 3"],
            workingDirectory: nil,
            timeout: .seconds(10)
        )
        #expect(result != nil)
        #expect(result?.exitCode == 3)
        #expect(result?.isSuccess == false)
    }

    @Test("a missing executable returns nil instead of trapping")
    func runTool_missingExecutable_returnsNil() async {
        let result = await runTool(
            executable: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"),
            arguments: [],
            workingDirectory: nil,
            timeout: .seconds(5)
        )
        #expect(result == nil)
    }

    /// The regression this file exists for. Before the cancellation
    /// handler that terminates the child, this call returned only when
    /// `sleep` finished — thirty seconds, not the fraction of a second
    /// that was asked for. Asserting on elapsed time is what distinguishes "timed out"
    /// from "the process happened to be quick".
    @Test("a hung process is cut off at the timeout")
    func runTool_timeoutTerminatesChild() async {
        let clock = ContinuousClock()
        let started = clock.now
        let result = await runTool(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            workingDirectory: nil,
            timeout: .milliseconds(400)
        )
        let elapsed = clock.now - started
        #expect(result == nil)
        // Generous bound: the point is that we did not wait out the
        // full 30 seconds, not that the timer is precise.
        #expect(elapsed < .seconds(10))
    }

    @Test("the working directory is honored")
    func runTool_usesWorkingDirectory() async throws {
        try await withTempDir { directory in
            let result = await runTool(
                executable: URL(fileURLWithPath: "/bin/pwd"),
                arguments: [],
                workingDirectory: directory,
                timeout: .seconds(10)
            )
            let printed = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // Compare resolved *paths*: /private/tmp and /tmp are the
            // same place, and URL adds a trailing slash for a directory
            // that exists while `pwd` never prints one.
            let expected = directory.resolvingSymlinksInPath().path
            let actual = printed.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            #expect(actual == expected)
        }
    }

    /// `ProcessDrain.drainAndWait` reads both pipes before waiting on
    /// the child, and this is what pins that order. Wait first and a
    /// tool whose output exceeds the pipe buffer (64KB on Darwin)
    /// blocks in `write(2)` while we block in `waitUntilExit`, and
    /// neither side moves again — the deadlock `GitProcess` was
    /// written around, now shared with every forge CLI call.
    ///
    /// Both streams are overfilled, in sequence, which is enough: the
    /// child cannot finish its second `dd` while that pipe is full, so
    /// it never closes the first either. A reader that takes the pipes
    /// one at a time therefore blocks whichever it reads first, and
    /// the order it picks does not save it.
    ///
    /// A regression fails rather than hangs — `runTool`'s own timeout
    /// fires and returns nil, which the size assertion then rejects.
    @Test("output larger than the pipe buffer is captured, not deadlocked")
    func runTool_largeOutput_doesNotDeadlock() async {
        let bytes = 200 * 1024
        let result = await runTool(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "dd if=/dev/zero bs=1024 count=200 2>/dev/null | tr '\\0' a; "
                    + "dd if=/dev/zero bs=1024 count=200 2>/dev/null | tr '\\0' b 1>&2"
            ],
            workingDirectory: nil,
            timeout: .seconds(10)
        )
        #expect(result?.stdout.count == bytes)
        #expect(result?.stderr.count == bytes)
    }

    @Test("supplied environment entries reach the child")
    func runTool_layersEnvironment() async {
        let result = await runTool(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s \"$LIMPID_TEST_VAR\""],
            workingDirectory: nil,
            environment: ["LIMPID_TEST_VAR": "present"],
            timeout: .seconds(10)
        )
        #expect(result?.stdout == "present")
    }
}
