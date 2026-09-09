// AgentRemediationRegressionTests.swift
// Limpid — failures found in the merge-readiness review.

import Foundation
import Testing
@testable import Limpid

@Suite("Agent remediation regressions")
@MainActor
struct AgentRemediationRegressionTests {
    @Test func retiredMetadata_isBoundedWithoutEvictingActiveRuns() throws {
        try withTempDir { directory in
            let store = CodexAgentStateStore(directory: directory, maxRetiredRecords: 1)
            let paneID = UUID()
            let first = record(paneID: paneID, runID: UUID().uuidString, pid: "2147483646")
            let second = record(paneID: paneID, runID: UUID().uuidString, pid: "2147483646")
            let live = record(paneID: paneID, runID: UUID().uuidString, pid: String(getpid()))
            for item in [first, second, live] {
                try store.save(item)
            }
            #expect(try store.removeIfUnchanged(first) == .applied)
            #expect(try store.removeIfUnchanged(second) == .applied)
            #expect(store.allRecords().map(\.storageID) == [live.storageID])
            let retired = directory.appendingPathComponent("retired")
            #expect(try FileManager.default.contentsOfDirectory(atPath: retired.path).count == 1)
            store.pruneRetired(now: Date().addingTimeInterval(AgentLifecyclePolicy.retiredLifetime + 1))
            #expect(try FileManager.default.contentsOfDirectory(atPath: retired.path).isEmpty)
            #expect(store.allRecords().count == 1)
        }
    }

    private func record(paneID: UUID, runID: String, pid: String) -> CodexAgentStateRecord {
        CodexAgentStateRecord(
            schemaVersion: 2,
            runId: runID,
            revision: 1,
            paneId: paneID.uuidString,
            state: "running",
            detail: nil,
            runStartedAt: nil,
            updatedAt: "2026-09-09T00:00:00Z",
            lastHookEvent: nil,
            contextTokens: nil,
            pid: pid,
            lastPrompt: nil
        )
    }

    @Test func busyHintCleanup_retainsRetryRecordUntilReleased() throws {
        try withTempDir { directory in
            let paneID = UUID(), runID = UUID().uuidString
            let store = CodexAgentStateStore(directory: directory.appendingPathComponent("states"))
            let hints = CodexSessionStore(directory: directory.appendingPathComponent("sessions"))
            try store.save(record(paneID: paneID, runID: runID, pid: "2147483646"))
            try hints.save(CodexSessionRecord(
                schemaVersion: 1,
                paneId: paneID.uuidString,
                sessionId: UUID().uuidString,
                cwd: directory.path,
                updatedAt: "2026-09-09T00:00:00Z",
                runId: runID
            ))
            let fd = open(hints.directory.appendingPathComponent(paneID.uuidString + ".json.flock").path, O_CREAT | O_RDWR, 0o600)
            #expect(fd >= 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
            let tracker = CodexAgentStateTracker(store: store, sessionStore: hints)
            tracker.runPIDSweep()
            #expect(store.allRecords().count == 1)
            #expect(hints.record(forPaneID: paneID) != nil)
            flock(fd, LOCK_UN)
            tracker.runPIDSweep()
            #expect(store.allRecords().isEmpty)
            #expect(hints.record(forPaneID: paneID) == nil)
        }
    }

    @Test func shutdownIntent_protectsResumeDespiteRuntimeLock() throws {
        try withTempDir { directory in
            let paneID = UUID(), runID = UUID().uuidString
            let store = CodexAgentStateStore(directory: directory.appendingPathComponent("states"))
            let hints = CodexSessionStore(directory: directory.appendingPathComponent("sessions"))
            try store.save(record(paneID: paneID, runID: runID, pid: "12345"))
            try hints.save(CodexSessionRecord(
                schemaVersion: 1,
                paneId: paneID.uuidString,
                sessionId: UUID().uuidString,
                cwd: directory.path,
                updatedAt: "2026-09-09T00:00:00Z",
                runId: runID
            ))
            var status = AgentProcessStatus.alive
            let tracker = CodexAgentStateTracker(store: store, sessionStore: hints, processStatus: { _ in status })
            let fd = open(store.directory.appendingPathComponent(runID + ".state.json.flock").path, O_CREAT | O_RDWR, 0o600)
            #expect(fd >= 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
            tracker.preserveLiveSessionsOnTerminate()
            #expect(tracker.resumeIntents.record(runID: runID) != nil)
            #expect(store.allRecords().first?.killedByLimpidAt == nil)
            flock(fd, LOCK_UN)
            status = .dead
            tracker.cleanupDeadSessionsOnLaunch()
            #expect(hints.record(forPaneID: paneID) != nil)
            #expect(store.allRecords().first?.resumeAttemptedAt != nil)
            #expect(tracker.resumeIntents.record(runID: runID) == nil)
        }
    }

    @Test func update_contendedLock_reportsBusy() throws {
        try withTempDir { directory in
            let store = CodexAgentStateStore(directory: directory)
            let paneID = UUID()
            let record = CodexAgentStateRecord(
                schemaVersion: 1, paneId: paneID.uuidString, state: "idle", detail: nil,
                runStartedAt: nil, updatedAt: "2026-09-09T00:00:00Z", lastHookEvent: nil,
                contextTokens: nil, pid: nil, lastPrompt: nil
            )
            try store.save(record)
            let path = directory.appendingPathComponent(paneID.uuidString + ".state.json.flock").path
            let fd = open(path, O_CREAT | O_RDWR, 0o600)
            #expect(fd >= 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
            let outcome = try store.update(recordID: record.storageID) { $0.state = "finished" }
            #expect(outcome == .busy)
            #expect(store.record(forPaneID: paneID)?.state == "idle")
        }
    }

    @Test func aggregate_sameRunAcrossTwoTabs_countsOnce() {
        let (session, _, paneA, _, paneB) = WindowSessionFixture.withTwoLooseTabs()
        let attention = AttentionState()
        let badge = AgentBadge(state: .finished, updatedAt: Date(timeIntervalSince1970: 100))
        attention.replaceRuntimes([AgentRuntimePresentation(
            kind: .codex, runID: UUID().uuidString, revision: 1, badge: badge,
            paneIDs: [paneA, paneB], tmuxLocations: [:]
        )], kind: .codex)
        #expect(attention.agentStateBreakdown(in: .loose, session: session)[.finished] == 1)
        #expect(attention.attentionEntries(in: session).count == 1)
    }
}
