// FileDropTextTests.swift
// Limpid — checks the text a file drop types, which ordinary and mirror panes share.

import Foundation
import Testing
@testable import Limpid

@Suite("File drop text")
struct FileDropTextTests {
    /// A single quote cannot appear inside single quotes, so it closes the
    /// quote, is escaped, and reopens it; everything else stays literal.
    @Test("each dropped path is single-quoted and the paths are joined by spaces")
    func text_quotesEachPathAndJoinsThem() {
        let files = [
            URL(fileURLWithPath: "/tmp/plain"),
            URL(fileURLWithPath: "/tmp/a b/$HOME;`x`"),
            URL(fileURLWithPath: "/tmp/it's")
        ]
        #expect(FileDropText.text(for: files) == #"'/tmp/plain' '/tmp/a b/$HOME;`x`' '/tmp/it'\''s'"#)
    }

    @Test("no files type nothing")
    func text_withoutFiles_isEmpty() {
        #expect(FileDropText.text(for: []).isEmpty)
    }
}
