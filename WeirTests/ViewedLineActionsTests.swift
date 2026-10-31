// ViewedLineActionsTests.swift
// Weir — moving a viewed line from the decision bar, the timeline's rows, and a restore, and the Undos that take it back.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("Viewed line actions")
struct ViewedLineActionsTests {
    private typealias Fixture = TurnSummaryFixture
    private static let pane = UUID()

    /// One finished run in `pane`, with its unread item listed.
    @MainActor
    private struct Scene {
        let attention = AttentionState()
        let lines = ViewedLineStore(directory: URL(fileURLWithPath: "/nonexistent"), writesFiles: false)
        let toasts = ToastCenter()
        let window = ProjectWindowState(id: WindowID())
        let queue: AttentionQueue
        let itemID: AttentionItemID
        let history: [ConversationKey: [TurnSummary]]

        init(conversation: ConversationKey?, history: [ConversationKey: [TurnSummary]]) {
            var runtime = AgentRuntimePresentation.test(
                badge: AgentBadge(state: .finished, updatedAt: Date(timeIntervalSince1970: 100)),
                paneIDs: [ViewedLineActionsTests.pane],
                stateEpisodeToken: "episode"
            )
            runtime.conversation = conversation
            attention.runtimesByKind = [.claude: [runtime]]
            var queue = AttentionQueue()
            let itemID = AttentionItemID.unread(TurnID("\(runtime.id)#episode"))
            queue.insert(
                id: itemID,
                kind: .unread(UnreadTurn(turnID: TurnID("t"), changes: .unknown, conversation: conversation)),
                subject: .runtime(id: runtime.id, provider: .claude, paneID: ViewedLineActionsTests.pane, tabID: nil, projectID: nil),
                arrivedAt: Date()
            )
            self.queue = queue
            self.itemID = itemID
            self.history = history
        }

        var actions: ViewedLineActions {
            ViewedLineActions(queue: queue, attention: attention, history: history, lines: lines, toasts: toasts, window: window)
        }
    }

    private static func recordedScene() throws -> (Scene, TurnSummary) {
        let turn = try Fixture.turn("T1", changes: Fixture.changedFiles, number: 1)
        return (Scene(conversation: Fixture.conversation, history: [Fixture.conversation: [turn]]), turn)
    }

    @Test func markingViewed_movesTheLine_andOffersUndoOnTheBarAndAToast() throws {
        let (scene, turn) = try Self.recordedScene()

        #expect(scene.actions.markViewed(scene.itemID, inPane: Self.pane))

        #expect(scene.lines.isViewed(turn))
        guard case let .markedViewed(undo) = scene.window.decisionBarDone[Self.pane] else {
            Issue.record("the bar says Done with Undo")
            return
        }
        #expect(scene.toasts.current(in: scene.window.id)?.id == undo.changeID)
        #expect(scene.toasts.current(in: scene.window.id)?.message.resolved(in: Locale(identifier: "ja")) == "T1 まで確認済みにしました。")
        #expect(!scene.actions.markViewed(scene.itemID, inPane: Self.pane), "already viewed: nothing to take back")
    }

    @Test func theBarsToast_takesTheLineBack_afterItsWindowClosed() throws {
        let (scene, turn) = try Self.recordedScene()
        let session = WorkspaceSession()
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()
        registry.onClose = { window in
            WindowClosing.tidy(
                window,
                session: session,
                registry: registry,
                toasts: scene.toasts
            )
        }
        let id = WorkspaceSessionFixture.addWindow(to: session)
        weak var closed: ProjectWindowState?
        do {
            let window = try registry.addWindow(#require(session.selection(id)))
            registry.show(registry.primary.id)
            registry.show(id)
            closed = window
            let actions = ViewedLineActions(
                queue: scene.queue,
                attention: scene.attention,
                history: scene.history,
                lines: scene.lines,
                toasts: scene.toasts,
                window: window
            )
            #expect(actions.markViewed(scene.itemID, inPane: Self.pane))
            registry.close(id, in: session)
        }

        // The window is gone; its toast moved to the window left.
        #expect(closed == nil)
        let left = registry.primary.id
        #expect(scene.toasts.current(in: left) != nil)
        scene.toasts.undo(in: left)

        #expect(!scene.lines.isViewed(turn))
        #expect(scene.toasts.current(in: left) == nil)
    }

    @Test func aTurnsRow_movesTheLine_endsTheBarsEarlierDone_andItsToastTakesItBack() throws {
        let first = try Fixture.turn("T1", changes: Fixture.changedFiles, number: 1)
        let second = try Fixture.turn("T2", changes: Fixture.changedFiles, number: 2)
        let scene = Scene(conversation: Fixture.conversation, history: [Fixture.conversation: [first, second]])
        scene.actions.markViewed(scene.itemID, through: 1, inPane: Self.pane)
        let other = UUID()
        scene.window.pendingDecisionBarDone[other] = .markedViewed(ViewedLineUndo(conversation: Fixture.conversation, changeID: UUID()))
        scene.window.pendingDecisionBarDone[UUID()] = .insertedReview(agent: .claude)

        let change = try #require(scene.actions.markViewed(through: second))

        #expect(scene.lines.isViewed(second))
        #expect(scene.window.decisionBarDone[Self.pane] == nil, "its Undo was for the move before")
        #expect(scene.window.pendingDecisionBarDone[other] == nil)
        #expect(scene.window.pendingDecisionBarDone.count == 1, "another kind of Done stays")
        #expect(scene.toasts.current(in: scene.window.id)?.id == change.id)
        #expect(scene.toasts.current(in: scene.window.id)?.message.resolved(in: Locale(identifier: "en")) == "Marked as viewed up to T2.")
        scene.toasts.current(in: scene.window.id)?.undo?()
        #expect(!scene.lines.isViewed(second))
        #expect(scene.lines.isViewed(first), "back to where the bar had put it")
        #expect(scene.toasts.current(in: scene.window.id) == nil)
    }

    /// "Mark as Viewed up to Here" on the worktree's timeline: the row's
    /// conversation and the others move as one mark, the toast counts the
    /// conversations, and its Undo takes every move back; so does "Unmark
    /// as Viewed" with the moves the panel's line offers.
    @Test func aRowOnTheTimeline_movesEveryConversationsLine_andOneUndoTakesThemAllBack() throws {
        var codexExtras = Fixture.Extras()
        codexExtras.conversationID = "codex"
        let claude = try Fixture.turn("c4", changes: Fixture.changedFiles, number: 4)
        let codex = try Fixture.turn("x1", changes: Fixture.changedFiles, number: 1, extras: codexExtras)
        let scene = Scene(conversation: Fixture.conversation, history: [Fixture.conversation: [claude], codex.conversation: [codex]])
        scene.window.pendingDecisionBarDone[UUID()] = .markedViewed(ViewedLineUndo(conversation: codex.conversation, changeID: UUID()))

        let moves = scene.actions.markViewed(through: [claude, codex], named: { _ in "Claude #4" })

        #expect(moves.map(\.conversation) == [claude.conversation, codex.conversation])
        #expect(scene.lines.isViewed(claude) && scene.lines.isViewed(codex))
        #expect(scene.window.pendingDecisionBarDone.isEmpty, "a Done for either conversation's earlier move goes")
        let toast = try #require(scene.toasts.current(in: scene.window.id))
        #expect(toast.id == moves.first?.change.id)
        #expect(toast.message.resolved(in: Locale(identifier: "en"))
            == "Marked as viewed up to T4 of Claude #4, and 1 other conversation up to the same point.")
        #expect(toast.message.resolved(in: Locale(identifier: "ja"))
            == "Claude #4 の T4 まで確認済みにしました。ほかの会話 1 件も同じ時点まで確認済みにしました。")
        #expect(toast.undoLabel?.resolved(in: Locale(identifier: "en")) == "Undo in 2 Conversations")
        toast.undo?()
        #expect(!scene.lines.isViewed(claude) && !scene.lines.isViewed(codex), "both lines back")
        #expect(scene.toasts.current(in: scene.window.id) == nil)

        // Marked again, the panel's line takes the mark back as one.
        let again = scene.actions.markViewed(through: [claude, codex])
        scene.actions.unmark(again.map(\.undo))
        #expect(!scene.lines.isViewed(claude) && !scene.lines.isViewed(codex))
        #expect(scene.toasts.current(in: scene.window.id) == nil)

        // One conversation alone keeps the one-conversation toast.
        let alone = scene.actions.markViewed(through: [claude])
        #expect(alone.count == 1)
        #expect(scene.toasts.current(in: scene.window.id)?.message.resolved(in: Locale(identifier: "en")) == "Marked as viewed up to T4.")
    }

    /// The toast says what moved, not what was asked: a conversation whose
    /// line was already past its turn moves nothing, so the toast neither
    /// names it nor counts it, and names the first conversation that did
    /// move, with that conversation's turn.
    @Test func aMarkWhoseFirstLineDidNotMove_namesAndCountsOnlyTheLinesThatMoved() throws {
        var codexExtras = Fixture.Extras()
        codexExtras.conversationID = "codex"
        var thirdExtras = Fixture.Extras()
        thirdExtras.conversationID = "third"
        let claude = try Fixture.turn("c4", changes: Fixture.changedFiles, number: 4)
        let codex = try Fixture.turn("x2", changes: Fixture.changedFiles, number: 2, extras: codexExtras)
        let third = try Fixture.turn("t5", changes: Fixture.changedFiles, number: 5, extras: thirdExtras)
        let scene = Scene(
            conversation: Fixture.conversation,
            history: [Fixture.conversation: [claude], codex.conversation: [codex], third.conversation: [third]]
        )
        let names = [claude.conversation: "Claude #4", codex.conversation: "Codex", third.conversation: "Claude #5"]
        scene.actions.markViewed(through: [claude])

        let moves = scene.actions.markViewed(through: [claude, codex, third], named: { names[$0] })

        #expect(moves.map(\.conversation) == [codex.conversation, third.conversation])
        let toast = try #require(scene.toasts.current(in: scene.window.id))
        #expect(toast.message.resolved(in: Locale(identifier: "en"))
            == "Marked as viewed up to T2 of Codex, and 1 other conversation up to the same point.")
        #expect(toast.undoLabel?.resolved(in: Locale(identifier: "en")) == "Undo in 2 Conversations")

        // The mirror: the line already above its turn is left out too.
        scene.toasts.dismiss(in: scene.window.id)
        scene.actions.markNotViewed(from: [codex])
        scene.toasts.dismiss(in: scene.window.id)
        let back = scene.actions.markNotViewed(from: [codex, claude, third], named: { names[$0] })
        #expect(back.map(\.conversation) == [claude.conversation, third.conversation])
        #expect(scene.toasts.current(in: scene.window.id)?.message.resolved(in: Locale(identifier: "en"))
            == "Marked as unviewed from T4 of Claude #4, and 1 other conversation from the same point.")
    }

    /// "Mark as Unviewed from Here" on the worktree's timeline, the mirror:
    /// every conversation's line goes back as one mark, the toast names the
    /// row's conversation and counts the others, and its one Undo puts
    /// every line back where it was.
    @Test func unmarkingARowOnTheTimeline_movesEveryLineBackAsOneMark_withOneUndo() throws {
        var codexExtras = Fixture.Extras()
        codexExtras.conversationID = "codex"
        let claude3 = try Fixture.turn("c3", changes: Fixture.changedFiles, number: 3)
        let claude4 = try Fixture.turn("c4", changes: Fixture.changedFiles, number: 4)
        let codex = try Fixture.turn("x1", changes: Fixture.changedFiles, number: 1, extras: codexExtras)
        let scene = Scene(
            conversation: Fixture.conversation,
            history: [Fixture.conversation: [claude3, claude4], codex.conversation: [codex]]
        )
        scene.actions.markViewed(through: [claude4, codex], named: { _ in "Claude #4" })

        let moves = scene.actions.markNotViewed(from: [claude4, codex], named: { _ in "Claude #4" })

        #expect(moves.map(\.conversation) == [claude4.conversation, codex.conversation])
        #expect(Set(moves.map(\.change.markID)).count == 1 && moves.first?.change.markID != nil, "one mark")
        #expect(scene.lines.isViewed(claude3) && !scene.lines.isViewed(claude4) && !scene.lines.isViewed(codex))
        let toast = try #require(scene.toasts.current(in: scene.window.id))
        #expect(toast.message.resolved(in: Locale(identifier: "ja"))
            == "Claude #4 の T4 から未確認にしました。ほかの会話 1 件も同じ時点から未確認にしました。")
        toast.undo?()
        #expect(scene.lines.isViewed(claude4) && scene.lines.isViewed(codex), "both lines back where they were")

        // One line moved: the row offers the way forward again, no toast.
        scene.toasts.dismiss(in: scene.window.id)
        #expect(scene.actions.markNotViewed(from: [claude4], named: { _ in "Claude #4" }).count == 1)
        #expect(scene.toasts.current(in: scene.window.id) == nil)
    }

    @Test func aViewedTurnsRow_movesTheLineBackAboveIt_andTheLineTakesItsLastMoveBack() throws {
        let first = try Fixture.turn("T1", changes: Fixture.changedFiles, number: 1)
        let second = try Fixture.turn("T2", changes: Fixture.changedFiles, number: 2)
        let scene = Scene(conversation: Fixture.conversation, history: [Fixture.conversation: [first, second]])
        let actions = scene.actions
        actions.markViewed(through: second)

        scene.window.decisionBarDone[Self.pane] = .markedViewed(ViewedLineUndo(conversation: Fixture.conversation, changeID: UUID()))
        #expect(actions.markNotViewed(from: second) != nil)
        #expect(scene.lines.isViewed(first))
        #expect(!scene.lines.isViewed(second))
        #expect(scene.toasts.current(in: scene.window.id) == nil, "the earlier move's Undo would do nothing now")
        #expect(scene.window.decisionBarDone[Self.pane] == nil, "nor would the bar's")
        #expect(actions.markNotViewed(from: second) == nil, "already below the line")

        let moved = try #require(actions.markViewed(through: second))
        scene.window.pendingDecisionBarDone[Self.pane] = .markedViewed(ViewedLineUndo(
            conversation: Fixture.conversation,
            changeID: moved.id
        ))
        actions.unmark(ViewedLineUndo(conversation: second.conversation, changeID: moved.id))
        #expect(!scene.lines.isViewed(second))
        #expect(scene.toasts.current(in: scene.window.id) == nil, "the toast for that move goes with it")
        #expect(scene.window.pendingDecisionBarDone[Self.pane] == nil)
    }

    @Test func undoOnTheBar_movesTheLineBack_andTakesTheToastAway() throws {
        let (scene, turn) = try Self.recordedScene()
        scene.actions.markViewed(scene.itemID, inPane: Self.pane)
        guard case let .markedViewed(undo) = scene.window.decisionBarDone[Self.pane] else {
            Issue.record("the bar says Done with Undo")
            return
        }

        scene.actions.takeBack(undo, inPane: Self.pane)

        #expect(!scene.lines.isViewed(turn))
        #expect(scene.window.decisionBarDone[Self.pane] == nil)
        #expect(scene.toasts.current(in: scene.window.id) == nil)
    }

    @Test func undoOnTheToast_movesTheLineBack_andClearsTheBar() throws {
        let (scene, turn) = try Self.recordedScene()
        scene.actions.markViewed(scene.itemID, inPane: Self.pane)

        scene.toasts.undo(in: scene.window.id)

        #expect(!scene.lines.isViewed(turn))
        #expect(scene.window.decisionBarDone[Self.pane] == nil)
    }

    @Test func markingViewed_stopsAtTheLastTurnShown() throws {
        let shown = try Fixture.turn("T1", changes: Fixture.changedFiles, number: 1)
        let unseen = try Fixture.turn("T2", changes: Fixture.changedFiles, number: 2)
        let scene = Scene(conversation: Fixture.conversation, history: [Fixture.conversation: [shown, unseen]])

        scene.actions.markViewed(scene.itemID, through: 1, inPane: Self.pane)

        #expect(scene.lines.isViewed(shown))
        #expect(!scene.lines.isViewed(unseen), "it joined after the bar was read")
    }

    @Test func anUndoLeftOnScreen_doesNothingAfterALaterMark() throws {
        let first = try Fixture.turn("T1", changes: Fixture.changedFiles, number: 1)
        let scene = Scene(conversation: Fixture.conversation, history: [Fixture.conversation: [first]])
        scene.actions.markViewed(scene.itemID, inPane: Self.pane)
        guard case let .markedViewed(stale) = scene.window.decisionBarDone[Self.pane] else {
            Issue.record("the bar says Done with Undo")
            return
        }
        let second = try Fixture.turn("T2", changes: Fixture.changedFiles, number: 2)
        scene.lines.markViewed(through: second, source: .decisionBar)

        scene.actions.takeBack(stale, inPane: Self.pane)

        #expect(scene.lines.isViewed(second), "the later move stays")
    }

    // MARK: - After a restore

    @Test func aRestore_marksTheTurnsItTookBackViewed_andItsUndoPutsTheLineBack() throws {
        let turns = try (1...3).map { try Fixture.turn("T\($0)", changes: Fixture.changedFiles, number: $0) }
        let scene = Scene(conversation: Fixture.conversation, history: [Fixture.conversation: turns])
        scene.lines.markViewed(through: turns[0], source: .decisionBar)

        let moves = scene.actions.markRestored([turns[1], turns[2]])

        #expect(moves.count == 1)
        #expect(scene.lines.isViewed(turns[2]))
        #expect(scene.toasts.current(in: scene.window.id) == nil, "the restore's own toast says what happened")
        scene.actions.takeBackRestored(moves)
        #expect(!scene.lines.isViewed(turns[1]))
        #expect(scene.lines.isViewed(turns[0]))
    }

    /// The line cannot pass an unviewed turn whose changes are still there.
    @Test func aRestore_leavesTheLine_whenAnEarlierTurnIsUnviewed() throws {
        let turns = try (1...3).map { try Fixture.turn("T\($0)", changes: Fixture.changedFiles, number: $0) }
        let scene = Scene(conversation: Fixture.conversation, history: [Fixture.conversation: turns])

        #expect(scene.actions.markRestored([turns[2]]).isEmpty)
        #expect(!scene.lines.isViewed(turns[0]))
    }

    /// A turn that only answered has nothing to read: the line passes it.
    @Test func aRestore_movesTheLinePastAnUnviewedAnswer() throws {
        let answer = try Fixture.turn("T1", number: 1)
        let changed = try Fixture.turn("T2", changes: Fixture.changedFiles, number: 2)
        let scene = Scene(conversation: Fixture.conversation, history: [Fixture.conversation: [answer, changed]])

        #expect(scene.actions.markRestored([changed]).count == 1)
        #expect(scene.lines.isViewed(changed))
    }

    @Test func aRunNoTurnRecordStandsFor_isReadByItsEpisode() {
        let scene = Scene(conversation: nil, history: [:])

        #expect(scene.actions.markViewed(scene.itemID, inPane: Self.pane))

        #expect(scene.attention.allRuntimes.allSatisfy(scene.attention.isViewed))
        #expect(scene.window.decisionBarDone[Self.pane] == nil, "nothing to undo")
        #expect(scene.toasts.current(in: scene.window.id) == nil)
        #expect(!scene.actions.markViewed(scene.itemID, inPane: Self.pane))
    }
}
