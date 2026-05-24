// WindowSession+Scrollback.swift
// Limpid — session-restore plumbing on top of the ghostty fork's
// `ghostty_surface_write_scrollback` / `initial_scrollback_path` C
// API. Quit captures every live surface's scrollback into a `.vt`
// file under Application Support and remembers the path on each Tab;
// restore plumbs the path back through `SurfaceView.initialScrollbackPath`
// so libghostty replays it before the first prompt.
//
// File lifecycle:
//   * Files live under `<LimpidPaths app support>/scrollback/` —
//     `Limpid/scrollback/` for Release, `Limpid Dev/scrollback/` for
//     Debug, `Limpid Tests Stray/scrollback/` under the XCTest host.
//   * One per pane, named `<paneUUID>.vt`.
//   * Captured fresh on every ⌘Q.
//   * Consumed in `PaneHostView.stageScrollback`: the path is moved
//     onto the SurfaceView and immediately cleared from the model so
//     a later split / re-mount can't double-replay.
//   * `pruneScrollbackDir` deletes any file not referenced by a live
//     tab so the directory doesn't grow unboundedly across months.

import Foundation

@MainActor
extension WindowSession {
    /// Iterate every live surface and ask libghostty to dump its
    /// scrollback to disk. Paths are stashed back into each tab so
    /// `makeSnapshot` carries them through JSON persistence. Called
    /// from `applicationWillTerminate`; crashes only retain whatever
    /// was last debounce-saved (which has no scrollback yet).
    func captureScrollbackPaths(from registry: any SurfaceViewProviding) {
        let baseDir = Self.scrollbackDir()
        SecureFileWrite.ensureUserOnlyDirectory(baseDir)
        var liveFiles: Set<String> = []
        for tabIdx in tabs.indices {
            let paneIDs = tabs[tabIdx].splitTree.allLeafIDs()
            var paths: [UUID: String] = [:]
            for pid in paneIDs {
                guard let view = registry.view(for: pid) else { continue }
                let url = baseDir.appendingPathComponent("\(pid.uuidString).vt")
                if view.writeScrollback(to: url.path) {
                    // libghostty writes the `.vt` file directly via
                    // its C API, so it lands with the platform-default
                    // umask permissions (typically 0644). Tighten to
                    // 0600 after the fact — scrollback contents
                    // include any command output the shell printed,
                    // which can carry secrets the user pasted or
                    // env vars that leaked into stdout.
                    SecureFileWrite.tightenPermissions(url)
                    paths[pid] = url.path
                    liveFiles.insert(url.path)
                }
            }
            tabs[tabIdx].scrollbackPaths = paths
        }
        Self.pruneScrollbackDir(keeping: liveFiles)
    }

    /// Remove any `.vt` file in the scrollback dir that no live or
    /// recently-closed tab references. Static so call sites that
    /// already know `liveFiles` can sweep without needing the full
    /// session.
    static func pruneScrollbackDir(keeping live: Set<String>) {
        let baseDir = scrollbackDir()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else { return }
        for url in contents where !live.contains(url.path) {
            try? fm.removeItem(at: url)
        }
    }

    private static func scrollbackDir() -> URL {
        LimpidPaths.applicationSupportDirectory()
            .appendingPathComponent("scrollback", isDirectory: true)
    }
}
