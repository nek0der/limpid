// ReviewDestinationTests.swift
// Limpid — where the review tab's comments go, when Insert is unavailable, and what is said once they arrive.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Review destination")
struct ReviewDestinationTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)

    private static func tab(agent: UUID?, destination: UUID?) -> ReviewTabState {
        ReviewTabState(
            root: "/repo",
            selection: .uncommitted(includesChangesOutsideTurns: false),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: agent,
            destinationPaneID: destination,
            opening: UUID()
        )
    }

    @Test func aPaneWhoseTerminalHasNotStarted_isStillADestination() throws {
        // Restored and not shown since: its tab is in the strip, but no
        // surface has been made for it yet.
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        let registry = RecordingSurfaceRegistry()

        let waiting = try #require(ReviewAgents.destination(session: session, paneID: paneID, registry: registry))
        #expect(!waiting.isLive)
        let choices = ReviewTabModel.destinationChoices([waiting])
        #expect(choices.count == 1)
        let status = ReviewTabModel.destinationStatus(Self.tab(agent: nil, destination: paneID), .init(
            isPaneOpen: true,
            destination: waiting,
            isResolving: false,
            choices: choices,
            agents: []
        ))
        #expect(status != .noPane)
        #expect(status.isReady)

        registry.deliverers[paneID] = RecordingReviewDeliverer()
        #expect(ReviewAgents.destination(session: session, paneID: paneID, registry: registry)?.isLive == true)
        // A pane no tab holds is none.
        #expect(ReviewAgents.destination(session: session, paneID: UUID(), registry: registry) == nil)
    }

    /// The agent named is the one the pane runs now, not the one its resume
    /// hint names: a Claude hint left behind while Codex runs in front is
    /// Codex, and a hint alone, its agent not started, is no agent.
    @Test func theDestinationsAgent_isTheOneRunningNow_notTheResumeHint() throws {
        let (session, tab, paneID) = WorkspaceSessionFixture.withLooseTab()
        let registry = RecordingSurfaceRegistry()
        session.update(tab.id) { $0.agentSessions[.claude] = [paneID: AgentSessionInfo(sessionId: "s1", cwd: nil)] }

        let hintOnly = try #require(ReviewAgents.destination(session: session, paneID: paneID, registry: registry))
        #expect(hintOnly.agent == nil)
        #expect(hintOnly.title != "Claude Code")

        session.update(tab.id) { $0.agentsInFront[paneID] = PaneAgentInFront(kind: .codex, isStaged: false) }
        let codex = try #require(ReviewAgents.destination(session: session, paneID: paneID, registry: registry))
        #expect(codex.agent == .codex)
        #expect(codex.title == "Codex")
    }

    @Test func twoPanesWithOneName_areToldApartByTheirPlace() {
        let shell = ReviewDestination(paneID: UUID(), title: "review-demo")
        let agent = ReviewDestination(paneID: UUID(), title: "Claude Code")
        let other = ReviewDestination(paneID: UUID(), title: "review-demo")

        let choices = ReviewTabModel.destinationChoices([shell, agent, other])
        let labels = choices.map { ReviewTabText.destinationLabel($0, locale: Self.english) }

        #expect(labels == ["review-demo (1)", "Claude Code", "review-demo (2)"], "counted among the panes of that name")
        // Set off as the catalog sets it, in Japanese with full-width parentheses.
        #expect(choices.map { ReviewTabText.destinationLabel($0, locale: Self.japanese) }
            == ["review-demo（1）", "Claude Code", "review-demo（2）"])
    }

    @Test func aConversationsPane_isNamedAsItsChipIs() throws {
        let first = ReviewDestination(paneID: UUID(), title: "Claude Code")
        let second = ReviewDestination(paneID: UUID(), title: "Claude Code")
        let shell = ReviewDestination(paneID: UUID(), title: "review-demo")
        let numbered = ConversationChoice(conversation: TurnSummaryFixture.conversation, ordinal: 4, unviewedCount: 0)
        let lone = ConversationChoice(
            conversation: TurnSummaryFixture.conversation("x", provider: .codex),
            ordinal: nil,
            unviewedCount: 0
        )

        let choices = ReviewTabModel.destinationChoices([first, second, shell]) { pane in
            switch pane {
            case first.paneID: numbered
            case shell.paneID: lone
            default: nil
            }
        }

        #expect(
            choices.map { ReviewTabText.destinationLabel($0, locale: Self.english) } == ["Claude #4", "Claude Code", "review-demo"],
            "the numbered one by its chip; the other Claude pane has no namesake left; a kind alone keeps the pane's name"
        )
        let named = try #require(choices.first)
        #expect(ReviewTabText.destinationChoice(named, foreground: "claude", locale: Self.japanese) == "Claude #4 · claude")
    }

    /// A conversation alone of its kind has no number, but a title of its
    /// own names its pane (`ConversationChoice.hasOwnName`), as its chip
    /// does; the menu cuts a long one, and its tooltip keeps it whole.
    @Test func aTitledConversationsPane_isNamedByItsTitle() throws {
        let titled = ReviewDestination(paneID: UUID(), title: "Claude Code")
        let untitled = ReviewDestination(paneID: UUID(), title: "Codex")
        let long = "Review every libghostty patch on the fork and list the ones upstream took"
        let conversation = ConversationChoice(conversation: TurnSummaryFixture.conversation, title: long, ordinal: nil, unviewedCount: 0)
        let lone = ConversationChoice(
            conversation: TurnSummaryFixture.conversation("x", provider: .codex),
            ordinal: nil,
            unviewedCount: 0
        )

        let choices = ReviewTabModel.destinationChoices([titled, untitled]) { $0 == titled.paneID ? conversation : lone }

        #expect(choices.map(\.agent?.conversation) == [conversation.conversation, nil], "a kind alone keeps the pane's name")
        #expect(choices.map { ReviewTabText.destinationLabel($0, locale: Self.english) } == [long, "Codex"])
        let named = try #require(choices.first)
        #expect(ReviewTabText
            .destinationChoice(named, foreground: "claude", form: .menu, locale: Self.english) == String(long.prefix(32)) + "… · claude")
        #expect(ReviewTabText.destinationChoice(named, foreground: "claude", locale: Self.english) == "\(long) · claude")
        #expect(
            ReviewTabText.destinationChoice(named, foreground: "claude", form: .spoken, locale: Self.english)
                == "Claude, \(long) · claude",
            "VoiceOver names a titled conversation with its agent"
        )
        #expect(ReviewTabText.destinationLabel(choices[1], form: .spoken, locale: Self.english) == "Codex", "an untitled pane as drawn")
    }

    @Test func twoPanesOfOneConversation_areToldApartByTheirTabs() {
        let first = ReviewDestination(paneID: UUID(), title: "Claude Code")
        let shell = ReviewDestination(paneID: UUID(), title: "review-demo")
        let second = ReviewDestination(paneID: UUID(), title: "Claude Code")
        let numbered = ConversationChoice(conversation: TurnSummaryFixture.conversation, ordinal: 1, unviewedCount: 0)
        let titles = [first.paneID: "first", shell.paneID: "zsh", second.paneID: "second"]

        let choices = ReviewTabModel.destinationChoices(
            [first, shell, second],
            agent: { $0 == shell.paneID ? nil : numbered },
            tabTitle: { titles[$0] ?? "" }
        )

        #expect(
            choices.map { ReviewTabText.destinationLabel($0, locale: Self.english) } == [
                "Claude #1 · “first”",
                "review-demo",
                "Claude #1 · “second”"
            ],
            "by the tabs, never a second number after the conversation's"
        )
        #expect(ReviewTabText.destinationLabel(choices[0], locale: Self.japanese) == "Claude #1 · 「first」")
    }

    @Test func twoPanesOfOneConversation_inTabsOfOneTitle_areToldApartByTheirPlace() {
        let first = ReviewDestination(paneID: UUID(), title: "Claude Code")
        let second = ReviewDestination(paneID: UUID(), title: "Claude Code")
        let other = ReviewDestination(paneID: UUID(), title: "Claude Code")
        let numbered = ConversationChoice(conversation: TurnSummaryFixture.conversation, ordinal: 1, unviewedCount: 0)
        let elsewhere = ConversationChoice(conversation: TurnSummaryFixture.conversation("s2"), ordinal: 2, unviewedCount: 0)

        let choices = ReviewTabModel.destinationChoices(
            [first, second, other],
            agent: { $0 == other.paneID ? elsewhere : numbered },
            tabTitle: { _ in "claude" }
        )

        #expect(choices.map { ReviewTabText.destinationLabel($0, locale: Self.english) } == ["Claude #1 (1)", "Claude #1 (2)", "Claude #2"])
        #expect(choices.map { ReviewTabText.destinationLabel($0, locale: Self.japanese) } == ["Claude #1（1）", "Claude #1（2）", "Claude #2"])
    }

    @Test func insert_isUnavailableOnlyOnceThePaneIsGone() {
        let pane = UUID()
        let ready = ReviewDestination(paneID: pane, title: "Claude Code")
        let tab = Self.tab(agent: pane, destination: pane)
        let choices = ReviewTabModel.destinationChoices([ready])
        func status(isPaneOpen: Bool, destination: ReviewDestination?, isResolving: Bool) -> ReviewTabModel.DestinationStatus {
            ReviewTabModel.destinationStatus(tab, .init(
                isPaneOpen: isPaneOpen,
                destination: destination,
                isResolving: isResolving,
                choices: choices,
                agents: []
            ))
        }

        #expect(status(isPaneOpen: true, destination: ready, isResolving: false) == .ready(ready))
        #expect(status(isPaneOpen: true, destination: nil, isResolving: true) == .resolving)
        // The only pane listed is itself, which is no other pane.
        #expect(status(isPaneOpen: true, destination: nil, isResolving: false) == .noTerminal(hasOtherPanes: false))
        // An answer from before the pane closed does not keep it on offer.
        #expect(!status(isPaneOpen: false, destination: ready, isResolving: false).isReady)
        #expect(ReviewTabText.insertHelp(.ready(ready), locale: Self.english) == "Inserts the comments into Claude Code’s input")
    }

    @Test func eachPaneInTheMenu_saysWhatRunsInFrontThere() throws {
        let shell = ReviewDestination(paneID: UUID(), title: "review-demo")
        let agent = ReviewDestination(paneID: UUID(), title: "Claude Code")
        let choices = ReviewTabModel.destinationChoices([shell, agent])
        let shellChoice = try #require(choices.first)
        let agentChoice = try #require(choices.last)

        #expect(ReviewTabText.destinationChoice(shellChoice, foreground: "zsh", locale: Self.english) == "review-demo · zsh")
        #expect(ReviewTabText.destinationChoice(agentChoice, foreground: "claude", locale: Self.english) == "Claude Code · claude")
        #expect(ReviewTabText.destinationChoice(agentChoice, foreground: "Claude Code", locale: Self.english) == "Claude Code", "said once")
        #expect(ReviewTabText.destinationChoice(shellChoice, foreground: nil, locale: Self.english) == "review-demo", "not read yet")
    }

    @Test func theCommandInFront_isNamedOnlyWhenItAddsToThePanesName() {
        var destination = ReviewDestination(paneID: UUID(), title: "Claude Code", foreground: "Claude Code")
        #expect(ReviewTabText.destinationForeground(.ready(destination)) == nil)

        destination.foreground = "zsh"
        #expect(ReviewTabText.destinationForeground(.ready(destination)) == "zsh")

        destination.foreground = nil
        #expect(ReviewTabText.destinationForeground(.ready(destination)) == "—", "not resolved yet")
        #expect(ReviewTabText.destinationForeground(.paneClosed) == nil)
    }

    /// A pane of the closing cases.
    enum Pane: Sendable {
        case agent, shell, other

        static let ids: [Self: UUID] = [.agent: UUID(), .shell: UUID(), .other: UUID()]

        var id: UUID? {
            Self.ids[self]
        }
    }

    /// A review tab opened from the agent (or from no pane), writing to the
    /// shell, closed with `live` panes left, after an insert into
    /// `inserted` or none.
    struct Closing: Sendable, CustomTestStringConvertible {
        let name: String
        var hasAgent = true
        let live: [Pane]
        var inserted: Pane?
        let expected: Pane?

        var testDescription: String {
            name
        }
    }

    nonisolated static let closings = [
        Closing(name: "after an insert, to the pane it went to", live: [.agent, .shell], inserted: .shell, expected: .shell),
        Closing(name: "after an insert into a pane gone since, to the agent", live: [.agent], inserted: .shell, expected: .agent),
        Closing(name: "a plain close, to the agent", live: [.agent, .shell], expected: .agent),
        Closing(name: "the agent gone, to none", live: [.other], expected: nil),
        Closing(name: "no pane left, to none", live: [], expected: nil),
        Closing(name: "a tab opened from no pane, to none", hasAgent: false, live: [.agent], expected: nil)
    ]

    /// Closing the review tab returns to the pane a complete insert went to,
    /// else to the agent pane it was opened from while that pane exists.
    @Test(arguments: closings)
    func closingTheTab_returnsToThePaneTheCommentsWentTo_elseTheAgentsWhileItExists(_ closing: Closing) {
        let tab = Self.tab(agent: closing.hasAgent ? Pane.agent.id : nil, destination: Pane.shell.id)
        let live = Set(closing.live.compactMap(\.id))

        #expect(ReviewTabModel.paneAfterClosing(tab, livePanes: live, inserted: closing.inserted?.id) == closing.expected?.id)
    }

    @Test func theDestinationChosen_isKeptThroughAChangeOfScope() {
        let agent = UUID()
        let shell = UUID()
        let window = ProjectWindowState(id: WindowID())
        window.review = Self.tab(agent: agent, destination: agent)
        window.reviewPresentation.open(URL(fileURLWithPath: "/repo"), originPaneID: agent, initialScope: .uncommitted)

        ReviewTabActions.chooseDestination(shell, window: window)

        #expect(window.review?.destinationPaneID == shell)
        #expect(window.reviewPresentation.originPaneID == shell)
        let context = ReviewTabModel.Context(turns: [], isViewed: { _ in false }, branchBase: "main")
        let tab = window.review.map { ReviewTabModel.select(.branch(base: "main"), in: $0, context) }
        #expect(tab?.destinationPaneID == shell)
        #expect(tab?.agentPaneID == agent, "closing still goes back to the agent")
    }

    @Test func afterAnInsert_theToastSaysWhatStayedBehind() {
        #expect(ReviewTabText.inserted(held: 0).key == "Review inserted. Press Return to send it.")
        #expect(ReviewTabText.inserted(held: 2)
            .key == "Review inserted. %lld comments no longer match the current diff and stay in this review.")
    }

    @Test func aCompleteInsert_closesOnlyTheTabItStartedIn_inFront_withNothingBeingWritten() {
        let tab = Self.tab(agent: UUID(), destination: UUID())
        let inserted = ReviewTabInserted(paneID: UUID(), agent: .claude, opening: tab.opening, selection: tab.selection)

        #expect(ReviewTabModel.closesAfterInsert(tab, inserted, hasUnsavedComment: false))
        #expect(!ReviewTabModel.closesAfterInsert(tab, inserted, hasUnsavedComment: true), "the comment would be thrown away")
        var behind = tab
        behind.isShown = false
        #expect(!ReviewTabModel.closesAfterInsert(behind, inserted, hasUnsavedComment: false), "the person went elsewhere")
        var reread = tab
        reread.selection = .branch(base: "main")
        #expect(!ReviewTabModel.closesAfterInsert(reread, inserted, hasUnsavedComment: false), "another range since")
        let reopened = Self.tab(agent: tab.agentPaneID, destination: tab.destinationPaneID)
        #expect(!ReviewTabModel.closesAfterInsert(reopened, inserted, hasUnsavedComment: false))
        #expect(!ReviewTabModel.closesAfterInsert(nil, inserted, hasUnsavedComment: false))
    }

    @Test func closingAfterAnInsert_goesToThePane_andItsBarSaysWhereTheCommentsWent() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        let container = ContainerID.project(project.id)
        let agentTab = session.openTab(container: container)
        let shellTab = session.openTab(container: container)
        let agent = try #require(agentTab.splitTree.allLeafIDs().first)
        let shell = try #require(shellTab.splitTree.allLeafIDs().first)
        let window = ProjectWindowState(selection: session.primarySelection)
        window.review = Self.tab(agent: agent, destination: agent)
        window.reviewPresentation.open(URL(fileURLWithPath: "/repo"), originPaneID: agent, initialScope: .uncommitted)
        window.decisionBarSelection[agent] = .stop(EpisodeKey(origin: .runtime("r"), episodeToken: "1"))
        let tab = try #require(window.review)

        let toAgent = ReviewTabActions.closeAfterInsert(
            ReviewTabInserted(paneID: agent, agent: .claude, opening: tab.opening, selection: tab.selection),
            window: window,
            session: session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter()
        )

        #expect(toAgent == .toldOnBar)
        #expect(!toAgent.needsToast, "the bar says it")
        #expect(window.review == nil)
        #expect(session.primarySelection.activeTabID == agentTab.id)
        #expect(session.tab(agentTab.id)?.splitTree.focusedLeafID == agent)
        #expect(window.decisionBarSelection[agent] == nil, "⌘J's choice would keep the sentence behind it")
        #expect(window.pendingDecisionBarDone[agent] == .insertedReview(agent: .claude))

        // A shell has no bar to say it, and shows the pasted text itself.
        window.review = Self.tab(agent: agent, destination: shell)
        let again = try #require(window.review)
        let toShell = ReviewTabActions.closeAfterInsert(
            ReviewTabInserted(paneID: shell, agent: nil, opening: again.opening, selection: again.selection),
            window: window,
            session: session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter()
        )
        #expect(toShell == .toShell)
        #expect(!toShell.needsToast)
        #expect(window.review == nil)
        #expect(session.primarySelection.activeTabID == shellTab.id)
        #expect(window.pendingDecisionBarDone[shell] == nil)

        // A request waiting in the pane keeps its bar: the toast says it,
        // and nothing is left to show later about comments sent since.
        window.review = Self.tab(agent: agent, destination: agent)
        let third = try #require(window.review)
        let request = Self.waitingRequest(paneID: agent)
        let closed = ReviewTabActions.closeAfterInsert(
            ReviewTabInserted(paneID: agent, agent: .claude, opening: third.opening, selection: third.selection),
            window: window,
            session: session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter(),
            barItems: request
        )
        #expect(closed == .barBusy)
        #expect(closed.needsToast)
        #expect(window.review == nil)
        #expect(window.pendingDecisionBarDone[agent] == nil)
    }

    /// The banner of a refused paste names what Insert puts in the pane,
    /// the comments, as the button does, and not the review, which
    /// is still open around them.
    @Test func aRefusedPaste_saysTheCommentsWereNotInserted() {
        #expect(ReviewError.pasteRefused.message.resolved(in: Self.english)
            == "The comments weren’t inserted. They stay in this review.")
        #expect(ReviewError.pasteRefused.message.resolved(in: Self.japanese)
            == "コメントを挿入できませんでした。コメントはこのレビューに残っています。")
    }

    /// A paste refused after the insert brought its destination forward
    /// leaves the review tab open, in front, writing to the same pane.
    ///
    /// A shell whose tab had not been shown since launch has no terminal, so
    /// the insert brings its tab forward to start it, then pastes. That
    /// paste reaches zsh before it has asked for bracketed paste, and goes
    /// through the confirmation sheet; the reader can cancel there. The
    /// insert waits for the paste's own answer, not the paste action's
    /// return: until it comes, no comment is marked and the tab stays on
    /// the review.
    @Test func aPasteRefusedAfterTheDestinationWasBroughtForward_keepsTheReviewTabAndItsDestination() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        let container = ContainerID.project(project.id)
        let agentTab = session.openTab(container: container)
        let shellTab = session.openTab(container: container)
        let agent = try #require(agentTab.splitTree.allLeafIDs().first)
        let shell = try #require(shellTab.splitTree.allLeafIDs().first)
        session.setActiveTab(agentTab.id)
        let window = ProjectWindowState(selection: session.primarySelection)
        window.review = Self.tab(agent: agent, destination: agent)
        window.reviewPresentation.open(URL(fileURLWithPath: "/repo"), originPaneID: agent, initialScope: .uncommitted)
        ReviewTabActions.chooseDestination(shell, window: window)
        let registry = RecordingSurfaceRegistry()
        registry.deliverers[agent] = RecordingReviewDeliverer()
        // The shell's view is registered, its surface is not: a tab not
        // shown since launch.
        let deliverer = RecordingReviewDeliverer()
        deliverer.isReadyForReviewPaste = false
        deliverer.hasTerminalSurface = false
        deliverer.verdict = .isRefused
        registry.deliverers[shell] = deliverer
        let repository = FakeReviewRepository()
        repository.files = [Self.file]
        repository.diffs[Self.file.id] = try ReviewDiff(
            file: Self.file,
            fingerprint: "f1",
            lines: ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        )
        let root = URL(fileURLWithPath: "/tmp/limpid-review-refused-\(UUID().uuidString)")
        let reviewSession = ReviewSession(root: root, git: repository, drafts: RecordingReviewDraftStore())
        _ = await reviewSession.reload(scope: .uncommitted, selectedFileID: nil)
        let line = try #require(reviewSession.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        #expect(reviewSession.add(line: line, body: "Mine"))
        var broughtForward: [UUID] = []
        let target = ReviewInsertion.Target(
            session: session,
            registry: registry,
            originPaneID: { window.reviewPresentation.originPaneID },
            instructions: "",
            locale: Self.english,
            isSameReview: { true },
            // What the window does for a pane with no surface
            // (`ReviewTabActions.startPane`): its tab comes forward, the
            // review goes behind it, and comes back once the pane is ready.
            startPane: { paneID in
                broughtForward.append(paneID)
                ReviewTabActions.hide(
                    window: window,
                    showing: shellTab.id,
                    session: session,
                    registry: registry,
                    paneVisibility: PaneVisibilityReporter()
                )
                deliverer.isReadyForReviewPaste = true
                deliverer.hasTerminalSurface = true
                ReviewTabActions.show(window: window)
                return true
            }
        )

        await #expect(throws: ReviewError.pasteRefused) {
            try await ReviewInsertion.run(reviewSession: reviewSession, to: target)
        }

        #expect(broughtForward == [shell])
        #expect(deliverer.delivered.count == 1, "the paste was started; the shell did not take it")
        #expect(reviewSession.comments.allSatisfy { $0.insertedAt == nil }, "nothing was marked")
        let tab = try #require(window.review)
        #expect(tab.isShown, "the review tab is still open, in front")
        #expect(tab.destinationPaneID == shell, "and still writes to the shell")
        #expect(window.reviewPresentation.originPaneID == shell)

        // The sheet stays up: the insert waits on the paste's answer, marking
        // nothing meanwhile, and a cancel there is the same refusal.
        deliverer.verdict = .waits
        async let suspended: Void = {
            await #expect(throws: ReviewError.pasteRefused) {
                try await ReviewInsertion.run(reviewSession: reviewSession, to: target)
            }
        }()
        await pollUntil { deliverer.delivered.count >= 2 }
        try #require(deliverer.delivered.count == 2, "the second insert reached the paste")
        #expect(reviewSession.comments.allSatisfy { $0.insertedAt == nil }, "nothing is marked while the sheet is up")
        #expect(window.review?.isShown == true)
        try #require(deliverer.receipts.last ?? nil).settlement?.settle(wasDelivered: false)
        await suspended
        #expect(reviewSession.comments.allSatisfy { $0.insertedAt == nil })
        #expect(window.review?.destinationPaneID == shell)

        // The same insert, with the paste taken: marked, complete, and the
        // tab closes to the shell as before.
        deliverer.verdict = .lands
        let outcome = try await ReviewInsertion.run(reviewSession: reviewSession, to: target)
        #expect(outcome.isComplete)
        #expect(outcome.paneID == shell)
        #expect(reviewSession.comments.allSatisfy { $0.insertedAt != nil })
        let closed = ReviewTabActions.closeAfterInsert(
            ReviewTabInserted(paneID: outcome.paneID, agent: outcome.agent, opening: tab.opening, selection: tab.selection),
            window: window,
            session: session,
            registry: registry,
            paneVisibility: PaneVisibilityReporter()
        )
        #expect(closed == .toShell)
        #expect(window.review == nil)
        #expect(session.primarySelection.activeTabID == shellTab.id)
    }

    private static func waitingRequest(paneID: UUID) -> [AttentionItem] {
        var queue = AttentionQueue()
        queue.insert(
            id: .prompt(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
            kind: .prompt(PromptWait(detail: "Allow edit?")),
            subject: .runtime(id: "r", provider: .claude, paneID: paneID, tabID: nil, projectID: nil),
            arrivedAt: Date()
        )
        return queue.items
    }

    /// A comment an earlier build saved in the per-pane "This turn" scope
    /// still decodes, as a legacy comment: it is in no scope an insert
    /// sends, so it is neither sent nor counted, and never checked, so never
    /// stale.
    @Test func anInsert_leavesASavedThisTurnComment_alone() async throws {
        let fixture = WorkspaceSessionFixture.withLooseTab()
        let registry = RecordingSurfaceRegistry()
        let deliverer = RecordingReviewDeliverer()
        registry.deliverers[fixture.paneID] = deliverer
        let repository = FakeReviewRepository()
        repository.files = [Self.file]
        repository.diffs[Self.file.id] = try ReviewDiff(
            file: Self.file,
            fingerprint: "f1",
            lines: ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        )
        let theirs = ReviewComment(
            scopeIDs: ["turn:bbb"],
            file: ReviewFile(path: "a.swift", layer: .turn, status: .modified),
            fingerprint: "theirs",
            anchor: ReviewAnchor(lineID: 1, oldLine: nil, newLine: 1),
            code: "new",
            body: "About their turn"
        )
        let drafts = RecordingReviewDraftStore()
        let root = URL(fileURLWithPath: "/tmp/limpid-review-destination-\(UUID().uuidString)")
        try drafts.save(ReviewDraft(comments: [theirs]), root: root)
        let reviewSession = ReviewSession(root: root, git: repository, drafts: drafts)
        _ = await reviewSession.reload(scope: .uncommitted, selectedFileID: nil)
        let line = try #require(reviewSession.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        #expect(reviewSession.add(line: line, body: "Mine"))

        let outcome = try await ReviewInsertion.run(
            reviewSession: reviewSession,
            to: ReviewInsertion.Target(
                session: fixture.session,
                registry: registry,
                originPaneID: { fixture.paneID },
                instructions: "",
                locale: Self.english,
                isSameReview: { true }
            )
        )

        #expect(reviewSession.comments.first { $0.id == theirs.id }?.isLegacy == true)
        #expect(outcome.held == 0)
        #expect(deliverer.delivered.count == 1)
        #expect(reviewSession.comments.first { $0.id == theirs.id }?.insertedAt == nil, "not sent, not marked")
        #expect(reviewSession.staleCommentIDs.isEmpty, "never checked, so never stale")
    }

    /// A comment edited while the paste waits on its answer (another
    /// window's review of the same worktree shares the draft) went out
    /// with its earlier text: it is not marked as inserted, and the insert
    /// is not complete, so the review stays open on it.
    @Test func aCommentEditedWhileThePasteWaits_isNotMarkedInserted() async throws {
        let fixture = WorkspaceSessionFixture.withLooseTab()
        let registry = RecordingSurfaceRegistry()
        let deliverer = RecordingReviewDeliverer()
        deliverer.verdict = .waits
        registry.deliverers[fixture.paneID] = deliverer
        let repository = FakeReviewRepository()
        repository.files = [Self.file]
        repository.diffs[Self.file.id] = try ReviewDiff(
            file: Self.file,
            fingerprint: "f1",
            lines: ReviewDiffParser.parse("@@ -1,1 +1,2 @@\n-old\n+new\n+more")
        )
        let root = URL(fileURLWithPath: "/tmp/limpid-review-edited-\(UUID().uuidString)")
        let reviewSession = ReviewSession(root: root, git: repository, drafts: RecordingReviewDraftStore())
        _ = await reviewSession.reload(scope: .uncommitted, selectedFileID: nil)
        let lines = try #require(reviewSession.diff?.lines.filter { $0.isCommentable && $0.kind == .added })
        try #require(lines.count == 2)
        #expect(reviewSession.add(line: lines[0], body: "Kept"))
        #expect(reviewSession.add(line: lines[1], body: "Old"))
        let kept = try #require(reviewSession.comments.first { $0.body == "Kept" })
        let edited = try #require(reviewSession.comments.first { $0.body == "Old" })

        let target = ReviewInsertion.Target(
            session: fixture.session,
            registry: registry,
            originPaneID: { fixture.paneID },
            instructions: "",
            locale: Self.english,
            isSameReview: { true }
        )
        let running = Task { try await ReviewInsertion.run(reviewSession: reviewSession, to: target) }
        await pollUntil { !deliverer.delivered.isEmpty }
        #expect(reviewSession.edit(edited.id, body: "New"))
        try #require(deliverer.receipts.last ?? nil).settlement?.settle(wasDelivered: true)
        let outcome = try await running.value

        #expect(outcome.changed == 1)
        #expect(!outcome.isComplete)
        #expect(reviewSession.comments.first { $0.id == kept.id }?.insertedAt != nil)
        #expect(reviewSession.comments.first { $0.id == edited.id }?.insertedAt == nil, "sent as it was, not as it is")
    }
}

/// These cover what `ReviewTabActions.startPane` leaves shown once a pane
/// with no surface has come forward and got ready.
@MainActor
@Suite("Review destination start", .timeLimit(.minutes(1)))
struct ReviewDestinationStartTests {
    /// This holds the project's first tab, in front with the review over it,
    /// and a second whose pane has a view but no surface yet.
    private struct Setup {
        let fixture: ActionStoresFixture
        let first: Tab
        let restored: Tab
        let pane: UUID
        let deliverer: RecordingReviewDeliverer
    }

    private static func setUp() throws -> Setup {
        let fixture = ActionStoresFixture()
        let container = ContainerID.project(fixture.project.id)
        let first = try #require(fixture.session.tabs(in: container).first)
        let restored = fixture.session.openTab(container: container)
        let pane = try #require(restored.splitTree.allLeafIDs().first)
        fixture.session.setActiveTab(first.id, in: fixture.window.id, intent: .person)
        let deliverer = RecordingReviewDeliverer()
        deliverer.isReadyForReviewPaste = false
        deliverer.hasTerminalSurface = false
        fixture.registry.deliverers[pane] = deliverer
        fixture.window.review = review(root: fixture.root, destination: pane)
        return Setup(fixture: fixture, first: first, restored: restored, pane: pane, deliverer: deliverer)
    }

    private static func review(root: String, destination: UUID) -> ReviewTabState {
        ReviewTabState(
            root: root,
            selection: .uncommitted(includesChangesOutsideTurns: false),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: nil,
            destinationPaneID: destination,
            opening: UUID()
        )
    }

    private static func start(_ setup: Setup) -> Task<Bool, Never> {
        let fixture = setup.fixture
        return Task {
            await ReviewTabActions.startPane(
                setup.pane,
                window: fixture.window,
                stores: fixture.review,
                paneVisibility: PaneVisibilityReporter()
            )
        }
    }

    @Test func aPaneThatGotReady_putsTheReviewBackInFront() async throws {
        let setup = try Self.setUp()
        let fixture = setup.fixture
        let started = Self.start(setup)
        await pollUntil { fixture.window.selection.activeTabID == setup.restored.id }
        #expect(fixture.window.review?.isShown == false, "the pane's tab came forward")
        setup.deliverer.isReadyForReviewPaste = true

        #expect(await started.value)
        #expect(fixture.window.review?.isShown == true)
    }

    /// The person went to another tab while the pane started: they stay
    /// there, and the review stays behind, so the insert does not close
    /// it onto the pane.
    @Test func aMoveToAnotherTabDuringTheWait_isKept() async throws {
        let setup = try Self.setUp()
        let fixture = setup.fixture
        let other = fixture.session.openTab(container: .project(fixture.project.id))
        fixture.session.setActiveTab(setup.first.id, in: fixture.window.id, intent: .person)
        let started = Self.start(setup)
        await pollUntil { fixture.window.selection.activeTabID == setup.restored.id }
        ReviewTabActions.hide(
            window: fixture.window,
            showing: other.id,
            session: fixture.session,
            registry: fixture.registry,
            paneVisibility: PaneVisibilityReporter()
        )
        setup.deliverer.isReadyForReviewPaste = true

        #expect(await started.value)
        #expect(fixture.window.selection.activeTabID == other.id)
        #expect(fixture.window.review?.isShown == false)
    }

    /// The review was opened again during the wait: that one is not
    /// brought in front as if it were the one the insert left.
    @Test func anotherOpeningDuringTheWait_isNotBroughtForward() async throws {
        let setup = try Self.setUp()
        let fixture = setup.fixture
        let started = Self.start(setup)
        await pollUntil { fixture.window.selection.activeTabID == setup.restored.id }
        var reopened = Self.review(root: fixture.root, destination: setup.pane)
        reopened.isShown = false
        fixture.window.review = reopened
        setup.deliverer.isReadyForReviewPaste = true

        #expect(await started.value)
        #expect(fixture.window.review?.isShown == false)
    }
}
