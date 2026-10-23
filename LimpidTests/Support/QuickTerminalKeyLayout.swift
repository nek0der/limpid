// QuickTerminalKeyLayout.swift
// Limpid — a made-up keyboard layout for the quick terminal hotkey suites.

import Foundation

/// The layout the hotkey suites read key codes through, in place of the
/// machine's own input source.
enum QuickTerminalKeyLayout {
    /// A US-like layout for the parts the tests touch: letters on their
    /// ANSI keyCodes, the digit 1 on both the top row (18) and the
    /// keypad (83), and `]` on 30.
    static let us: [UInt16: String] = [
        0: "a", 1: "s", 17: "t", 30: "]", 18: "1", 83: "1", 40: "k"
    ]

    static func translate(_ layout: [UInt16: String]) -> (UInt16) -> String? {
        { layout[$0] }
    }
}
