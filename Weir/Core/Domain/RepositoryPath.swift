// RepositoryPath.swift
// Weir — whether one folder is another or inside it, the one rule every caller asks.

import Foundation

/// Folder paths compared as text. Links are not followed here: a caller
/// that needs them followed resolves both paths first
/// (`WorktreePathResolver`), since following one stats the disk, which a
/// rule asked on every hook event and every draw cannot afford.
enum RepositoryPath {
    /// Whether `child` is `parent` or inside it. A trailing `/` on either
    /// does not count, and a sibling whose name only starts the same
    /// (`/a/bc` beside `/a/b`) is not inside.
    static func contains(_ parent: String, _ child: String) -> Bool {
        let parent = standardized(parent)
        let child = standardized(child)
        return child == parent || child.hasPrefix(parent == "/" ? "/" : parent + "/")
    }

    /// Whether `child` is inside `parent` and not `parent` itself: a path
    /// read under a root, which the root itself never is.
    static func isStrictDescendant(_ child: String, of parent: String) -> Bool {
        contains(parent, child) && standardized(child) != standardized(parent)
    }

    /// Whether either folder is the other or inside it.
    static func overlaps(_ path: String, _ other: String) -> Bool {
        contains(path, other) || contains(other, path)
    }

    /// `path` without its trailing `/`, so `/a` and `/a/` compare equal;
    /// the root stays `/`.
    static func standardized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
