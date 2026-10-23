// AttentionCursorTests.swift
// Limpid — where ⌘J goes next: this window's project first, in arrival order, then the others.

import Foundation
import Testing
@testable import Limpid

struct AttentionCursorTests {
    private static let here = UUID()
    private static let there = UUID()
    private static let third = UUID()

    /// A list of stops, one per name, in the project given for each. A name
    /// starting with "u" is a request no pane is known for.
    private static func queue(_ entries: [(String, UUID?)]) -> AttentionQueue {
        var queue = AttentionQueue()
        for (offset, (name, project)) in entries.enumerated() {
            queue.insert(
                id: id(name),
                kind: .stop(.error(nil)),
                subject: name.hasPrefix("u")
                    ? .unplaced(provider: .claude)
                    : .runtime(id: name, provider: .claude, paneID: UUID(), tabID: nil, projectID: project),
                arrivedAt: Date(timeIntervalSince1970: TimeInterval(offset))
            )
        }
        return queue
    }

    private static func id(_ name: String) -> AttentionItemID {
        .stop(EpisodeKey(origin: .runtime(name), episodeToken: "1"))
    }

    private static func ids(_ names: String...) -> [AttentionItemID?] {
        names.map(id)
    }

    /// Presses ⌘J (or ⇧⌘J) `count` times. The window follows the walk as
    /// the app does: opening an item's pane shows its project, while a
    /// request with no pane opens its card and leaves the window where it
    /// was.
    private static func walk(
        _ queue: AttentionQueue,
        from start: (state: AttentionCursorState, project: UUID?) = (AttentionCursorState(), here),
        forward: Bool = true,
        count: Int
    ) -> Walk {
        var state = start.state
        var project = start.project
        var landed: [AttentionItemID?] = []
        for _ in 0..<count {
            let (next, id) = AttentionCursor.step(state, queue: queue, currentProjectID: project, forward: forward)
            state = next
            landed.append(id)
            if let item = queue.items.first(where: { $0.id == id }), case .runtime = item.subject {
                project = item.subject.projectID
            }
            // As the store does once the move is done.
            state.windowGroup = AttentionCursorGroup(project)
        }
        return Walk(landed: landed, state: state, project: project)
    }

    /// Where each press landed, and the cursor and window afterwards.
    private struct Walk {
        let landed: [AttentionItemID?]
        let state: AttentionCursorState
        let project: UUID?
    }

    @Test func anEmptyList_goesNowhere() {
        #expect(Self.walk(AttentionQueue(), count: 1).landed == [nil])
    }

    @Test func thisProject_comesFirst_inArrivalOrder() {
        let queue = Self.queue([("a", Self.there), ("b", Self.here), ("c", Self.here)])
        #expect(Self.walk(queue, count: 3).landed == Self.ids("b", "c", "a"))
    }

    @Test func theWalk_goesThroughEveryProject_inTheOrderTheyFirstArrived() {
        let queue = Self.queue([("a", Self.here), ("x", Self.there), ("y", Self.third), ("b", Self.here)])
        #expect(Self.walk(queue, count: 5).landed == Self.ids("a", "b", "x", "y", "a"))
    }

    @Test func aRequestWithNoPane_isAStopOnTheWay_notADeadEnd() {
        // Its card opens and the window stays; the walk still moves on.
        let queue = Self.queue([("a", Self.here), ("u1", nil), ("x", Self.there)])
        #expect(Self.walk(queue, count: 4).landed == Self.ids("a", "u1", "x", "a"))
    }

    @Test func withNoOtherProject_theRoundStartsOver() {
        let queue = Self.queue([("a", Self.here), ("b", Self.here)])
        #expect(Self.walk(queue, count: 5).landed == Self.ids("a", "b", "a", "b", "a"))
    }

    @Test func aRoundStartedFromTheList_wrapsWithinTheProject() {
        // The person opened "b" from the list; ⌘J continues from there and
        // wraps to "a" before leaving the project.
        let queue = Self.queue([("a", Self.here), ("b", Self.here), ("c", Self.here), ("x", Self.there)])
        var chosen = AttentionCursor.land(AttentionCursorState(), on: queue.items[1], currentProjectID: Self.here)
        chosen.windowGroup = AttentionCursorGroup(Self.here)
        let landed = Self.walk(queue, from: (chosen, Self.here), count: 3).landed
        #expect(landed == Self.ids("c", "a", "x"))
    }

    /// Turning round goes back to the item ⌘J just left, rather than past
    /// every item the walk has visited.
    @Test func turningRound_stepsBackToTheItemJustLeft_thenGoesOn() {
        let queue = Self.queue([("a", Self.here), ("b", Self.here), ("c", Self.here), ("d", Self.here)])
        let forward = Self.walk(queue, count: 2)
        #expect(forward.landed == Self.ids("a", "b"))
        let back = Self.walk(queue, from: (forward.state, forward.project), forward: false, count: 2)
        #expect(back.landed == Self.ids("a", "d"))
        // And round again: ⌘J goes back to the one ⇧⌘J left.
        #expect(Self.walk(queue, from: (back.state, back.project), count: 1).landed == Self.ids("a"))
    }

    @Test func anItemArrivingMidRound_isVisitedInItsTurn() {
        let before = Self.queue([("a", Self.here), ("b", Self.here)])
        let walked = Self.walk(before, count: 2)
        let after = Self.queue([("a", Self.here), ("b", Self.here), ("c", Self.here), ("x", Self.there)])

        // "a" and "b" stay visited, so the round ends after "c".
        let landed = Self.walk(after, from: (walked.state, walked.project), count: 2).landed
        #expect(landed == Self.ids("c", "x"))
    }

    @Test func anItemLeavingAsItIsRead_doesNotRestartTheRound() {
        // An unread turn leaves the list once its pane is seen.
        let full = Self.queue([("s", Self.here), ("t", Self.here), ("x", Self.there)])
        let walked = Self.walk(full, count: 2)
        var read = full
        read.remove(Self.id("t"))

        #expect(Self.walk(read, from: (walked.state, walked.project), count: 1).landed == Self.ids("x"))
    }

    @Test func theCurrentItemLeaving_continuesFromItsPlace() {
        let full = Self.queue([("a", Self.here), ("b", Self.here), ("c", Self.here)])
        let walked = Self.walk(full, count: 2)
        #expect(walked.state.current == Self.id("b"))

        var shorter = full
        shorter.remove(Self.id("b"))
        #expect(Self.walk(shorter, from: (walked.state, walked.project), count: 1).landed == Self.ids("c"))
    }

    @Test func switchingProjectsByHand_startsThatProjectFromItsHead() {
        let queue = Self.queue([("a", Self.here), ("x", Self.there), ("y", Self.there)])
        let walked = Self.walk(queue, count: 1)

        // The person opens the other project themselves.
        #expect(Self.walk(queue, from: (walked.state, Self.there), count: 1).landed == Self.ids("x"))
    }

    @Test func goingBackByHand_afterTheWalkMovedOn_startsFromThatProject() {
        let queue = Self.queue([("a", Self.here), ("b", Self.here), ("x", Self.there), ("y", Self.there)])
        let walked = Self.walk(queue, count: 3)
        #expect(walked.landed == Self.ids("a", "b", "x"))

        // The person goes back to "here" themselves: ⌘J starts there again
        // instead of pulling the window back to "there".
        #expect(Self.walk(queue, from: (walked.state, Self.here), count: 1).landed == Self.ids("a"))
    }

    @Test func backward_walksTheSameRuleInReverse() {
        let mixed = Self.queue([("a", Self.here), ("b", Self.there), ("c", Self.here)])
        #expect(Self.walk(mixed, forward: false, count: 3).landed == Self.ids("c", "a", "b"))
        // The projects' order comes from their first items either way, so
        // ⇧⌘J visits them in the reverse of ⌘J.
        let queue = Self.queue([("a", Self.here), ("x", Self.there), ("y", Self.third), ("b", Self.there)])
        #expect(Self.walk(queue, forward: false, count: 4).landed == Self.ids("a", "y", "b", "x"))
    }

    @Test func itemsInNoProject_areAGroupOfTheirOwn() {
        let queue = Self.queue([("scratch", nil), ("a", Self.here)])
        #expect(Self.walk(queue, from: (AttentionCursorState(), nil), count: 2).landed == Self.ids("scratch", "a"))
    }
}
