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
}
