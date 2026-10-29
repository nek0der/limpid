// WorktreeSetupTests.swift
// Limpid — a worktree's setup commands: run in order in the worktree, stopped at the first failure or on cancel, their log's end kept.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WorktreeSetupTests {
    /// The test's own `PATH`: no login shell is started.
    private nonisolated static let path = ProcessInfo.processInfo.environment["PATH"]

    @Test func setupSteps_runInOrder_inTheWorktree_andStopAtTheFirstFailure() async throws {
        try await withTempDir { folder in
            let failure = try await WorktreeSetup.run([
                .shorthand("echo one > order.txt"),
                .shorthand("echo two >> order.txt; printf 'line\\n%.0s' $(seq 1 3000); echo 'the last words' >&2; exit 7"),
                .shorthand("echo three >> order.txt")
            ], in: folder, path: Self.path)
            let order = try String(contentsOf: folder.appendingPathComponent("order.txt"), encoding: .utf8)
            #expect(order == "one\ntwo\n")
            #expect(failure?.offset == 1)
            guard case let .exited(logTail) = failure?.reason else {
                Issue.record("not an exit: \(String(describing: failure))")
                return
            }
            #expect(logTail.hasSuffix("the last words"))
            // Only the end is kept of a long log.
            #expect(logTail.utf8.count <= WorktreeSetup.logTailBytes)
            #expect(try await WorktreeSetup.run([.shorthand("true")], in: folder, path: Self.path) == nil)
        }
    }

    @Test func theLogsEnd_keepsWholeCharacters_andSurvivesBytesThatAreNotUTF8() throws {
        try withTempDir { folder in
            let japanese = folder.appendingPathComponent("ja.log")
            try Data(String(repeating: "あ", count: 3000).utf8).write(to: japanese)
            let tail = WorktreeSetup.tail(of: japanese)
            #expect(!tail.isEmpty)
            #expect(tail.allSatisfy { $0 == "あ" })

            let mixed = folder.appendingPathComponent("mixed.log")
            try (Data("before ".utf8) + Data([0xFF, 0xFE]) + Data(" after".utf8)).write(to: mixed)
            #expect(WorktreeSetup.tail(of: mixed).hasSuffix("after"))
        }
    }

    @Test func aStepThatCannotStart_saysWhy() async throws {
        let failure = try await WorktreeSetup.run([.shorthand("true")], in: WorktreeFixture.freshPath(), path: Self.path)
        #expect(failure?.offset == 0)
        guard case let .exited(logTail) = failure?.reason else {
            Issue.record("not reported: \(String(describing: failure))")
            return
        }
        #expect(!logTail.isEmpty)
    }

    @Test func aStepWhoseFolderLeadsOutOfTheWorktree_stopsTheSetupUnrun() async throws {
        try await withTempDir { folder in
            let outside = BootstrapItem.detailed(BootstrapDetail(cmd: "touch ran.txt", timeout: nil, cwd: "../"))
            let failure = try await WorktreeSetup.run(
                [.shorthand("true"), outside, .shorthand("touch after.txt")],
                in: folder,
                path: Self.path
            )
            #expect(failure?.offset == 1)
            #expect(failure?.reason == .directoryOutsideWorktree("../"))
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("after.txt").path))
        }
    }

    /// A worktree with an `inside` folder, and a folder beside it that is
    /// not in it, both under `scratch`.
    private static func worktreeAndOutside(in scratch: URL) throws -> (worktree: URL, outside: URL) {
        let worktree = scratch.appendingPathComponent("worktree")
        let outside = scratch.appendingPathComponent("outside")
        try FileManager.default.createDirectory(
            at: worktree.appendingPathComponent("inside"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("web"),
            withIntermediateDirectories: true
        )
        return (worktree, outside)
    }

    private static func touch(in cwd: String) -> BootstrapItem {
        .detailed(BootstrapDetail(cmd: "touch ran.txt", timeout: nil, cwd: cwd))
    }

    @Test func aStepFolderThatLinksOutOfTheWorktree_stopsTheSetupUnrun() async throws {
        try await withTempDir { scratch in
            let (worktree, outside) = try Self.worktreeAndOutside(in: scratch)
            try FileManager.default.createSymbolicLink(
                at: worktree.appendingPathComponent("frontend"),
                withDestinationURL: outside
            )
            let failure = try await WorktreeSetup.run(
                [Self.touch(in: "frontend"), .shorthand("touch after.txt")],
                in: worktree,
                path: Self.path
            )
            #expect(failure?.offset == 0)
            #expect(failure?.reason == .directoryOutsideWorktree("frontend"))
            #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("ran.txt").path))
            #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("after.txt").path))
        }
    }

    @Test func aStepFolderUnderAParentThatLinksOutOfTheWorktree_stopsTheSetupUnrun() async throws {
        try await withTempDir { scratch in
            let (worktree, outside) = try Self.worktreeAndOutside(in: scratch)
            try FileManager.default.createSymbolicLink(
                at: worktree.appendingPathComponent("packages"),
                withDestinationURL: outside
            )
            let failure = try await WorktreeSetup.run([Self.touch(in: "packages/web")], in: worktree, path: Self.path)
            #expect(failure?.reason == .directoryOutsideWorktree("packages/web"))
            #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("web/ran.txt").path))
        }
    }

    @Test func aSiblingWhoseNameStartsWithTheWorktrees_isOutsideIt() throws {
        try withTempDir { scratch in
            let (worktree, _) = try Self.worktreeAndOutside(in: scratch)
            let sibling = scratch.appendingPathComponent("worktree-other")
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: worktree.appendingPathComponent("next"),
                withDestinationURL: sibling
            )
            guard case .outside = WorktreeSetup.stepDirectory("next", in: worktree) else {
                Issue.record("a sibling counted as inside the worktree")
                return
            }
        }
    }

    @Test func aStepFolderThatLinksInsideTheWorktree_runs() async throws {
        try await withTempDir { scratch in
            let (worktree, _) = try Self.worktreeAndOutside(in: scratch)
            try FileManager.default.createSymbolicLink(
                atPath: worktree.appendingPathComponent("alias").path,
                withDestinationPath: "inside"
            )
            #expect(try await WorktreeSetup.run([Self.touch(in: "alias")], in: worktree, path: Self.path) == nil)
            #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("inside/ran.txt").path))
        }
    }

    @Test func aStepFolderThatIsMissing_stopsTheSetupUnrun_andSaysWhy() async throws {
        try await withTempDir { scratch in
            let (worktree, _) = try Self.worktreeAndOutside(in: scratch)
            try FileManager.default.createSymbolicLink(
                atPath: worktree.appendingPathComponent("dangling").path,
                withDestinationPath: "nowhere"
            )
            for cwd in ["missing", "dangling"] {
                let failure = try await WorktreeSetup.run(
                    [Self.touch(in: cwd), .shorthand("touch after.txt")],
                    in: worktree,
                    path: Self.path
                )
                #expect(failure?.offset == 0)
                guard case let .exited(logTail) = failure?.reason else {
                    Issue.record("not reported: \(String(describing: failure))")
                    continue
                }
                #expect(!logTail.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("after.txt").path))
            }
        }
    }

    @Test func aWorktreeReachedThroughALink_stillHoldsItsSubfolder() throws {
        try withTempDir { scratch in
            let (worktree, outside) = try Self.worktreeAndOutside(in: scratch)
            let link = scratch.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: worktree)
            guard case .inside = WorktreeSetup.stepDirectory("inside", in: link) else {
                Issue.record("a subfolder of a linked worktree counted as outside")
                return
            }
            try FileManager.default.createSymbolicLink(
                at: worktree.appendingPathComponent("frontend"),
                withDestinationURL: outside
            )
            guard case .outside = WorktreeSetup.stepDirectory("frontend", in: link) else {
                Issue.record("a link out of a linked worktree counted as inside")
                return
            }
        }
    }

    @Test func aStepFolderThatIsASubfolder_runs() async throws {
        try await withTempDir { scratch in
            let (worktree, _) = try Self.worktreeAndOutside(in: scratch)
            #expect(try await WorktreeSetup.run([Self.touch(in: "inside")], in: worktree, path: Self.path) == nil)
            #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("inside/ran.txt").path))
        }
    }

    @Test func cancellingTheSetup_stopsTheStepThatRuns_andIsNoFailedStep() async throws {
        try await withTempDir { folder in
            let started = folder.appendingPathComponent("started")
            let task = Task {
                try await WorktreeSetup.run(
                    [.shorthand("touch started; exec sleep 30"), .shorthand("touch after.txt")],
                    in: folder,
                    path: Self.path
                )
            }
            // Canceled while the step runs, not before it starts.
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) {
                FileManager.default.fileExists(atPath: started.path)
            }
            #expect(FileManager.default.fileExists(atPath: started.path))
            let clock = SuspendingClock.now
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            // `sleep` ends on the cancel's SIGTERM, a fraction of a second.
            // The bound is well short of the 30 seconds it sleeps and leaves
            // room for a busy CI runner.
            #expect(SuspendingClock.now - clock < .seconds(15), "the cancel, not the step's own end")
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("after.txt").path))
        }
    }

    @Test func aStepThatIgnoresSIGTERM_andItsChildren_areKilledAfterTheGrace() async throws {
        try await withTempDir { folder in
            let child = folder.appendingPathComponent("child.pid")
            let task = Task {
                try await WorktreeSetup.run(
                    [.shorthand("trap '' TERM; sleep 30 & echo $! > child.pid; wait")],
                    in: folder,
                    path: Self.path
                )
            }
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) {
                (try? String(contentsOf: child, encoding: .utf8))?.isEmpty == false
            }
            let pid = try #require(Int32(String(contentsOf: child, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            // SIGKILL reaches the whole group, the child that ignored
            // SIGTERM included.
            await pollUntil(timeout: .seconds(6), interval: .milliseconds(50)) { !ProcessLiveness.isLive(pid) }
            #expect(!ProcessLiveness.isLive(pid))
        }
    }

    /// The wait for a stopped step sends SIGKILL itself, rather than
    /// counting on the timer `RunningStep.stop` schedules, which a busy
    /// runner can hold back past any deadline the wait keeps. Here no
    /// timer runs, and no signal is sent before the wait, so only the
    /// wait's SIGKILL ends the group.
    @Test func theWaitForAStoppedStep_killsItsGroup_withoutTheStopsTimer() async throws {
        let group = try spawnProcessGroup(["/bin/sleep", "30"])
        defer {
            if WorktreeSetup.isRunning(group: group) {
                kill(-group, SIGKILL)
            }
        }
        reapWhenItEnds(group)

        let clock = SuspendingClock()
        let started = clock.now
        await WorktreeSetup.waitForGroup(group)

        #expect(!WorktreeSetup.isRunning(group: group))
        // The step still had its time to end on SIGTERM.
        #expect(clock.now - started >= .seconds(3))
    }

    /// Before Limpid exits, the quit sends SIGKILL to a step that ignores
    /// SIGTERM. No timer runs here, unlike a cancel's, so a step that ends
    /// was ended by the quit, however long that takes on a busy runner.
    @Test func theQuit_killsAStepThatIgnoresSIGTERM_withNoTimerOfItsOwn() async throws {
        try await withTempDir { folder in
            let ready = folder.appendingPathComponent("ready")
            // `exec` keeps the ignored SIGTERM, as a step's children do.
            let group = try spawnProcessGroup(["/bin/sh", "-c", "trap '' TERM; touch \"$1\"; exec sleep 60", "sh", ready.path])
            defer {
                if WorktreeSetup.isRunning(group: group) {
                    kill(-group, SIGKILL)
                }
            }
            reapWhenItEnds(group)
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) {
                FileManager.default.fileExists(atPath: ready.path)
            }
            try #require(FileManager.default.fileExists(atPath: ready.path))

            let steps = WorktreeSetup.RunningSteps()
            steps.insert(group)
            steps.stopBeforeExit()

            await pollUntil(timeout: .seconds(15), interval: .milliseconds(20)) { !WorktreeSetup.isRunning(group: group) }
            #expect(!WorktreeSetup.isRunning(group: group))
        }
    }
}
