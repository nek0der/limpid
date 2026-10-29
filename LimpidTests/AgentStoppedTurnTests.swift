// AgentStoppedTurnTests.swift
// Limpid — a Claude turn the person stopped at its own prompt leaves the row, the bar, and the list, and its record is closed.

import Foundation
import Synchronization
import Testing
@testable import Limpid

/// Esc at Claude's question sends no hook, so the run record keeps saying the
/// run waits, and Esc or Ctrl+C while it works sends none either, so the
/// record keeps saying it works. The projection reads the transcript the
/// record names, or Claude's own status report, and what the window shows
/// follows from the runtime it returns; the pass also asks for the record
/// and its turn to be ended, which the adapter hands to the bridge's writer:
/// once when the write settles, and up to `StoppedTurnCloser.maximumAttempts`
/// times when it does not. These cases go from the record the hook runtime
/// writes to what the pane's tab, the attention list, and the decision bar
/// make of it, through the real rules.
@MainActor
@Suite("A Claude turn the person stopped")
struct AgentStoppedTurnTests {
    /// This is a run of the corpus, as the hook runtime wrote it from
    /// recorded payloads (`rust/fixtures/projection`).
    private struct Corpus {
        let scenario: String
        let run: String
        let pane: String

        /// This waits on a question inside a turn.
        static let waiting = Self(
            scenario: "needs-input",
            run: "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
            pane: "11111111-1111-4111-8111-111111111111"
        )
        /// This works on a tool inside a turn.
        static let working = Self(
            scenario: "sweep-dead-pid-open-pane",
            run: "CCCCCCCC-3333-4333-8333-CCCCCCCCCCC3",
            pane: "33333333-3333-4333-8333-333333333333"
        )
    }

    /// This is what one projection pass made of the waiting record.
    private struct Pass {
        let runtime: AgentRuntimePresentation?
        let tabState: AgentState?
        let items: [AttentionItem]
        let bar: DecisionBarContent
    }

    /// This holds the corpus's waiting question in a scratch directory, and
    /// an adapter over it.
    @MainActor
    private struct Scene {
        let adapter: AgentProjectionAdapter
        let attention: AttentionState
        let session: WorkspaceSession
        let tab: Tab
        let pane: UUID
        let recordURL: URL
        let transcriptURL: URL

        /// Returns what the adapter's last pass made of the record.
        func pass() -> Pass {
            let runtimes = attention.allRuntimes
            let input = AttentionQueueStore.makeInput(
                runtimes: runtimes,
                isRead: { _ in false },
                // Claude records its turns, and the turn the question
                // stopped lists no unread turn here (`UnreadTurnRules.byRuntime`).
                unreadTurns: Dictionary(uniqueKeysWithValues: runtimes.map { ($0.id, []) }),
                approvals: [],
                session: session,
                isApprovalServiceRunning: false
            )
            let items = AttentionQueueReducer.reduce(AttentionQueue(), input: input).0.items(inPane: pane)
            return Pass(
                runtime: runtimes.first,
                tabState: session.tab(tab.id)?.agentBadges[.claude]?[pane]?.state,
                items: items,
                bar: DecisionBarContent.make(.init(items: items))
            )
        }

        /// Reads the record on disk as JSON.
        func record() throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        }
    }

    /// Runs `body` on the corpus's run `corpus`, the waiting question unless
    /// told otherwise, moved to the session's pane, with its transcript at
    /// `transcript` (a file under `rust/fixtures/transcripts`), and with the
    /// adapter bootstrapped once.
    private func withScene<T>(
        _ corpus: Corpus = .waiting,
        transcript: String,
        stoppedTurns: StoppedTurnCloser,
        _ body: (Scene) async throws -> T
    ) async throws -> T {
        let root = try #require(RepoFixture.limpidRoot)
        let fixtures = root.appendingPathComponent("rust/fixtures", isDirectory: true)
        var record = try String(
            contentsOf: fixtures.appendingPathComponent(
                "projection/\(corpus.scenario)/agent-states/\(corpus.run).state.json"
            ),
            encoding: .utf8
        )
        let corpusTranscript = "/Users/example/.claude/projects/-tmp-example/00000000-0000-4000-8000-0000000000ff.jsonl"
        #expect(record.contains(corpus.pane))
        #expect(record.contains(corpusTranscript), "the hook keeps the turn's transcript")
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        return try await withTempDir { directory in
            let state = directory.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
            for folder in [state, sessions] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let transcriptURL = directory.appendingPathComponent("session.jsonl")
            try Data(contentsOf: fixtures.appendingPathComponent("transcripts/\(transcript)")).write(to: transcriptURL)
            record = record
                .replacingOccurrences(of: corpus.pane, with: pane.uuidString)
                .replacingOccurrences(of: corpusTranscript, with: transcriptURL.path)
            let recordURL = try state.appendingPathComponent(AgentRecordFixtures.recordFileName(corpus.run))
            try Data(record.utf8).write(to: recordURL)
            let adapter = ProjectionFixture.adapter(
                provider: "claude",
                state: state,
                sessions: sessions,
                processStatus: { _ in .alive },
                stoppedTurns: stoppedTurns
            )
            let attention = AttentionState()
            adapter.bootstrap(into: session, attention: attention)
            #expect(adapter.lastFailure == nil)
            let scene = Scene(
                adapter: adapter,
                attention: attention,
                session: session,
                tab: tab,
                pane: pane,
                recordURL: recordURL,
                transcriptURL: transcriptURL
            )
            let result = try await body(scene)
            // We let the writes and passes settle, so nothing is left to
            // write into the directory once it goes.
            await stoppedTurns.writesSettled()
            await adapter.passesSettled()
            return result
        }
    }

    /// This records the writes a closer was asked for, answers each with
    /// `outcome`, and never performs one.
    private final class Requests: Sendable {
        private let asked = Mutex<[StoppedTurnRequest]>([])
        let outcome: StoppedTurnEnd

        init(answering outcome: StoppedTurnEnd) {
            self.outcome = outcome
        }

        var all: [StoppedTurnRequest] {
            asked.withLock { $0 }
        }

        @MainActor
        func closer() -> StoppedTurnCloser {
            StoppedTurnCloser { [self] request in
                asked.withLock { $0.append(request) }
                return outcome
            }
        }
    }

    private static func isPrompt(_ item: AttentionItem) -> Bool {
        if case .prompt = item.kind {
            true
        } else {
            false
        }
    }

    @Test(.disabled(if: !RepoFixture.hasLocalRepo))
    func aQuestionStillUp_isListedAndShownInTheBarAsAQuestion() async throws {
        let requests = Requests(answering: .ended)
        try await withScene(transcript: "claude-2.1.309-question-open.jsonl", stoppedTurns: requests.closer()) { scene in
            let pass = scene.pass()
            #expect(pass.runtime?.badge.state == .needsInput)
            #expect(pass.runtime?.badge.promptWaitKind == .question)
            #expect(pass.tabState == .needsInput)
            let prompt = try #require(pass.items.first(where: Self.isPrompt))
            #expect(pass.bar.itemID == prompt.id)
        }
        #expect(requests.all.isEmpty, "a wait still up is not ended")
    }

    @Test(.disabled(if: !RepoFixture.hasLocalRepo))
    func aQuestionDeclinedWithEsc_leavesTheRowTheListAndTheBar() async throws {
        let requests = Requests(answering: .ended)
        try await withScene(transcript: "claude-2.1.309-question-declined.jsonl", stoppedTurns: requests.closer()) { scene in
            let pass = scene.pass()
            #expect(pass.runtime?.badge.state == .finished)
            #expect(pass.runtime?.badge.promptWaitKind == nil)
            #expect(pass.runtime?.badge.detail == nil)
            #expect(pass.runtime?.badge.isWaitDeclined == true, "the bar says declined, not answered")
            #expect(pass.tabState == .finished)
            // Nothing is left to list for the wait, so the bar does not ask.
            #expect(!pass.items.contains(where: Self.isPrompt))
            #expect(pass.bar.itemID == nil)
        }
    }

    @Test(.disabled(if: !RepoFixture.hasLocalRepo))
    func aQuestionDeclinedWithEsc_isHandedToTheWriterOnce_notOnEveryPass() async throws {
        let requests = Requests(answering: .ended)
        let closer = requests.closer()
        try await withScene(transcript: "claude-2.1.309-question-declined.jsonl", stoppedTurns: closer) { scene in
            await closer.writesSettled()
            // The writer here writes nothing, so every pass reads the wait
            // declined and asks again.
            for _ in 0..<3 {
                scene.adapter.refresh()
                await closer.writesSettled()
            }
            let request = try #require(requests.all.first)
            #expect(requests.all.count == 1)
            #expect(request.provider == "claude")
            #expect(request.storageID == Corpus.waiting.run)
            #expect(request.transcriptPath == scene.transcriptURL.path)
            #expect(request.stateDirectory == scene.recordURL.deletingLastPathComponent())
            let record = try scene.record()
            #expect(request.episodeToken == record["stateEpisodeToken"] as? String)
            #expect(request.turnID == record["currentTurnId"] as? String)
        }
    }

    @Test(.disabled(if: !RepoFixture.hasLocalRepo))
    func aWriteThatDoesNotLand_isTriedABoundedNumberOfTimes() async throws {
        let requests = Requests(answering: .busy)
        let closer = requests.closer()
        try await withScene(transcript: "claude-2.1.309-question-declined.jsonl", stoppedTurns: closer) { scene in
            for _ in 0..<(StoppedTurnCloser.maximumAttempts + 3) {
                await closer.writesSettled()
                scene.adapter.refresh()
            }
            await closer.writesSettled()
            #expect(requests.all.count == StoppedTurnCloser.maximumAttempts)
            // The badge alone still shows the turn stopped.
            #expect(scene.pass().runtime?.badge.state == .finished)
        }
    }

    @Test(.disabled(if: !RepoFixture.hasLocalRepo))
    func aQuestionDeclinedWithEsc_isClosedOnDisk_byTheBridgesWriter() async throws {
        let closer = StoppedTurnCloser()
        try await withScene(transcript: "claude-2.1.309-question-declined.jsonl", stoppedTurns: closer) { scene in
            let token = try scene.record()["stateEpisodeToken"] as? String
            await closer.writesSettled()
            let record = try scene.record()
            #expect(record["state"] as? String == "finished")
            #expect(record["runStartedAt"] == nil || record["runStartedAt"] is NSNull)
            #expect(record["transcriptPath"] == nil)
            #expect(record["waitKind"] == nil)
            #expect(record["stateEpisodeToken"] as? String == token, "the finish the badge showed is no new episode")

            scene.adapter.refresh()
            let pass = scene.pass()
            #expect(pass.runtime?.badge.state == .finished)
            #expect(pass.runtime?.badge.isWaitDeclined == false, "the record says it now")
            #expect(pass.runtime?.stateEpisodeToken == token)
            #expect(!pass.items.contains(where: Self.isPrompt))
        }
    }

    /// Returns the report Claude Code makes over OSC 7501 once the person
    /// answers "No" at its prompt, or stops its work with Esc or Ctrl+C:
    /// idle again, in the same second the record last changed.
    private static func reportedIdle(in scene: Scene) throws -> [String: AgentProjectionProgramStatus] {
        let changed = try #require(scene.record()["updatedAt"] as? String)
        return [scene.pane.uuidString: AgentProjectionProgramStatus(app: "claude-code", state: "idle", observedAt: changed)]
    }

    @Test(.disabled(if: !RepoFixture.hasLocalRepo))
    func aWaitClaudeReportsIdleAfter_leavesTheRow_thoughTheTranscriptShowsItOpen() async throws {
        let requests = Requests(answering: .ended)
        let closer = requests.closer()
        try await withScene(transcript: "claude-2.1.309-question-open.jsonl", stoppedTurns: closer) { scene in
            let report = try Self.reportedIdle(in: scene)
            scene.adapter.programStatus = { report }
            scene.adapter.refresh()
            await closer.writesSettled()
            let pass = scene.pass()
            #expect(pass.runtime?.badge.state == .finished)
            #expect(pass.runtime?.badge.isWaitDeclined == true)
            #expect(!pass.items.contains(where: Self.isPrompt))
            let request = try #require(requests.all.first)
            #expect(request.byProgramStatus, "the writer is told not to ask the transcript")
        }
    }

    @Test(.disabled(if: !RepoFixture.hasLocalRepo))
    func aWaitClaudeReportsIdleAfter_isClosedOnDisk_byTheBridgesWriter() async throws {
        let closer = StoppedTurnCloser()
        try await withScene(transcript: "claude-2.1.309-question-open.jsonl", stoppedTurns: closer) { scene in
            let report = try Self.reportedIdle(in: scene)
            scene.adapter.programStatus = { report }
            scene.adapter.refresh()
            await closer.writesSettled()
            let record = try scene.record()
            #expect(record["state"] as? String == "finished")
            #expect(record["waitKind"] == nil)
        }
    }

    @Test(.disabled(if: !RepoFixture.hasLocalRepo))
    func workClaudeReportsIdleIn_leavesTheRowAndAnnouncesNothing() async throws {
        let requests = Requests(answering: .ended)
        let closer = requests.closer()
        try await withScene(.working, transcript: "claude-2.1.309-question-open.jsonl", stoppedTurns: closer) { scene in
            #expect(scene.pass().runtime?.badge.state == .running)
            #expect(scene.pass().tabState == .running)

            let report = try Self.reportedIdle(in: scene)
            scene.adapter.programStatus = { report }
            scene.adapter.refresh()
            await closer.writesSettled()
            let pass = scene.pass()
            #expect(pass.runtime?.badge.state == .finished)
            #expect(pass.runtime?.badge.tool == nil)
            #expect(pass.runtime?.badge.stopReason == "interrupted")
            #expect(pass.runtime?.badge.isWaitDeclined == false, "work was stopped, not a wait declined")
            #expect(pass.tabState == .finished)
            let request = try #require(requests.all.first)
            #expect(requests.all.count == 1)
            #expect(request.storageID == Corpus.working.run)
            #expect(request.byProgramStatus)
            #expect(request.transcriptPath == scene.transcriptURL.path)
        }
    }

    @Test(.disabled(if: !RepoFixture.hasLocalRepo))
    func workClaudeReportsIdleIn_isClosedOnDisk_byTheBridgesWriter() async throws {
        let closer = StoppedTurnCloser()
        try await withScene(.working, transcript: "claude-2.1.309-question-open.jsonl", stoppedTurns: closer) { scene in
            let token = try scene.record()["stateEpisodeToken"] as? String
            let report = try Self.reportedIdle(in: scene)
            scene.adapter.programStatus = { report }
            scene.adapter.refresh()
            await closer.writesSettled()
            let record = try scene.record()
            #expect(record["state"] as? String == "finished")
            #expect(record["tool"] == nil)
            #expect(record["transcriptPath"] == nil)
            #expect(record["lastHookEvent"] as? String == "interrupted")
            #expect(record["stateEpisodeToken"] as? String == token, "the finish the badge showed is no new episode")
        }
    }

    /// An MCP server's request for input sends no hook, only Claude's
    /// report that it is blocked on a question. The work is not stopped:
    /// the row waits on the answer, and the record is left as it is.
    @Test(.disabled(if: !RepoFixture.hasLocalRepo))
    func aQuestionClaudeReportsDuringWork_isListedAsOne_andStopsNothing() async throws {
        let requests = Requests(answering: .ended)
        let closer = requests.closer()
        try await withScene(.working, transcript: "claude-2.1.309-question-open.jsonl", stoppedTurns: closer) { scene in
            let changed = try #require(scene.record()["updatedAt"] as? String)
            let report = [scene.pane.uuidString: AgentProjectionProgramStatus(
                app: "claude-code",
                state: "blocked",
                kind: "question",
                observedAt: changed
            )]
            scene.adapter.programStatus = { report }
            scene.adapter.refresh()
            await closer.writesSettled()
            let pass = scene.pass()
            #expect(pass.runtime?.badge.state == .needsInput)
            #expect(pass.runtime?.badge.promptWaitKind == .question)
            #expect(pass.tabState == .needsInput)
            #expect(pass.items.map(\.kind) == [.prompt(.question(detail: nil))])
            #expect(requests.all.isEmpty)
            #expect(try scene.record()["state"] as? String == "running")
        }
    }
}
