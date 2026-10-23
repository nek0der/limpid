// TurnGarbageCollector.swift
// Limpid — deletes the turns the retention sweep chose, off the main actor and one batch at a time.

import Foundation
import OSLog

private let log = Logger.limpid("turn.gc")

/// Runs the projection's `deleteTurn` commands: each turn's record
/// and the refs that pin its snapshots go together, in Rust
/// (`LimpidTurnBridge`).
///
/// An actor, so two batches never work on one directory at once, and one
/// that runs on its own background queue rather than the shared pool: the
/// bridge runs
/// git synchronously, once per repository a turn names, and a blocked pool
/// thread would stall unrelated tasks. A batch that fails is only logged.
/// The records it left are still there, so the next sweep chooses them
/// again.
actor TurnGarbageCollector {
    typealias Apply = @Sendable ([String], URL) throws -> [TurnDeletion]

    private let apply: Apply
    private let queue = DispatchSerialQueue(label: "dev.limpid.turn-gc", qos: .background)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(apply: @escaping Apply = { try LimpidTurnBridge.deleteTurns($0, in: $1) }) {
        self.apply = apply
    }

    /// Deletes `turnIDs` from the turns directory `directory` and answers
    /// what became of each; none when the bridge refused the call.
    @discardableResult
    func delete(_ turnIDs: [String], in directory: URL) -> [TurnDeletion] {
        do {
            let deletions = try apply(turnIDs, directory)
            for deletion in deletions {
                switch deletion.outcome {
                // A restore of the worktree is under way: the next sweep
                // deletes the turn.
                case .failed where deletion.reason == "restoreInProgress":
                    log.info("turn \(deletion.turnID, privacy: .public) left for the next sweep: a restore is under way")
                case .failed:
                    log.error("""
                    turn \(deletion.turnID, privacy: .public) not deleted: \
                    \(deletion.reason ?? "", privacy: .private)
                    """)
                case .deletedLeavingRefs:
                    log.info("""
                    turn \(deletion.turnID, privacy: .public) deleted; refs may remain in \
                    \(deletion.roots?.joined(separator: ", ") ?? "", privacy: .private)
                    """)
                case .deleted, .alreadyGone, .unreadable, .unknown:
                    continue
                }
            }
            return deletions
        } catch {
            log.error("turn deletion failed: \(String(describing: error), privacy: .private)")
            return []
        }
    }

    /// From the main actor: the batch is queued and this returns at once;
    /// `finished` hears what became of each turn, on the main actor,
    /// including the turns of deletions a quit cut short, which every
    /// batch finishes first. An empty batch only finishes those.
    nonisolated func enqueue(
        _ turnIDs: [String],
        in directory: URL,
        finished: @escaping @MainActor @Sendable ([TurnDeletion]) -> Void = { _ in }
    ) {
        Task(priority: .background) {
            let deletions = await delete(turnIDs, in: directory)
            await finished(deletions)
        }
    }
}
