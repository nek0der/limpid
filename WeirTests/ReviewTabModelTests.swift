// ReviewTabModelTests.swift
// Weir — the review tab's rules: one per window, what each entry reads, where closing goes, and what it marks.

import Foundation
import Testing
@testable import Weir

@Suite("Review tab model")
struct ReviewTabModelTests {
    private typealias Fixture = TurnSummaryFixture
    private static let root = "/repo"
    private static let agent = UUID()
    private static let otherAgent = UUID()

    private static func turn(
        _ number: Int,
        changes: String = TurnSummaryFixture.changedFiles,
        phase: String = "finished",
        root: String = root,
        hasEnd: Bool = true,
        prompt: String? = nil
    ) throws -> TurnSummary {
        try Fixture.turn(
            "T\(number)",
            phase: phase,
            changes: changes,
            number: number,
            endTree: hasEnd ? SnapshotTree(tree: Fixture.tree("e", number), root: root) : nil,
            extras: .init(beginTree: SnapshotTree(tree: Fixture.tree("b", number), root: root), promptHead: prompt)
        )
    }

    private static func context(
        _ turns: [TurnSummary],
        viewedThrough: Int = 0,
        outside: Bool = false
    ) -> ReviewTabModel.Context {
        ReviewTabModel.Context(
            turns: turns,
            isViewed: { $0.displayNumber <= viewedThrough },
            branchBase: "main",
            hasChangesOutsideTurns: outside,
            hasUnviewedChangesOutsideTurns: outside
        )
    }

    private static func open(
        _ request: ReviewTabRequest,
        _ context: ReviewTabModel.Context,
        from agent: UUID? = agent,
        current: ReviewTabState? = nil
    ) -> ReviewTabState? {
        try? ReviewTabModel.open(request, context, root: root, agentPaneID: agent, current: current).get()
    }

    private static func failure(_ request: ReviewTabRequest, _ context: ReviewTabModel.Context) -> ReviewTabUnavailable? {
        guard case let .failure(reason) = ReviewTabModel.open(request, context, root: root, agentPaneID: agent, current: nil)
        else { return nil }
        return reason
    }

    private static func range(_ tab: ReviewTabState?) -> ClosedRange<Int>? {
        guard case let .turns(range) = tab?.scope else { return nil }
        return range.numbers
    }

    @Test func eachEntry_readsItsOwnComparison() throws {
        let context = try Self.context([Self.turn(5), Self.turn(6), Self.turn(7)], viewedThrough: 5)

        #expect(Self.range(Self.open(.unviewedTurns, context)) == 6...7)
        #expect(Self.range(Self.open(.turn(TurnID("T5")), context)) == 5...5, "one turn, viewed or not")
        #expect(Self.range(Self.open(.latestTurn, context)) == 7...7)
        #expect(Self.open(.uncommitted, context)?.selection == .uncommitted(includesChangesOutsideTurns: false))
    }

    @Test func aStopsPartialChanges_areItsTurn_orElseWhatIsUncommitted() throws {
        let context = try Self.context([Self.turn(5), Self.turn(6, hasEnd: false), Self.turn(7, phase: "started")])
        #expect(Self.range(Self.open(.partialChanges(TurnID("T5")), context)) == 5...5)
        let uncommitted = ReviewScopeOption.uncommitted(includesChangesOutsideTurns: false)
        // Cut short with no end snapshot, still running, unknown, or none.
        #expect(Self.open(.partialChanges(TurnID("T6")), context)?.selection == uncommitted)
        #expect(Self.open(.partialChanges(TurnID("T7")), context)?.selection == uncommitted)
        #expect(Self.open(.partialChanges(TurnID("T9")), context)?.selection == uncommitted)
        #expect(Self.open(.partialChanges(nil), context)?.selection == uncommitted)
    }

    @Test func aTurnWithNothingToRead_saysWhy_andARecordThatLostASnapshotOpensToSayItIsIncomplete() throws {
        // As the record reports a turn that lost its end snapshot, and one
        // whose snapshots were never taken.
        let endMissing = #"{"kind":"unavailable","reason":"endMissing"}"#
        let notGit = #"{"kind":"unavailable","reason":"notGit"}"#
        let context = try Self.context([
            Self.turn(1, changes: #"{"kind":"unchanged"}"#),
            Self.turn(2, changes: notGit, hasEnd: false),
            Self.turn(3, changes: endMissing, hasEnd: false),
            Self.turn(4, changes: #"{"kind":"unchanged"}"#),
            Self.turn(5, phase: "started", hasEnd: false)
        ])

        #expect(Self.failure(.turn(TurnID("T1")), context) == .answerOnly)
        #expect(Self.failure(.turn(TurnID("T2")), context) == .changesUnavailable)
        #expect(Self.failure(.turn(TurnID("T5")), context) == .running)
        #expect(Self.failure(.turn(TurnID("T9")), context) == .noTurn)
        #expect(Self.open(.turn(TurnID("T3")), context)?.selection == .incompleteTurn(3), "not an answer")
        // The latest turn there is something to read in, not an older one
        // in its place.
        #expect(Self.open(.latestTurn, context)?.selection == .incompleteTurn(3))
        // As the decision bar counts them, neither is unread changes.
        #expect(Self.open(.unviewedTurns, context)?.selection == .unviewedTurns(.none))
    }

    @Test func aTurnWhoseChangesCouldNotBeJudged_isNotReadAsADiff_evenWithBothTrees() throws {
        // One snapshot left out a large file the other kept.
        let context = try Self.context([Self.turn(6, changes: #"{"kind":"unavailable","reason":"skippedFilesDiffer"}"#)])

        #expect(Self.failure(.turn(TurnID("T6")), context) == .changesUnavailable)
        #expect(Self.failure(.latestTurn, context) == .changesUnavailable, "not an older turn in its place")
        let tab = try #require(Self.open(.uncommitted, context))
        #expect(!ReviewTabModel.menu(tab, context).contains {
            if case .turn = $0 {
                true
            } else {
                false
            }
        }, "not listed")
    }

    @Test func aRecordNobodyPrompted_isNoTurnToReview() throws {
        let context = try Self.context([Fixture.turn("T1", changes: Fixture.changedFiles, hasPrompt: false, number: 1)])

        #expect(Self.failure(.turn(TurnID("T1")), context) == .noTurn)
    }

    @Test func aTurnThatLostItsEnd_inTheMiddleOfARange_isReadLikeAnyOther() throws {
        // A range compares T6's begin with T8's end.
        let context = try Self.context([
            Self.turn(6),
            Self.turn(7, changes: #"{"kind":"unavailable","reason":"endMissing"}"#, hasEnd: false),
            Self.turn(8)
        ])

        #expect(Self.range(Self.open(.unviewedTurns, context)) == 6...8)
    }

    @Test func noUnviewedTurns_stillOpens_toSaySo() throws {
        let context = try Self.context([Self.turn(1)], viewedThrough: 1)
        let tab = try #require(Self.open(.unviewedTurns, context))

        #expect(tab.selection == .unviewedTurns(.none))
        #expect(ReviewTabModel.bandStatus(tab.selection, fileIDs: [], viewed: []) == .noChanges)
        #expect(ReviewTabModel.bandStatus(.incompleteTurn(2), fileIDs: [], viewed: []) == .incompleteRecord)
    }

    @Test func anotherEntry_replacesWhatTheOneTabReads_keepingTheOpening() throws {
        let context = try Self.context([Self.turn(6), Self.turn(7)])
        var first = try #require(Self.open(.unviewedTurns, context))
        first.destinationPaneID = UUID()
        first.isShown = false

        let again = try #require(Self.open(.uncommitted, context, current: first))

        #expect(again.opening == first.opening, "the same tab")
        #expect(again.selection == .uncommitted(includesChangesOutsideTurns: false))
        #expect(again.destinationPaneID == first.destinationPaneID, "the person's pick stays")
        #expect(again.isShown, "brought back in front")
    }

    @Test func somethingThatCannotBeRead_leavesTheOpenTabAsItWas() throws {
        let context = try Self.context([Self.turn(6), Self.turn(7, phase: "started", hasEnd: false)])
        let tab = try #require(Self.open(.unviewedTurns, context))

        let result = ReviewTabModel.open(.turn(TurnID("T7")), context, root: Self.root, agentPaneID: Self.agent, current: tab)

        #expect(result == .failure(.running), "the caller keeps its tab rather than writing nil over it")
    }

    @Test func switchingToAnAgentWithNoPane_leavesNoPaneToInsertInto() throws {
        let codex = ConversationKey(provider: .codex, conversationID: "x", isFallback: false)
        var claude = try Self.context([Self.turn(6)])
        claude.conversation = Fixture.conversation
        let tab = try #require(Self.open(.unviewedTurns, claude))
        var other = try Self.context([Self.turn(2)])
        other.conversation = codex

        let switched = try #require(Self.open(.unviewedTurns, other, from: nil, current: tab))

        #expect(switched.conversation == codex)
        #expect(switched.destinationPaneID == nil, "Codex's comments never go into Claude's input")
        #expect(switched.agentPaneID == Self.agent, "closing still returns to where the person was")
        // The same conversation again keeps the pane it writes to.
        let again = try #require(Self.open(.uncommitted, claude, from: nil, current: tab))
        #expect(again.destinationPaneID == Self.agent)
        // An agent that has a pane writes there.
        let withPane = try #require(Self.open(.unviewedTurns, other, from: Self.otherAgent, current: tab))
        #expect(withPane.destinationPaneID == Self.otherAgent)
        // Back to Claude from Codex's paneless switch: Claude's pane, the
        // one the tab already returns to, is written to again.
        let back = try #require(Self.open(.unviewedTurns, claude, from: Self.agent, current: switched))
        #expect(back.conversation == Fixture.conversation)
        #expect(back.destinationPaneID == Self.agent)
    }

    /// The band after a switch to a conversation with no pane, beside a
    /// live agent in another tab: whose pane closed, and the menu to pick
    /// another, rather than "no pane".
    @Test func aConversationWithNoPane_namesWhosePaneClosed_andOffersAnother() throws {
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")
        let codex = ConversationKey(provider: .codex, conversationID: "x", isFallback: false)
        var claude = try Self.context([Self.turn(6)])
        claude.conversation = Fixture.conversation
        let tab = try #require(Self.open(.unviewedTurns, claude))
        var other = try Self.context([Self.turn(2)])
        other.conversation = codex
        let switched = try #require(Self.open(.unviewedTurns, other, from: nil, current: tab))
        let live = ReviewTabModel.destinationChoices([ReviewDestination(paneID: Self.agent, title: "Claude Code")])
        let agents = [
            ConversationChoice(conversation: Fixture.conversation, ordinal: 2, unviewedCount: 1),
            ConversationChoice(conversation: codex, ordinal: nil, unviewedCount: 1)
        ]
        func status(
            _ tab: ReviewTabState,
            choices: [ReviewTabModel.DestinationChoice] = live,
            agents: [ConversationChoice] = agents
        ) -> ReviewTabModel.DestinationStatus {
            ReviewTabModel.destinationStatus(tab, .init(
                isPaneOpen: false,
                destination: nil,
                isResolving: false,
                choices: choices,
                agents: agents
            ))
        }

        let paneless = status(switched)
        #expect(paneless == .conversationPaneClosed(agents[1]))
        #expect(paneless.offersChoice)
        #expect(ReviewTabText.destinationName(paneless, locale: en) == "Codex’s pane is closed")
        #expect(ReviewTabText.destinationName(paneless, locale: ja) == "Codex のペインは閉じています")
        #expect(ReviewTabText.chooseDestination(locale: en) == "Choose Destination…")
        #expect(ReviewTabText.chooseDestination(locale: ja) == "挿入先を選択…")
        #expect(ReviewTabText.insertHelp(paneless, locale: en) == "Choose a destination to insert into")
        #expect(ReviewTabText.insertHelp(paneless, locale: ja) == "挿入先を選択してください")

        // The agent's own pane closed: named as the conversation filter
        // numbers it, or by its kind alone where the worktree's conversations
        // do not list it.
        let ownClosed = status(tab)
        #expect(ReviewTabText.destinationName(ownClosed, locale: en) == "Claude #2’s pane is closed")
        #expect(ReviewTabText.destinationName(status(tab, agents: []), locale: ja) == "Claude のペインは閉じています")

        // A pane the person picked, then closed, is no conversation's.
        var picked = tab
        picked.destinationPaneID = Self.otherAgent
        let pickedClosed = status(picked)
        #expect(pickedClosed == .paneClosed)
        #expect(pickedClosed.offersChoice)
        #expect(ReviewTabText.destinationName(pickedClosed, locale: en) == "The destination pane is closed")
        #expect(ReviewTabText.destinationName(pickedClosed, locale: ja) == "挿入先のペインは閉じています")
        #expect(ReviewTabText.insertHelp(pickedClosed, locale: en) == "Choose a destination to insert into")

        // "No pane" only where the workspace has no pane to choose.
        let none = status(switched, choices: [])
        #expect(none == .noPane)
        #expect(!none.offersChoice)
        #expect(ReviewTabText.destinationName(none, locale: en) == "No pane to insert into")
        #expect(ReviewTabText.destinationName(none, locale: ja) == "挿入先のペインがありません")
        #expect(ReviewTabText.insertHelp(none, locale: en) == nil, "nothing to choose; the band says why")

        // Opened with no pane and no conversation: nothing closed, there
        // is only nothing chosen, and the button says what to do.
        let unopened = ReviewTabState(
            root: Self.root,
            selection: .uncommitted(includesChangesOutsideTurns: false),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: nil,
            destinationPaneID: nil,
            opening: UUID()
        )
        let unchosen = status(unopened)
        #expect(unchosen == .unchosen)
        #expect(unchosen.offersChoice)
        #expect(!unchosen.hasClosedReason, "no reason before the button")
        #expect(ReviewTabText.destinationName(unchosen, locale: en) == "Choose a destination to insert into")
        #expect(ReviewTabText.insertHelp(unchosen, locale: ja) == "挿入先を選択してください")
        #expect(status(unopened, choices: []) == .noPane)
    }

    /// ⌘W and ⌥⌘W close the review tab in front first, so they stay live
    /// for one open in a workspace with no terminal tab ("Show Current
    /// Diff" after every tab closed).
    @Test func closeCommands_areLiveForAReviewInFront_withNoTerminalTab() {
        var review = ReviewTabState(
            root: Self.root,
            selection: .uncommitted(includesChangesOutsideTurns: false),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: nil,
            destinationPaneID: nil,
            opening: UUID()
        )
        #expect(ReviewTabModel.closeCommandsAreLive(hasActiveTab: false, review: review))
        #expect(ReviewTabModel.closeCommandsAreLive(hasActiveTab: true, review: nil))
        #expect(!ReviewTabModel.closeCommandsAreLive(hasActiveTab: false, review: nil))
        // Behind a terminal tab there is none to close here.
        review.isShown = false
        #expect(!ReviewTabModel.closeCommandsAreLive(hasActiveTab: false, review: review))
    }

    /// A pane with no terminal: Insert says to choose another only where
    /// the menu has one.
    @Test func aPaneWithNoTerminal_asksForAnotherOnlyWhereThereIsOne() {
        let tab = ReviewTabState(
            root: Self.root,
            selection: .uncommitted(includesChangesOutsideTurns: false),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: Self.agent,
            destinationPaneID: Self.agent,
            opening: UUID()
        )
        let others = ReviewTabModel.destinationChoices([ReviewDestination(paneID: Self.otherAgent, title: "zsh")])
        let en = Locale(identifier: "en")
        func status(_ choices: [ReviewTabModel.DestinationChoice]) -> ReviewTabModel.DestinationStatus {
            ReviewTabModel.destinationStatus(tab, .init(
                isPaneOpen: true,
                destination: nil,
                isResolving: false,
                choices: choices,
                agents: []
            ))
        }

        #expect(status(others) == .noTerminal(hasOtherPanes: true))
        #expect(ReviewTabText.insertHelp(status(others), locale: en) == "Choose a destination to insert into")
        #expect(status([]) == .noTerminal(hasOtherPanes: false))
        #expect(ReviewTabText.insertHelp(status([]), locale: en) == nil)
        #expect(!status(others).offersChoice, "the band names the pane, with no terminal, as before")
    }

    @Test func openingFromNoPane_keepsTheAgentTheTabFollows() throws {
        let context = try Self.context([Self.turn(6)])
        let tab = try #require(Self.open(.unviewedTurns, context))

        let again = try #require(Self.open(.uncommitted, context, from: nil, current: tab))

        #expect(again.agentPaneID == Self.agent)
        #expect(again.destinationPaneID == Self.agent)
    }

    @Test func aCommentBeingWritten_keepsTheTabOnWhatItReads() throws {
        let context = try Self.context([Self.turn(6), Self.turn(7)])
        let tab = try #require(Self.open(.unviewedTurns, context))
        let uncommitted = try #require(Self.open(.uncommitted, context, current: tab))
        let elsewhere = try ReviewTabModel.open(.unviewedTurns, context, root: "/elsewhere", agentPaneID: Self.agent, current: nil).get()

        #expect(ReviewTabModel.refusesReplacing(tab, with: uncommitted, hasUnsavedComment: true))
        #expect(ReviewTabModel.refusesReplacing(tab, with: elsewhere, hasUnsavedComment: true), "another worktree too")
        #expect(!ReviewTabModel.refusesReplacing(tab, with: tab, hasUnsavedComment: true), "the same comparison shown again")
        #expect(!ReviewTabModel.refusesReplacing(tab, with: uncommitted, hasUnsavedComment: false))
        #expect(!ReviewTabModel.refusesReplacing(nil, with: uncommitted, hasUnsavedComment: true))
    }

    @Test func openingFromAnotherAgent_followsThatAgent() throws {
        let context = try Self.context([Self.turn(6)])
        var tab = try #require(Self.open(.unviewedTurns, context))
        tab.destinationPaneID = UUID()

        let moved = try #require(Self.open(.unviewedTurns, context, from: Self.otherAgent, current: tab))

        #expect(moved.agentPaneID == Self.otherAgent)
        #expect(moved.destinationPaneID == Self.otherAgent)
        #expect(moved.opening == tab.opening, "the same root's one tab")
    }

    @Test func anotherWorktree_opensANewTab() throws {
        let context = try Self.context([Self.turn(6)])
        let other = try ReviewTabModel.open(.unviewedTurns, context, root: "/elsewhere", agentPaneID: Self.agent, current: nil).get()

        let tab = try #require(Self.open(.unviewedTurns, context, current: other))

        #expect(tab.opening != other.opening)
        #expect(tab.root == Self.root)
    }

    @Test func theShortcut_closesTheTabOnScreen_andOtherwiseShowsTheUnviewedTurns() throws {
        let context = try Self.context([Self.turn(6), Self.turn(7)])
        var tab = try #require(Self.open(.turn(TurnID("T6")), context))

        #expect(ReviewTabModel.shortcut(context, root: Self.root, agentPaneID: Self.agent, current: tab) == .close)
        tab.isShown = false
        guard case let .show(shown) = ReviewTabModel.shortcut(context, root: Self.root, agentPaneID: Self.agent, current: tab) else {
            Issue.record("shows the tab")
            return
        }
        #expect(shown.isShown)
        #expect(Self.range(shown) == 6...7)
        guard case .show = ReviewTabModel.shortcut(context, root: Self.root, agentPaneID: Self.agent, current: nil) else {
            Issue.record("opens one")
            return
        }
    }

    @Test func aTurnEndingAfterTheTabOpened_isOffered_andOnesThatHadEndedAreNot() throws {
        let before = try Self.context([Self.turn(5), Self.turn(6), Self.turn(7)])
        let past = try #require(Self.open(.turn(TurnID("T5")), before))
        let latest = try #require(Self.open(.unviewedTurns, before))
        let after = try Self.context([Self.turn(5), Self.turn(6), Self.turn(7), Self.turn(8), Self.turn(9)])

        #expect(ReviewTabModel.followingTurns(past, before).isEmpty, "T6 and T7 had ended")
        #expect(ReviewTabModel.followingTurns(past, after).isEmpty, "a past turn is not carried over the turns after it")
        #expect(ReviewTabModel.followingTurns(latest, before).isEmpty)
        #expect(ReviewTabModel.followingTurns(latest, after).map(\.displayNumber) == [8, 9])
    }

    @Test func anAnswerAfterTheRange_doesNotStopLaterTurnsBeingOffered() throws {
        let before = try Self.context([Self.turn(6), Self.turn(7, changes: #"{"kind":"unchanged"}"#)])
        let tab = try #require(Self.open(.unviewedTurns, before))
        let after = try Self.context([Self.turn(6), Self.turn(7, changes: #"{"kind":"unchanged"}"#), Self.turn(8)])

        #expect(ReviewTabModel.followingTurns(tab, before).isEmpty, "the answer had ended before")
        #expect(ReviewTabModel.followingTurns(tab, after).map(\.displayNumber) == [8])
    }

    @Test func addingTheFollowingTurns_carriesTheRangeOn_andFixesItAgain() throws {
        let before = try Self.context([Self.turn(6, prompt: "Fix it")])
        var tab = try #require(Self.open(.turn(TurnID("T6")), before))
        tab.destinationPaneID = Self.otherAgent
        let after = try Self.context([Self.turn(6, prompt: "Fix it"), Self.turn(7)])

        let carried = try #require(ReviewTabModel.addFollowingTurns(tab, after))
        let added = carried.tab

        #expect(Self.range(added) == 6...7)
        guard case let .turns(original) = tab.scope else {
            Issue.record("a range")
            return
        }
        #expect(original.extended(with: carried.turns).map(ReviewScope.turns) == added.scope, "the session arrives at the same range")
        guard case .turn(_, TurnPrompt(head: "Fix it")) = added.selection else {
            Issue.record("still the turn picked, carried on")
            return
        }
        #expect(added.opening == tab.opening)
        #expect(added.destinationPaneID == Self.otherAgent)
        #expect(ReviewTabModel.followingTurns(added, after).isEmpty, "fixed again")
        #expect(ReviewTabModel.addFollowingTurns(added, after) == nil)
        #expect(ReviewTabModel.menu(added, after).contains(added.selection), "the dropdown shows what the tab reads")
    }

    @Test func theDropdown_keepsTheUnviewedTurnsTheTabFixed() throws {
        let before = try Self.context([Self.turn(6), Self.turn(7)])
        let tab = try #require(Self.open(.unviewedTurns, before))
        let after = try Self.context([Self.turn(6), Self.turn(7), Self.turn(8)])

        let menu = ReviewTabModel.menu(tab, after)

        #expect(menu.first == tab.selection, "T6–T7, not the T6–T8 of now")
        #expect(menu.count == ReviewScopeCatalog.options(
            turns: after.turns, isViewed: after.isViewed, branchBase: "main", hasChangesOutsideTurns: false
        ).count)
    }

    @Test func theDropdown_alwaysShowsWhatTheTabReads() throws {
        let before = try Self.context([Self.turn(6)])
        let uncommitted = try #require(Self.open(.uncommitted, before))
        let incomplete = ReviewTabModel.select(.incompleteTurn(6), in: uncommitted, before)
        // Changes outside turns appeared after the tab was fixed.
        let after = try Self.context([Self.turn(6)], outside: true)

        let menu = ReviewTabModel.menu(uncommitted, after)

        // The uncommitted changes, as they are now; one choice, not two.
        #expect(menu.contains(.uncommitted(includesChangesOutsideTurns: true)))
        #expect(!menu.contains(uncommitted.selection))
        #expect(ReviewTabModel.menu(incomplete, after).contains(.incompleteTurn(6)))
    }

    @Test func choosingAnotherScope_keepsTheTab_andFixesItAsOfNow() throws {
        let before = try Self.context([Self.turn(6)])
        let tab = try #require(Self.open(.uncommitted, before))
        let after = try Self.context([Self.turn(6), Self.turn(7)])
        let option = try #require(ReviewTabModel.menu(tab, after).first)

        let chosen = ReviewTabModel.select(option, in: tab, after)

        #expect(chosen.opening == tab.opening)
        #expect(Self.range(chosen) == 6...7)
        #expect(chosen.fixedPoint.knownThrough == 7)
    }

    @Test func markAsViewed_movesTheLineToTheFixedEnd_notToALaterTurn() throws {
        let tab = try #require(try Self.open(.unviewedTurns, Self.context([Self.turn(6), Self.turn(7)])))
        let later = try Self.context([Self.turn(6), Self.turn(7), Self.turn(8)])

        #expect(ReviewTabModel.markViewed(tab, later) == .throughTurn(ReviewTabTurn(id: TurnID("T7"), number: 7)))
    }

    @Test func markAsViewed_followsTheTurnsTheReviewReads_notTheConversationItOpenedWith() throws {
        // Opened from a shell pane, whose agent started afterwards: the tab
        // knows no conversation, and the turns it reads now are that agent's.
        let tab = try #require(try Self.open(.unviewedTurns, Self.context([Self.turn(6)])))
        #expect(tab.conversation == nil)
        #expect(try ReviewTabModel.markViewed(tab, Self.context([Self.turn(6)])) == .throughTurn(ReviewTabTurn(
            id: TurnID("T6"),
            number: 6
        )))
    }

    @Test func markAsViewed_onAPartlyViewedRange_stillMovesToItsEnd() throws {
        let turns = try [Self.turn(6), Self.turn(7), Self.turn(8)]
        let tab = try #require(Self.open(.unviewedTurns, Self.context(turns)))

        #expect(ReviewTabModel.markViewed(tab, Self.context(turns, viewedThrough: 7)) == .throughTurn(ReviewTabTurn(
            id: TurnID("T8"),
            number: 8
        )))
    }

    @Test func markAsViewed_onUncommittedChanges_stopsAtTheTurnThatHadEnded() throws {
        let before = try Self.context([Self.turn(6), Self.turn(7, phase: "started", hasEnd: false)])
        let tab = try #require(Self.open(.uncommitted, before))
        let after = try Self.context([Self.turn(6), Self.turn(7), Self.turn(8)])
        let throughT6 = ReviewTabModel.MarkViewed.includingChangesOutsideTurns(through: ReviewTabTurn(id: TurnID("T6"), number: 6))

        #expect(ReviewTabModel.markViewed(tab, after) == throughT6)
        // Viewed through T6, there is nothing left to mark: the turns that
        // ended since are not the tab's.
        #expect(ReviewTabModel.markViewed(tab, Self.context(after.turns, viewedThrough: 6)) == nil)
        #expect(
            ReviewTabModel.markViewed(tab, Self.context(after.turns, viewedThrough: 6, outside: true)) == throughT6,
            "changes outside turns still unviewed"
        )
    }

    @Test func markAsViewed_isNotOfferedWhereThereIsNothingToMove() throws {
        let turns = try [Self.turn(6), Self.turn(7)]
        let viewed = Self.context(turns, viewedThrough: 7)
        let range = try #require(Self.open(.turn(TurnID("T7")), viewed))
        let unviewed = try #require(Self.open(.unviewedTurns, viewed))

        #expect(ReviewTabModel.markViewed(range, viewed) == nil, "already viewed")
        #expect(ReviewTabModel.markViewed(unviewed, viewed) == nil, "none unviewed")
        #expect(ReviewTabModel.markViewed(ReviewTabModel.select(.branch(base: "main"), in: range, viewed), viewed) == nil)
        #expect(ReviewTabModel.markViewed(ReviewTabModel.select(.incompleteTurn(7), in: range, viewed), viewed) == nil)
    }

    @Test func theTurnsRead_areTheConversationsInThisWorktree() throws {
        // The conversation resumed in another worktree for T2.
        let turns = try [Self.turn(3), Self.turn(2, root: "/elsewhere"), Self.turn(1)]
        let other = ConversationKey(provider: .codex, conversationID: "x", isFallback: false)

        let kept = ReviewTabModel.turns(turns, root: Self.root, conversation: Fixture.conversation)

        #expect(kept.map(\.displayNumber) == [1, 3], "oldest first, without the turn of another worktree")
        #expect(ReviewTabModel.turns(turns, root: Self.root, conversation: other).isEmpty)
    }

    @Test func commandReturn_marksViewedOnlyOnceTheButtonHasBeenOnScreen_andOnce() {
        var gate = ReviewBandGate()
        let start = SuspendingClock().now
        let opening = UUID()
        let action = ReviewTabModel.MarkViewed.throughTurn(ReviewTabTurn(id: TurnID("T7"), number: 7))
        let shown = ReviewBandGate.Shown(opening: opening, selection: .uncommitted(includesChangesOutsideTurns: false), action: action)

        gate.noteShown(shown, at: start)
        #expect(gate.decide(at: start.advanced(by: .milliseconds(100))) == nil, "a press meant for the screen before")
        #expect(gate.decide(at: start.advanced(by: PrimaryActionGate.settleTime)) == action)
        #expect(gate.decide(at: start.advanced(by: .seconds(2))) == nil, "a held key marks once")

        // Another range ending at the same turn is a new showing, which waits again.
        let other = ReviewBandGate.Shown(opening: opening, selection: .unviewedTurns(.none), action: action)
        gate.noteShown(other, at: start.advanced(by: .seconds(3)))
        #expect(gate.decide(at: start.advanced(by: .seconds(3))) == nil)
        #expect(gate.decide(at: start.advanced(by: .seconds(4))) == action)
    }

    @Test func commandReturn_waitsAgain_afterTheTabClosesAndOpens_orTheWindowComesBack() {
        var gate = ReviewBandGate()
        let start = SuspendingClock().now
        let action = ReviewTabModel.MarkViewed.throughTurn(ReviewTabTurn(id: TurnID("T7"), number: 7))
        let first = ReviewBandGate.Shown(opening: UUID(), selection: .unviewedTurns(.none), action: action)
        gate.noteShown(first, at: start)
        #expect(gate.decide(at: start.advanced(by: .seconds(1))) == action)

        // Marked, then the tab closed and opened again: a new opening,
        // pressable after its wait.
        gate.noteShown(nil, at: start.advanced(by: .seconds(2)))
        let reopened = ReviewBandGate.Shown(opening: UUID(), selection: .unviewedTurns(.none), action: action)
        gate.noteShown(reopened, at: start.advanced(by: .seconds(3)))
        #expect(gate.decide(at: start.advanced(by: .seconds(3))) == nil)
        #expect(gate.decide(at: start.advanced(by: .seconds(4))) == action)

        let sameAgain = ReviewBandGate.Shown(opening: UUID(), selection: .unviewedTurns(.none), action: action)
        gate.noteShown(sameAgain, at: start.advanced(by: .seconds(5)))
        gate.restartSettling(at: start.advanced(by: .seconds(6)))
        #expect(gate.decide(at: start.advanced(by: .milliseconds(6100))) == nil, "the window came back in front")
        #expect(gate.decide(at: start.advanced(by: .seconds(7))) == action)
    }

    @Test func includingOutsideTurns_describesTheUncommittedChangesAsTheyAreNow() throws {
        let fixed = try Self.context([Self.turn(6)])
        let tab = try #require(Self.open(.uncommitted, fixed))
        let now = try Self.context([Self.turn(6)], outside: true)

        #expect(tab.selection == .uncommitted(includesChangesOutsideTurns: false))
        #expect(ReviewTabModel.shown(tab.selection, now) == .uncommitted(includesChangesOutsideTurns: true))
        #expect(ReviewTabModel.menu(tab, now).contains(.uncommitted(includesChangesOutsideTurns: true)))
        #expect(!ReviewTabModel.menu(tab, now).contains(.uncommitted(includesChangesOutsideTurns: false)))
        #expect(ReviewTabModel.isSameChoice(.uncommitted(includesChangesOutsideTurns: true), tab.selection), "the same comparison")
        #expect(!ReviewTabModel.isSameChoice(.branch(base: "main"), tab.selection))
    }

    @Test func theBandAndAddToScope_waitForTheReviewToShowTheTabsRange() throws {
        let tab = try #require(try Self.open(.unviewedTurns, Self.context([Self.turn(6), Self.turn(7)])))
        let scope = try #require(tab.scope)

        #expect(ReviewTabModel.isShowingItsScope(tab, loadedScope: scope, hasLoaded: true, isLoading: false))
        #expect(!ReviewTabModel.isShowingItsScope(tab, loadedScope: scope, hasLoaded: true, isLoading: true), "still loading")
        #expect(!ReviewTabModel.isShowingItsScope(tab, loadedScope: .uncommitted, hasLoaded: true, isLoading: false), "another range")
        #expect(!ReviewTabModel.isShowingItsScope(tab, loadedScope: scope, hasLoaded: false, isLoading: false))
        let none = ReviewTabModel.select(.unviewedTurns(.none), in: tab, Self.context([]))
        #expect(!ReviewTabModel.isShowingItsScope(none, loadedScope: nil, hasLoaded: true, isLoading: false))
    }

    @Test func aTreeRecordedThroughALink_isInThisWorktree() throws {
        let turns = try [Self.turn(1, root: "/link/repo")]

        let kept = ReviewTabModel
            .turns(turns, root: Self.root, conversation: Fixture.conversation) { $0 == "/link/repo" || $0 == Self.root }

        #expect(kept.count == 1)
        #expect(ReviewTabModel.turns(turns, root: Self.root, conversation: Fixture.conversation).isEmpty, "by name, it is elsewhere")
    }

    @Test func theTab_keepsTheConversationItOpenedOn() throws {
        var context = try Self.context([Self.turn(6)])
        context.conversation = Fixture.conversation
        let tab = try #require(Self.open(.unviewedTurns, context))
        let other = ConversationKey(provider: .codex, conversationID: "x", isFallback: false)
        var noAgent = context
        noAgent.conversation = nil

        #expect(tab.conversation == Fixture.conversation)
        #expect(
            Self.open(.uncommitted, noAgent, from: nil, current: tab)?.conversation == Fixture.conversation,
            "a pane with no agent keeps it"
        )
        context.conversation = other
        #expect(Self.open(.unviewedTurns, context, current: tab)?.conversation == other)
    }

    @Test func theBar_countsTheFilesLeftToRead() {
        let option = ReviewScopeOption.uncommitted(includesChangesOutsideTurns: false)

        #expect(ReviewTabModel.bandStatus(option, fileIDs: [], viewed: []) == .noChanges)
        #expect(ReviewTabModel.bandStatus(option, fileIDs: ["a", "b"], viewed: ["a"]) == .unviewedFiles(1))
        #expect(ReviewTabModel.bandStatus(option, fileIDs: ["a", "b"], viewed: ["a", "b", "gone"]) == .allFilesViewed)
        #expect(ReviewTabModel.bandStatus(.unviewedTurns(.incomplete(6...7)), fileIDs: [], viewed: []) == .incompleteRecord)
    }

    @Test func markAsViewed_recordsTheChangesOutsideTurnsAsTheReviewReadThem() throws {
        let tab = try #require(Self.open(.uncommitted, Self.context([Self.turn(6)])))
        let read = ReviewTabModel.OutsideTurnsRead(
            opening: tab.opening,
            listReads: 2,
            counted: ["notes.md": "blob:1", "new.md": "blob:9"],
            listed: ["notes.md", "a.swift"]
        )
        let action = ReviewTabModel.MarkViewed.includingChangesOutsideTurns(through: nil)

        #expect(read.contents == ["notes.md": "blob:1"], "a path the review did not list was never there to view")
        #expect(ReviewTabModel.outsideTurnsToRecord(action, read: read, tab: tab, listReads: 2, viewed: nil) == ["notes.md": "blob:1"])
        #expect(
            ReviewTabModel.outsideTurnsToRecord(action, read: read, tab: tab, listReads: 2, viewed: ["notes.md": "blob:1"]) == nil,
            "viewed as it is"
        )
        #expect(
            ReviewTabModel.hasUnviewedChangesOutsideTurns(read, tab: tab, listReads: 2, viewed: ["notes.md": "blob:0"]),
            "changed since"
        )
        let turnAction = ReviewTabModel.MarkViewed.throughTurn(ReviewTabTurn(id: TurnID("T6"), number: 6))
        #expect(ReviewTabModel.outsideTurnsToRecord(turnAction, read: read, tab: tab, listReads: 2, viewed: nil) == nil)
        let other = ReviewTabModel.OutsideTurnsRead(opening: UUID(), listReads: 2, counted: ["notes.md": "blob:1"], listed: ["notes.md"])
        #expect(!ReviewTabModel.hasUnviewedChangesOutsideTurns(other, tab: tab, listReads: 2, viewed: nil), "another opening's read")
        // The review read another list since, such as the range chosen
        // next, whose count has not come yet.
        #expect(ReviewTabModel.outsideTurnsToRecord(action, read: read, tab: tab, listReads: 3, viewed: nil) == nil)
    }
}

extension ReviewTabModelTests {
    /// "Review Unviewed" on the changes panel reads the worktree's
    /// timeline, not the conversation's turns: Codex's unviewed turn and
    /// Claude's as one comparison, the tab's conversation the one the
    /// panel chose to open it from.
    @Test func theWorktreesUnviewedTurns_readEveryConversation_asOneComparison() throws {
        var codexExtras = Fixture.Extras()
        codexExtras.conversationID = "codex"
        codexExtras.startedAt = "2026-10-12T00:00:10Z"
        codexExtras.beginTree = SnapshotTree(tree: Fixture.tree("b", 9), root: Self.root)
        let codex = try Fixture.turn(
            "X1",
            changes: Fixture.changedFiles,
            number: 1,
            endTree: SnapshotTree(tree: Fixture.tree("e", 9), root: Self.root),
            extras: codexExtras
        )
        // Codex's turn started ten seconds after Claude's T7.
        let claude = try Self.turn(7)
        var context = try Self.context([Self.turn(6), claude])
        context.conversation = Fixture.conversation
        context.isViewed = { $0.conversation == Fixture.conversation && $0.displayNumber <= 6 }
        context.worktreeTurns = [claude, codex]

        let tab = try #require(Self.open(.worktreeUnviewedTurns, context))

        guard case let .turns(range)? = tab.scope else {
            Issue.record("expected a range of turns")
            return
        }
        #expect(range.turnIDs == [claude.turnID, codex.turnID])
        #expect(range.beginTree == Fixture.tree("b", 7))
        #expect(range.endTree == Fixture.tree("e", 9))
        #expect(range.isAcrossConversations)
        #expect(tab.conversation == Fixture.conversation)
        #expect(Self.range(Self.open(.unviewedTurns, context)) == 7...7, "the conversation's own entry reads its turns alone")
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")
        let counts = ReviewScopeCatalog.counts(in: range, timeline: context.worktreeTurns, isViewed: { _ in false })
        #expect(ReviewTabText.option(tab.selection, counts: counts, locale: en) == "All Unviewed (2 turns · 2 conversations)")
        #expect(ReviewTabText.option(tab.selection, counts: counts, locale: ja) == "すべての未確認（ターン 2 · 会話 2）")
        #expect(ReviewTabModel.menu(tab, context).contains(tab.selection), "the dropdown shows what the tab reads")
    }
}
