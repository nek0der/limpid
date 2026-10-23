// ReviewPresentationTests.swift
// Limpid — which review is open, and which pane its feedback goes to.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Review presentation")
struct ReviewPresentationTests {
    private static let directory = URL(fileURLWithPath: "/tmp/review")

    /// The review writes to the pane it was opened from until the reader
    /// names another, and closing keeps nothing of it: a new opening starts
    /// from its own pane again.
    @Test func theReview_writesToItsOpeningPane_untilTheReaderNamesAnother_andClosingKeepsNothing() {
        let presentation = ReviewPresentation()
        let opened = UUID()
        let chosen = UUID()

        presentation.open(Self.directory, originPaneID: opened)
        #expect(presentation.directory == Self.directory)
        #expect(presentation.isPresented)
        #expect(presentation.originPaneID == opened)

        presentation.pinDestination(to: chosen)
        #expect(presentation.originPaneID == chosen)

        presentation.close()
        #expect(presentation.directory == nil)
        #expect(!presentation.isPresented)
        #expect(presentation.originPaneID == nil)
        presentation.open(Self.directory, originPaneID: opened)
        #expect(presentation.originPaneID == opened)
    }

    /// A request for the review already open changes its scope and pane,
    /// and is the same opening.
    @Test func aRequestForTheOpenRoot_changesTheScopeWithoutReopening() throws {
        let presentation = ReviewPresentation()
        let firstPane = UUID()
        let turnPane = UUID()
        let scope = try ReviewScope.turns(TurnSummaryFixture.range(number: 1))
        presentation.open(Self.directory, originPaneID: firstPane)
        let opening = presentation.opening

        presentation.open(Self.directory, originPaneID: turnPane, initialScope: scope)

        #expect(presentation.opening == opening)
        #expect(presentation.originPaneID == turnPane)
        #expect(presentation.requestedScope == scope)
    }
}
