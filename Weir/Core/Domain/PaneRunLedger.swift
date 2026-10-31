// PaneRunLedger.swift
// Weir — which agent runs each pane shows and the turn each is in, so a "Done" line ends as they move on.

import Foundation

/// The runs and the panes they show, kept from one pass of the runtimes to
/// the next. A decision bar's "Done" line says what was true just
/// after the person acted: once a turn starts in its pane, or the agent
/// leaves it, "Press Return to send" or "Answered in the terminal"
/// describes what is already past. This tells which panes that happened
/// in, and gives each pane an epoch (`epoch(inPane:)`) so a bar can tell
/// whether its pane moved on since it showed an item.
///
/// Kept by run rather than by pane, so a run whose panes are not known for
/// a moment (a tmux client between attachments), or whose pane moves to
/// another tab, is the same run in the same panes, and its line does not
/// end for that.
package struct PaneRunLedger: Equatable, Sendable {

    package init() {}
    /// A runtime as the ledger sees it.
    package struct Run: Equatable, Sendable {
        package let runtimeID: String
        package let paneIDs: Set<UUID>
        package let state: AgentState
        /// The turn the run is in, or ended last; `nil` before its first.
        package let turnID: TurnID?

        package init(
            runtimeID: String,
            paneIDs: Set<UUID>,
            state: AgentState,
            turnID: TurnID?
        ) {
            self.runtimeID = runtimeID
            self.paneIDs = paneIDs
            self.state = state
            self.turnID = turnID
        }
    }

    /// Where a run was last seen.
    private struct Place: Equatable, Sendable {
        package var turnID: TurnID?
        package var paneIDs: Set<UUID>
        /// Whether the run rests in error (`StopFailure`: a usage limit, an
        /// API error). The agent is still in its pane and can go on in the
        /// same run, but it may also have exited, its record left in error
        /// until the conversation is back in a new run. So a stopped
        /// run going away says nothing, while its next turn still does.
        ///
        /// What we cannot tell here, the stop ledger tells: a new run of
        /// another conversation in the pane ends the stop as the person
        /// moving on (`StopLedger.hasMovedOn`), and `note` takes those
        /// panes as moved on too. A line set while stopped (a restore's,
        /// say) ends then, not at the new conversation's first turn.
        package var isStopped: Bool

        package init(
            turnID: TurnID? = nil,
            paneIDs: Set<UUID>,
            isStopped: Bool
        ) {
            self.turnID = turnID
            self.paneIDs = paneIDs
            self.isStopped = isStopped
        }
    }

    private var places: [String: Place] = [:]
    /// Each pane's epoch, for the panes a run is in: a number no other
    /// stretch of any pane has had, taken anew each time the pane moves on.
    private var epochs: [UUID: Int] = [:]
    private var nextEpoch = 0

    /// Notes this pass's runs and returns the panes the runs moved on in
    /// since the last: a turn began there, or the agent left (it ended,
    /// stopped, is no longer listed, or now shows in other panes only). A
    /// run arriving in a pane is not listed: nothing said there was about
    /// it. Nor is a stopped run going away: the stop's conversation may be
    /// back in a new run, under a line that says so. `movedOnFromStops`
    /// are the panes whose stop ended as the person moved on to another
    /// conversation there (`StopLedger.Ended.movedOn`), which a run
    /// arriving alone does not say.
    package mutating func note(_ runs: [Run], movedOnFromStops: Set<UUID> = []) -> Set<UUID> {
        var next: [String: Place] = [:]
        var movedOn = movedOnFromStops
        // An unknown state is a session that ended (`SessionEnd`), as the
        // pane header reads it: the run is gone.
        for run in runs where run.state != .unknown {
            let previous = places[run.runtimeID]
            // A run that names no pane now is in the panes it was in.
            let paneIDs = run.paneIDs.isEmpty ? previous?.paneIDs ?? [] : run.paneIDs
            let isStopped = run.state == .error
            if let previous {
                if previous.turnID != run.turnID {
                    movedOn.formUnion(previous.paneIDs)
                    movedOn.formUnion(paneIDs)
                }
                if isStopped, !previous.isStopped {
                    movedOn.formUnion(previous.paneIDs)
                }
                movedOn.formUnion(previous.paneIDs.subtracting(paneIDs))
            }
            next[run.runtimeID] = Place(turnID: run.turnID, paneIDs: paneIDs, isStopped: isStopped)
        }
        for (runtimeID, place) in places where next[runtimeID] == nil && !place.isStopped {
            movedOn.formUnion(place.paneIDs)
        }
        places = next
        // A pane a run arrives in starts a stretch too, so a count taken
        // before its last run left never matches the one after.
        var nextEpochs: [UUID: Int] = [:]
        // In no particular order: an epoch is only ever compared for being
        // the same, so which pane takes which number does not matter.
        for paneID in Set(next.values.flatMap(\.paneIDs)) {
            if let epoch = epochs[paneID], !movedOn.contains(paneID) {
                nextEpochs[paneID] = epoch
            } else {
                nextEpochs[paneID] = nextEpoch
                nextEpoch += 1
            }
        }
        epochs = nextEpochs
        return movedOn
    }

    /// The stretch `paneID` is in, while a run is in it; `nil` once none
    /// is. Compared with the epoch taken as an item was shown, it tells
    /// whether the item left with the turn or the agent rather than being
    /// answered: a different epoch, or none, means the pane moved on.
    package func epoch(inPane paneID: UUID) -> Int? {
        epochs[paneID]
    }
}
