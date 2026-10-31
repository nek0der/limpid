// ScrollbackFiles.swift
// Weir — the folder the panes' scrollback is saved in, and the one rule for what in it may be replayed.

import Foundation
import OSLog
import WeirDomain

private let scrollbackLog = Logger.weir("scrollback")

/// Writes one pane's scrollback to a file. Only the pane's terminal can make
/// that dump (libghostty's `ghostty_surface_write_scrollback`), so the
/// session asks through this rather than naming the view that draws the
/// terminal; the app's surface registry answers it
/// (`SurfaceRegistry+Scrollback`).
@MainActor
protocol ScrollbackWriting: AnyObject {
    /// Writes the scrollback of `paneID` to `url`. `false` when the pane has
    /// no terminal to ask (never mounted this run, or already gone), or the
    /// terminal refused.
    func writeScrollback(ofPane paneID: UUID, to url: URL) -> Bool
}

/// The folder the panes' scrollback goes to as Weir quits or a tab closes,
/// one `<paneID>.vt` file per pane, and what in it a restore may replay. The
/// app hands the session its folder (`WorkspaceSession.scrollbackFiles`), so
/// a test reads and writes a folder of its own.
struct ScrollbackFiles: Equatable {
    let directory: URL

    /// Writes the pane's scrollback to its file and returns where, or `nil`
    /// when the pane had none to give. The one place the file's name, its
    /// folder's creation, and its permissions are decided, so ⌘Q and a tab's
    /// close save alike.
    @MainActor
    func capture(_ paneID: UUID, with writer: any ScrollbackWriting) -> URL? {
        let url = directory.appendingPathComponent("\(paneID.uuidString).vt")
        // libghostty writes the file itself, past `SecureFileWrite`, so the
        // guard is asked here, before it is handed the path.
        guard TestWriteGuard.permits(url) else { return nil }
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        guard writer.writeScrollback(ofPane: paneID, to: url) else { return nil }
        // libghostty writes the `.vt` directly via its C API, so it lands
        // with the platform-default umask (typically 0644). Tightened to
        // 0600: scrollback can carry secrets the person pasted, or
        // environment variables that leaked into stdout.
        SecureFileWrite.tightenPermissions(url)
        return url
    }

    /// Removes every file in the folder that no live or recently closed tab
    /// references, so the folder does not grow across months.
    func prune(keeping live: Set<String>) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in contents where !live.contains(url.path) {
            // A file that cannot be removed now is tried again at the next
            // prune.
            try? SecureFileWrite.removeItem(at: url)
        }
    }

    /// Returns `path` only when it is a `.vt` file in the folder: one we
    /// wrote. A tab's scrollback paths are restored from state.json, which a
    /// tampered or hand-edited file could point at any path (`~/.ssh/id_rsa`);
    /// libghostty would then read and replay that file into the terminal,
    /// where OSC 52 could take it out. Anything outside the folder is refused.
    func validatedPath(_ path: String) -> String? {
        // `standardizedFileURL` strips `.` / `..` and the `/private` alias
        // but does not follow links, which takes `resolvingSymlinksInPath()`.
        // Without it, someone with the same user's write access to the folder
        // could plant `leak.vt -> ~/.ssh/id_rsa` beside a tampered state.json,
        // and libghostty would replay the target through `open(2)` (no
        // `O_NOFOLLOW`). So both sides are resolved, the resolved path must be
        // in the folder, and the leaf itself must not be a link.
        let url = URL(fileURLWithPath: path)
        let resolved = url.resolvingSymlinksInPath()
        let base = directory.resolvingSymlinksInPath().path
        guard resolved.pathExtension == "vt", RepositoryPath.isStrictDescendant(resolved.path, of: base) else {
            scrollbackLog.warning("rejected out-of-sandbox scrollback path on restore")
            return nil
        }
        // A leaf whose kind cannot be read is taken as no link: the resolved
        // path is already in the folder.
        let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        if isSymlink {
            scrollbackLog.warning("rejected symlinked scrollback path on restore")
            return nil
        }
        // The resolved path goes on, so libghostty opens the real target and
        // no link can be swapped in between this check and the open.
        return resolved.path
    }
}
