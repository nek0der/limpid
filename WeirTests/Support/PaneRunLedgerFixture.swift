// PaneRunLedgerFixture.swift
// Weir — one builder for the runs a pane's run ledger is handed.

import Foundation
@testable import Weir

extension PaneRunLedger.Run {
    /// Run `id` in `panes`, in `turn`, `state` (finished unless a test says).
    static func test(_ id: String, in panes: Set<UUID>, turn: String?, state: AgentState = .finished) -> PaneRunLedger.Run {
        PaneRunLedger.Run(runtimeID: id, paneIDs: panes, state: state, turnID: turn.map(TurnID.init))
    }
}
