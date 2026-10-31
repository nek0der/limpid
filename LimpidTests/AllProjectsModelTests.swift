// AllProjectsModelTests.swift
// Limpid — the all projects sheet: its sections, filter, counts, keys, window notes, and the terminal's last lines.

import AppKit
import Foundation
import Testing
@testable import Limpid

@MainActor
struct AllProjectsModelTests {
    private static func card(
        _ name: String,
        glyph: SessionRowFact.Glyph = .idle,
        project: String = "limpid",
        branch: String? = "main"
    ) -> AllProjectsModel.Card {
        AllProjectsModel.Card(
            id: .project(UUID()),
            projectID: UUID(),
            projectName: project,
            paletteIndex: nil,
            branch: branch,
            name: name,
            nameTruncation: .name,
            glyph: glyph,
            factText: "",
            chips: [],
            agentKinds: [],
            badgesSpokenName: "",
            windowNote: nil,
            action: nil,
            leadItemID: nil,
            leadPaneID: nil,
            factTruncation: .sentence
        )
    }

    /// `card` with its glyph, when one is given, and its button set to
    /// `action`.
    private static func copy(
        of card: AllProjectsModel.Card,
        glyph: SessionRowFact.Glyph? = nil,
        action: AllProjectsModel.Action? = nil
    ) -> AllProjectsModel.Card {
        AllProjectsModel.Card(
            id: card.id, projectID: card.projectID, projectName: card.projectName, paletteIndex: nil, branch: card.branch,
            name: card.name, nameTruncation: .name, glyph: glyph ?? card.glyph, factText: "", chips: [],
            agentKinds: [], badgesSpokenName: "", windowNote: nil, action: action,
            leadItemID: nil, leadPaneID: nil, factTruncation: .sentence
        )
    }

    /// The sheet's cards in the primary, from `session`'s rows as
    /// `registry`'s windows show them, with no pull request or Git facts.
    private static func cards(
        _ session: WorkspaceSession,
        registry: WindowRegistry,
        queue: AttentionQueue = AttentionQueue(),
        approvals: ApprovalLedger = ApprovalLedger()
    ) -> [AllProjectsModel.Card] {
        AllProjectsModel.cards(AllProjectsModel.Sources(
            session: session,
            window: session.primaryWindowID,
            registry: registry,
            queue: queue,
            runtimes: [],
            approvals: approvals,
            pullRequest: { _ in nil },
            gitFacts: { _ in nil },
            locale: Locale(identifier: "en")
        ))
    }

    // MARK: - Sections and counts

    @Test func aCardsBadges_nameItsAgents() {
        let english = Locale(identifier: "en")
        #expect(AllProjectsModel.badgesSpokenName([.claude], locale: english) == "Claude")
        #expect(AllProjectsModel.badgesSpokenName([.claude, .codex], locale: english) == "Claude, Codex")
        #expect(AllProjectsModel.badgesSpokenName([], locale: english).isEmpty)
    }

    @Test func aCardsFactLine_isLeftOut_whenAGitChipAlreadySaysIt() {
        let commits = SessionHeaderModel.GitChip(kind: .fact(.commits), text: "コミット 8")
        #expect(AllProjectsModel.factLine("コミット 8", chips: [commits]).isEmpty)
        #expect(AllProjectsModel.factLine("未読 · 1 ファイル", chips: [commits]) == "未読 · 1 ファイル")
        #expect(AllProjectsModel.factLine("待機中", chips: []) == "待機中")
    }

    @Test func eachSectionsHeading_takesAGlyphOfItsOwnLayer() {
        #expect(AllProjectsModel.Section.allCases.map(\.glyph) == [.needsAnswer, .running, .idle])
        for section in AllProjectsModel.Section.allCases {
            #expect(AllProjectsModel.Section.of(section.glyph) == section)
        }
    }

    @Test func cards_fallIntoTheThreeLayersOfState() {
        let cards = [
            Self.card("idle"), Self.card("question", glyph: .needsAnswer), Self.card("running", glyph: .running),
            Self.card("stopped", glyph: .stopped), Self.card("unread", glyph: .unread), Self.card("pr"),
            Self.card("shell", glyph: .shell), Self.card("unknown", glyph: .unknown), Self.card("approval", glyph: .needsApproval)
        ]

        let model = AllProjectsModel(cards: cards, query: "", attentionCount: 7)

        #expect(model.groups.map(\.section) == [.needsAttention, .running, .idle])
        #expect(model.groups[0].cards.map(\.name) == ["question", "stopped", "unread", "approval"])
        #expect(model.groups[1].cards.map(\.name) == ["running"])
        #expect(model.groups[2].cards.map(\.name) == ["idle", "pr", "shell", "unknown"])
        // The title bar's number, and the running sessions shown.
        #expect(model.attentionCount == 7)
        #expect(model.runningCount == 1)
    }

    @Test func aSectionWithNoCard_isLeftOut() {
        let model = AllProjectsModel(cards: [Self.card("a", glyph: .running)], query: "", attentionCount: 0)

        #expect(model.groups.map(\.section) == [.running])
    }

    // MARK: - Order

    /// The sheet's one order of its own is its sections. Within one,
    /// the cards come in the window's sidebar order of projects, the ones
    /// it has not met last, and each project's as its sidebar lists the
    /// rows: the folder, then the worktrees.
    @Test func theCards_comeInTheWindowsProjectOrder_andTheSidebarsRowOrder() throws {
        let fixture = ProjectWindowsFixture()
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(projectOrder: [fixture.c.id, fixture.a.id])
        let index = try #require(fixture.session.projects.firstIndex { $0.id == fixture.b.id })
        let worktree = Worktree(label: "feat", workingDirectory: URL(fileURLWithPath: "/tmp/b-feat"), origin: .gitWorktree)
        fixture.session.projects[index].worktrees = [worktree]
        let worktreeRow = ContainerID.worktree(projectID: fixture.b.id, worktreeID: worktree.id)
        fixture.session.openTab(container: worktreeRow, in: fixture.session.primaryWindowID, intent: .person, selects: false)

        let cards = Self.cards(fixture.session, registry: fixture.registry)

        #expect(cards.map(\.projectID) == [fixture.c.id, fixture.a.id, fixture.b.id, fixture.b.id])
        #expect(cards.suffix(2).map(\.id) == [.project(fixture.b.id), worktreeRow])
    }

    /// A card the person labeled is placed by its branch, as its sidebar
    /// row shows it, and the filter finds it by that branch or its folder.
    @Test func aLabeledCard_isPlacedByItsBranch_andFoundByIt() throws {
        let fixture = ProjectWindowsFixture()
        let index = try #require(fixture.session.projects.firstIndex { $0.id == fixture.b.id })
        let worktree = Worktree(
            label: "login",
            workingDirectory: URL(fileURLWithPath: "/tmp/login-redesign"),
            gitRef: GitRef(branchName: "feat/login"),
            origin: .gitWorktree
        )
        fixture.session.projects[index].worktrees = [worktree]
        let worktreeRow = ContainerID.worktree(projectID: fixture.b.id, worktreeID: worktree.id)
        fixture.session.openTab(container: worktreeRow, in: fixture.session.primaryWindowID, intent: .person, selects: false)
        fixture.session.renameRow(worktreeRow, to: "Login work", runtimes: [])

        let card = try #require(Self.cards(fixture.session, registry: fixture.registry).first { $0.id == worktreeRow })
        #expect(card.name == "Login work")
        #expect(card.checkout == "feat/login")
        #expect(AllProjectsText.place(project: card.projectName, branch: card.branch, checkout: card.checkout)
            == "\(card.projectName) / feat/login")
        // Found by its branch, and by its folder, which no card shows.
        #expect(AllProjectsModel(cards: [card], query: "feat/login", attentionCount: 0).cards.count == 1)
        #expect(card.folderName == "login-redesign")
        #expect(AllProjectsModel(cards: [card], query: "redesign", attentionCount: 0).cards.count == 1)
    }

    // MARK: - Filter

    @Test func theFilter_matchesProjectBranchOrName_everyWord_ignoringCase() {
        let cards = [
            Self.card("Pricing copy", project: "site", branch: "feat/pricing"),
            Self.card("ssh", project: "limpid", branch: "main")
        ]

        #expect(AllProjectsModel(cards: cards, query: "SITE", attentionCount: 0).cards.map(\.name) == ["Pricing copy"])
        #expect(AllProjectsModel(cards: cards, query: "feat/pri", attentionCount: 0).cards.map(\.name) == ["Pricing copy"])
        #expect(AllProjectsModel(cards: cards, query: "limpid ssh", attentionCount: 0).cards.map(\.name) == ["ssh"])
        #expect(AllProjectsModel(cards: cards, query: "  ", attentionCount: 0).cards.count == 2)
    }

    @Test func aFilterNothingMatches_saysSo_andNoCardsSaysNoneIsOpen() {
        let none = AllProjectsModel(cards: [Self.card("ssh")], query: "zzz", attentionCount: 0)
        let unfiltered = AllProjectsModel(cards: [], query: "", attentionCount: 0)
        let shown = AllProjectsModel(cards: [Self.card("ssh")], query: "", attentionCount: 0)
        let nothingAdded = AllProjectsModel(cards: [], query: "", attentionCount: 0, hasProjects: false)

        #expect(none.groups.isEmpty)
        #expect(none.emptyState == .noMatchingWorktrees)
        // The sheet lists only worktrees with a tab open or an item, so
        // with no card it says none is open, not that there is none.
        #expect(unfiltered.emptyState == .noOpenWorktrees)
        #expect(shown.emptyState == nil)
        // With no project at all there is no worktree to call closed.
        #expect(nothingAdded.emptyState == .noProjects)
        #expect(!nothingAdded.showsCounts)
        // The header's counts go only with no card at all; a filter that
        // hides every card keeps them.
        #expect(!unfiltered.showsCounts)
        #expect(none.showsCounts)
        #expect(shown.showsCounts)
    }

    // MARK: - Keys

    @Test func theSelection_followsItsSession_whenTheCardMoves() {
        let card = Self.card("a")
        var selection = AllProjectsSelection(selectedID: card.id)
        let moved = Self.copy(of: card, glyph: .running)

        selection.reconcile(with: [Self.card("b"), moved])

        #expect(selection.selectedID == card.id)
        selection.reconcile(with: [Self.card("c")])
        #expect(selection.selectedID != card.id)
    }

    @Test func tab_goesFromTheFilter_throughTheSelectedCardsButton_toTheClose_andRoundAgain() {
        let plain = Self.card("a")
        let withButton = Self.copy(of: Self.card("b"), action: .openPane)
        let groups = [AllProjectsModel.Group(section: .idle, cards: [withButton, plain])]
        var selection = AllProjectsSelection(selectedID: withButton.id)
        #expect(selection.control == .filter)

        selection.nextControl(backward: false, in: groups.flatMap(\.cards))
        #expect(selection.control == .cardAction)
        selection.nextControl(backward: false, in: groups.flatMap(\.cards))
        #expect(selection.control == .close)
        selection.nextControl(backward: false, in: groups.flatMap(\.cards))
        #expect(selection.control == .filter)
        selection.nextControl(backward: true, in: groups.flatMap(\.cards))
        #expect(selection.control == .close)

        // A card with no button: from the filter straight to the ×.
        selection.move(.next, in: groups, columns: 3)
        #expect(selection.control == .filter, "the arrows move the card, and the keyboard is back in the filter")
        selection.nextControl(backward: false, in: groups.flatMap(\.cards))
        #expect(selection.control == .close)

        // A button that went (the request was answered elsewhere) takes the
        // keyboard back to the filter.
        selection = AllProjectsSelection(selectedID: withButton.id)
        selection.nextControl(backward: false, in: [withButton])
        selection.reconcile(with: [Self.copy(of: withButton, action: nil)])
        #expect(selection.control == .filter)
    }

    @Test func sidewaysKeys_moveOneCard_andStopAtTheEnds() {
        let cards = (0..<4).map { Self.card("\($0)") }
        let groups = [AllProjectsModel.Group(section: .idle, cards: cards)]
        var selection = AllProjectsSelection(selectedID: cards[0].id)

        selection.move(.previous, in: groups, columns: 3)
        #expect(selection.selectedID == cards[0].id)
        selection.move(.next, in: groups, columns: 3)
        #expect(selection.selectedID == cards[1].id)
    }

    @Test func upAndDown_moveARowOfThree_intoTheNextSectionsColumn() {
        let attention = (0..<5).map { Self.card("a\($0)", glyph: .stopped) }
        let idle = (0..<2).map { Self.card("i\($0)") }
        let groups = [
            AllProjectsModel.Group(section: .needsAttention, cards: attention),
            AllProjectsModel.Group(section: .idle, cards: idle)
        ]
        var selection = AllProjectsSelection(selectedID: attention[1].id)

        selection.move(.down, in: groups, columns: 3)
        #expect(selection.selectedID == attention[4].id)
        // The last row of the section: the next section, same column, or
        // its last card.
        selection.move(.down, in: groups, columns: 3)
        #expect(selection.selectedID == idle[1].id)
        selection.move(.up, in: groups, columns: 3)
        #expect(selection.selectedID == attention[4].id)
        selection.move(.up, in: groups, columns: 3)
        #expect(selection.selectedID == attention[1].id)
        selection.move(.up, in: groups, columns: 3)
        #expect(selection.selectedID == attention[1].id)

        // A shorter last row takes the column's nearest card.
        selection = AllProjectsSelection(selectedID: attention[2].id)
        selection.move(.down, in: groups, columns: 3)
        #expect(selection.selectedID == attention[4].id)

        // Up from the next section lands in this one's shorter last row.
        selection = AllProjectsSelection(selectedID: idle[0].id)
        selection.move(.up, in: groups, columns: 3)
        #expect(selection.selectedID == attention[3].id)
    }

    @Test func columns_followTheSheetsWidth_fromOneToThree() {
        // Cards of at least 260pt, 12pt apart: a column more for each
        // 272pt, never more than three, never fewer than one.
        let columns = { (width: CGFloat) in
            AllProjectsSelection.columns(width: width, cardMinWidth: 260, spacing: 12)
        }

        #expect(columns(200) == 1)
        #expect(columns(531) == 1)
        #expect(columns(532) == 2)
        #expect(columns(570) == 2)
        #expect(columns(804) == 3)
        #expect(columns(1040) == 3)
        // Before the sheet is measured, it is laid out as wide.
        #expect(columns(0) == AllProjectsSelection.maxColumns)
    }

    @Test func upAndDown_moveARowOfTheGridsColumns() {
        let cards = (0..<5).map { Self.card("\($0)") }
        let groups = [AllProjectsModel.Group(section: .idle, cards: cards)]
        var selection = AllProjectsSelection(selectedID: cards[1].id)

        selection.move(.down, in: groups, columns: 2)
        #expect(selection.selectedID == cards[3].id)
        selection.move(.down, in: groups, columns: 2)
        #expect(selection.selectedID == cards[4].id)
        selection.move(.up, in: groups, columns: 1)
        #expect(selection.selectedID == cards[3].id)
    }

    @Test func noCards_leaveNothingSelected() {
        var selection = AllProjectsSelection()

        selection.reconcile(with: [])
        #expect(selection.selectedID == nil)
        selection.move(.next, in: [], columns: 3)
        #expect(selection.selectedID == nil)
    }

    // MARK: - From the session

    @Test func cards_areEverySessionWithATab_withWhereItsProjectIsShown() throws {
        let (session, current) = WorkspaceSessionFixture.withProject(name: "current")
        session.openTab(container: .project(current.id))
        let other = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("other"), suggestedName: "other")
        session.openTab(container: .project(other.id))
        let empty = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("empty"), suggestedName: "empty")
        session.setActiveContainer(.project(current.id))
        session.primarySelection.projectID = current.id
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()

        let cards = Self.cards(session, registry: registry)

        #expect(cards.map(\.projectName) == ["current", "other"])
        #expect(!cards.contains { $0.projectID == empty.id })
        #expect(cards.first?.windowNote == .current)
        // No window shows it: opening it switches this window, which
        // needs no note, and ⌘ opens it in a new one.
        #expect(cards.last?.windowNote == nil)
        #expect(cards.last?.opensInNewWindow == true)
        #expect(cards.first?.opensInNewWindow == false)

        // Once another window shows it, opening it brings that window
        // forward, which the card says.
        let otherWindow = try #require(registry.openInNewWindow(project: other.id, in: session, from: nil))
        let again = Self.cards(session, registry: registry)
        #expect(again.last?.windowNote == .otherWindow)
        #expect(again.last?.opensInNewWindow == false)

        // Hidden, that window still shows it, and comes back when chosen.
        registry.hide(otherWindow.id)
        let hidden = Self.cards(session, registry: registry)
        #expect(hidden.last?.windowNote == .otherWindow)
    }

    /// A workspace whose new session failed to set up has no tab yet, and
    /// its stop is what the person has to see: it is a card all the same.
    @Test func aRowWithNoTabButAStop_isACardThatNeedsAttention() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "failed")
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .sessionRow(worktreeRoot: project.rootURL), episodeToken: "1")),
            kind: .stop(.launchFailed(.setup(stepIndex: 0), logTail: "boom")),
            subject: .sessionRow(projectID: project.id, worktreeRoot: project.rootURL),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        let registry = WindowRegistry(primary: session.primarySelection)
        let cards = Self.cards(session, registry: registry, queue: queue)
        #expect(cards.count == 1)
        let card = try #require(cards.first)
        #expect(card.section == .needsAttention)
    }

    @Test func theWindowNotes_sayWhereTheProjectIsShown_inEnglishAndJapanese() {
        let english = Locale(identifier: "en")
        let japanese = Locale(identifier: "ja")

        #expect(AllProjectsText.windowNote(.current, locale: english) == "Current Window")
        #expect(AllProjectsText.windowNote(.otherWindow, locale: english) == "Other Window")
        #expect(AllProjectsText.windowNote(.current, locale: japanese) == "現在のウインドウ")
        #expect(AllProjectsText.windowNote(.otherWindow, locale: japanese) == "別のウインドウ")
    }

    @Test func aCardsButton_answersWhatLimpidCan_andSendsWhatTheTerminalAnswersToThePane() {
        let key = ApprovalKey(epoch: UUID(), runID: UUID(), requestID: UUID())

        #expect(AllProjectsModel.action(answerKey: key, requiresTerminalAnswer: false, hasPane: true) == .answer(key))
        #expect(AllProjectsModel.action(answerKey: nil, requiresTerminalAnswer: true, hasPane: true) == .openPane)
        #expect(AllProjectsModel.action(answerKey: nil, requiresTerminalAnswer: false, hasPane: true) == nil)
        // With no pane to go to, "Open Pane" would lead nowhere.
        #expect(AllProjectsModel.action(answerKey: nil, requiresTerminalAnswer: true, hasPane: false) == nil)
    }

    /// A card whose session waits on a request Limpid does not hold (a
    /// wait at the agent's prompt, an approval handed to the TUI, a
    /// question timed out, Codex's question) offers its pane, as the Needs
    /// Attention list does; a stop offers nothing.
    @Test(arguments: [
        (AttentionItemKind.prompt(PromptWait(detail: "Edit: /repo/App.swift")), AllProjectsModel.Action.openPane),
        (.approval(ApprovalFact.test(state: .handedToTerminal(since: SuspendingClock().now))), .openPane),
        (.question(ApprovalFact.test(isQuestion: true, state: .timedOut)), .openPane),
        (.question(ApprovalFact.test(isQuestion: true, provider: .codex)), .openPane),
        (.stop(.processExited), nil)
    ] as [(AttentionItemKind, AllProjectsModel.Action?)])
    func aCardWaitingOnTheTerminal_offersItsPane(_ kind: AttentionItemKind, expected: AllProjectsModel.Action?) throws {
        #expect(try Self.cardAction(kind, ledger: ApprovalLedger()) == expected)
    }

    /// A request Limpid holds, with the ledger's text for its card, is
    /// answered on the approval card.
    @Test func aCardWithAHeldRequestTheLedgerHas_offersAnswer() throws {
        let request = ApprovalPresentation.test(summary: "swift test", deadlineMilliseconds: 0, hasInputCommand: true)
        let ledger = ApprovalLedger()
        ledger.observe(pending: [request], epoch: request.epoch)

        #expect(try Self.cardAction(.approval(ApprovalFact.test(key: request.key)), ledger: ledger) == .answer(request.key))
    }

    /// A held question the ledger has no text for offers neither a card it
    /// could not fill nor the pane, as the Needs Attention list does.
    @Test func aCardWithAHeldQuestionTheLedgerLacks_offersNothing() throws {
        #expect(try Self.cardAction(.question(ApprovalFact.test(isQuestion: true)), ledger: ApprovalLedger()) == nil)
    }

    /// The button of the one card of a project whose tab's pane holds an
    /// item of `kind`, keyed as the attention list keys that kind.
    private static func cardAction(_ kind: AttentionItemKind, ledger: ApprovalLedger) throws -> AllProjectsModel.Action? {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        let tab = session.openTab(container: .project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let episode = EpisodeKey(origin: .runtime("r"), episodeToken: "1")
        let id: AttentionItemID = switch kind {
        case let .approval(fact): .approval(fact.key)
        case let .question(fact): .question(fact.key)
        case .prompt: .prompt(episode)
        case .stop: .stop(episode)
        case let .unread(turn): .unread(turn.turnID)
        }
        var queue = AttentionQueue()
        queue.insert(
            id: id,
            kind: kind,
            subject: .runtime(id: "r", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()

        let cards = Self.cards(session, registry: registry, queue: queue, approvals: ledger)
        return try #require(cards.first).action
    }

    @Test func aCardsPlace_isProjectAndBranch_orTheProjectAlone() {
        #expect(AllProjectsText.place(project: "limpid", branch: "feat/x") == "limpid / feat/x")
        #expect(AllProjectsText.place(project: "limpid", branch: nil) == "limpid")
        #expect(AllProjectsText.place(project: "limpid", branch: "limpid") == "limpid")
    }

    // MARK: - The terminal's last lines

    @Test func theLastLines_skipTheBlankRowsBelow_andTheSpacesAfter() {
        let screen = "$ swift test\nBuilding...   \n\n✔ 12 tests passed  \n$ \n\n\n   \n"

        #expect(TerminalTail.lastLines(of: screen) == ["", "✔ 12 tests passed", "$"])
        #expect(TerminalTail.lastLines(of: "one\ntwo", count: 3) == ["one", "two"])
        #expect(TerminalTail.lastLines(of: "\n\n").isEmpty)
    }

    @Test func theLastLines_skipTheTUIsChrome_atTheBottom() {
        // Claude: the input box, its prompt, and the hints under it.
        let claude = "● Done.\n╭──────────╮\n│ > │\n╰──────────╯\n  ? for shortcuts"
        #expect(TerminalTail.lastLines(of: claude) == ["● Done."])
        // Codex: the input box, its prompt with a placeholder, and the
        // status line under it.
        let codex = "• Ran echo out > out-long.txt\n\n╭───────────╮\n│ › Ask Codex to do anything │\n╰───────────╯\n"
            + "  GPT-6.1-Sol xhigh · ~/projects/beta · weekly 91% left · F…"
        #expect(TerminalTail.lastLines(of: codex) == ["• Ran echo out > out-long.txt"])
        // Claude's separators and the mode line, with a draft typed.
        let draft = "● Done.\n────────\n> fix the test\n────────\n  ⏵⏵ accept edits on (shift+tab to cycle)"
        #expect(TerminalTail.lastLines(of: draft) == ["● Done."])
    }

    /// The working line above the input box says what the agent does
    /// now, hint and all; it is kept.
    @Test func theLastLines_keepTheWorkingLine_aboveTheChrome() {
        let claude = "● Done.\n✻ Thinking… (12s · ↑ 1.2k tokens · esc to interrupt)\n╭──────────╮\n│ > │\n╰──────────╯\n  ? for shortcuts"
        #expect(TerminalTail.lastLines(of: claude) == ["● Done.", "✻ Thinking… (12s · ↑ 1.2k tokens · esc to interrupt)"])
        let codex = "• Working (12s • esc to interrupt)\n╭───╮\n│ › │\n╰───╯\n  gpt-5 high · ~/x · 100% left"
        #expect(TerminalTail.lastLines(of: codex) == ["• Working (12s • esc to interrupt)"])
    }

    @Test func theLastLines_areNone_whenTheScreenIsChromeAlone() {
        let screen = "╭──────────╮\n│ › │\n╰──────────╯\n  gpt-5 high · ~/x · 100% left"
        #expect(TerminalTail.lastLines(of: screen).isEmpty)
    }

    @Test func theLastLines_keepOutputThatOnlyLooksLikeChrome() {
        // A quote in the output, a percentage, and a shell prompt are
        // output, not chrome, above the TUI's run or without one.
        let shell = "$ make test\n> note: 3 of 4 passed · 75%\nDone in 12s"
        #expect(TerminalTail.lastLines(of: shell) == ["$ make test", "> note: 3 of 4 passed · 75%", "Done in 12s"])
        #expect(TerminalTail.lastLines(of: "$ ls\nfoo\n$") == ["$ ls", "foo", "$"])
    }
}

/// The keys the sheet takes at its window.
@MainActor
struct AllProjectsKeysTests {
    @Test func theArrowsReturnEscAndTab_areTheSheets_andAShortcutIsNot() throws {
        func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) throws -> AllProjectsKeys.Key? {
            try AllProjectsKeys.key(for: NSEvent.testKeyDown(keyCode: keyCode, modifiers: modifiers))
        }
        #expect(try key(123) == .previous)
        #expect(try key(124) == .next)
        #expect(try key(126) == .up)
        #expect(try key(125) == .down)
        #expect(try key(36) == .open)
        // The keypad's Enter opens as Return does.
        #expect(try key(76) == .open)
        #expect(try key(53) == .close)
        #expect(try key(48) == .nextControl)
        #expect(try key(48, .shift) == .previousControl)
        // ⌘⏎ opens the card in a new window; ⇧⌘⏎ and ⌥← are
        // shortcuts, and a letter is the field's.
        #expect(try key(36, .command) == .openInNewWindow)
        #expect(try key(36, [.command, .shift]) == nil)
        #expect(try key(123, .option) == nil)
        #expect(try key(0) == nil)
    }
}

// What lies over the whole window keeps the pointer from what is under it.
