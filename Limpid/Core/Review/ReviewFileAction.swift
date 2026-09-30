// ReviewFileAction.swift
// Limpid — resolves reviewed worktree paths for actions outside the app.

import AppKit
import Foundation

/// The boundary between Review's Git-relative paths and macOS file actions.
/// Opening goes through `FileOpener`, shared with terminal links.
enum ReviewFileAction {
    /// Resolves a Git-relative or absolute file path only when its canonical
    /// location remains under the canonical repository root. Resolving both
    /// sides closes the parent-symlink escape that lexical prefix checks miss.
    static func fileURL(for path: String, in repositoryRoot: URL) -> URL? {
        guard !path.isEmpty else { return nil }
        let candidate = if path.hasPrefix("/") {
            URL(fileURLWithPath: path)
        } else {
            repositoryRoot.appendingPathComponent(path)
        }

        let root = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        var rootPath = root.path
        if !rootPath.hasSuffix("/") {
            rootPath += "/"
        }
        guard resolved.path.hasPrefix(rootPath) else { return nil }
        return resolved
    }

    /// Shows the file in Finder without changing the reader's app preference.
    static func revealInFinder(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
