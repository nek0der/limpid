// CommandLineText.swift
// Limpid — a command line a person typed, made safe to hand to `sh -c`.

import Foundation

enum CommandLineText {
    /// Belt-and-braces normalizer for `state.json` hand-edits or
    /// snapshots from older builds. The editors use `PlainTextEditor`,
    /// which already turns off the substitutions; this catches the case
    /// where the value flowed in from outside the editor and still carries
    /// curly quotes, which `sh -c` would read as part of a word rather
    /// than as quoting. Here in Core, beside the settings it cleans, so a
    /// sheet, a settings pane, and the tests all call one function.
    nonisolated static func sanitizeSmartPunctuation(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\u{201C}", with: "\"") // "
            .replacingOccurrences(of: "\u{201D}", with: "\"") // "
            .replacingOccurrences(of: "\u{2018}", with: "'") // '
            .replacingOccurrences(of: "\u{2019}", with: "'") // '
    }
}
