// TmuxMirrorActions.swift
// Limpid — opens a tab that mirrors one tmux window.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.mirror")

@MainActor
enum TmuxMirrorActions {
    /// Open `target` as a new tab in the active scope. The tab starts with
    /// the window's active pane; the first `%layout-change` after
    /// `refresh-client -C` fills in the others.
    ///
    /// The tab is written before the connection is taken: every write to
    /// `session.tabs` has the store release connections no mirror uses,
    /// and the mirror can only be registered once its tab id exists. A
    /// server that refuses us leaves a mirror tab with a dormant pane,
    /// which is the state a lost connection produces too.
    @discardableResult
    static func open(
        _ target: TmuxMirrorTarget,
        session: WindowSession,
        store: TmuxConnectionStore,
        registry: any SurfaceViewProviding,
        secureInput: SecureInputManager?
    ) -> Bool {
        let tab = session.openTabInActiveScope()
        guard let paneID = tab.splitTree.allLeafIDs().first else { return false }
        let ref = TmuxPaneRef(binding: target.binding, windowID: target.windowID, paneID: target.activePaneID)
        session.update(tab.id) { t in
            t.kind = .tmuxMirror
            t.title = target.displayName
            t.paneSources[paneID] = .tmux(ref)
        }
        let connection: TmuxServerConnection
        do {
            connection = try store.connection(for: target.binding)
        } catch {
            log.error("cannot mirror \(target.displayName, privacy: .private): \(String(describing: error), privacy: .public)")
            return false
        }
        let mirror = TmuxWindowMirror(
            tabID: tab.id,
            windowID: target.windowID,
            connection: connection,
            session: session,
            registry: registry,
            secureInput: secureInput
        )
        store.register(mirror)
        mirror.start()
        return true
    }
}
