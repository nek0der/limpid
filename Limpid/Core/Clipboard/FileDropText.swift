// FileDropText.swift
// Limpid — the text a file drop types into a pane: each path quoted for the shell.

import Foundation

/// What dropping files onto a pane types. An ordinary pane writes it to its
/// pty and a mirror pane pastes it through tmux; both build it here so the
/// two kinds of pane type the same thing for the same drop.
enum FileDropText {
    /// The paths of `fileURLs`, shell-quoted and separated by spaces.
    static func text(for fileURLs: [URL]) -> String {
        fileURLs.map { shellQuoted($0.path) }.joined(separator: " ")
    }

    /// Wraps `path` in single quotes, writing each single quote inside it
    /// as `'\''`, so spaces and shell metacharacters stay part of the path.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
