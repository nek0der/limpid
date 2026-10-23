// TerminalTail.swift
// Limpid — the last lines a terminal shows, as an all projects card quotes them.

import Foundation

/// The last lines of what a terminal shows: the lines that hold text, with
/// the blank rows below a short output and the spaces after each line's
/// text left off, so a card quotes what the person would read there. An
/// agent's TUI ends in its own chrome, which says nothing of the work: the
/// frame of its input box, the prompt inside it, the key hints under it
/// ("? for shortcuts"), and its status line (the model, the folder, the
/// quota left). That run at the bottom is left off whole, and a card
/// whose screen holds nothing else quotes nothing rather than the chrome.
enum TerminalTail {
    /// The lines a card quotes.
    static let lineCount = 3

    static func lastLines(of screen: String, count: Int = lineCount) -> [String] {
        var lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line.reversed().drop { $0 == " " || $0 == "\r" || $0 == "\t" }.reversed())
        }
        // The chrome is the TUI's bottom: everything from the last line
        // that is not chrome down is left off, blank rows among it too.
        while let last = lines.last, last.isEmpty || isChrome(last) {
            lines.removeLast()
        }
        // A frame higher up (a box the agent drew around a result) is a
        // line of nothing either.
        lines.removeAll(where: isFrame)
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        return Array(lines.suffix(count))
    }

    /// Whether a line is an agent TUI's chrome rather than its output.
    static func isChrome(_ line: String) -> Bool {
        isFrame(line) || isPrompt(line) || isKeyHint(line) || isStatusLine(line)
    }

    /// A line of box-drawing characters and spaces alone (U+2500–U+257F).
    private static func isFrame(_ line: String) -> Bool {
        !line.isEmpty && line.unicodeScalars.contains { (0x2500...0x257F).contains($0.value) }
            && line.unicodeScalars.allSatisfy { (0x2500...0x257F).contains($0.value) || $0 == " " }
    }

    /// The agent's input line: Codex's "›" or Claude's ">" first, after the
    /// box's own edge when the prompt sits inside one, whatever is typed or
    /// placed after it.
    private static func isPrompt(_ line: String) -> Bool {
        let text = line.drop { $0 == " " || (0x2500...0x257F).contains($0.unicodeScalars.first?.value ?? 0) }
        guard let first = text.first, first == "›" || first == ">" else { return false }
        let rest = text.dropFirst()
        return rest.isEmpty || rest.first == " "
    }

    /// The hints both TUIs keep under the prompt. Not "esc to interrupt":
    /// that is on the agents' working line ("Thinking… (12s · esc to
    /// interrupt)"), which says what the agent does now, and stays.
    private static let keyHints = ["for shortcuts", "shift+tab", "auto-compact", "⏎ send"]

    private static func isKeyHint(_ line: String) -> Bool {
        keyHints.contains { line.localizedCaseInsensitiveContains($0) }
    }

    /// Codex's status line: facts set apart by " · " (the model and its
    /// effort, the folder, the quota or context left), one of them a
    /// percentage.
    private static func isStatusLine(_ line: String) -> Bool {
        line.contains(" · ") && line.contains("%")
    }
}
