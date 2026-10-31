// AttentionQueueFixture.swift
// Weir — the Needs Attention list with one stopped agent, going to items as the app does.

import Foundation
@testable import Weir
@testable import WeirDomain

@MainActor
enum AttentionQueueFixture {
    /// Makes the Needs Attention list with one stopped agent in `tab` of the
    /// project `projectID`, going to items as the app does
    /// (`SessionAttentionNavigator`), the review put behind the pane gone
    /// to.
    ///
    /// We return the navigator beside the list because the list holds it
    /// weakly: the caller keeps both for as long as it goes to items.
    static func stopped(
        in tab: Tab,
        projectID: UUID,
        session: WorkspaceSession,
        registry: WindowRegistry
    ) -> (store: AttentionQueueStore, navigator: SessionAttentionNavigator) {
        let store = AttentionQueueStore()
        let navigator = SessionAttentionNavigator(session: session, registry: registry)
        store.navigator = navigator
        store.apply(.init(runtimes: [
            RuntimeFact(
                runtimeID: "stopped", provider: .claude, paneIDs: tab.splitTree.allLeafIDs(), tabID: tab.id,
                projectID: projectID, state: .error, updatedAt: Date(), episodeToken: "1", isEpisodeRead: false, detail: nil
            )
        ]), announces: false)
        return (store, navigator)
    }
}
