// WorkspaceSession+Scrollback.swift
// Weir — session-restore plumbing on top of the ghostty fork's
// `ghostty_surface_write_scrollback` / `initial_scrollback_path` C
// API. Quit captures every live surface's scrollback into a `.vt`
// file under Application Support and remembers the path on each Tab;
// restore plumbs the path back through `SurfaceView.initialScrollbackPath`
// so libghostty replays it before the first prompt.
//
// File lifecycle:
//   * Files live in the folder the app hands the session
//     (`scrollbackFiles`): `<WeirPaths app support>/scrollback/`.
//   * One per pane, named `<paneUUID>.vt` (`ScrollbackFiles`).
//   * Captured fresh on every ⌘Q.
//   * Consumed in `PaneHostView.stageScrollback`: the path is moved
//     onto the SurfaceView and immediately cleared from the model so
//     a later split / re-mount can't double-replay.
//   * `ScrollbackFiles.prune` deletes any file not referenced by a live
//     tab so the directory doesn't grow unboundedly across months.

import Foundation

@MainActor
extension WorkspaceSession {
    /// Iterate every live surface and ask libghostty to dump its
    /// scrollback to disk. Paths are stashed back into each tab so
    /// `makeSnapshot` carries them through JSON persistence. Called
    /// from `applicationWillTerminate`; crashes only retain whatever
    /// was last debounce-saved (which has no scrollback yet).
    func captureScrollbackPaths(from writer: any ScrollbackWriting) {
        // A demo run's panes are not the person's: writing their scrollback
        // would leave strays, and the prune below would delete the files
        // the person's own state.json points at. A session handed no folder
        // saves none.
        guard writesUserFiles, let files = scrollbackFiles else { return }
        var liveFiles: Set<String> = []
        for tabIdx in tabs.indices {
            let paneIDs = tabs[tabIdx].splitTree.allLeafIDs()
            // Walk each live pane and overwrite its slot only when we
            // got a fresh dump. Leaves whose terminal was never
            // mounted this run (a restored tab the user never clicked
            // into) keep their previously-persisted path — wiping the
            // map would also drop the .vt file via the prune,
            // taking real scrollback with it.
            for pid in paneIDs {
                if let url = files.capture(pid, with: writer) {
                    tabs[tabIdx].scrollbackPaths[pid] = url.path
                    liveFiles.insert(url.path)
                } else if let preserved = tabs[tabIdx].scrollbackPaths[pid] {
                    // Surface not mounted this run — keep the inherited
                    // path alive so prune leaves the on-disk file alone.
                    liveFiles.insert(preserved)
                }
            }
            // Drop entries for leaves the tab no longer contains so
            // stale uuids don't pile up across edits.
            let liveSet = Set(paneIDs)
            tabs[tabIdx].scrollbackPaths = tabs[tabIdx].scrollbackPaths.filter { liveSet.contains($0.key) }
        }
        // Keep `.vt` files referenced by the reopen-closed-tab stack
        // too — they're about to be replayed when the user hits ⌘⇧T.
        for closed in closedTabStack {
            for path in closed.tab.scrollbackPaths.values {
                liveFiles.insert(path)
            }
        }
        files.prune(keeping: liveFiles)
    }
}
