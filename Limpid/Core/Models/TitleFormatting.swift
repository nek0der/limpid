// TitleFormatting.swift
// Limpid — pure helpers for synthesizing tab/window titles. Pulled out
// of `WindowSession` so the session can stay focused on state and so
// these strings stay easy to unit-test without spinning up a session.

import Foundation

enum TitleFormatting {
    /// Best-effort initial tab title matching what zsh/bash emit via
    /// OSC 2 once shell-integration loads:
    ///   - bash uses `\w` → `~/path/from/home`
    ///   - zsh uses `%(4~|…/%3~|%~)` → `~/path` up to 3 levels, then
    ///     `…/last3` for deeper trees
    /// Picking the same string up front avoids a visible title flash
    /// from our placeholder to the shell's first emission.
    static func pwdStyle(for workingDirectory: URL?) -> String {
        let path = workingDirectory?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        let tildePath = PathFormatting.abbreviateHome(path)
        if tildePath == "~" {
            return "~"
        }
        // zsh-style truncation: ≥4 components → "…/last3"
        let components = tildePath.split(separator: "/", omittingEmptySubsequences: false)
        let nonEmpty = components.filter { !$0.isEmpty }
        if nonEmpty.count >= 4 {
            return "…/" + nonEmpty.suffix(3).joined(separator: "/")
        }
        return tildePath
    }
}
