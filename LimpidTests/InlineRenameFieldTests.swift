// InlineRenameFieldTests.swift
// Limpid — pins what a submitted inline rename turns into, now that
// the tab and container rows share one rule instead of each keeping
// a copy, and when an edit commits rather than being abandoned.

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

    @Test func focusLoss_commitsOnlyAnEditStillOpen() {
        // A click elsewhere takes the keyboard from an open edit: commit.
        #expect(InlineRenameField.commitsOnFocusLoss(isFocused: false, didFinalize: false))
        // A field that ended already (submitted, cancelled, or closed by
        // its owner) losing the keyboard as it goes away commits nothing.
        #expect(!InlineRenameField.commitsOnFocusLoss(isFocused: false, didFinalize: true))
        #expect(!InlineRenameField.commitsOnFocusLoss(isFocused: true, didFinalize: false))
    }

    @Test func closedByItsOwner_abandonsTheEdit() {
        // A floating rename whose request was dropped (the pane closed, a
        // tab switch) or replaced (another header's rename) goes without
        // committing.
        #expect(InlineRenameField.abandonsWhenClosedByOwner(isEditing: false, didFinalize: false))
        // An edit the field ended itself has nothing left to abandon, and
        // one still open is not closed.
        #expect(!InlineRenameField.abandonsWhenClosedByOwner(isEditing: false, didFinalize: true))
        #expect(!InlineRenameField.abandonsWhenClosedByOwner(isEditing: true, didFinalize: false))
    }
}
