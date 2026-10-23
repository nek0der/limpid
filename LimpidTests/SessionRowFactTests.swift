// SessionRowFactTests.swift
// Limpid — a session row shows the agent that most needs the person, in one order for the app.

import Foundation
import Testing
@testable import Limpid

struct SessionRowFactTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let pane = UUID()

    private static func queue(_ kinds: [AttentionItemKind], provider: AgentKind = .claude) -> [AttentionItem] {
        AttentionItem.testList(kinds, pane: pane, provider: provider)
    }

    private static let unread = AttentionItemKind.unread(
        UnreadTurn(turnID: TurnID("t"), changes: .changed(files: 2, added: 94, removed: 2))
    )

    @Test func aQuestion_comesBeforeAnApproval_aStop_andAnUnreadTurn() {
        let question = ApprovalFact.test(isQuestion: true)
        let approval = ApprovalFact.test()
        let fact = SessionRowFact.make(.init(
            items: Self.queue([Self.unread, .stop(.processExited), .approval(approval), .question(question)]),
            requestText: [question.key: "Which branch?", approval.key: "swift test"]
        ))

        #expect(fact == SessionRowFact(glyph: .needsAnswer, fact: .question("Which branch?"), badge: .agent(.claude)))
    }

    @Test func withoutAQuestion_theApprovalShows_withItsCommand_thenAStop_thenUnread() {
        let approval = ApprovalFact.test()
        #expect(SessionRowFact.make(.init(
            items: Self.queue([.stop(.processExited), .approval(approval)]),
            requestText: [approval.key: "swift test"]
        )).fact == .approval("swift test"))
        #expect(SessionRowFact.make(.init(items: Self.queue([Self.unread, .stop(.processExited)]))).glyph == .stopped)
        #expect(SessionRowFact.make(.init(items: Self.queue([Self.unread]))).fact == .unread(.changed(files: 2, added: 94, removed: 2)))
    }

    @Test func aWaitWithNoRequest_showsWithTheApprovalsGlyph_andItsWait() {
        let wait = PromptWait(detail: "Bash: swift test")
        let fact = SessionRowFact.make(.init(items: Self.queue([.prompt(wait)], provider: .codex)))
        #expect(fact == SessionRowFact(glyph: .needsApproval, fact: .prompt(wait), badge: .agent(.codex)))
        // A question its record names wears a held question's glyph.
        let question = PromptWait(detail: "Which color?", kind: .question, tool: nil)
        let asked = SessionRowFact.make(.init(items: Self.queue([.prompt(question)])))
        #expect(asked.glyph == .needsAnswer)
        // A wait we cannot name wears the state's neutral name.
        let unnamed = SessionRowFact.make(.init(items: Self.queue([.prompt(PromptWait(detail: "Which color?"))])))
        #expect(unnamed.glyph == .needsResponse)
        #expect(SessionRowFactText.stateName(unnamed.glyph, locale: Locale(identifier: "ja")) == "応答待ち")
    }

    @Test func aRecordedApproval_ofAnUnlistedTool_isWaitingForThatTool() {
        let fact = SessionRowFact.Fact.prompt(PromptWait(detail: "Monitor", kind: .approval, tool: "Monitor"))
        #expect(SessionRowFactText.make(fact, locale: Locale(identifier: "en")) == "Waiting for approval: Monitor")
        #expect(SessionRowFactText.make(fact, locale: Locale(identifier: "ja")) == "承認待ち：Monitor")
    }

    @Test(arguments: [
        ("Write: /Users/me/repo/notes.txt", "Waiting for approval: notes.txt", "承認待ち：notes.txt"),
        ("Bash: swift   test", "Waiting for approval: swift test", "承認待ち：swift test"),
        ("Bash", "Waiting for approval: Bash", "承認待ち：Bash"),
        ("permission", "Needs approval", "承認待ち"),
        ("Which color?", "Needs response: Which color?", "応答待ち：Which color?"),
        (String?.none, "Needs response", "応答待ち")
    ])
    func aWaitWithNoRequest_isWordedAsAnApproval_orAWaitForAResponse(detail: String?, english: String, japanese: String) {
        let fact = SessionRowFact.Fact.prompt(PromptWait(detail: detail))
        #expect(SessionRowFactText.make(fact, locale: Locale(identifier: "en")) == english)
        #expect(SessionRowFactText.make(fact, locale: Locale(identifier: "ja")) == japanese)
    }

    @Test func aRecordedQuestion_isWordedAsAHeldOneIs() {
        let worded = SessionRowFact.Fact.prompt(PromptWait(detail: "Which color?", kind: .question, tool: nil))
        #expect(SessionRowFactText.make(worded, locale: Locale(identifier: "en")) == "Question: Which color?")
        #expect(SessionRowFactText.make(worded, locale: Locale(identifier: "ja")) == "質問：Which color?")
        let bare = SessionRowFact.Fact.prompt(.question(detail: nil))
        #expect(SessionRowFactText.make(bare, locale: Locale(identifier: "ja")) == "回答待ち")
    }

    @Test func withNothingWaiting_aRunningAgent_showsWhatItIsDoing() {
        let fact = SessionRowFact.make(.init(agents: [
            .init(provider: .claude, state: .idle, detail: nil),
            .init(provider: .codex, state: .running, detail: "Bash: swift test")
        ]))
        #expect(fact == SessionRowFact(glyph: .running, fact: .running("Bash: swift test"), badge: .agent(.codex)))
        #expect(SessionRowFact.make(.init(agents: [.init(provider: .claude, state: .compacting, detail: nil)])).fact == .compacting)
    }

    /// A row at rest keeps its resting glyph, the idle ring for an agent and
    /// the shell's for none, and states its pull request when it has one.
    struct RestCase: Sendable {
        let agents: [SessionRowFact.Agent]
        let glyph: SessionRowFact.Glyph
        let badge: SessionRowFact.Badge
    }

    @Test(arguments: [
        RestCase(agents: [.init(provider: .claude, state: .idle, detail: nil)], glyph: .idle, badge: .agent(.claude)),
        RestCase(agents: [], glyph: .shell, badge: .shell)
    ])
    func aRowAtRest_keepsItsRestingGlyph_andAttachesItsPullRequest(_ test: RestCase) {
        let (agents, glyph, badge) = (test.agents, test.glyph, test.badge)
        let pullRequest = SessionRowFact.PullRequest(number: 128, state: .open, isDraft: false)
        #expect(SessionRowFact.make(.init(agents: agents, pullRequest: pullRequest)) == SessionRowFact(
            glyph: glyph,
            fact: .pullRequest(number: 128, state: .open, isDraft: false),
            badge: badge,
            pullRequest: pullRequest
        ))
        #expect(SessionRowFact.make(.init(agents: agents)) == SessionRowFact(glyph: glyph, fact: .idle, badge: badge))
    }

    /// One case per state a row shows: the glyph is the state's own, never
    /// the pull request, and the request is attached whatever the state.
    struct AttachedCase: Sendable, CustomTestStringConvertible {
        let items: [AttentionItemKind]
        let agents: [AgentState]
        let glyph: SessionRowFact.Glyph

        var testDescription: String {
            "\(glyph)"
        }
    }

    @Test(arguments: [
        AttachedCase(items: [.approval(ApprovalFact.test())], agents: [.idle], glyph: .needsApproval),
        AttachedCase(items: [.question(ApprovalFact.test(isQuestion: true))], agents: [.idle], glyph: .needsAnswer),
        AttachedCase(items: [.prompt(.unclassified(detail: nil))], agents: [.needsInput], glyph: .needsResponse),
        AttachedCase(items: [.stop(.processExited)], agents: [.error], glyph: .stopped),
        AttachedCase(items: [Self.unread], agents: [.finished], glyph: .unread),
        AttachedCase(items: [], agents: [.running], glyph: .running),
        AttachedCase(items: [], agents: [.idle], glyph: .idle),
        AttachedCase(items: [], agents: [.unknown], glyph: .unknown),
        AttachedCase(items: [], agents: [], glyph: .shell)
    ])
    func everyState_keepsItsGlyph_andShowsThePullRequestOnlyWhenThereIsOne(_ test: AttachedCase) {
        let pullRequest = SessionRowFact.PullRequest(number: 7, state: .merged, isDraft: false)
        let agents = test.agents.map { SessionRowFact.Agent(provider: .claude, state: $0, detail: nil) }
        let withPR = SessionRowFact.make(.init(items: Self.queue(test.items), agents: agents, pullRequest: pullRequest))
        let without = SessionRowFact.make(.init(items: Self.queue(test.items), agents: agents))
        #expect(withPR.glyph == test.glyph)
        #expect(without.glyph == test.glyph, "the request never changes the left glyph")
        #expect(withPR.pullRequest == pullRequest)
        #expect(without.pullRequest == nil)
    }

    /// The glyph and the line agree: an agent not matched yet is unknown
    /// in both, never an unknown mark over "Idle".
    @Test func agentsNotMatchedYet_readAsUnknown_notIdle() {
        let fact = SessionRowFact.make(.init(agents: [.init(provider: .claude, state: .unknown, detail: nil)]))
        #expect(fact.glyph == .unknown)
        #expect(fact.fact == .unknown)
        #expect(SessionRowFactText.make(fact.fact, locale: Self.english) == "Unknown")
        #expect(SessionRowFactText.make(fact.fact, locale: Self.japanese) == "不明")
        #expect(SessionRowFactText.stateName(fact.glyph, locale: Self.japanese) == "不明")
    }

    /// One agent matched is enough for the row to be at rest; a Git fact
    /// still takes the line from the unknown state, as it does from idle.
    @Test func anUnknownRow_statesItsGitFact_andOneMatchedAgentMakesItIdle() {
        let unknown = SessionRowFact.Agent(provider: .claude, state: .unknown, detail: nil)
        let uncommitted = SessionRowFact.make(.init(agents: [unknown], uncommittedFiles: 3))
        #expect(uncommitted.glyph == .unknown)
        #expect(uncommitted.fact == .uncommitted(files: 3))
        let mixed = SessionRowFact.make(.init(agents: [unknown, .init(provider: .codex, state: .idle, detail: nil)]))
        #expect(mixed.glyph == .idle)
        #expect(mixed.fact == .idle)
        // A row with no agent is never unknown: the shell has no state.
        #expect(SessionRowFact.make(.init()).fact == .idle)
    }

    // MARK: - A pane's glyph

    /// Each row glyph draws one icon, and a shell has no state to draw.
    @Test(arguments: [
        (SessionRowFact.Glyph.needsAnswer, StateGlyph.Kind.needsAnswer),
        (.needsApproval, .needsApproval),
        (.needsResponse, .needsResponse),
        (.stopped, .stopped),
        (.unread, .unread),
        (.running, .running),
        (.idle, .idle),
        (.unknown, .unknown),
        (.shell, .unknown)
    ])
    func eachRowGlyph_drawsOneStateIcon(glyph: SessionRowFact.Glyph, kind: StateGlyph.Kind) {
        #expect(StateGlyph.Kind(glyph) == kind)
    }

    /// A pane header wears what the row of a session holding only that pane
    /// wears, through the row's own function: an unread turn over a running
    /// or resting agent, a wait over a running one, and two runs in one
    /// pane weighed as the row weighs them.
    struct PaneCase: Sendable {
        let items: [AttentionItemKind]
        let states: [AgentState]
        let kind: StateGlyph.Kind
    }

    @Test(arguments: [
        PaneCase(items: [Self.unread], states: [.running], kind: .unread),
        PaneCase(items: [Self.unread], states: [.idle], kind: .unread),
        PaneCase(items: [.approval(ApprovalFact.test())], states: [.running], kind: .needsApproval),
        PaneCase(items: [.question(ApprovalFact.test(isQuestion: true))], states: [.needsInput], kind: .needsAnswer),
        PaneCase(items: [.prompt(PromptWait(detail: nil))], states: [.needsInput], kind: .needsResponse),
        PaneCase(items: [.stop(.processExited)], states: [.error], kind: .stopped),
        PaneCase(items: [], states: [.running], kind: .running),
        PaneCase(items: [], states: [.compacting], kind: .running),
        PaneCase(items: [], states: [.finished], kind: .idle),
        PaneCase(items: [], states: [.idle], kind: .idle),
        PaneCase(items: [], states: [.unknown], kind: .unknown),
        // Two runs in one pane: a finished Claude beside a running Codex,
        // and a stop beside a running run.
        PaneCase(items: [], states: [.finished, .running], kind: .running),
        PaneCase(items: [Self.unread], states: [.finished, .running], kind: .unread),
        PaneCase(items: [.stop(.processExited)], states: [.error, .running], kind: .stopped),
        PaneCase(items: [], states: [.unknown, .running], kind: .running)
    ])
    func aPanesGlyph_isTheGlyphOfItsOnePaneRow(_ test: PaneCase) {
        let providers: [AgentKind] = [.claude, .codex]
        let agents = test.states.enumerated().map { index, state in
            SessionRowFact.Agent(provider: providers[index % providers.count], state: state, detail: nil)
        }
        let row = SessionRowFact.make(.init(items: Self.queue(test.items), agents: agents))
        #expect(StateGlyph.Kind(row.glyph) == test.kind)
    }

    @Test func atRest_theSecondLineStatesThePullRequest_elseUncommittedFiles_elseCommits() {
        let agent = SessionRowFact.Agent(provider: .claude, state: .idle, detail: nil)
        let pullRequest = SessionRowFact.PullRequest(number: 7, state: .open, isDraft: false)
        func fact(_ request: SessionRowFact.PullRequest?, uncommitted: Int, commits: Int) -> SessionRowFact {
            SessionRowFact.make(.init(agents: [agent], pullRequest: request, uncommittedFiles: uncommitted, proposedCommits: commits))
        }
        #expect(fact(pullRequest, uncommitted: 2, commits: 3).fact == .pullRequest(number: 7, state: .open, isDraft: false))
        #expect(fact(nil, uncommitted: 2, commits: 3) == SessionRowFact(glyph: .idle, fact: .uncommitted(files: 2), badge: .agent(.claude)))
        #expect(fact(nil, uncommitted: 0, commits: 3).fact == .commits(3))
        #expect(fact(nil, uncommitted: 0, commits: 0).fact == .idle)
        // Not while something needs the person or the agent runs.
        let running = SessionRowFact.make(.init(
            agents: [.init(provider: .claude, state: .running, detail: "Bash: swift test")],
            uncommittedFiles: 2
        ))
        #expect(running.fact == .running("Bash: swift test"))
        let english = Locale(identifier: "en")
        #expect(SessionRowFactText.make(.uncommitted(files: 2), locale: english) == "2 Uncommitted")
        #expect(SessionRowFactText.make(.commits(1), locale: english) == "1 Commit")
        #expect(SessionRowFactText.make(.commits(3), locale: Locale(identifier: "ja")) == "コミット 3")
    }

    // MARK: - The second line's words

    @Test func secondLines_sayEachFact() {
        #expect(SessionRowFactText.make(.question("Which branch?"), locale: Self.japanese) == "質問：Which branch?")
        #expect(SessionRowFactText
            .make(.unread(.changed(files: 2, added: 9, removed: 1)), locale: Self.english) == "Unread · 2 files changed")
        #expect(SessionRowFactText.make(.unread(.unchanged), locale: Self.japanese) == "未読 · ファイルの変更なし")
        #expect(SessionRowFactText.make(.unread(.unknown), locale: Self.english) == "Unread")
        #expect(SessionRowFactText.make(.pullRequest(number: 128, state: .open, isDraft: false), locale: Self.english) == "PR #128 · Open")
        #expect(SessionRowFactText.make(.pullRequest(number: 128, state: .open, isDraft: true), locale: Self.japanese) == "PR #128 · ドラフト")
        #expect(SessionRowFactText.make(.stopped(.processExited), locale: Self.japanese) == "停止：プロセスが異常終了しました。")
        #expect(SessionRowFactText.badge(.agent(.codex), locale: Self.english) == "Cx")
    }

    @Test func theTime_isTheLargestWholeUnit_andTheTooltipSaysItInFull() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(SessionRowFactText.elapsed(since: now.addingTimeInterval(-12 * 60), now: now) == "12m")
        #expect(SessionRowFactText.elapsed(since: now.addingTimeInterval(-3 * 3600 - 60), now: now) == "3h")
        #expect(SessionRowFactText.elapsed(since: now.addingTimeInterval(-2 * 86400 - 3600), now: now) == "2d")
        #expect(SessionRowFactText.elapsed(since: now, now: now) == "0m")
        // A clock that went back reads as no time, not a negative one.
        #expect(SessionRowFactText.elapsed(since: now.addingTimeInterval(60), now: now) == "0m")
        // Rounded down, as the tooltip's minutes are.
        #expect(SessionRowFactText.elapsed(since: now.addingTimeInterval(-(12 * 60 + 40)), now: now) == "12m")
        #expect(SessionRowFactText.elapsed(since: now.addingTimeInterval(-(59 * 60 + 30)), now: now) == "59m")
        #expect(SessionRowFactText.elapsed(since: now.addingTimeInterval(-(3 * 3600 + 59 * 60)), now: now) == "3h")
    }

    @Test func aShell_hasNoBadgeWord_itsGlyphSaysIt() {
        for locale in [Self.english, Self.japanese] {
            #expect(SessionRowFactText.badge(.shell, locale: locale).isEmpty)
        }
        #expect(SessionRowFactText.badge(.agent(.claude), locale: Self.japanese) == "Cl")
    }

    @Test func anAgentNotMatchedYet_keepsTheUnknownGlyph_overItsPullRequest() {
        let pullRequest = SessionRowFact.PullRequest(number: 7, state: .open, isDraft: false)
        let fact = SessionRowFact.make(.init(agents: [.init(provider: .codex, state: .unknown, detail: nil)], pullRequest: pullRequest))
        #expect(fact.glyph == .unknown)
        #expect(fact.fact == .pullRequest(number: 7, state: .open, isDraft: false))
    }
}
