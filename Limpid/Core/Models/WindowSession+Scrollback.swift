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
import OSLog

private let scrollbackLog = Logger.limpid("scrollback")

@MainActor
extension WindowSession {
    /// Iterate every live surface and ask libghostty to dump its
    /// scrollback to disk. Paths are stashed back into each tab so
    /// `makeSnapshot` carries them through JSON persistence. Called
    /// from `applicationWillTerminate`; crashes only retain whatever
    /// was last debounce-saved (which has no scrollback yet).
    func captureScrollbackPaths(from registry: any SurfaceViewProviding) {
        var liveFiles: Set<String> = []
        for tabIdx in tabs.indices {
            let paneIDs = tabs[tabIdx].splitTree.allLeafIDs()
            // Walk each live pane and overwrite its slot only when we
            // got a fresh dump. Leaves whose `SurfaceView` was never
            // mounted this run (a restored tab the user never clicked
            // into) keep their previously-persisted path — wiping the
            // map would also drop the .vt file via `pruneScrollbackDir`,
            // taking real scrollback with it.
            for pid in paneIDs {
                if let view = registry.view(for: pid),
                   let url = Self.captureScrollback(paneID: pid, view: view)
                {
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
        Self.pruneScrollbackDir(keeping: liveFiles)
    }

    /// Write one pane's scrollback to `<scrollbackDir>/<paneID>.vt`
    /// and return the path, or nil if libghostty refused (surface
    /// already gone). Centralises filename convention, directory
    /// creation, and permission tightening so ⌘Q capture and per-tab
    /// close-time capture stay in lock-step.
    static func captureScrollback(paneID: UUID, view: SurfaceView) -> URL? {
        let baseDir = scrollbackDir()
        SecureFileWrite.ensureUserOnlyDirectory(baseDir)
        let url = baseDir.appendingPathComponent("\(paneID.uuidString).vt")
        guard view.writeScrollback(to: url.path) else { return nil }
        // libghostty writes the `.vt` directly via its C API, so it
        // lands with the platform-default umask (typically 0644).
        // Tighten to 0600 — scrollback can carry secrets the user
        // pasted or env vars that leaked into stdout.
        SecureFileWrite.tightenPermissions(url)
        return url
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

    static func scrollbackDir() -> URL {
        LimpidPaths.applicationSupportDirectory()
            .appendingPathComponent("scrollback", isDirectory: true)
    }

    /// Returns `path` only when it is a `.vt` file under `scrollbackDir()` —
    /// one we actually wrote. `scrollbackPaths` is restored from state.json,
    /// which a tampered or hand-edited file could point at an arbitrary path
    /// (e.g. `~/.ssh/id_rsa`); libghostty would then read and replay that file
    /// into the terminal, where OSC 52 could exfiltrate it. Reject anything
    /// outside the sandbox.
    static func validatedScrollbackPath(_ path: String) -> String? {
        // `standardizedFileURL` strips `.` / `..` and the `/private`
        // alias but does NOT resolve symlinks — that requires
        // `resolvingSymlinksInPath()`. Without it, an attacker with
        // same-UID write access to `scrollbackDir()` can plant
        // `leak.vt -> ~/.ssh/id_rsa` and pair it with a tampered
        // `state.json`; libghostty would replay the target file via
        // `open(2)` (no `O_NOFOLLOW`) and OSC 52 could exfiltrate it.
        // Resolve symlinks on both sides, then require the resolved
        // path is under the sandbox AND the leaf itself is not a
        // symbolic link.
        let url = URL(fileURLWithPath: path)
        let resolved = url.resolvingSymlinksInPath()
        var base = scrollbackDir().resolvingSymlinksInPath().path
        if !base.hasSuffix("/") { base += "/" }
        guard resolved.pathExtension == "vt", resolved.path.hasPrefix(base) else {
            scrollbackLog.warning("rejected out-of-sandbox scrollback path on restore")
            return nil
        }
        let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        if isSymlink {
            scrollbackLog.warning("rejected symlinked scrollback path on restore")
            return nil
        }
        // Pass the resolved (canonical) path downstream so libghostty
        // opens the real target, closing a swap-between-validate-and-open
        // window.
        return resolved.path
    }
}
