// CodexAgentStateTrackerTests.swift
// Limpid — covers the disk-only cleanup / preserve lifecycle of
// `CodexAgentStateTracker`. The directory watch and PID sweep timer
// aren't exercised here — they're driven by `DispatchSource` /
// `RunLoop` and would make the suite flaky. We pin the test surface
// to the two public methods (`cleanupDeadSessionsOnLaunch`,
// `preserveLiveSessionsOnTerminate`) that operate purely on the
// on-disk stores, plus a full cycle that proves the
// preserve → next-launch → second-launch sequence is the one-shot
// contract documented on `killedByLimpidAt`.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("CodexAgentStateTracker")
struct CodexAgentStateTrackerTests {

    // MARK: - Helpers

    private struct Setup {
        let state: CodexAgentStateStore
        let session: CodexSessionStore
        let tracker: CodexAgentStateTracker
    }

    private func makeTracker(stateDir: URL, sessionDir: URL) -> Setup {
        let state = CodexAgentStateStore(directory: stateDir)
        let session = CodexSessionStore(directory: sessionDir)
        let tracker = CodexAgentStateTracker(
            store: state,
            sessionStore: session
        )
        return Setup(state: state, session: session, tracker: tracker)
    }

    /// A pid that is guaranteed to be dead. macOS's `pid_max` defaults
    /// to 99998, so anything above that can never be a running process —
    /// `kill(pid, 0)` returns -1 with `errno == ESRCH`, which the
    /// tracker reads as "dead." Spawning `/bin/true` would be cleaner
    /// but the test bundle's sandbox forbids launching subprocesses.
    private let deadPID: String = "2147483646"

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func stateRecord(
        paneID: UUID,
        state: String = "idle",
        pid: String?,
        killedByLimpidAt: String? = nil
    ) -> CodexAgentStateRecord {
        CodexAgentStateRecord(
            schemaVersion: 1,
            paneId: paneID.uuidString,
            state: state,
            detail: nil,
            runStartedAt: nil,
            updatedAt: Self.iso.string(from: Date()),
            lastHookEvent: "Stop",
            contextTokens: nil,
            pid: pid,
            lastPrompt: nil,
            killedByLimpidAt: killedByLimpidAt
        )
    }

    private func sessionRecord(paneID: UUID) -> CodexSessionRecord {
        CodexSessionRecord(
            schemaVersion: 1,
            paneId: paneID.uuidString,
            sessionId: UUID().uuidString,
            cwd: "/tmp",
            updatedAt: Self.iso.string(from: Date()),
            lastHookEvent: "SessionStart"
        )
    }

    // MARK: - cleanupDeadSessionsOnLaunch

    @Test("alive pid → record preserved as-is")
    func cleanup_alivePid_preserved() throws {
        try withTempDir { stateDir in
            try withTempDir { sessionDir in
                let s = makeTracker(
                    stateDir: stateDir, sessionDir: sessionDir
                )
                let id = UUID()
                let original = stateRecord(paneID: id, pid: String(getpid()))
                try s.state.save(original)
                try s.session.save(sessionRecord(paneID: id))

                s.tracker.cleanupDeadSessionsOnLaunch()

                #expect(s.state.record(forPaneID: id) == original)
                #expect(s.session.record(forPaneID: id) != nil)
            }
        }
    }

    @Test("dead pid with no marker → state + session both deleted")
    func cleanup_deadPid_noMarker_deleted() throws {
        try withTempDir { stateDir in
            try withTempDir { sessionDir in
                let s = makeTracker(
                    stateDir: stateDir, sessionDir: sessionDir
                )
                let id = UUID()
                try s.state.save(stateRecord(paneID: id, pid: deadPID))
                try s.session.save(sessionRecord(paneID: id))

                s.tracker.cleanupDeadSessionsOnLaunch()

                #expect(s.state.record(forPaneID: id) == nil)
                #expect(s.session.record(forPaneID: id) == nil)
            }
        }
    }

    @Test("dead pid with recent marker → record kept, marker + pid cleared")
    func cleanup_deadPid_recentMarker_keepsAndClears() throws {
        try withTempDir { stateDir in
            try withTempDir { sessionDir in
                let s = makeTracker(
                    stateDir: stateDir, sessionDir: sessionDir
                )
                let id = UUID()
                let recent = Self.iso.string(from: Date().addingTimeInterval(-60))
                try s.state.save(stateRecord(
                    paneID: id,
                    pid: deadPID,
                    killedByLimpidAt: recent
                ))
                try s.session.save(sessionRecord(paneID: id))

                s.tracker.cleanupDeadSessionsOnLaunch()

                let kept = try #require(s.state.record(forPaneID: id))
                #expect(kept.pid == nil)
                #expect(kept.killedByLimpidAt == nil)
                #expect(s.session.record(forPaneID: id) != nil)
            }
        }
    }

    @Test("dead pid with stale marker (>24h) → record deleted")
    func cleanup_deadPid_staleMarker_deleted() throws {
        try withTempDir { stateDir in
            try withTempDir { sessionDir in
                let s = makeTracker(
                    stateDir: stateDir, sessionDir: sessionDir
                )
                let id = UUID()
                let stale = Self.iso.string(
                    from: Date().addingTimeInterval(-25 * 60 * 60)
                )
                try s.state.save(stateRecord(
                    paneID: id,
                    pid: deadPID,
                    killedByLimpidAt: stale
                ))
                try s.session.save(sessionRecord(paneID: id))

                s.tracker.cleanupDeadSessionsOnLaunch()

                #expect(s.state.record(forPaneID: id) == nil)
                #expect(s.session.record(forPaneID: id) == nil)
            }
        }
    }

    // MARK: - preserveLiveSessionsOnTerminate

    @Test("alive pid → killedByLimpidAt stamped, pid preserved")
    func preserve_alivePid_stampsMarker() throws {
        try withTempDir { stateDir in
            try withTempDir { sessionDir in
                let s = makeTracker(
                    stateDir: stateDir, sessionDir: sessionDir
                )
                let id = UUID()
                let alivePid = String(getpid())
                try s.state.save(stateRecord(paneID: id, pid: alivePid))

                s.tracker.preserveLiveSessionsOnTerminate()

                let kept = try #require(s.state.record(forPaneID: id))
                #expect(kept.killedByLimpidAt != nil)
                #expect(kept.pid == alivePid)
            }
        }
    }

    @Test("dead pid → record untouched (no marker stamped)")
    func preserve_deadPid_noChange() throws {
        try withTempDir { stateDir in
            try withTempDir { sessionDir in
                let s = makeTracker(
                    stateDir: stateDir, sessionDir: sessionDir
                )
                let id = UUID()
                let original = stateRecord(paneID: id, pid: deadPID)
                try s.state.save(original)

                s.tracker.preserveLiveSessionsOnTerminate()

                #expect(s.state.record(forPaneID: id) == original)
            }
        }
    }

    @Test("nil pid → record untouched")
    func preserve_nilPid_noChange() throws {
        try withTempDir { stateDir in
            try withTempDir { sessionDir in
                let s = makeTracker(
                    stateDir: stateDir, sessionDir: sessionDir
                )
                let id = UUID()
                let original = stateRecord(paneID: id, pid: nil)
                try s.state.save(original)

                s.tracker.preserveLiveSessionsOnTerminate()

                #expect(s.state.record(forPaneID: id) == original)
            }
        }
    }

    // MARK: - full cycle

    @Test("preserve → next-launch keeps session once; second launch drops it")
    func fullCycle_oneShotResume() throws {
        try withTempDir { stateDir in
            try withTempDir { sessionDir in
                let s = makeTracker(
                    stateDir: stateDir, sessionDir: sessionDir
                )
                let id = UUID()
                try s.state.save(stateRecord(paneID: id, pid: String(getpid())))
                try s.session.save(sessionRecord(paneID: id))

                // ⌘Q while codex is alive — marker is stamped.
                s.tracker.preserveLiveSessionsOnTerminate()

                // Simulate next launch: pid is now a reaped one so the
                // sweep sees it as dead. The recent marker grants the
                // one-shot resume — pid + marker cleared but session
                // preserved for the next codex launch to repopulate.
                var afterTerminate = try #require(s.state.record(forPaneID: id))
                afterTerminate.pid = deadPID
                try s.state.save(afterTerminate)

                s.tracker.cleanupDeadSessionsOnLaunch()

                let preserved = try #require(s.state.record(forPaneID: id))
                #expect(preserved.killedByLimpidAt == nil)
                #expect(preserved.pid == nil)
                #expect(s.session.record(forPaneID: id) != nil)

                // Second launch with no fresh hook to restamp pid:
                // marker is gone, pid is nil → record is deleted. This
                // is the contract that protects against an infinite
                // resume loop when SessionStart never fires.
                s.tracker.cleanupDeadSessionsOnLaunch()

                #expect(s.state.record(forPaneID: id) == nil)
                #expect(s.session.record(forPaneID: id) == nil)
            }
        }
    }
}
