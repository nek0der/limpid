// InlineRenameFieldTests.swift
// Limpid — pins what a submitted inline rename turns into, now that
// the tab and container rows share one rule instead of each keeping
// a copy.

import Testing
@testable import Limpid

@Suite("InlineRenameField")
struct InlineRenameFieldTests {
    @Test func committedName_trimsSurroundingWhitespaceAndNewlines() {
        #expect(InlineRenameField.committedName(from: "  build \n") == "build")
        #expect(InlineRenameField.committedName(from: "\tbuild") == "build")
    }

    @Test func committedName_keepsInteriorWhitespace() {
        #expect(InlineRenameField.committedName(from: " feature  work ") == "feature  work")
    }

    @Test func committedName_emptyOrBlankSubmit_keepsPriorName() {
        #expect(InlineRenameField.committedName(from: "") == nil)
        #expect(InlineRenameField.committedName(from: "   ") == nil)
        #expect(InlineRenameField.committedName(from: " \n\t ") == nil)
    }
}
