// ReviewSyntaxTests.swift
// Weir — what the review lexer colors, and what it deliberately does not.

import Foundation
import Testing
@testable import Weir

struct ReviewSyntaxTests {
    @Test func theLexerColorsWholeWordsOnly() throws {
        let swift = try #require(ReviewSyntax.language(for: "a/b/File.swift"), "Swift is not recognized")
        // A keyword is a whole word: `information` starts with `in` and is
        // left alone. `class` is colored wherever it appears — the lexer reads
        // one line at a time and does not look back at the `.` before it, so a
        // member with a keyword's name is colored like the keyword.
        let words = ReviewSyntax.tokens(in: "let information = value.class", language: swift)
        #expect(words.count == 2, "Expected `let` and `class`: \(words.count)")
        #expect(words.allSatisfy { $0.kind == .keyword }, "Both are keywords")
        let line = "let name = \"text\" // let"
        let mixed = ReviewSyntax.tokens(in: line, language: swift)
        try #require(mixed.map(\.kind) == [.keyword, .string, .comment], "Kinds: \(mixed.map(\.kind))")
        // The comment runs to the end of the line, and the keyword inside it
        // is part of the comment rather than a keyword of its own.
        #expect(String(line[mixed[2].range]) == "// let", "Comment: \(String(line[mixed[2].range]))")
        #expect(String(line[mixed[1].range]) == "\"text\"", "The quotes belong to the string")
        // An escaped quote does not end the string, and one that never closes
        // ends with the line: a diff cuts lines wherever the change did.
        let escaped = ReviewSyntax.tokens(in: "\"a\\\"b\" x", language: swift)
        #expect(escaped.first.map { String("\"a\\\"b\" x"[$0.range]) } == "\"a\\\"b\"", "Escapes end the string early")
        let open = ReviewSyntax.tokens(in: "\"unterminated", language: swift)
        #expect(open.count == 1 && open[0].kind == .string, "An unterminated string is still a string")
        // Numbers, but not the digits inside a name.
        #expect(ReviewSyntax.tokens(in: "x = 42", language: swift).contains { $0.kind == .number }, "42 is a number")
        #expect(
            !ReviewSyntax.tokens(in: "utf8 = utf8", language: swift).contains { $0.kind == .number },
            "The 8 in utf8 is part of the word"
        )
        // Swift's attributes and directives are open-ended, so they are read
        // off the sigil rather than from a list.
        #expect(
            ReviewSyntax.tokens(in: "@MainActor func run()", language: swift).count(where: { $0.kind == .keyword }) == 2,
            "An attribute is a keyword"
        )
        // A shell reads `$` the same way, and comments with `#`.
        let shell = try #require(ReviewSyntax.language(for: "run.sh"), "Shell is not recognized")
        let script = ReviewSyntax.tokens(in: "echo $HOME # done", language: shell)
        #expect(script.map(\.kind) == [.keyword, .comment], "Shell kinds: \(script.map(\.kind))")
        // A file we do not know is drawn plain rather than guessed at.
        #expect(ReviewSyntax.language(for: "notes.unknownext") == nil, "An unknown extension has no language")
        #expect(ReviewSyntax.tokens(in: "", language: swift).isEmpty, "An empty line has nothing to color")
        // A character `isNumber` calls a number but no literal is written
        // with. A token that started on one used to be empty, and the scan
        // that never moved past it hung the thread that was drawing the line.
        #expect(ReviewSyntax.tokens(in: "* ② step", language: swift).isEmpty, "A numeral that is not a digit")
        #expect(ReviewSyntax.tokens(in: "½ ٣ Ⅳ", language: swift).isEmpty, "Numerals from other scripts")
    }
}
