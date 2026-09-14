// AgentStateRecordSchemaTests.swift
// Limpid — the Swift readers accept the version 3 records the Rust hook
// runtime writes, alongside the version 2 records the shell receivers wrote.

import Foundation
import Testing
@testable import Limpid

@Suite("Agent state record schema")
struct AgentStateRecordSchemaTests {
    /// A record as `limpid-agent-hook` writes it after a turn finished: no
    /// `runStartedAt` and no `detail` rather than empty strings, a neutral
    /// `lastHookEvent`, and a field this build does not know.
    private static let versionThree = """
    {"schemaVersion":3,"paneId":"6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10","runId":"6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11",\
    "revision":4,"stateEpisodeToken":"4","state":"finished","updatedAt":"2026-09-14T00:00:05Z",\
    "lastHookEvent":"turn_finished","pid":"4242","lastPrompt":"first","firstPrompt":"first",\
    "sessionId":"00000000-0000-4000-8000-000000000001","providerSessionTitle":"Formal",\
    "sessionStartedAt":"2026-09-14T00:00:00Z","turnBaseTree":"0123456789abcdef0123456789abcdef01234567",\
    "turnRoot":"/tmp/example","futureField":{"nested":true}}
    """

    @Test("decodes a version 3 Claude record with absent optionals")
    func claudeRecord_versionThree_decodes() throws {
        let record = try JSONDecoder().decode(ClaudeAgentStateRecord.self, from: Data(Self.versionThree.utf8))
        #expect(record.schemaVersion == 3)
        #expect(record.state == "finished")
        #expect(record.runStartedAt == nil)
        #expect(record.detail == nil)
        #expect(record.revision == 4)
        #expect(record.stateEpisodeToken == "4")
        #expect(record.sessionId == "00000000-0000-4000-8000-000000000001")
        #expect(record.providerSessionTitle == "Formal")
        #expect(record.storageID == "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11")
        #expect(record.isTmuxRuntime == false)

        let badge = try #require(ClaudeAgent.makeBadge(from: record))
        #expect(badge.state == .finished)
        #expect(badge.runStartedAt == nil)
        #expect(badge.firstPrompt == "first")
        #expect(badge.providerSessionTitle == "Formal")
    }

    @Test("decodes a version 3 Codex record with absent optionals")
    func codexRecord_versionThree_decodes() throws {
        let record = try JSONDecoder().decode(CodexAgentStateRecord.self, from: Data(Self.versionThree.utf8))
        #expect(record.schemaVersion == 3)
        #expect(record.runStartedAt == nil)
        #expect(record.killedByLimpidAt == nil)
        let badge = try #require(CodexAgent.makeBadge(from: record))
        #expect(badge.state == .finished)
        #expect(badge.runStartedAt == nil)
    }

    @Test("treats a version 2 empty runStartedAt and a version 3 null alike")
    func runStartedAt_emptyAndAbsent_bothMeanNotRunning() throws {
        let versionTwo = Self.versionThree
            .replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":2")
            .replacingOccurrences(of: "\"state\":\"finished\"", with: "\"state\":\"finished\",\"runStartedAt\":\"\",\"detail\":\"\"")
        let two = try JSONDecoder().decode(ClaudeAgentStateRecord.self, from: Data(versionTwo.utf8))
        let three = try JSONDecoder().decode(ClaudeAgentStateRecord.self, from: Data(Self.versionThree.utf8))
        let badgeTwo = try #require(ClaudeAgent.makeBadge(from: two))
        let badgeThree = try #require(ClaudeAgent.makeBadge(from: three))
        #expect(badgeTwo.runStartedAt == nil)
        #expect(badgeThree.runStartedAt == nil)
        #expect(badgeTwo.state == badgeThree.state)
    }
}
