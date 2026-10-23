// TurnGarbageCollectorTests.swift
// Limpid — deleting the turns the sweep chose, through the Rust bridge, off the main actor.

import Foundation
import Testing
@testable import Limpid

@Suite("Turn garbage collector")
struct TurnGarbageCollectorTests {
    /// What becomes of each turn is the bridge's own rule
    /// (`each_turn_reports_what_became_of_it`); here, that its answer
    /// reaches Swift, read turn by turn.
    @Test func theBridgesAnswer_isReadTurnByTurn() throws {
        try withTempDir { directory in
            let missing = UUID().uuidString
            let deletions = try LimpidTurnBridge.deleteTurns([missing], in: directory)

            #expect(deletions.map(\.turnID) == [missing])
            #expect(deletions.map(\.outcome) == [.alreadyGone])
        }
    }

    @Test func aBatchTheBridgeRefuses_isOnlyLogged() async {
        struct Refused: Error {}
        let collector = TurnGarbageCollector { _, _ in throw Refused() }

        let deletions = await collector.delete(["A"], in: URL(fileURLWithPath: "/nonexistent"))

        #expect(deletions.isEmpty, "the records stay, and the next sweep chooses them again")
    }

    @Test func aBatch_reachesTheBridgeWithItsDirectory() async {
        let asked = Recorded<[(ids: [String], directory: URL)]>([])
        let collector = TurnGarbageCollector { ids, directory in
            asked.update { $0.append((ids, directory)) }
            return ids.map { TurnDeletion(outcome: .deleted, turnID: $0, reason: nil, roots: nil) }
        }
        let directory = URL(fileURLWithPath: "/states/claude/turns")

        let deletions = await collector.delete(["A", "B"], in: directory)

        #expect(deletions.map(\.outcome) == [.deleted, .deleted])
        #expect(asked.value.map(\.ids) == [["A", "B"]])
        #expect(asked.value.map(\.directory) == [directory])
    }

    @Test func aQueuedBatch_reachesTheBridge_andAnEmptyOneToo() async {
        let asked = Recorded<[(ids: [String], directory: URL)]>([])
        let collector = TurnGarbageCollector { ids, directory in
            asked.update { $0.append((ids, directory)) }
            return []
        }

        // An empty batch finishes the deletions a quit cut short.
        collector.enqueue([], in: URL(fileURLWithPath: "/states/claude/turns"))
        collector.enqueue(["A"], in: URL(fileURLWithPath: "/states/claude/turns"))

        await pollUntil { asked.value.count == 2 }
        #expect(Set(asked.value.map(\.ids)) == [[], ["A"]])
    }

    @Test func anOutcomeANewerBridgeAdded_doesNotFailTheBatch() throws {
        let data = Data(#"[{"outcome":"somethingNewer","turnId":"A"},{"outcome":"deleted","turnId":"B"}]"#.utf8)
        let deletions = try JSONDecoder().decode([TurnDeletion].self, from: data)
        #expect(deletions.map(\.outcome) == [.unknown, .deleted])
    }
}
