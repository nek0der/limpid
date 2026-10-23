// InlineRenameFieldTests.swift
// Limpid — what a submitted inline rename turns into, when an edit commits rather than being abandoned, and the field's edges.

import AppKit
import Testing
@testable import Limpid

@MainActor
@Suite("InlineRenameField")
struct InlineRenameFieldTests {
    /// A submit is trimmed of whitespace and newlines around it, keeps the
    /// whitespace inside it, and, empty or blank, keeps the name it had.
    @Test(arguments: [
        ("  build \n", String?.some("build")),
        ("\tbuild", "build"),
        (" feature  work ", "feature  work"),
        ("", nil),
        ("   ", nil),
        (" \n\t ", nil)
    ])
    func committedName_isTheSubmitTrimmed_orNoneWhenBlank(submitted: String, name: String?) {
        #expect(InlineRenameField.committedName(from: submitted) == name)
    }

    /// The label draws the name until the field has seeded its draft, and
    /// from then on the draft, held at least as wide as the name the edit
    /// started from: an edit opening never narrows it, whatever the last
    /// edit left in the draft.
    @Test(arguments: ["claude", "a-tab-title-long-enough-to-be-cut-by-the-strip", ""])
    func labelText_neverDropsBelowTheNameAnEditOpensOn(name: String) {
        func label(draft: String, start: String, shown: Bool, seeded: Bool) -> InlineRenameLabelText {
            InlineRenameLabelText(name: name, draft: draft, startName: start, isFieldShown: shown, isDraftSeeded: seeded)
        }
        // At rest, whatever an earlier edit left behind.
        #expect(label(draft: "x", start: "y", shown: false, seeded: false) == label(draft: "", start: "", shown: false, seeded: false))
        #expect(label(draft: "x", start: "y", shown: false, seeded: false).text == name)
        #expect(label(draft: "x", start: "y", shown: false, seeded: false).floor == name)
        // Opened, before the field seeds the draft: still the name, not the
        // empty or stale draft.
        #expect(label(draft: "", start: "", shown: true, seeded: false).text == name)
        #expect(label(draft: "stale", start: "older", shown: true, seeded: false).floor == name)
        // Seeded: the draft, held at the name it started from.
        #expect(label(draft: name, start: name, shown: true, seeded: true).text == name)
        let typedLonger = label(draft: name + "-renamed", start: name, shown: true, seeded: true)
        #expect(typedLonger.text == name + "-renamed")
        #expect(typedLonger.floor == name)
        // Closed but not yet reset: the name again.
        #expect(label(draft: "c", start: name, shown: false, seeded: true) == label(draft: "", start: "", shown: false, seeded: false))
        let typedShorter = label(draft: "c", start: name, shown: true, seeded: true)
        #expect(typedShorter.text == "c")
        #expect(typedShorter.floor == name)
    }

    @Test func focusLoss_commitsOnlyAnEditStillOpen() {
        // A click elsewhere takes the keyboard from an open edit: commit.
        #expect(InlineRenameField.commitsOnFocusLoss(isFocused: false, didFinalize: false))
        // A field that ended already (submitted, canceled, or closed by
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

    @Test func aSubmit_handsOnOnlyAChange_fromTheNameTheEditStartedFrom() {
        func submit(_ draft: String, from start: String, clears: Bool = false) -> String? {
            InlineRenameField.submission(draft: draft, startedFrom: start, submitsEmptyName: clears)
        }
        // Untouched, however the name around it changed while the field was
        // open: the field compares with where it started.
        #expect(submit("claude", from: "claude") == nil)
        #expect(submit(" claude ", from: "claude") == nil)
        #expect(submit("web", from: "claude") == "web")
        // A blank submit keeps the name, or clears it where names clear.
        #expect(submit("", from: "claude") == nil)
        #expect(submit("  ", from: "claude", clears: true) == "")
        // Nothing to clear when there was no name to begin with.
        #expect(submit("", from: "", clears: true) == nil)
        #expect(submit("web", from: "", clears: true) == "web")
    }

    // MARK: - The field's edges

    /// The well and the fade reach a few points past the label on each side,
    /// and on the leading side never as far as what stands before the label:
    /// a tab's badge with its state mark laid into the gap, the sidebar
    /// row's state glyph, and the pane header's kind glyph.
    @Test func inlineOutsets_reachPastTheLabel_andStopShortOfTheIcon() {
        let style = InlineRenameEditingStyle.inline
        let layout = LimpidLayout.Supervision.self
        #expect(style.leadingOutset >= 2)
        #expect(style.trailingOutset >= 3)
        #expect(style.trailingOutset > InlineRenameEditingStyle.caretWidth)
        #expect(style.leadingOutset < layout.paneStripTabSpacing - layout.tabStateMarkOutset)
        #expect(style.leadingOutset < layout.sessionRowColumnSpacing)
        #expect(style.leadingOutset < LimpidLayout.paneHeaderItemSpacing)
        // On the trailing side, the gap before the tab's marks and close
        // button, the sidebar row's trailing column, and the header's detail.
        #expect(style.trailingOutset < layout.paneStripTabSpacing)
        #expect(style.trailingOutset < layout.sessionRowColumnSpacing)
        #expect(style.trailingOutset < LimpidLayout.paneHeaderItemSpacing)
    }

    /// The floating panel's field keeps to the box it is drawn in.
    @Test func boxedOutsets_keepToTheLabel() {
        let style = InlineRenameEditingStyle.boxed
        #expect(style.leadingOutset == 0)
        #expect(style.trailingOutset == InlineRenameEditingStyle.caretAllowance)
        #expect(!style.fadesEdges)
        #expect(!style.drawsWell)
    }

    /// Which sides text is scrolled out on, from the clip as AppKit leaves
    /// it (13pt: a 3pt slack, a 1.5pt trailing inset): a name that fits, a
    /// long one at its start (aligned to the slack), at its end, and in its
    /// middle.
    @Test func overflow_readsTheSidesTextIsScrolledOutOn() {
        let fits = InlineRenameEditorAlignment.overflow(originX: -3, visibleWidth: 55, documentWidth: 52, slack: 3)
        let atStart = InlineRenameEditorAlignment.overflow(originX: -3, visibleWidth: 102.5, documentWidth: 246.5, slack: 3)
        let atEnd = InlineRenameEditorAlignment.overflow(originX: 144, visibleWidth: 102.5, documentWidth: 246.5, slack: 3)
        let inMiddle = InlineRenameEditorAlignment.overflow(originX: 60, visibleWidth: 102.5, documentWidth: 246.5, slack: 3)
        #expect(fits == InlineRenameOverflow(hasLeadingOverflow: false, hasTrailingOverflow: false))
        #expect(atStart == InlineRenameOverflow(hasLeadingOverflow: false, hasTrailingOverflow: true))
        #expect(atEnd == InlineRenameOverflow(hasLeadingOverflow: true, hasTrailingOverflow: false))
        #expect(inMiddle == .both)
    }

    /// The field editor is given at least its line fragment padding across,
    /// and keeps an inset it already had that is wider, and its height.
    @Test func editorInset_isAtLeastThePadding() {
        #expect(InlineRenameEditorAlignment.inset(.zero, padding: 2) == NSSize(width: 2, height: 0))
        #expect(InlineRenameEditorAlignment.inset(NSSize(width: 5, height: 1), padding: 2) == NSSize(width: 5, height: 1))
    }

    /// Only a stop at the start is taken back to where the edit began; the
    /// edit's own start and any scroll further along are left alone.
    @Test func editorAlignment_movesOnlyAStopAtTheStart() {
        #expect(InlineRenameEditorAlignment.alignedOriginX(0, slack: 3) == -3)
        #expect(InlineRenameEditorAlignment.alignedOriginX(-1, slack: 3) == -3)
        #expect(InlineRenameEditorAlignment.alignedOriginX(-3, slack: 3) == nil)
        #expect(InlineRenameEditorAlignment.alignedOriginX(0.5, slack: 3) == nil)
        #expect(InlineRenameEditorAlignment.alignedOriginX(140, slack: 3) == nil)
    }
}
