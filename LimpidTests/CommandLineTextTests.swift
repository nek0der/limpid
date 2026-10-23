// CommandLineTextTests.swift
// Limpid — a command typed in a settings field, with the quotes macOS curls put back as the shell reads them.

import Testing
@testable import Limpid

struct CommandLineTextTests {
    /// macOS' default `NSTextView` turns a typed `"` into U+201C / U+201D.
    /// PlainTextEditor turns that off as the person types; this pass covers
    /// a hand-edited state.json or an older snapshot. ASCII is left alone.
    @Test(arguments: [
        ("echo \u{201C}hi\u{201D}", "echo \"hi\""),
        ("git commit -m \u{2018}fix\u{2019}", "git commit -m 'fix'"),
        ("echo \"hi\" && rm -f /tmp/x", "echo \"hi\" && rm -f /tmp/x")
    ])
    func sanitizeSmartPunctuation_straightensCurlyQuotes_andLeavesASCII(input: String, expected: String) {
        #expect(CommandLineText.sanitizeSmartPunctuation(input) == expected)
    }
}
