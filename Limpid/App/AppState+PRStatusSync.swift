// AppState+PRStatusSync.swift
// Limpid — starts the pull request lookups and what asks for one as a turn ends.

import Foundation

extension AppState {
    /// The pull request lookups, started, with what looks a row up as a turn
    /// ends in it.
    static func makePRStatusSync(
        session: WorkspaceSession,
        store: PRStatusStore,
        attention: AttentionState
    ) -> (PRStatusSyncer, TurnEndPRRefresh) {
        let syncer = PRStatusSyncer(session: session, store: store, source: prStatusSource)
        syncer.start()
        let refresh = TurnEndPRRefresh(attention: attention, session: session) { [weak syncer] in
            syncer?.turnEnded(in: $0)
        }
        return (syncer, refresh)
    }
}
