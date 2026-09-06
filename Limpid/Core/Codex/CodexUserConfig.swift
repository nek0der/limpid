// CodexUserConfig.swift
// Limpid — splices our hook-trust block into the user's own
// `~/.codex/config.toml`.
//
// This is the only file Limpid edits that belongs to someone else, so the
// splice is deliberately narrow: it finds its own markers, replaces what
// is between them, and forms no opinion about any other line. The shadow
// CODEX_HOME this replaced parsed and rewrote their content instead, and
// a bug there could only corrupt a copy — here it would reach the
// original, which is why nothing in this type reads their TOML.

import Foundation

enum CodexUserConfig {
    static let beginMarker = "# BEGIN limpid — managed hook trust, regenerated on launch"
    static let endMarker = "# END limpid"

    /// Return `existing` with `block` between our markers, appending the
    /// section when it is absent. Returns the input unchanged when the
    /// result would be identical, so the caller can skip writing and leave
    /// a version-controlled config alone.
    static func applying(block: String, to existing: String) -> String {
        let lines = existing.components(separatedBy: "\n")
        let rendered = [beginMarker, block, endMarker]

        guard let start = lines.firstIndex(of: beginMarker) else {
            var out = lines
            // Keep exactly one blank line between their content and ours,
            // and none at all when the file was empty.
            while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                out.removeLast()
            }
            if !out.isEmpty {
                out.append("")
            }
            return (out + rendered).joined(separator: "\n") + "\n"
        }

        // A hand-edited file can lose the closing marker. Ending the span
        // at the marker we find — and at the start line otherwise — keeps
        // whatever they wrote after our block instead of swallowing it.
        let tailStart: Int = if let end = lines[start...].firstIndex(of: endMarker) {
            end + 1
        } else {
            start + 1
        }
        let head = Array(lines[..<start])
        let tail = Array(lines[tailStart...])
        return (head + rendered + tail).joined(separator: "\n")
    }
}
