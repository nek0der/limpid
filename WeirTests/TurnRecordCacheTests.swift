// TurnRecordCacheTests.swift
// Weir — which turn records a pass hands the projection, and what comes back.
//
// The projection keeps what it read of every turn, so the cache sends a
// record's content only when the file changed. Sending too little loses a
// turn's ending; sending everything every pass costs a little more for every
// turn the person has ever run.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite("Turn records")
struct TurnRecordCacheTests {
    private static let run = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1"
    private static let first = "00000000-0000-4000-8000-000000000001"
    private static let second = "00000000-0000-4000-8000-000000000002"

    private func source(_ state: URL) throws -> TurnRecordCache.Source {
        try TurnRecordCache.Source(
            provider: "claude",
            directory: AgentRecordFixtures.turns(in: state),
            suffix: AgentRecordFixtures.layout().turnRecordSuffix
        )
    }

    // MARK: - What a pass sends

    @Test func pastItsBudget_aPassSendsTheRestByName_andTheNextSendsIt() throws {
        try withTempDir { state in
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            let cache = TurnRecordCache()

            // One record's worth: the second waits.
            let firstRead = try cache.read([source(state)], contentBudgetBytes: 1)
            #expect(!firstRead.isComplete)
            #expect(firstRead.files.map { $0.content != nil } == [true, false])
            cache.commit(firstRead)
            #expect(cache.unchanged()?.isComplete == false, "a pass that reads nothing knows it too")

            let secondRead = try cache.read([source(state)], contentBudgetBytes: 1)
            #expect(secondRead.isComplete)
            #expect(secondRead.files.map { $0.content != nil } == [false, true])
        }
    }

    /// A record too large for the bridge, sent, would fail every pass after
    /// it: a failed pass is tried again with the same content.
    @Test func aRecordTooLargeToSend_goesByName_andTheRestStillArrive() throws {
        try withTempDir { state in
            let large = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, in: state
            )
            try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            let content = try String(contentsOf: large, encoding: .utf8)
            try (content + String(repeating: " ", count: 4096)).write(to: large, atomically: true, encoding: .utf8)
            let cache = TurnRecordCache()

            let read = try cache.read([source(state)], maxRecordBytes: 2048)
            #expect(read.files.map(\.name) == [Self.first, Self.second])
            #expect(read.files.map { $0.content != nil } == [false, true])
            #expect(read.oversized == [large.path])
            #expect(read.isComplete, "nothing is left for a pass that would only hold it back again")
            #expect(!read.hasUnreadRecord)
            cache.commit(read)

            // Not read again, and still said, until the file changes.
            let again = try cache.read([source(state)], maxRecordBytes: 2048)
            #expect(again.files.allSatisfy { $0.content == nil })
            #expect(again.oversized == [large.path])
            #expect(cache.unchanged()?.oversized == [large.path])
            cache.commit(again)

            try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, phase: "failed", in: state
            )
            let shrunk = try cache.read([source(state)], maxRecordBytes: 2048)
            #expect(shrunk.files.first?.content?.contains("failed") == true)
            #expect(shrunk.oversized.isEmpty)
        }
    }

    /// The bridge refuses an input over 16 MiB; one record past it used to be
    /// read whole and sent on every pass.
    @Test func aRecordPastTheBridgeLimit_keepsThePassUnderIt() throws {
        try withTempDir { state in
            let large = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, in: state
            )
            try Data(count: 17 * 1024 * 1024).write(to: large)
            let read = try TurnRecordCache().read([source(state)])
            #expect(read.oversized == [large.path])
            let encoded = try JSONEncoder().encode(read.files)
            #expect(encoded.count < TurnRecordCache.maxRecordBytes)
        }
    }

    /// The budget counts content as encoded: escapes can take a record past
    /// the bridge's limit when its bytes alone are under it.
    @Test func encodedLength_isWhatJSONEncoderWrites() throws {
        let samples = ["", "plain", "a/b\\c\"d", "\n\t\r\u{8}\u{C}", "\u{1}\u{1F}\u{7F}", "日本語 é"]
        for sample in samples {
            let encoded = try JSONEncoder().encode([sample])
            // Less the brackets and the quotes.
            #expect(TurnRecordCache.encodedLength(of: sample) == encoded.count - 4, "\(sample.debugDescription)")
        }
    }

    @Test func aRecordIsSentOnce_untilItChanges() throws {
        try withTempDir { state in
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            let cache = TurnRecordCache()

            let firstRead = try cache.read([source(state)])
            #expect(firstRead.files.map(\.name) == [Self.first])
            #expect(firstRead.files.first?.content != nil)
            cache.commit(firstRead)

            let secondRead = try cache.read([source(state)])
            #expect(secondRead.files.map(\.name) == [Self.first], "still named, so the turn stays")
            #expect(secondRead.files.first?.content == nil)
            cache.commit(secondRead)

            // The hook ends the turn: a new file renamed over the old one.
            try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, phase: "failed", in: state
            )
            let thirdRead = try cache.read([source(state)])
            #expect(thirdRead.files.first?.content?.contains("failed") == true)
        }
    }

    @Test func aPassThatDoesNotLook_sendsEveryRecordByName() throws {
        // The sweep's pass: no directory read, and nothing the projection
        // holds is lost.
        try withTempDir { state in
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            let cache = TurnRecordCache()
            try cache.commit(cache.read([source(state)]))

            let unchanged = try #require(cache.unchanged())

            #expect(unchanged.files.map(\.name) == [Self.first, Self.second])
            #expect(unchanged.files.allSatisfy { $0.content == nil })
            cache.commit(unchanged)
            #expect(try cache.read([source(state)]).files.allSatisfy { $0.content == nil }, "still sent")
        }
    }

    @Test func aListThatCannotStandInForTheDirectories_isNotOffered() throws {
        // Then the sweep's pass reads the directories after all.
        try withTempDir { state in
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            let cache = TurnRecordCache()
            #expect(cache.unchanged() == nil, "nothing committed yet")

            try cache.commit(cache.read([source(state)]))
            #expect(cache.unchanged() != nil)

            cache.forgetLastList()
            #expect(cache.unchanged() == nil, "a pass failed after reading")

        }
    }

    @Test func aLinkNamedLikeARecord_isNotRead() throws {
        try withTempDir { state in
            let target = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, in: state
            )
            let link = try target.deletingLastPathComponent()
                .appendingPathComponent(Self.second + AgentRecordFixtures.layout().turnRecordSuffix)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            #expect(try TurnRecordCache().read([source(state)]).files.map(\.name) == [Self.first])
        }
    }

    @Test func aPassThatFailed_sendsTheContentAgain() throws {
        try withTempDir { state in
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            let cache = TurnRecordCache()

            // Read but never committed: the projection never took it in.
            _ = try cache.read([source(state)])
            let again = try cache.read([source(state)])

            #expect(again.files.first?.content != nil)
        }
    }

    /// The projection drops a turn whose name a pass leaves out, so a
    /// directory that could not be listed must not read as one emptied.
    @Test func aDirectoryThatCouldNotBeListed_keepsItsTurns_untilItCanBe() throws {
        try withTempDir { state in
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            let cache = TurnRecordCache()
            try cache.commit(cache.read([source(state)]))
            let directory = try source(state).directory
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

            let read = try cache.read([source(state)])
            #expect(read.files.map(\.name) == [Self.first, Self.second])
            #expect(read.files.allSatisfy { $0.content == nil }, "by name, which keeps what the projection read")
            #expect(read.hasUnreadRecord)
            cache.commit(read)
            #expect(cache.unchanged() == nil, "the next pass lists the directory again")
        }
    }

    /// A directory that is not there yet has no turns.
    @Test func aMissingDirectory_hasNoTurns() throws {
        try withTempDir { state in
            let cache = TurnRecordCache()
            let read = try cache.read([source(state)])
            #expect(read.files.isEmpty)
            #expect(!read.hasUnreadRecord)
        }
    }

    @Test func aRemovedRecord_isNoLongerSent() throws {
        try withTempDir { state in
            let url = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, in: state
            )
            try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            let cache = TurnRecordCache()
            try cache.commit(cache.read([source(state)]))
            try FileManager.default.removeItem(at: url)

            #expect(try cache.read([source(state)]).files.map(\.name) == [Self.second])
        }
    }

    @Test func aRecordReplacedWithTheSameSizeAndTime_isSentAgain() throws {
        // Only the inode tells this rewrite apart, as when a turn ends within
        // the clock tick it began in.
        try withTempDir { state in
            let url = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, in: state
            )
            let cache = TurnRecordCache()
            try cache.commit(cache.read([source(state)]))
            let modified = try #require(
                FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            )
            let staging = url.deletingLastPathComponent().appendingPathComponent(".replacement")
            try FileManager.default.copyItem(at: url, to: staging)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)

            #expect(try cache.read([source(state)]).files.first?.content != nil)
        }
    }

    @Test func aRecordThatCouldNotBeRead_isSentWhenItCanBe() throws {
        try withTempDir { state in
            let url = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, in: state
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            let cache = TurnRecordCache()

            let unreadable = try cache.read([source(state)])
            #expect(unreadable.files.map(\.name) == [Self.first], "named, so what was read stays")
            #expect(unreadable.files.first?.content == nil)
            cache.commit(unreadable)
            // Its file can change without its directory changing, so the
            // list does not stand in for the next pass's.
            #expect(cache.unchanged() == nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

            #expect(try cache.read([source(state)]).files.first?.content != nil)
        }
    }

    @Test func aFileInProgressOrOfAnotherKind_isNotARecord() throws {
        try withTempDir { state in
            let directory = try AgentRecordFixtures.turns(in: state)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: directory.appendingPathComponent(".T.turn.json"))
            try Data("{}".utf8).write(to: directory.appendingPathComponent("0123abcd.counter"))

            #expect(try TurnRecordCache().read([source(state)]).files.isEmpty)
        }
    }

    // MARK: - Reading what comes back

    @Test func aTurnFromANewerWriter_readsAsUnknown() throws {
        let json = #"""
        {"turnId":"T","conversation":{"provider":"claude","conversationId":"s","isFallback":false},
         "runId":"R","paneId":"P","displayNumber":3,"startedAt":"2026-10-12T00:00:00Z",
         "phase":"paused","changes":{"kind":"partial"},"hasPrompt":true}
        """#
        let turn = try JSONDecoder().decode(TurnSummary.self, from: Data(json.utf8))

        #expect(turn.phase == .unknown)
        #expect(turn.changes == .unknown)
        #expect(turn.displayNumber == 3)
    }

    @Test func aConversationOfAProviderThisBuildLacks_isDropped() throws {
        let json = #"""
        [{"key":{"provider":"gemini","conversationId":"g","isFallback":false},"turns":[]},
         {"key":{"provider":"claude","conversationId":"s","isFallback":false},"turns":[]}]
        """#
        let list = try JSONDecoder().decode(
            AgentProjectionLossyList<ConversationTurns>.self, from: Data(json.utf8)
        )

        #expect(list.elements.map(\.key.conversationID) == ["s"])
    }

    // MARK: - Through a pass

    private func adapter(
        state: URL,
        sessions: URL,
        engine: any ProjectionPassing = WeirProjectionBridge.Engine()
    ) -> AgentProjectionAdapter {
        ProjectionFixture.adapter(
            provider: "claude",
            state: state,
            sessions: sessions,
            resumeIntents: AgentResumeIntentStore(directory: state.deletingLastPathComponent()
                .appendingPathComponent("resume-intents", isDirectory: true)),
            processStatus: { _ in .alive },
            engine: engine
        )
    }

    private func writeRun(
        session: String,
        currentTurn: String?,
        state runState: String = "finished",
        revision: Int = 4,
        in state: URL
    ) throws {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        var record: [String: Any] = [
            "schemaVersion": 3,
            "paneId": UUID().uuidString,
            "runId": Self.run,
            "revision": revision,
            "state": runState,
            "updatedAt": "2026-10-12T00:01:30Z",
            "pid": "4242",
            "sessionId": session
        ]
        record["currentTurnId"] = currentTurn
        try JSONSerialization.data(withJSONObject: record)
            .write(to: state.appendingPathComponent(AgentRecordFixtures.recordFileName(Self.run)))
    }

    @Test func aPass_putsTheRecordedTurnsInTheHistory() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s1", currentTurn: Self.second, in: state)
            try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, phase: "started",
                changes: #"{"kind":"pending"}"#, in: state
            )
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let attention = AttentionState()
            let adapter = adapter(state: state, sessions: sessions)

            adapter.bootstrap(into: session, attention: attention)

            let key = ConversationKey(provider: .claude, conversationID: "s1", isFallback: false)
            let turns = adapter.turnHistory.turns(of: key)
            #expect(turns.map(\.displayNumber) == [1, 2])
            // The first is still started behind a later one: overtaken, so
            // not running and not known.
            #expect(turns.first?.phase == .unknown)
            #expect(turns.first?.changes == .unavailable(reason: "endMissing"))
            #expect(turns.last?.changes == .changed(files: 2, added: 94, removed: 2))
            #expect(turns.last?.hasShellChanges == false)
            #expect(turns.last?.largeFilesSkipped == 0)
            let runtime = try #require(attention.allRuntimes.first)
            #expect(runtime.conversation == key)
            #expect(runtime.currentTurnID == TurnID(Self.second))
            #expect(adapter.turnHistory.turn(TurnID(Self.second))?.displayNumber == 2)
        }
    }

    @Test func aFileEventOutsideTheTurns_goesByTheLastList_andOneInsideListsThemAgain() async throws {
        try await withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s1", currentTurn: nil, in: state)
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let adapter = adapter(state: state, sessions: sessions)
            adapter.bootstrap(into: session, attention: AttentionState())
            try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)

            // A run record changed, or tmux, attention, or the sweep asked:
            // the turns are not listed again, and the ones known stay.
            adapter.requestPass()
            await adapter.passesSettled()
            #expect(adapter.turnHistory.turn(TurnID(Self.second)) == nil)
            #expect(adapter.turnHistory.turn(TurnID(Self.first))?.displayNumber == 1)

            adapter.noteTurnsChanged()
            adapter.requestPass()
            await adapter.passesSettled()
            #expect(adapter.turnHistory.turn(TurnID(Self.second))?.displayNumber == 2)
        }
    }

    @Test func aRecordWrittenBeforeTheWatchStarted_isListed() async throws {
        try await withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s1", currentTurn: nil, in: state)
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let adapter = adapter(state: state, sessions: sessions)
            adapter.bootstrap(into: session, attention: AttentionState())
            // Between the first listing and the descriptors opening.
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)

            adapter.startWatching()
            defer { adapter.stopWatching() }
            adapter.requestPass()
            await adapter.passesSettled()

            #expect(adapter.turnHistory.turn(TurnID(Self.first))?.displayNumber == 1)
        }
    }

    @Test func aRecordThatCouldNotBeRead_isReadByTheNextPass_withoutItsDirectoryChanging() async throws {
        try await withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s1", currentTurn: nil, in: state)
            let url = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, in: state
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let adapter = adapter(state: state, sessions: sessions)
            adapter.bootstrap(into: session, attention: AttentionState())
            #expect(adapter.turnHistory.turn(TurnID(Self.first)) == nil)

            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            adapter.requestPass()
            await adapter.passesSettled()

            #expect(adapter.turnHistory.turn(TurnID(Self.first))?.displayNumber == 1)
        }
    }

    @Test func theRecordsAreSentInNameOrder() throws {
        try withTempDir { state in
            let ids = (1...12).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
            for (index, id) in ids.reversed().enumerated() {
                try AgentRecordFixtures.writeTurn(id: id, number: index + 1, session: "s1", runID: Self.run, in: state)
            }
            #expect(try TurnRecordCache().read([source(state)]).files.map(\.name) == ids)
        }
    }

    @Test func aPassAskedForWhileOneRuns_runsAfterIt_andReadsWhatChanged() async throws {
        try await withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s1", currentTurn: nil, in: state)
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let attention = AttentionState()
            let adapter = adapter(state: state, sessions: sessions)
            adapter.bootstrap(into: session, attention: attention)

            // The run records are read on the main actor before the pass
            // leaves it, so this one has read the finished record already.
            adapter.requestPass()
            try writeRun(session: "s1", currentTurn: nil, state: "running", revision: 5, in: state)
            adapter.requestPass()
            adapter.requestPass()
            await adapter.passesSettled()

            #expect(attention.allRuntimes.first?.badge.state == .running, "the pass owed afterwards read it")
            #expect(adapter.lastFailure == nil)
        }
    }

    @Test func aPassRunInPlace_isNotUndoneByARequestedOneThatStartedBefore() async throws {
        try await withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s1", currentTurn: nil, in: state)
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let attention = AttentionState()
            let adapter = adapter(state: state, sessions: sessions)
            adapter.bootstrap(into: session, attention: attention)

            // Read the finished record; its answer comes back after the pass
            // below has applied the running one.
            adapter.requestPass()
            try writeRun(session: "s1", currentTurn: nil, state: "running", revision: 5, in: state)
            adapter.refresh()
            #expect(attention.allRuntimes.first?.badge.state == .running)
            await adapter.passesSettled()

            #expect(attention.allRuntimes.first?.badge.state == .running)
            #expect(adapter.lastFailure == nil, "dropped, not reported as a failure")
        }
    }

    @Test func aMarkSetWhileAPassRuns_isKept() async throws {
        try await withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s1", currentTurn: nil, in: state)
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let attention = AttentionState()
            let adapter = adapter(state: state, sessions: sessions)
            adapter.bootstrap(into: session, attention: attention)
            let runtime = try #require(attention.allRuntimes.first)

            // The pass reads the marks before the person views the run, here
            // by reading its notification (the run's pane is in no tab).
            adapter.requestPass()
            attention.markFinishedRuntimesViewed(matching: [runtime.id: [runtime.attentionEventToken]])
            await adapter.passesSettled()

            #expect(attention.viewedRuntimeTokens[runtime.id] == runtime.attentionEventToken)
            // The pass that change asks for keeps it, the run still being there.
            adapter.requestPass()
            await adapter.passesSettled()
            #expect(attention.viewedRuntimeTokens[runtime.id] == runtime.attentionEventToken)
        }
    }

    @Test func aPassThatFailed_changesNothing_andTheNextOneCatchesUp() async throws {
        try await withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s1", currentTurn: nil, in: state)
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let attention = AttentionState()
            let engine = FailingEngine()
            let adapter = adapter(state: state, sessions: sessions, engine: engine)
            adapter.bootstrap(into: session, attention: attention)

            engine.fails(true)
            try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            try writeRun(session: "s1", currentTurn: nil, state: "running", revision: 5, in: state)
            adapter.noteTurnsChanged()
            adapter.requestPass()
            await adapter.passesSettled()
            #expect(adapter.lastFailure != nil)
            #expect(attention.allRuntimes.first?.badge.state == .finished)
            #expect(adapter.turnHistory.turn(TurnID(Self.second)) == nil)

            // Asked for by something other than the turn directory: what the
            // failed pass read never arrived, so this one lists them again.
            engine.fails(false)
            adapter.requestPass()
            await adapter.passesSettled()
            #expect(adapter.lastFailure == nil)
            #expect(attention.allRuntimes.first?.badge.state == .running)
            #expect(adapter.turnHistory.turn(TurnID(Self.second))?.displayNumber == 2)
        }
    }

    /// One pass over 200 turns in each of five conversations, read cold and
    /// then with nothing changed. The times are printed for a person to
    /// compare and not checked: a bound that fails cannot tell a regression
    /// from a slow machine. Off unless `WEIR_MEASURE=1` (`make test-measure`).
    @Test(.tags(.measurement), .enabled(if: ProcessInfo.processInfo.environment["WEIR_MEASURE"] == "1"))
    func aPassOverAThousandTurns_isTimed() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s0", currentTurn: nil, in: state)
            for conversation in 0..<5 {
                for number in 1...200 {
                    try AgentRecordFixtures.writeTurn(
                        id: UUID().uuidString, number: number, session: "s\(conversation)",
                        runID: Self.run, in: state
                    )
                }
            }
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let adapter = adapter(state: state, sessions: sessions)
            let clock = ContinuousClock()

            let cold = clock.measure { adapter.bootstrap(into: session, attention: AttentionState()) }
            let warm = clock.measure { adapter.refresh() }

            print("TurnRecordCacheTests: 1000 turns, cold pass \(cold), warm pass \(warm)")
            #expect(adapter.turnHistory.conversations.count == 5)
            #expect(adapter.turnHistory.conversations.values.allSatisfy { $0.count == 200 })
        }
    }
}
