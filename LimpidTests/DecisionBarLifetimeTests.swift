// DecisionBarLifetimeTests.swift
// Limpid — a pane's decision bar keeps its chosen item until the person moves on, and its "Done" line until the run does.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct DecisionBarLifetimeTests {
    private static let item = AttentionItemID.stop(EpisodeKey(origin: .runtime("r"), episodeToken: "1"))

    private static func window(choosing panes: UUID...) -> ProjectWindowState {
        let window = ProjectWindowState(id: WindowID())
        for pane in panes {
            window.decisionBarSelection[pane] = item
            window.decisionBarDone[pane] = .answeredInTerminal
        }
        return window
    }

    @Test func movingOnFromAPane_endsItsChoice_only() {
        // ⌘J chose for the pane it went to before going; the one left gives
        // way.
        let (left, arrived) = (UUID(), UUID())
        let window = Self.window(choosing: left, arrived)

        window.keyboardMoved(from: left, livePanes: [left, arrived])

        #expect(window.decisionBarSelection[left] == nil)
        #expect(window.decisionBarDone[left] == nil)
        #expect(window.decisionBarSelection[arrived] == Self.item)
        #expect(window.decisionBarDone[arrived] == .answeredInTerminal)
    }

    @Test func aDoneLineWaitingForItsBar_goesWithThePersonMovingOn() {
        // "Mark as Viewed" in the review tab left it for the pane's bar.
        let (marked, other, closed) = (UUID(), UUID(), UUID())
        let window = ProjectWindowState(id: WindowID())
        for pane in [marked, other, closed] {
            window.pendingDecisionBarDone[pane] = .answeredInTerminal
        }

        window.keyboardMoved(from: marked, livePanes: [marked, other])

        #expect(window.pendingDecisionBarDone[marked] == nil)
        #expect(window.pendingDecisionBarDone[closed] == nil, "a pane the session no longer has")
        #expect(window.pendingDecisionBarDone[other] == .answeredInTerminal)
    }

    @Test func aPaneTheSessionNoLongerHas_letsItsChoiceGo() {
        let (closed, kept) = (UUID(), UUID())
        let window = Self.window(choosing: closed, kept)

        window.keyboardMoved(from: nil, livePanes: [kept])

        #expect(window.decisionBarSelection[closed] == nil)
        #expect(window.decisionBarSelection[kept] == Self.item)
    }

    // MARK: - The "Done" line as items and runs change

    private static func itemsGone(
        from shown: ProjectWindowState.ShownItem,
        epoch: Int?,
        in window: ProjectWindowState,
        isSelectedPane: Bool = true
    ) {
        window.itemsChanged(
            .init(paneID: shown.item.subject.paneID ?? UUID(), items: [], lastShown: shown, epoch: epoch),
            isSelectedPane: isSelectedPane,
            isCurrent: { _ in true }
        )
    }

    @Test func runsChanged_endsTheLinesOfThosePanes_only() {
        let window = ProjectWindowState(id: WindowID())
        let pane = UUID()
        let other = UUID()
        let choice = AttentionItemID.stop(EpisodeKey(origin: .runtime("a"), episodeToken: "1"))
        window.decisionBarDone[pane] = .insertedReview(agent: .claude)
        window.pendingDecisionBarDone[pane] = .resumed
        window.decisionBarSelection[pane] = choice
        window.decisionBarDone[other] = .answeredInTerminal

        window.runsChanged(inPanes: [pane])
        #expect(window.decisionBarDone == [other: .answeredInTerminal])
        #expect(window.pendingDecisionBarDone.isEmpty)
        // Only the line ends; the item chosen for the pane is the bar's to drop.
        #expect(window.decisionBarSelection[pane] == choice)
    }

    @Test func anItemAnsweredInTheTerminal_setsTheLine_inTheSameEpoch() {
        let window = ProjectWindowState(id: WindowID())
        let shown = ProjectWindowState.ShownItem(item: AttentionItem.testPrompt(in: UUID()), epoch: 3)
        Self.itemsGone(from: shown, epoch: 3, in: window)
        #expect(window.decisionBarDone[shown.item.subject.paneID ?? UUID()] == .answeredInTerminal)
    }

    @Test func anItemThatLeftAsThePaneMovedOn_setsNoLine() {
        let window = ProjectWindowState(id: WindowID())
        let pane = UUID()
        // The next turn began, the agent left, the item was shown before any
        // run was in the pane, or no run was in it then or now: with no run
        // to have answered it, that counts as moved on too.
        for (shownEpoch, epoch) in [(3, 4), (3, nil), (nil, 3), (nil, nil)] as [(Int?, Int?)] {
            Self.itemsGone(from: .init(item: AttentionItem.testPrompt(in: pane), epoch: shownEpoch), epoch: epoch, in: window)
            #expect(window.decisionBarDone[pane] == nil)
        }
    }

    @Test func aLine_isSetOnlyInThePaneWithTheKeyboard() {
        let window = ProjectWindowState(id: WindowID())
        let shown = ProjectWindowState.ShownItem(item: AttentionItem.testPrompt(in: UUID()), epoch: 1)
        Self.itemsGone(from: shown, epoch: 1, in: window, isSelectedPane: false)
        #expect(window.decisionBarDone.isEmpty)
    }
}

// MARK: - The "Done" line and the runs

/// A bar's "Done" line, set or pending, lasts until its pane's run moves on
/// to its next turn (`WindowRegistry.noteRuns`).
extension DecisionBarLifetimeTests {
    private static func run(_ id: String, in pane: UUID, turn: String?, state: AgentState = .finished) -> PaneRunLedger.Run {
        PaneRunLedger.Run.test(id, in: [pane], turn: turn, state: state)
    }

    /// One pass as the app makes it: the runs are noted, then the bar sees
    /// its items change, as `AppState.refreshAttentionQueue` and the bar's
    /// change handler do.
    private static func pass(
        _ runs: [PaneRunLedger.Run],
        itemsNow items: [AttentionItem],
        shown: ProjectWindowState.ShownItem?,
        pane: UUID,
        registry: WindowRegistry
    ) {
        registry.noteRuns(runs)
        registry.primary.itemsChanged(
            .init(paneID: pane, items: items, lastShown: shown, epoch: registry.epoch(inPane: pane)),
            isSelectedPane: true,
            isCurrent: { _ in true }
        )
    }

    @Test func aPromptAnsweredInTheTurn_setsTheLine_untilTheNextTurn() {
        let registry = WindowRegistry(primary: WindowSelection())
        let pane = UUID()
        let item = AttentionItem.testPrompt(in: pane)
        registry.noteRuns([Self.run("a", in: pane, turn: "t1", state: .needsInput)])
        let shown = ProjectWindowState.ShownItem(item: item, epoch: registry.epoch(inPane: pane))

        Self.pass([Self.run("a", in: pane, turn: "t1", state: .running)], itemsNow: [], shown: shown, pane: pane, registry: registry)
        #expect(registry.primary.decisionBarDone[pane] == .answeredInTerminal)
        registry.primary.pendingDecisionBarDone[pane] = .insertedReview(agent: .claude)

        registry.noteRuns([Self.run("a", in: pane, turn: "t2", state: .running)])
        #expect(registry.primary.decisionBarDone[pane] == nil)
        #expect(registry.primary.pendingDecisionBarDone[pane] == nil)
    }

    @Test func quittingTheAgentAtItsPrompt_setsNoLine() {
        let registry = WindowRegistry(primary: WindowSelection())
        let pane = UUID()
        registry.noteRuns([Self.run("a", in: pane, turn: "t1", state: .needsInput)])
        let shown = ProjectWindowState.ShownItem(item: AttentionItem.testPrompt(in: pane), epoch: registry.epoch(inPane: pane))

        // In the same pass the session ends and the item leaves.
        Self.pass([Self.run("a", in: pane, turn: "t1", state: .unknown)], itemsNow: [], shown: shown, pane: pane, registry: registry)
        #expect(registry.primary.decisionBarDone[pane] == nil)
    }

    @Test func theNextPromptLeavingWithTheItem_setsNoLine() {
        let registry = WindowRegistry(primary: WindowSelection())
        let pane = UUID()
        registry.noteRuns([Self.run("a", in: pane, turn: "t1", state: .needsInput)])
        let shown = ProjectWindowState.ShownItem(item: AttentionItem.testPrompt(in: pane), epoch: registry.epoch(inPane: pane))

        // Escape at the prompt, then the next prompt sent: the turn and the
        // item change in one pass.
        Self.pass([Self.run("a", in: pane, turn: "t2", state: .running)], itemsNow: [], shown: shown, pane: pane, registry: registry)
        #expect(registry.primary.decisionBarDone[pane] == nil)
    }

    @Test func aStopsNextTurnInTheSameRun_endsTheLineAndThePendingOne() {
        let registry = WindowRegistry(primary: WindowSelection())
        let window = registry.primary
        let pane = UUID()
        registry.noteRuns([Self.run("a", in: pane, turn: "t1", state: .error)])
        window.decisionBarDone[pane] = .markedViewed(ViewedLineUndo(conversation: TurnSummaryFixture.conversation, changeID: UUID()))
        window.pendingDecisionBarDone[pane] = .insertedReview(agent: .claude)

        registry.noteRuns([Self.run("a", in: pane, turn: "t2", state: .running)])
        #expect(window.decisionBarDone[pane] == nil)
        #expect(window.pendingDecisionBarDone[pane] == nil)
    }

    @Test func aResumedLine_setInThePassThatBringsItsRunBack_staysAsTheOldRunGoes() {
        let registry = WindowRegistry(primary: WindowSelection())
        let window = registry.primary
        let pane = UUID()
        // The old run stays in error while its conversation is resumed.
        registry.noteRuns([Self.run("old", in: pane, turn: "t1", state: .running)])
        registry.noteRuns([Self.run("old", in: pane, turn: "t1", state: .error)])

        registry.noteRuns(
            [Self.run("old", in: pane, turn: "t1", state: .error), Self.run("new", in: pane, turn: nil, state: .idle)],
            endedStops: StopLedger.Ended(resumed: [StopLedger.Resumed(paneID: pane, window: window.id)])
        )
        #expect(window.pendingDecisionBarDone[pane] == .resumed)

        // The old run's record is cleaned up later.
        registry.noteRuns([Self.run("new", in: pane, turn: nil, state: .idle)])
        #expect(window.pendingDecisionBarDone[pane] == .resumed)
    }

    @Test func aResumedLine_isNotSet_forARunThatBeganATurn_orWithNoWindow() {
        let registry = WindowRegistry(primary: WindowSelection())
        let window = registry.primary
        let typedOn = UUID()
        let unasked = UUID()
        registry.noteRuns(
            [Self.run("a", in: typedOn, turn: "t1", state: .running), Self.run("b", in: unasked, turn: nil, state: .idle)],
            endedStops: StopLedger.Ended(resumed: [
                StopLedger.Resumed(paneID: typedOn, window: window.id, hasBegunATurn: true),
                StopLedger.Resumed(paneID: unasked, window: nil)
            ])
        )
        #expect(window.pendingDecisionBarDone.isEmpty)
    }

    @Test func aStoppedRunEnding_keepsTheLine() {
        let registry = WindowRegistry(primary: WindowSelection())
        let pane = UUID()
        registry.noteRuns([Self.run("a", in: pane, turn: "t1", state: .error)])
        registry.primary.decisionBarDone[pane] = .resumed

        // Its session's end, after the conversation came back elsewhere.
        registry.noteRuns([Self.run("a", in: pane, turn: "t1", state: .unknown)])
        #expect(registry.primary.decisionBarDone[pane] == .resumed)
    }

    /// A line set while the run was stopped stays as the stopped agent
    /// exits (its conversation may come back under a line that says so),
    /// and ends once its stop ends as the person moving on to another
    /// conversation in the pane (`StopLedger.Ended.movedOn`).
    @Test func aLineSetWhileStopped_endsWhenThePaneMovesOnToAnotherConversation() {
        let registry = WindowRegistry(primary: WindowSelection())
        let pane = UUID()
        registry.noteRuns([Self.run("a", in: pane, turn: "t1", state: .error)])
        registry.primary.decisionBarDone[pane] = .answeredInTerminal

        registry.noteRuns([])
        #expect(registry.primary.decisionBarDone[pane] == .answeredInTerminal)
        // A run arriving alone says nothing: it may be the conversation back.
        registry.noteRuns([Self.run("b", in: pane, turn: nil, state: .idle)])
        #expect(registry.primary.decisionBarDone[pane] == .answeredInTerminal)
        let epoch = registry.epoch(inPane: pane)

        registry.noteRuns(
            [Self.run("b", in: pane, turn: nil, state: .idle)],
            endedStops: StopLedger.Ended(movedOn: [pane])
        )
        #expect(registry.primary.decisionBarDone[pane] == nil)
        #expect(registry.epoch(inPane: pane) != epoch)
    }

    @Test func everyWindow_endsTheLinesOfThePanesThatMovedOn() {
        let registry = WindowRegistry(primary: WindowSelection())
        let second = registry.addWindow(WindowSelection())
        let pane = UUID()
        let other = UUID()
        registry.noteRuns([Self.run("a", in: pane, turn: "t1"), Self.run("b", in: other, turn: "t1")])
        registry.primary.decisionBarDone[pane] = .answeredInTerminal
        second.decisionBarDone[pane] = .answeredInTerminal
        second.decisionBarDone[other] = .answeredInTerminal

        registry.noteRuns([Self.run("a", in: pane, turn: "t2"), Self.run("b", in: other, turn: "t1")])
        #expect(registry.primary.decisionBarDone.isEmpty)
        #expect(second.decisionBarDone == [other: .answeredInTerminal])
    }

    @Test func afterAProjectSwitchInPlace_theNewProjectsLineEndsWithItsTurn() throws {
        let fixture = ProjectWindowsFixture()
        let window = fixture.primary
        let firstPane = try #require(fixture.aTab.splitTree.allLeafIDs().first)
        fixture.registry.noteRuns([Self.run("left", in: firstPane, turn: "t1")])

        fixture.choose(fixture.bTab, in: window)
        #expect(fixture.session.primarySelection.shownProjectID == fixture.b.id)
        let pane = try #require(fixture.bTab.splitTree.allLeafIDs().first)
        // The project left keeps its run; the ledger goes on from the same
        // passes in the window now showing another project.
        fixture.registry.noteRuns([Self.run("left", in: firstPane, turn: "t1"), Self.run("a", in: pane, turn: "t1")])
        window.decisionBarDone[pane] = .insertedReview(agent: .claude)

        fixture.registry.noteRuns([Self.run("left", in: firstPane, turn: "t1"), Self.run("a", in: pane, turn: "t2", state: .running)])
        #expect(window.decisionBarDone[pane] == nil)
    }

    @Test func aRunBetweenTmuxAttachments_keepsItsLine() {
        let registry = WindowRegistry(primary: WindowSelection())
        let pane = UUID()
        registry.noteRuns([Self.run("a", in: pane, turn: "t1")])
        registry.primary.decisionBarDone[pane] = .insertedReview(agent: .claude)

        // The run names no pane for a moment, then the same one again.
        registry.noteRuns([PaneRunLedger.Run.test("a", in: [], turn: "t1")])
        registry.noteRuns([Self.run("a", in: pane, turn: "t1")])
        #expect(registry.primary.decisionBarDone[pane] == .insertedReview(agent: .claude))
    }
}
