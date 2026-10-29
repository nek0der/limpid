// SessionLaunchSetupStopTests.swift
// Limpid — a new session's setup stopped by a skip, a delete, a hidden worktree, or the quit.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionLaunchSetupStopTests {
    typealias Fixture = SessionLaunchFixture

    @Test func skippingTheSetup_stopsTheStepThatRuns_andStartsTheAgent() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir, request: Fixture.shell)
            let id = fixture.worktree.id
            // A retry while the setup runs does nothing.
            fixture.store.retry(worktreeID: id, in: fixture.session)
            #expect(fixture.store.launches[id]?.failure == nil)
            fixture.store.skipSetup(worktreeID: id, in: fixture.session)
            #expect(fixture.tabs.isEmpty, "not before the step has stopped")
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { !fixture.tabs.isEmpty }
            #expect(!Fixture.isRunning(pid))
            let tab = try #require(fixture.tabs.first)
            // A shell: nothing is typed.
            #expect(tab.initialCommands.isEmpty)
            #expect(fixture.store.launches.isEmpty)
        }
    }

    @Test func skippingASetupThatIgnoresSIGTERM_startsOnceItHasBeenKilled() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir, ignoresTERM: true)
            let id = fixture.worktree.id

            fixture.store.skipSetup(worktreeID: id, in: fixture.session)
            #expect(fixture.store.launches[id]?.isStoppingSetup == true, "the bar offers the skip no more")
            // Pressed again while it stops: still one start.
            fixture.store.skipSetup(worktreeID: id, in: fixture.session)

            // The step runs on past its SIGTERM until the SIGKILL seconds
            // later, and no tab opens while it does.
            var openedWhileRunning = false
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) {
                let isOpen = !fixture.tabs.isEmpty
                if isOpen, Fixture.isRunning(pid) {
                    openedWhileRunning = true
                }
                return isOpen
            }
            #expect(!openedWhileRunning)
            #expect(!Fixture.isRunning(pid))
            #expect(fixture.tabs.count == 1)
            // A press that lands once the agent is starting opens nothing.
            fixture.store.skipSetup(worktreeID: id, in: fixture.session)
            #expect(fixture.tabs.count == 1)
        }
    }

    @Test func stoppingASetup_waitsForAChildThatIgnoresSIGTERM_afterItsShellDied() async throws {
        try await withTempDir { dir in
            let childFile = dir.appendingPathComponent("child")
            // The shell dies of the SIGTERM; the child it started ignores it.
            let fixture = try await Fixture.make(in: dir, bootstrap: [
                .shorthand("sh -c 'trap \"\" TERM; echo $$ > \"\(childFile.path)\"; exec sleep 30' & wait")
            ])
            fixture.begin()
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { Fixture.pid(in: childFile) != nil }
            let child = try #require(Fixture.pid(in: childFile))

            await fixture.store.cancelSetup(worktreeID: fixture.worktree.id)

            #expect(!Fixture.isRunning(child), "nothing it started still writes in the folder")
            #expect(fixture.tabs.isEmpty)
        }
    }

    @Test func deletingAWorktreeWhileItsSkippedSetupStops_waitsForTheStep_andStartsNothing() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir, ignoresTERM: true)
            let id = fixture.worktree.id

            fixture.store.skipSetup(worktreeID: id, in: fixture.session)
            await fixture.store.cancelSetup(worktreeID: id)

            #expect(!Fixture.isRunning(pid))
            #expect(fixture.tabs.isEmpty)
            #expect(fixture.store.launches.isEmpty)
        }
    }

    @Test func aRemovedWorktree_takesItsLaunchAlong_andStopsItsSetup() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir)
            fixture.store.prune(keeping: [])
            #expect(fixture.store.launches.isEmpty)
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { !Fixture.isRunning(pid) }
            #expect(!Fixture.isRunning(pid))
            #expect(fixture.tabs.isEmpty)
        }
    }

    @Test func aHiddenWorktree_takesItsLaunchAlong() async throws {
        try await withTempDir { dir in
            let (fixture, _) = try await Fixture.startBlockingSetup(in: dir)
            #expect(fixture.session.visibleWorktreeIDs == [fixture.worktree.id])
            fixture.session.hideWorktree(projectID: fixture.project.id, worktreeID: fixture.worktree.id)
            #expect(fixture.session.visibleWorktreeIDs.isEmpty)
            fixture.store.prune(keeping: fixture.session.visibleWorktreeIDs)
            #expect(fixture.store.launches.isEmpty)
        }
    }

    @Test func deletingTheWorktree_stopsItsSetupFirst() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir)
            // Returns once the step has ended.
            await fixture.store.cancelSetup(worktreeID: fixture.worktree.id)
            #expect(fixture.store.launches.isEmpty)
            #expect(!Fixture.isRunning(pid))
        }
    }

    @Test func deletingTheWorktree_leavesAnAgentAlreadyStarting() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            fixture.begin(SessionLaunchRequest(open: .agent(.claude)))
            #expect(fixture.store.launches[fixture.worktree.id]?.phase == .starting(isLaunched: false))
            await fixture.store.cancelSetup(worktreeID: fixture.worktree.id)
            #expect(fixture.store.launches[fixture.worktree.id]?.phase == .starting(isLaunched: false))
        }
    }

    @Test func deletingTheWorktree_afterAFailedSetup_leavesTheFailure() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("exit 3")])
            let id = fixture.worktree.id
            fixture.begin()
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { fixture.store.launches[id]?.failure != nil }
            await fixture.store.cancelSetup(worktreeID: id)
            #expect(fixture.store.launches[id]?.failure != nil)
        }
    }

    /// At quit nothing waits for the SIGKILL a cancel schedules seconds
    /// later: Limpid would be gone first, and the step would go on in a
    /// worktree no one watches. So the quit sends it before it returns.
    @Test func quitting_killsASetupThatIgnoresSIGTERM_beforeItReturns() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir, ignoresTERM: true)

            fixture.store.cancelAll()

            // The quit sent SIGKILL before it returned, so the step ends at
            // once. The cancel's own SIGKILL comes three seconds after its
            // SIGTERM, about two and a half past the return, so a step gone
            // within two seconds was ended by the quit. Whether the quit
            // sends SIGKILL at all is checked without a clock in
            // `WorktreeSetupTests`.
            await pollUntil(timeout: .seconds(2), interval: .milliseconds(20)) { !Fixture.isRunning(pid) }
            #expect(!Fixture.isRunning(pid))
        }
    }
}
