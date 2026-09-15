// AgentRemediationRegressionTests.swift
// Limpid — failures found in the merge-readiness review.

import Foundation
import Testing
@testable import Limpid

@Suite("Agent remediation regressions")
@MainActor
struct AgentRemediationRegressionTests {
    private func record(paneID: UUID, runID: String, pid: String) -> AgentStateRecordFixture {
        AgentStateRecordFixture(
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
            let (session, _, _) = WindowSessionFixture.withLooseTab()
            let paneID = UUID(), runID = UUID().uuidString
            let states = directory.appendingPathComponent("states")
            let hints = directory.appendingPathComponent("sessions")
            try AgentRecordFixtures.write(record(paneID: paneID, runID: runID, pid: "2147483646"), to: states)
            try AgentRecordFixtures.write(AgentSessionHintFixture(
                paneId: paneID.uuidString,
                sessionId: UUID().uuidString,
                cwd: directory.path,
                updatedAt: "2026-09-09T00:00:00Z",
                runId: runID
            ), to: hints)
            let fd = open(hints.appendingPathComponent(paneID.uuidString + ".json.flock").path, O_CREAT | O_RDWR, 0o600)
            #expect(fd >= 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
            let projection = ProjectionFixture.adapter(state: states, sessions: hints)
            projection.bootstrap(into: session)
            #expect(AgentRecordFixtures.records(in: states).count == 1)
            #expect(AgentRecordFixtures.hint(forPaneID: paneID, in: hints) != nil)
            flock(fd, LOCK_UN)
            projection.refresh()
            #expect(AgentRecordFixtures.records(in: states).isEmpty)
            #expect(AgentRecordFixtures.hint(forPaneID: paneID, in: hints) == nil)
        }
    }

    @Test func shutdownIntent_protectsResumeDespiteRuntimeLock() throws {
        try withTempDir { directory in
            let (session, _, paneID) = WindowSessionFixture.withLooseTab()
            let runID = UUID().uuidString
            let states = directory.appendingPathComponent("states")
            let hints = directory.appendingPathComponent("sessions")
            try AgentRecordFixtures.write(record(paneID: paneID, runID: runID, pid: "12345"), to: states)
            try AgentRecordFixtures.write(AgentSessionHintFixture(
                paneId: paneID.uuidString,
                sessionId: UUID().uuidString,
                cwd: directory.path,
                updatedAt: "2026-09-09T00:00:00Z",
                runId: runID
            ), to: hints)
            var status = AgentProcessStatus.alive
            let intents = AgentResumeIntentStore(
                directory: states.appendingPathComponent("resume-intents", isDirectory: true)
            )
            let projection = ProjectionFixture.adapter(
                state: states, sessions: hints,
                resumeIntents: intents, processStatus: { _ in status }
            )
            projection.bootstrap(into: session)
            let fd = open(states.appendingPathComponent(runID + ".state.json.flock").path, O_CREAT | O_RDWR, 0o600)
            #expect(fd >= 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
            projection.prepareForTermination()
            #expect(intents.record(runID: runID) != nil)
            #expect(AgentRecordFixtures.records(in: states).first?.killedByLimpidAt == nil)
            flock(fd, LOCK_UN)
            status = .dead
            projection.prepareForLaunch()
            #expect(AgentRecordFixtures.hint(forPaneID: paneID, in: hints) != nil)
            #expect(AgentRecordFixtures.records(in: states).first?.resumeAttemptedAt != nil)
            #expect(intents.record(runID: runID) == nil)
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
