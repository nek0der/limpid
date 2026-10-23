// TurnReadRules.swift
// Limpid — which ended turns the person has read by having their pane in sight.

import Foundation

/// What `TurnReadRules` needs of a runtime: which run it is, where it
/// shows, which conversation it numbers turns in, and its current turn.
struct TurnReadRuntime: Equatable, Sendable {
    /// The run's ID, as each of its turns names it (`TurnSummary.runID`).
    let runID: String
    /// The panes that would show the run if they were on screen; a tmux
    /// pane that is not its window's active one is left out, since it does
    /// not show the agent. The rules meet these with the panes seen.
    let activeAttachmentPaneIDs: Set<UUID>
    let conversation: ConversationKey?
    let currentTurnID: TurnID?
    let isFinished: Bool
}

/// The read rule for turns that changed no files: a turn that
/// answered without changing files, or whose changes could not be taken, is
/// read once its pane is in sight, whether it ended there or the pane came
/// into sight afterwards. A turn that changed files is read only when the
/// viewed line passes it, which these rules never decide; so is one whose
/// changes this build cannot read (`unknown`), which may have changed files.
/// An end-only record nobody prompted is never unread at all.
enum TurnReadRules {
    /// The turns that are read: those a pane in sight shows that changed no
    /// files, and every ended turn nobody prompted, wherever it is.
    static func turnsRead(
        inSight seenPaneIDs: Set<UUID>,
        runtimes: [TurnReadRuntime],
        history: [ConversationKey: [TurnSummary]]
    ) -> Set<TurnID> {
        var seenWhilePending: Set<TurnID> = []
        return turnsRead(inSight: seenPaneIDs, runtimes: runtimes, history: history, seenWhilePending: &seenWhilePending)
    }

    /// The same, remembering in `seenWhilePending` the ended turns that were
    /// in sight while their changes were still being taken. A turn that
    /// ended in sight is read as if its pane were opened, but its
    /// end snapshot can take seconds; the person may have looked away by
    /// the time it settles. One that settles as no change is read then; one
    /// that settles as a change waits for the viewed line, as any change.
    static func turnsRead(
        inSight seenPaneIDs: Set<UUID>,
        runtimes: [TurnReadRuntime],
        history: [ConversationKey: [TurnSummary]],
        seenWhilePending: inout Set<TurnID>
    ) -> Set<TurnID> {
        var read: Set<TurnID> = []
        for turns in history.values {
            for turn in turns where turn.phase != .started && !turn.hasPrompt {
                read.insert(turn.turnID)
            }
        }
        let inSight = runtimes.filter { !$0.activeAttachmentPaneIDs.isDisjoint(with: seenPaneIDs) }
        // A conversation can run in two panes at once (resumed in a second
        // one). A turn shows in its own run's pane: one of a run out of sight
        // is not read because another run of its conversation is in sight.
        // A turn whose run is gone shows in whichever pane resumed the
        // conversation.
        let liveRuns = Set(runtimes.map(\.runID))
        let runsInSight = Set(inSight.map(\.runID))
        for conversation in Set(inSight.compactMap(\.conversation)) {
            for turn in history[conversation] ?? [] where runsInSight.contains(turn.runID) || !liveRuns.contains(turn.runID) {
                if isReadBySight(turn) {
                    read.insert(turn.turnID)
                } else if turn.phase != .started, turn.changes == .pending {
                    seenWhilePending.insert(turn.turnID)
                }
            }
        }
        guard !seenWhilePending.isEmpty else { return read }
        // Settled since, or gone: either way nothing is left to wait for.
        var stillPending: Set<TurnID> = []
        for turns in history.values {
            for turn in turns where seenWhilePending.contains(turn.turnID) {
                if turn.changes == .pending {
                    stillPending.insert(turn.turnID)
                } else if isReadBySight(turn) {
                    read.insert(turn.turnID)
                }
            }
        }
        seenWhilePending = stillPending
        return read
    }

    /// Whether a turn is read by its pane being in sight: it has ended and
    /// it did not change files, as far as anyone can tell. A turn still
    /// running is not; nor is one whose changes are still being taken.
    static func isReadBySight(_ turn: TurnSummary) -> Bool {
        turn.phase != .started && !turn.changes.mayHaveChangedFiles
    }

    /// The turns a finished run's episode stands for: every ended turn
    /// someone prompted in the run's conversation. A later turn that only
    /// answered does not hide an earlier one that changed files and is still
    /// below the viewed line, and a stop nobody prompted (an answer to a
    /// background task) extends the turns before it rather than standing
    /// for them. The run's current turn stands in only when nobody prompted
    /// any. `nil` for a run still working, before the history has the
    /// conversation, and when no ended turn stands for the episode.
    static func episodeTurns(of runtime: TurnReadRuntime, history: [ConversationKey: [TurnSummary]]) -> [TurnSummary]? {
        guard runtime.isFinished,
              let conversation = runtime.conversation,
              let turns = history[conversation]
        else { return nil }
        let prompted = turns.filter { $0.hasPrompt && $0.phase != .started }
        if !prompted.isEmpty {
            return prompted
        }
        return turns.last { $0.turnID == runtime.currentTurnID && $0.phase != .started }.map { [$0] }
    }

    /// Whether a finished run's episode is read, as its turns decide
    /// (`isRead`: the turn read store, or the viewed line): only once every
    /// one of them is. `nil` when no turn stands for the episode, and the
    /// episode's own viewed mark decides as it always has.
    static func isEpisodeRead(
        _ runtime: TurnReadRuntime,
        history: [ConversationKey: [TurnSummary]],
        isRead: (TurnSummary) -> Bool
    ) -> Bool? {
        episodeTurns(of: runtime, history: history).map { $0.allSatisfy(isRead) }
    }
}
