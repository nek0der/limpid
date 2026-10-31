// NeedsAttentionListModelTests.swift
// Weir — the Needs Attention list's rows: their facts and their buttons.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct NeedsAttentionListModelTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    private static func runtime(_ name: String) -> AttentionSubject {
        .runtime(id: name, provider: .claude, paneID: UUID(), tabID: nil, projectID: nil)
    }

    private struct Entry {
        let id: AttentionItemID
        let kind: AttentionItemKind
        let subject: AttentionSubject

        init(_ id: AttentionItemID, _ kind: AttentionItemKind, _ subject: AttentionSubject) {
            self.id = id
            self.kind = kind
            self.subject = subject
        }
    }

    /// The items in the order given; the first arrives first.
    private static func queue(_ entries: [Entry]) -> AttentionQueue {
        var queue = AttentionQueue()
        for (offset, entry) in entries.enumerated() {
            queue.insert(
                id: entry.id,
                kind: entry.kind,
                subject: entry.subject,
                arrivedAt: Date(timeIntervalSince1970: TimeInterval(offset))
            )
        }
        return queue
    }

    private static func episode(_ name: String) -> EpisodeKey {
        EpisodeKey(origin: .runtime(name), episodeToken: "1")
    }

    private static func model(
        _ queue: AttentionQueue,
        requests: [ApprovalKey: NeedsAttentionListModel.RequestText] = [:],
        locale: Locale = english
    ) -> NeedsAttentionListModel {
        NeedsAttentionListModel(
            items: queue.items,
            names: { item in
                NeedsAttentionListModel.Names(title: "session \(item.arrivalSequence)", place: "weir")
            },
            request: { requests[$0] },
            windowProjectID: nil,
            locale: locale
        )
    }

    // MARK: - Rows

    @Test func everyItem_isOneRow_inArrivalOrder_underTheCount() {
        let approval = ApprovalFact.test()
        let queue = Self.queue([
            Entry(.stop(Self.episode("a")), .stop(.error("boom")), Self.runtime("a")),
            Entry(.approval(approval.key), .approval(approval), Self.runtime("b")),
            Entry(
                .unread(TurnID("c#1")),
                .unread(UnreadTurn(turnID: TurnID("c#1"), changes: .unknown)),
                Self.runtime("c")
            )
        ])
        let model = Self.model(queue)

        #expect(model.rows.map(\.state) == [.stopped, .approval, .unread])
        #expect(model.rows.map(\.title) == ["session 1", "session 2", "session 3"])
        #expect(model.heading.resolved(in: Self.english) == "Needs Attention 3 · All Projects · In Order of Arrival")
        #expect(model.heading.resolved(in: Self.japanese) == "要対応 3 · 全プロジェクト · 到着順")
    }

    /// An empty list has no count, reach, or order to tell, and its empty
    /// state says the rest: the heading is only the list's name.
    @Test func anEmptyList_isHeadedByItsNameAlone() {
        let model = Self.model(Self.queue([]))

        #expect(model.rows.isEmpty)
        #expect(model.heading.resolved(in: Self.english) == "Needs Attention")
        #expect(model.heading.resolved(in: Self.japanese) == "要対応")
    }

    @Test func anUnreadRow_namesItsTurns_andWhatTheyChanged() {
        let changed = UnreadTurn(
            turnID: TurnID("T6"),
            numbers: 6...7,
            changes: .changed(files: 2, added: 94, removed: 2),
            conversation: TurnSummaryFixture.conversation
        )
        let answered = UnreadTurn(turnID: TurnID("T3"), numbers: 3...3, changes: .unchanged)
        let queue = Self.queue([
            Entry(.unread(changed.turnID), .unread(changed), Self.runtime("a")),
            Entry(.unread(answered.turnID), .unread(answered), Self.runtime("b"))
        ])

        #expect(Self.model(queue).rows.map(\.fact) == ["T6–T7 Unread · 2 files +94 −2", "T3 Unread · No file changes"])
        #expect(Self.model(queue, locale: Self.japanese).rows.map(\.fact) == ["T6〜T7 未読 · 2 ファイル +94 −2", "T3 未読 · ファイルの変更なし"])
        // VoiceOver hears the turns as words and the facts as a list.
        #expect(Self.model(queue, locale: Self.japanese).rows.map(\.spokenDetail)
            == ["weir、ターン 6 から 7、未読、2 ファイル +94 −2", "weir、ターン 3、未読、ファイルの変更なし"])
    }

    @Test func anApprovalWeirStillHolds_offersAnswer_andNamesItsCommand() {
        let approval = ApprovalFact.test()
        let queue = Self.queue([Entry(.approval(approval.key), .approval(approval), Self.runtime("a"))])
        let request = NeedsAttentionListModel.RequestText(summary: "swift test", question: nil, toolName: "Bash")
        let model = Self.model(queue, requests: [approval.key: request])

        #expect(model.rows.first?.action == .answer(approval.key))
        #expect(model.rows.first?.fact == "Waiting for approval: swift test")
        #expect(Self.model(queue, requests: [approval.key: request], locale: Self.japanese).rows.first?.fact == "承認待ち：swift test")
    }

    /// Handed to the TUI or left there when its time ran out, a request is
    /// answered in its pane, which the row itself goes to: no dead card,
    /// and no button repeating the row.
    @Test(arguments: [
        ApprovalRequestState.handedToTerminal(since: SuspendingClock().now),
        .timedOut
    ], [false, true])
    func aRequestLeftToTheTerminal_offersNoButton(_ state: ApprovalRequestState, isQuestion: Bool) {
        let fact = ApprovalFact.test(isQuestion: isQuestion, state: state)
        let kind: AttentionItemKind = isQuestion ? .question(fact) : .approval(fact)
        let id: AttentionItemID = isQuestion ? .question(fact.key) : .approval(fact.key)
        let queue = Self.queue([Entry(id, kind, Self.runtime("a"))])
        let request = NeedsAttentionListModel.RequestText(summary: "swift test", question: "Which branch?", toolName: "Bash")

        #expect(Self.model(queue, requests: [fact.key: request]).rows.first?.action == nil)
    }

    @Test func aRequestLeftToTheTerminal_withNoPane_offersNothing() {
        let approval = ApprovalFact.test(state: .timedOut)
        let queue = Self.queue([Entry(.approval(approval.key), .approval(approval), .unplaced(provider: .claude))])

        #expect(Self.model(queue).rows.first?.action == nil)
    }

    /// A decision on its way to the broker is neither the card's nor the
    /// terminal's yet.
    @Test func anApprovalBeingSent_offersNoButton() {
        let approval = ApprovalFact.test(state: .sending(.allowOnce, since: SuspendingClock().now))
        let queue = Self.queue([Entry(.approval(approval.key), .approval(approval), Self.runtime("a"))])
        let request = NeedsAttentionListModel.RequestText(summary: "swift test", question: nil, toolName: "Bash")

        #expect(Self.model(queue, requests: [approval.key: request]).rows.first?.action == nil)
    }

    /// A failed send is still Weir's to retry, on the card.
    @Test func anApprovalWhoseSendFailed_offersAnswer() {
        let approval = ApprovalFact.test(state: .sendFailed(.allowOnce, error: "gone"))
        let queue = Self.queue([Entry(.approval(approval.key), .approval(approval), Self.runtime("a"))])
        let request = NeedsAttentionListModel.RequestText(summary: "swift test", question: nil, toolName: "Bash")

        #expect(Self.model(queue, requests: [approval.key: request]).rows.first?.action == .answer(approval.key))
    }

    @Test func aWaitAtTheAgentsPrompt_aStop_andAnUnreadTurn_offerNoButton() {
        let queue = Self.queue([
            Entry(.prompt(Self.episode("a")), .prompt(PromptWait(detail: nil)), Self.runtime("a")),
            Entry(.stop(Self.episode("b")), .stop(.processExited), Self.runtime("b")),
            Entry(
                .unread(TurnID("c#1")),
                .unread(UnreadTurn(turnID: TurnID("c#1"), changes: .unknown)),
                Self.runtime("c")
            )
        ])

        #expect(Self.model(queue).rows.map(\.action) == [nil, nil, nil])
    }

    @Test func aRequestTheLedgerForgot_offersNoCard_andSaysWhatItWaitsFor() {
        let approval = ApprovalFact.test()
        let queue = Self.queue([Entry(.approval(approval.key), .approval(approval), Self.runtime("a"))])
        let row = Self.model(queue).rows.first

        #expect(row?.action == nil)
        #expect(row?.fact == "Needs approval")
    }

    @Test func aClaudeQuestion_offersAnswer_andACodexQuestion_offersNoButton() {
        let claude = ApprovalFact.test(isQuestion: true)
        let codex = ApprovalFact.test(isQuestion: true, provider: .codex)
        let unplacedCodex = ApprovalFact.test(isQuestion: true, provider: .codex)
        let queue = Self.queue([
            Entry(.question(claude.key), .question(claude), Self.runtime("a")),
            Entry(.question(codex.key), .question(codex), Self.runtime("b")),
            Entry(.question(unplacedCodex.key), .question(unplacedCodex), .unplaced(provider: .codex))
        ])
        let question = NeedsAttentionListModel.RequestText(summary: nil, question: "Which branch?", toolName: "AskUserQuestion")
        let model = Self.model(queue, requests: [claude.key: question, codex.key: question, unplacedCodex.key: question])

        #expect(model.rows.map(\.action) == [.answer(claude.key), nil, nil])
        #expect(model.rows.map(\.state) == [.question, .question, .question])
        #expect(model.rows.first?.fact == "Question: Which branch?")
    }

    @Test func aWaitAtTheAgentsPrompt_isListedAsTheSessionRowWordsIt() {
        let queue = Self.queue([
            Entry(.prompt(Self.episode("a")), .prompt(PromptWait(detail: "Claude needs your permission to use Bash")), Self.runtime("a")),
            Entry(.prompt(Self.episode("b")), .prompt(PromptWait(detail: "Edit: /repo/Sources/App.swift")), Self.runtime("b")),
            Entry(.prompt(Self.episode("c")), .prompt(PromptWait(detail: nil)), Self.runtime("c"))
        ])
        let model = Self.model(queue)

        #expect(model.rows.map(\.state) == [.approval, .approval, .response])
        #expect(model.rows.map(\.fact) == [
            "Waiting for approval: Bash",
            "Waiting for approval: App.swift",
            "Needs response"
        ])
        // Weir holds none of them, so each is answered in its pane, which
        // the row itself goes to.
        #expect(model.rows.map(\.action) == [nil, nil, nil])
    }

    @Test func aStop_saysWhy_inTheListsLanguage() {
        let queue = Self.queue([
            Entry(.stop(Self.episode("a")), .stop(.processExited), Self.runtime("a")),
            Entry(.stop(Self.episode("b")), .stop(.error("rate limited")), Self.runtime("b")),
            Entry(.stop(Self.episode("c")), .stop(.error(nil)), Self.runtime("c"))
        ])

        #expect(Self.model(queue).rows.map(\.fact) == [
            "Stopped: The process exited unexpectedly.",
            "Stopped: rate limited",
            "Stopped"
        ])
        #expect(Self.model(queue, locale: Self.japanese).rows.first?.fact == "停止：プロセスが異常終了しました。")
    }

    @Test @MainActor func aPanesItem_isNamedByItsTab_andARequestWithNoPane_byItsAgent() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let tab = session.openTab(container: .project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let queue = Self.queue([
            Entry(
                .stop(Self.episode("a")),
                .stop(.processExited),
                .runtime(id: "a", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id)
            ),
            Entry(.stop(Self.episode("b")), .stop(.processExited), .unplaced(provider: .codex))
        ])

        let names = queue.items.map { NeedsAttentionListModel.names(of: $0, in: session, locale: Self.english) }

        #expect(names == [
            NeedsAttentionListModel.Names(
                title: SessionSidebarModel.rowName(of: tab.container, in: session, locale: Self.english),
                place: "weir"
            ),
            NeedsAttentionListModel.Names(title: "Codex", place: nil)
        ])
    }

    @Test @MainActor func aPanesItem_isNamedAsItsSidebarRowIs_notByTheTerminalsTitle() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let tab = session.openTab(container: .project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        // The agent's OSC 2 title, and the conversation the row is named by.
        session.update(tab.id) {
            $0.title = "✳ claude --continue"
            $0.conversationName = ConversationName(
                name: "Add tests",
                provider: .claude,
                paneID: paneID,
                conversationID: "c1",
                startedAt: Date(timeIntervalSince1970: 0)
            )
        }
        let item = Self.queue([
            Entry(
                .stop(Self.episode("a")),
                .stop(.processExited),
                .runtime(id: "a", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id)
            )
        ]).items[0]

        #expect(NeedsAttentionListModel.names(of: item, in: session, locale: Self.english)
            == NeedsAttentionListModel.Names(title: "Add tests", place: "weir"))
    }

    /// A worktree's item is named as its row is and placed by its project:
    /// the row's name is not said twice, as "weir / feat-x" after it.
    @Test @MainActor func aWorktreesItem_isNamedAsItsRow_andPlacedByItsProject() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .created)
        let tab = session.openTab(container: .worktree(projectID: project.id, worktreeID: worktree.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let item = Self.queue([
            Entry(
                .stop(Self.episode("a")),
                .stop(.processExited),
                .runtime(id: "a", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id)
            )
        ]).items[0]

        #expect(NeedsAttentionListModel.names(of: item, in: session, locale: Self.english)
            == NeedsAttentionListModel.Names(title: worktree.workingDirectory.lastPathComponent, place: "weir"))
        // A notification's place names the row the same way.
        #expect(session.containerLabel(for: tab.container, locale: Self.english)
            == "weir / \(worktree.workingDirectory.lastPathComponent)")
    }

    @Test @MainActor func aSessionRowsItem_isNamedByItsWorktreeFolder_inItsProject() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let item = Self.queue([
            Entry(
                .stop(Self.episode("a")),
                .stop(.worktreeMissing),
                .sessionRow(projectID: project.id, worktreeRoot: URL(fileURLWithPath: "/tmp/weir-feature"))
            )
        ]).items[0]

        #expect(NeedsAttentionListModel.names(of: item, in: session, locale: Self.english)
            == NeedsAttentionListModel.Names(title: "weir-feature", place: "weir"))
    }

    /// A row the person labeled is placed by its branch too, as its sidebar
    /// row shows it, so the list still says which worktree the item is in;
    /// one with no branch known, by its folder.
    @Test @MainActor func aLabeledRowsItem_isPlacedByItsProjectAndBranch_orItsFolder() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .created)
        let container = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
        session.renameRow(container, to: "Login work", runtimes: [])
        let tab = session.openTab(container: container)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let item = Self.queue([
            Entry(
                .stop(Self.episode("a")),
                .stop(.processExited),
                .runtime(id: "a", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id)
            )
        ]).items[0]
        let folder = worktree.workingDirectory.lastPathComponent

        #expect(NeedsAttentionListModel.names(of: item, in: session, locale: Self.english)
            == NeedsAttentionListModel.Names(title: "Login work", place: "weir / \(folder)"))
        let row = NeedsAttentionListModel(
            items: [item],
            names: { NeedsAttentionListModel.names(of: $0, in: session, locale: Self.english) },
            request: { _ in nil },
            windowProjectID: .some(project.id),
            locale: Self.english
        ).rows[0]
        #expect(row.placeLead == "weir / \(folder) · ")
        #expect(row.spokenDetail.hasPrefix("weir, \(folder), "), "\(row.spokenDetail)")

        // A session row's item is placed the same way.
        let rowItem = Self.queue([
            Entry(
                .stop(Self.episode("b")),
                .stop(.worktreeMissing),
                .sessionRow(projectID: project.id, worktreeRoot: worktree.workingDirectory)
            )
        ]).items[0]
        #expect(NeedsAttentionListModel.names(of: rowItem, in: session, locale: Self.english)
            == NeedsAttentionListModel.Names(title: "Login work", place: "weir / \(folder)"))

        // With its branch known, the pane's item and the session row's are
        // placed by the branch.
        let projectIndex = try #require(session.projects.firstIndex { $0.id == project.id })
        let worktreeIndex = try #require(session.projects[projectIndex].worktrees.firstIndex { $0.id == worktree.id })
        session.projects[projectIndex].worktrees[worktreeIndex].gitRef = GitRef(branchName: "feat/login")
        #expect(NeedsAttentionListModel.names(of: item, in: session, locale: Self.english)
            == NeedsAttentionListModel.Names(title: "Login work", place: "weir / feat/login"))
        #expect(NeedsAttentionListModel.names(of: rowItem, in: session, locale: Self.english)
            == NeedsAttentionListModel.Names(title: "Login work", place: "weir / feat/login"))
    }

    @Test func theSecondLine_placesTheItem_andSaysWhenAnotherWindowShowsItsProject() {
        let shown = UUID()
        let other = UUID()
        let inNoWindow = UUID()
        let queue = Self.queue([
            Entry(
                .stop(Self.episode("a")),
                .stop(.processExited),
                .runtime(id: "a", provider: .claude, paneID: UUID(), tabID: nil, projectID: shown)
            ),
            Entry(
                .stop(Self.episode("b")),
                .stop(.processExited),
                .runtime(id: "b", provider: .claude, paneID: UUID(), tabID: nil, projectID: other)
            ),
            Entry(
                .stop(Self.episode("c")),
                .stop(.processExited),
                .runtime(id: "c", provider: .claude, paneID: UUID(), tabID: nil, projectID: inNoWindow)
            ),
            Entry(
                .stop(Self.episode("d")),
                .stop(.processExited),
                .runtime(id: "d", provider: .claude, paneID: UUID(), tabID: nil, projectID: nil)
            )
        ])
        func leads(_ locale: Locale, place: String? = "weir") -> [String] {
            NeedsAttentionListModel(
                items: queue.items,
                names: { _ in NeedsAttentionListModel.Names(title: "session", place: place) },
                request: { _ in nil },
                // The list's window shows `shown`; another window shows
                // `other`; no window shows `inNoWindow`.
                projectsInOtherWindows: [other],
                windowProjectID: .some(shown),
                locale: locale
            ).rows.map(\.placeLead)
        }
        // Going to `inNoWindow`'s item switches this window, so it is not
        // said to be in another; nor is an item of no project.
        #expect(leads(Self.english) == ["weir · ", "weir (another window) · ", "weir · ", "weir · "])
        #expect(leads(Self.japanese) == ["weir · ", "weir（別のウインドウ） · ", "weir · ", "weir · "])
        // An item in no place leads with nothing: the fact stands alone.
        #expect(leads(Self.english, place: nil) == ["", "", "", ""])
        // Outside a window (the menu bar), no item is in another.
        let outside = NeedsAttentionListModel(
            items: queue.items,
            names: { _ in NeedsAttentionListModel.Names(title: "session", place: "weir") },
            request: { _ in nil },
            windowProjectID: nil,
            locale: Self.english
        )
        #expect(outside.rows.map(\.placeLead) == ["weir · ", "weir · ", "weir · ", "weir · "])
    }
}
