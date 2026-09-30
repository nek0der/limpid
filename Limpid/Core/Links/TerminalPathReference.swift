// TerminalPathReference.swift
// Limpid — reads a position suffix off a path printed in a terminal.

import Foundation

/// A path as printed by a compiler, a search tool, or an agent, split from
/// the line and column it may carry. libghostty's link matcher counts `:`
/// and `#` as path characters, so `src/a.swift:12:5` and `src/a.swift#L12`
/// reach us whole.
struct TerminalPathReference: Equatable {
    let path: String
    let position: FilePosition?

    /// The readings to try, most literal first. A file really named
    /// `notes:12` exists on some disks, so the text as printed is tried
    /// before the suffix is taken as a position.
    static func candidates(for text: String) -> [TerminalPathReference] {
        let literal = TerminalPathReference(path: text, position: nil)
        guard let split = splitSuffix(text) else { return [literal] }
        return [literal, split]
    }

    private static func splitSuffix(_ text: String) -> TerminalPathReference? {
        // `:line`, `:line:column`, `#Lline`, and `#LlineCcolumn`, which is
        // what Codex is told to print. A range such as `#L3-L9` keeps its
        // start line. The literal lives here because `Regex` is not
        // `Sendable` and cannot be a static constant.
        let suffix = #/^(.+?)(?::(\d+)(?::(\d+))?|#L(\d+)(?:C(\d+))?(?:-L?\d+)?)$/#
        guard let match = text.wholeMatch(of: suffix) else { return nil }
        let (_, path, colonLine, colonColumn, hashLine, hashColumn) = match.output
        guard let line = Int(colonLine ?? hashLine ?? ""), line > 0 else { return nil }
        let column = (colonColumn ?? hashColumn).flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        return TerminalPathReference(path: String(path), position: FilePosition(line: line, column: column))
    }
}
