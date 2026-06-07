// PathFormatting.swift
// Limpid — small utilities for rendering file-system paths in UI.
// Lives under `UI/Design` because the only callers are SwiftUI views
// (sheets, popovers) and the formatting choices are presentational.

import Foundation

enum PathFormatting {
    /// Collapse `$HOME` to `~` for display. Inputs that aren't inside
    /// the user's home directory are returned verbatim.
    static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
