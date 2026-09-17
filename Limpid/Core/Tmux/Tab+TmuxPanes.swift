// Tab+TmuxPanes.swift
// Limpid — which leaf of a mirror tab shows which tmux pane.

import Foundation

extension Tab {
    /// The leaf showing each pane of tmux window `windowID`, keyed by tmux
    /// pane id. The one place this map is built: the mirror attaches,
    /// folds layouts, and follows the active and zoomed pane with it, and
    /// the pane area places tmux's layout with it, so all of them agree on
    /// which leaves belong to the window. A leaf of another window, which a
    /// tab never holds once its layout has been folded, is left out.
    func tmuxLeafIDs(inWindow windowID: String) -> [String: UUID] {
        var leafIDs: [String: UUID] = [:]
        for (leafID, source) in paneSources {
            if case let .tmux(ref) = source, ref.windowID == windowID {
                leafIDs[ref.paneID] = leafID
            }
        }
        return leafIDs
    }

    /// The leaf showing each tmux pane this tab mirrors, keyed by the pane's
    /// canonical endpoint so a run's record finds it whichever spelling of
    /// the socket either side holds.
    ///
    /// A leaf whose binding does not name its server run is left out: pane
    /// ids restart from zero with the server, so without the run a record of
    /// an earlier server could land on an unrelated pane.
    func mirroredEndpoints(aliases: [String: String]) -> [TmuxRuntimeEndpoint: UUID] {
        var leaves: [TmuxRuntimeEndpoint: UUID] = [:]
        for (leafID, source) in paneSources {
            guard case let .tmux(ref) = source,
                  let server = TmuxServerGeneration.recorded(in: ref.binding)
            else { continue }
            let endpoint = TmuxRuntimeEndpoint(
                socketPath: ref.binding.socketPath,
                serverPID: server.pid,
                serverStartedAt: server.startedAt,
                paneID: ref.paneID
            )
            leaves[endpoint.canonical(aliases: aliases)] = leafID
        }
        return leaves
    }
}
