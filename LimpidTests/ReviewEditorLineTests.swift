// ReviewEditorLineTests.swift
// Limpid — pins which line of the file on disk a row of the diff opens at.

import Testing
@testable import Limpid

struct ReviewEditorLineTests {
    typealias Slot = ReviewEditorLine.Slot

    @Test func lineWithANewNumberOpensThere() {
        #expect(ReviewEditorLine.line(at: 1, in: [.line(10), .line(11), .line(12)]) == 11)
    }

    /// A removal is sent to where it was, which is where the next surviving
    /// line now starts.
    @Test func removedLineOpensAtTheNextSurvivingLine() {
        let slots: [Slot] = [.line(10), .line(nil), .line(nil), .line(11)]
        #expect(ReviewEditorLine.line(at: 1, in: slots) == 11)
        #expect(ReviewEditorLine.line(at: 2, in: slots) == 11)
    }

    /// With nothing after it in the run, the removal sits just past the last
    /// line that survived.
    @Test func removalAtTheEndOfARunOpensPastThePreviousLine() {
        #expect(ReviewEditorLine.line(at: 2, in: [.line(10), .line(11), .line(nil)]) == 12)
    }

    /// The next hunk and the lines past a fold are elsewhere in the file.
    @Test func searchStopsAtABoundary() {
        #expect(ReviewEditorLine.line(at: 1, in: [.line(10), .line(nil), .boundary, .line(80)]) == 11)
        #expect(ReviewEditorLine.line(at: 1, in: [.boundary, .line(nil), .boundary]) == nil)
    }

    @Test func rowOutsideTheListHasNoLine() {
        #expect(ReviewEditorLine.line(at: 3, in: [.line(1)]) == nil)
    }
}
