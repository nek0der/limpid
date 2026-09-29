// PathFormatting.swift
// Limpid — small utilities for rendering file-system paths for display.
// In Core so the command palette and tab titles share the one home
// abbreviation the sheets use; a copy that matched `$HOME` without the
// trailing separator turned `/Users/nameX` into `~X`.

import Foundation

enum PathFormatting {
    /// Collapse `$HOME` to `~` for display. Inputs that aren't inside
    /// the user's home directory are returned verbatim.
    static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
