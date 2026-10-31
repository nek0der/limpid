// BackgroundWorkTests.swift
// Weir — work an agent left running after its turn: read from the projection, marked on the rows, and said on the decision bar.

import Foundation
import Testing
@testable import Weir

@MainActor
struct BackgroundWorkTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let pane = UUID()
    private static let resting = SessionRowFact.Agent(provider: .claude, state: .finished, detail: nil)

    private static func badge(_ backgroundWork: String?) throws -> AgentBadge {
        try AgentBadge.decoded(field: "backgroundWork", value: backgroundWork)
    }

    /// `work` as the run of `items`' first item left it, or as the pane's
    /// run when the bar has no item to match.
    private static func ofRun(
        _ work: BackgroundWork,
        of items: [AttentionItem] = []
    ) -> DecisionBarContent.RuntimeBackgroundWork {
        .init(runtimeID: items.first?.subject.runtimeID ?? "claude:run", work: work)
    }

    private static func model(_ input: DecisionBarContent.Input, locale: Locale = english) -> DecisionBarModel {
        DecisionBarModel(content: DecisionBarContent.make(input), locale: locale)
    }

    // MARK: - Projection

    @Test func badge_readsEachCount_andAKindLeftOutAsZero() throws {
        #expect(try Self.badge(#"{"shells":2,"subagents":1}"#).backgroundWork == BackgroundWork(shells: 2, subagents: 1, others: 0))
        #expect(try Self.badge(#"{"others":3}"#).backgroundWork == BackgroundWork(shells: 0, subagents: 0, others: 3))
    }

    @Test func badge_withoutTheField_hasNoBackgroundWork() throws {
        #expect(try Self.badge(nil).backgroundWork == nil)
        #expect(try Self.badge("null").backgroundWork == nil)
    }

    /// A shape this build cannot read costs the sentence, never the badge.
    @Test func badge_aShapeItCannotRead_costsTheWorkAlone() throws {
        for shape in [#""two""#, "[1,2]", "7", "{}", #"{"shells":0}"#, #"{"shells":"2"}"#, #"{"shells":-1}"#] {
            let badge = try Self.badge(shape)
            #expect(badge.backgroundWork == nil, "\(shape)")
            #expect(badge.state == .finished)
        }
        // One count of another type does not take the others with it.
        #expect(try Self.badge(#"{"shells":"2","subagents":1}"#).backgroundWork == BackgroundWork(subagents: 1))
    }

    /// The badge is persisted with the session; a count left out reads as
    /// zero, however the counts were spelled when it was written.
    @Test func persistedWork_readsAMissingCountAsZero() throws {
        let work = try JSONDecoder().decode(BackgroundWork.self, from: Data(#"{"shells":1}"#.utf8))
        #expect(work == BackgroundWork(shells: 1))
        let written = try JSONEncoder().encode(BackgroundWork(subagents: 2))
        #expect(try JSONDecoder().decode(BackgroundWork.self, from: written) == BackgroundWork(subagents: 2))
    }

    // MARK: - Decision bar

    @Test func lastTurn_saysWhatStillRuns_afterItsReceipt() {
        let turn = UnreadTurn(turnID: TurnID("T3"), numbers: 3...3, changes: .unchanged)
        let input = DecisionBarContent.Input(agent: Self.resting, lastTurn: turn, backgroundWork: Self.ofRun(BackgroundWork(shells: 1)))

        let bar = Self.model(input)
        #expect(bar.text == "T3 · No file changes · 1 shell still running in the background")
        #expect(bar.spokenText == "Turn 3, No file changes, 1 shell still running in the background")
        #expect(bar.runs.last == ReceiptRun(text: "1 shell still running in the background", role: .plain))
        #expect(bar.runs.map(\.text).joined() == bar.text)
        #expect(bar.tone == .muted, "the run is finished, and nothing waits on the person")

        let japanese = Self.model(input, locale: Self.japanese)
        #expect(japanese.text == "T3 · ファイルの変更なし · バックグラウンドでシェル 1 件が実行中")
    }

    @Test func unread_saysWhatStillRuns_afterItsReceipt() {
        let turn = UnreadTurn(turnID: TurnID("T6"), numbers: 6...6, changes: .changed(files: 2, added: 94, removed: 2))
        let items = AttentionItem.testList([.unread(turn)], pane: Self.pane)
        let work = BackgroundWork(shells: 2, subagents: 1)
        let input = DecisionBarContent.Input(items: items, agent: Self.resting, backgroundWork: Self.ofRun(work, of: items))

        let bar = Self.model(input)
        #expect(bar.tag == "T6")
        #expect(bar.text == "2 files +94 −2 · 2 shells and 1 subagent still running in the background")
        #expect(bar.spokenText == "2 files +94 −2, 2 shells and 1 subagent still running in the background")
        #expect(bar.runs.map(\.text).joined() == bar.text)
        #expect(bar.primaryAction != nil, "Mark as Viewed stays")

        let japanese = Self.model(input, locale: Self.japanese)
        #expect(japanese.text.hasSuffix(" · バックグラウンドでシェル 2 件、サブエージェント 1 件が実行中"))
    }

    /// A pane can hold two runs: the work one left is not said beside the
    /// other's unread turn.
    @Test func unread_ofAnotherRun_doesNotSayIt() {
        let turn = UnreadTurn(turnID: TurnID("T2"), numbers: 2...2, changes: .changed(files: 1, added: 3, removed: 0))
        let items = AttentionItem.testList([.unread(turn)], pane: Self.pane, provider: .codex)
        let input = DecisionBarContent.Input(
            items: items,
            agent: Self.resting,
            backgroundWork: .init(runtimeID: "claude:other", work: BackgroundWork(shells: 1))
        )
        let bar = Self.model(input)
        #expect(bar.tag == "T2", "the unread turn is what the bar shows")
        #expect(bar.content.backgroundWork == nil)
        #expect(!bar.text.contains("background"), "\(bar.text)")
    }

    @Test func everyKind_isNamed_inOrder() {
        let all = BackgroundWork(shells: 1, subagents: 2, others: 1)
        #expect(BackgroundWorkText.sentence(all, locale: Self.english)
            == "1 shell, 2 subagents, and 1 other item still running in the background")
        #expect(BackgroundWorkText.sentence(all, locale: Self.japanese)
            == "バックグラウンドでシェル 1 件、サブエージェント 2 件、作業 1 件が実行中")
        #expect(BackgroundWorkText.sentence(BackgroundWork(others: 3), locale: Self.english)
            == "3 other items still running in the background")
        #expect(BackgroundWorkText.sentence(BackgroundWork(), locale: Self.english) == nil)
    }

    @Test func withoutBackgroundWork_theReceiptIsAsItWas() {
        let turn = UnreadTurn(turnID: TurnID("T3"), numbers: 3...3, changes: .unchanged)
        let bar = Self.model(.init(agent: Self.resting, lastTurn: turn))
        #expect(bar.text == "T3 · No file changes")
        #expect(bar.content.backgroundWork == nil)
        // An empty count says nothing either.
        #expect(Self.model(.init(agent: Self.resting, lastTurn: turn, backgroundWork: Self.ofRun(BackgroundWork())))
            .text == "T3 · No file changes")
    }

    /// Read from the pane's run, the one whose last turn the bar's receipt
    /// gives, through the window's sources.
    @Test func paneBar_readsTheWorkFromThePanesRun() throws {
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let conversation = TurnSummaryFixture.conversation
        let turn = try TurnSummaryFixture.turn("t1", number: 4)
        func bar(_ work: BackgroundWork?) -> DecisionBarModel? {
            var badge = AgentBadge(state: .finished, updatedAt: Date())
            badge.backgroundWork = work
            let runtime = AgentRuntimePresentation.test(badge: badge, paneIDs: [pane], conversation: conversation)
            var sources = DecisionBarModel.Sources(
                session: session,
                window: ProjectWindowState(selection: session.primarySelection),
                queue: AttentionQueue(),
                runtimes: [runtime],
                approvals: ApprovalLedger(),
                next: nil
            )
            sources.history = [conversation: [turn]]
            return DecisionBarModel(paneID: pane, sources: sources, locale: Self.english)
        }
        #expect(bar(BackgroundWork(subagents: 1))?.text == "T4 · No file changes · 1 subagent still running in the background")
        #expect(bar(nil)?.text == "T4 · No file changes")
    }

    /// A request, a stop, or a line after something was done is what the
    /// person acts on; the work behind a finished turn is not said there.
    @Test func onlyATurnsReceipt_saysIt() {
        let approval = AttentionItem.testList([.approval(ApprovalFact.test())], pane: Self.pane)
        let stop = AttentionItem.testList([.stop(.processExited)], pane: Self.pane)
        for items in [approval, stop] {
            // The work is the item's own run's, so only the body keeps it out.
            let work = Self.ofRun(BackgroundWork(shells: 1), of: items)
            let bar = Self.model(.init(items: items, agent: Self.resting, backgroundWork: work))
            #expect(bar.content.backgroundWork == nil)
            #expect(!bar.text.contains("background"), "\(bar.text)")
        }
        let summary = Self.model(.init(agent: Self.resting, backgroundWork: Self.ofRun(BackgroundWork(shells: 1))))
        #expect(summary.content.backgroundWork == nil, "no turn to say it after")
    }

    // MARK: - Work after a turn

    private static func badge(
        _ state: AgentState,
        runStartedAt: Date? = nil,
        backgroundWork: BackgroundWork? = nil
    ) -> AgentBadge {
        var badge = AgentBadge(state: state, runStartedAt: runStartedAt, updatedAt: Date())
        badge.backgroundWork = backgroundWork
        return badge
    }

    private static func agent(
        _ state: AgentState,
        _ work: BackgroundWork? = nil,
        provider: AgentKind = .claude,
        detail: String? = nil,
        runtimeID: String? = nil
    ) -> SessionRowFact.Agent {
        SessionRowFact.Agent(provider: provider, state: state, detail: detail, backgroundWork: work, runtimeID: runtimeID)
    }

    /// Only a finished run with work counted is at work after its turn: a
    /// turn, work outside a turn, compacting, a plain rest, and an empty
    /// count are not.
    @Test func agent_isWorkingAfterTurn_onlyFinishedWithWorkCounted() {
        #expect(Self.agent(.finished, BackgroundWork(shells: 1)).isWorkingAfterTurn)
        #expect(Self.agent(.finished, BackgroundWork(others: 2)).isWorkingAfterTurn)
        #expect(!Self.agent(.finished).isWorkingAfterTurn)
        #expect(!Self.agent(.finished, BackgroundWork()).isWorkingAfterTurn)
        for state in AgentState.allCases where state != .finished {
            #expect(!Self.agent(state, BackgroundWork(shells: 1)).isWorkingAfterTurn, "\(state)")
        }
        #expect(Self.agent(.running).isRunningATurn)
        #expect(Self.agent(.compacting).isRunningATurn)
        #expect(!Self.agent(.finished, BackgroundWork(shells: 1)).isRunningATurn)
    }

    /// A run reaches the row's rules with its work and its id.
    @Test func rowAgent_readsTheRun() {
        let runtime = AgentRuntimePresentation.test(
            runID: "r1",
            badge: Self.badge(.finished, backgroundWork: BackgroundWork(subagents: 1))
        )
        let agent = SessionRowFact.Agent(runtime: runtime)
        #expect(agent.backgroundWork == BackgroundWork(subagents: 1))
        #expect(agent.runtimeID == runtime.id)
        #expect(agent.isWorkingAfterTurn)
    }

    private static let leftRunning = SessionRowFact.Agent(
        provider: .claude, state: .finished, detail: nil, backgroundWork: BackgroundWork(shells: 1), runtimeID: "claude:run"
    )
    private static let inATurn = SessionRowFact.Agent(provider: .codex, state: .running, detail: "Edit")
    private static let unreadTurn = AttentionItemKind.unread(UnreadTurn(
        turnID: TurnID("T2"), numbers: 2...2, changes: .changed(files: 1, added: 3, removed: 0)
    ))

    /// The unread turn of `runtimeID`'s run in the pane.
    private static func unread(of runtimeID: String) -> [AttentionItem] {
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime(runtimeID), episodeToken: "1")),
            kind: unreadTurn,
            subject: .runtime(id: runtimeID, provider: .claude, paneID: pane, tabID: nil, projectID: nil),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        return queue.items
    }

    /// Work outside a turn (running with no turn start) is the agent's own
    /// work in the foreground, such as a stop hook's continuation: a
    /// running turn, as before.
    @Test func row_workOutsideATurn_isRunning() {
        let runtime = AgentRuntimePresentation.test(badge: Self.badge(.running))
        let agent = SessionRowFact.Agent(runtime: runtime)
        #expect(!agent.isWorkingAfterTurn)
        let row = SessionRowFact.make(.init(agents: [agent]))
        #expect(row.glyph == .running)
        #expect(PaneHeaderRules.mark(paneItems: [], shown: [runtime])?.glyph == .running)
    }

    /// A finished run with work left running rests with the mark of it.
    /// With no Git fact the line says what still runs, never "Idle"; a Git
    /// fact still goes first, as at any rest.
    @Test func row_finishedWithWorkLeftRunning_saysWhatStillRuns() {
        let row = SessionRowFact.make(.init(agents: [Self.leftRunning]))
        #expect(row == SessionRowFact(glyph: .workingAfterTurn, fact: .workingAfterTurn(BackgroundWork(shells: 1)), badge: .agent(.claude)))
        #expect(!SessionRowFact.repeatsGlyph(row.fact))
        #expect(SessionRowFactText.make(row.fact, locale: Self.english) == "1 shell still running in the background")
        #expect(SessionRowFactText.make(row.fact, locale: Self.japanese) == "バックグラウンドでシェル 1 件が実行中")

        let uncommitted = SessionRowFact.make(.init(agents: [Self.leftRunning], uncommittedFiles: 3))
        #expect(uncommitted.glyph == .workingAfterTurn)
        #expect(uncommitted.fact == .uncommitted(files: 3))
        // Without the work, the rest as it was.
        #expect(SessionRowFact.make(.init(agents: [Self.agent(.finished)])) == SessionRowFact(
            glyph: .idle, fact: .idle, badge: .agent(.claude)
        ))
    }

    /// An unread turn wears the unread mark of work only when its own run
    /// left the work; another run's work in the row does not mark it.
    @Test func row_unreadTurn_isMarkedWithItsOwnRunsWorkOnly() {
        let own = SessionRowFact.make(.init(items: Self.unread(of: "claude:run"), agents: [Self.leftRunning]))
        #expect(own.glyph == .unreadWorkingAfterTurn)
        #expect(own.fact == .unread(.changed(files: 1, added: 3, removed: 0)))

        let other = SessionRowFact.make(.init(
            items: Self.unread(of: "codex:other"),
            agents: [Self.leftRunning, Self.agent(.finished, provider: .codex, runtimeID: "codex:other")]
        ))
        #expect(other.glyph == .unread)

        // An agent known only by its pane's badge names no run.
        let unnamed = Self.agent(.finished, BackgroundWork(shells: 1))
        #expect(SessionRowFact.make(.init(items: Self.unread(of: "claude:run"), agents: [unnamed])).glyph == .unread)

        // A wait still goes first.
        let waiting = SessionRowFact.make(.init(
            items: AttentionItem.testList([.approval(ApprovalFact.test())], pane: Self.pane),
            agents: [Self.leftRunning]
        ))
        #expect(waiting.glyph == .needsApproval)
    }

    /// A turn in progress goes before work left running, whichever comes
    /// first, and its agent is the one the row speaks for.
    @Test func row_aTurnInProgress_goesFirst() {
        for agents in [[Self.leftRunning, Self.inATurn], [Self.inATurn, Self.leftRunning]] {
            let row = SessionRowFact.make(.init(agents: agents))
            #expect(row.glyph == .running)
            #expect(row.fact == .running("Edit"))
            #expect(row.badge == .agent(.codex))
            #expect(SessionRowFact.leadAgentIndex(of: agents).map { agents[$0] } == Self.inATurn)
        }
        let unread = SessionRowFact.make(.init(items: Self.unread(of: "claude:run"), agents: [Self.leftRunning, Self.inATurn]))
        #expect(unread.glyph == .running)
    }

    /// Of agents at rest, the one with work left running is the one the row
    /// speaks for, so the mark and the line are the same agent's.
    @Test func row_leadAgent_isTheOneWithWorkLeftRunning() {
        let resting = Self.agent(.finished, provider: .codex)
        let agents = [resting, Self.leftRunning]
        #expect(SessionRowFact.leadAgentIndex(of: agents) == 1)
        let row = SessionRowFact.make(.init(agents: agents))
        #expect(row.glyph == .workingAfterTurn)
        #expect(row.badge == .agent(.claude))
        #expect(SessionRowFact.leadAgentIndex(of: [resting]) == 0)
        #expect(SessionRowFact.leadAgentIndex(of: []) == nil)
    }

    /// Compacting is a running turn as before.
    @Test func row_compacting_staysRunning() {
        let row = SessionRowFact.make(.init(agents: [Self.agent(.compacting)]))
        #expect(row.glyph == .running)
        #expect(row.fact == .compacting)
    }

    /// The pane's header and its tab mark work left running too: a tab
    /// never shows unread, so it shows the work alone, and a run in any of
    /// its panes still goes first.
    @Test func paneHeaderAndTab_markWorkLeftRunning() {
        let pane = UUID()
        let left = AgentRuntimePresentation.test(badge: Self.badge(.finished, backgroundWork: BackgroundWork(shells: 1)), paneIDs: [pane])
        #expect(PaneHeaderRules.mark(paneItems: [], shown: [left])?.glyph == .workingAfterTurn)
        let rest = AgentRuntimePresentation.test(badge: Self.badge(.finished), paneIDs: [pane])
        #expect(PaneHeaderRules.mark(paneItems: [], shown: [rest]) == nil)

        #expect(PaneStripModel.tabGlyph([.unreadWorkingAfterTurn], items: []) == .workingAfterTurn)
        #expect(PaneStripModel.tabGlyph([.workingAfterTurn], items: []) == .workingAfterTurn)
        #expect(PaneStripModel.tabGlyph([.workingAfterTurn, .running], items: []) == .running)
        #expect(PaneStripModel.tabGlyph([.unread], items: []) == nil)
    }

    /// Each name in English and Japanese, said the same by the row's words
    /// and the glyph's label.
    @Test func names_inEnglishAndJapanese() {
        let names: [SessionRowFact.Glyph: (english: String, japanese: String)] = [
            .workingAfterTurn: ("Working in the background", "バックグラウンドで作業中"),
            .unreadWorkingAfterTurn: ("Unread, working in the background", "未読、バックグラウンドで作業中")
        ]
        for (glyph, (english, japanese)) in names {
            #expect(SessionRowFactText.stateName(glyph, locale: Self.english) == english)
            #expect(SessionRowFactText.stateName(glyph, locale: Self.japanese) == japanese)
            #expect(StateGlyph.Kind(glyph).name.resolved(in: Self.english) == english)
            #expect(StateGlyph.Kind(glyph).name.resolved(in: Self.japanese) == japanese)
        }
    }

    /// The all projects sheet holds the run finished, as the attention list
    /// does: work left running is at rest, its unread turn needs the person.
    @Test func allProjectsSections() {
        #expect(AllProjectsModel.Section.of(.unreadWorkingAfterTurn) == .needsAttention)
        #expect(AllProjectsModel.Section.of(.workingAfterTurn) == .idle)
    }
}
