// VisibilityInputBuilderTests.swift
// Limpid — which panes a pane area draws and which the person can be said to see.

import Foundation
import Testing
@testable import Limpid

struct VisibilityInputBuilderTests {
    private static let left = UUID()
    private static let right = UUID()

    private static func display(
        zoomed: UUID? = nil,
        review: PaneAreaDisplay.Review = .closed
    ) -> PaneAreaDisplay {
        PaneAreaDisplay(leafIDs: [left, right], zoomedLeafID: zoomed, review: review)
    }

    @Test func aSplit_drawsAndShowsEveryLeaf() {
        let display = Self.display()
        #expect(VisibilityInputBuilder.renderedPanes(display) == [Self.left, Self.right])
        // The unfocused leaf of a split counts as seen.
        #expect(VisibilityInputBuilder.attendedPanes(display) == [Self.left, Self.right])
    }

    @Test func aZoomedLeaf_isTheOnlyOneSeenButAllKeepDrawing() {
        let display = Self.display(zoomed: Self.right)
        // Siblings keep drawing so unzooming never shows a stale frame.
        #expect(VisibilityInputBuilder.renderedPanes(display) == [Self.left, Self.right])
        #expect(VisibilityInputBuilder.attendedPanes(display) == [Self.right])
    }

    @Test func aZoomOnALeafThatIsGone_showsTheSplit() {
        let display = Self.display(zoomed: UUID())
        #expect(VisibilityInputBuilder.attendedPanes(display) == [Self.left, Self.right])
    }

    @Test func theReviewTab_drawsNoTerminalAndCountsTheAgentPaneAsUnseen() {
        let display = Self.display(zoomed: Self.left, review: .tab)
        #expect(VisibilityInputBuilder.renderedPanes(display).isEmpty)
        #expect(VisibilityInputBuilder.attendedPanes(display).isEmpty)
    }

    @Test func noTab_showsNothing() {
        let display = PaneAreaDisplay(leafIDs: [], zoomedLeafID: nil, review: .closed)
        #expect(VisibilityInputBuilder.renderedPanes(display).isEmpty)
    }
}
