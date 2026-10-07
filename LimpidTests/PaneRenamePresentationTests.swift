// PaneRenamePresentationTests.swift
// Limpid — pins how rename asks are taken and dropped, how the floating
// rename field opens, is replaced, finishes, and is taken away, and where
// the panel is placed.

import CoreGraphics
import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("PaneRenamePresentation")
struct PaneRenamePresentationTests {
    private static let anchor = CGRect(x: 10, y: 20, width: 80, height: 24)

    // MARK: - Asks

    @Test func requestRename_isTakenOnceByItsPane() {
        let presentation = PaneRenamePresentation()
        let paneID = UUID()
        presentation.requestRename(paneID: paneID)

        #expect(!presentation.takeRenameRequest(paneID: UUID()))
        #expect(presentation.takeRenameRequest(paneID: paneID))
        #expect(!presentation.takeRenameRequest(paneID: paneID))
        #expect(presentation.pendingRename == nil)
    }

    @Test func requestRename_twiceForOnePane_isSeenAsANewAsk() throws {
        let presentation = PaneRenamePresentation()
        let paneID = UUID()
        presentation.requestRename(paneID: paneID)
        let first = try #require(presentation.pendingRename)
        presentation.requestRename(paneID: paneID)
        #expect(presentation.pendingRename != first)
    }

    @Test func headerDisappeared_dropsAnAskItNeverTook() {
        let presentation = PaneRenamePresentation()
        let paneID = UUID()
        let other = UUID()
        presentation.requestRename(paneID: paneID)

        presentation.headerDisappeared(paneID: other)
        #expect(presentation.pendingRename?.paneID == paneID)

        presentation.headerDisappeared(paneID: paneID)
        #expect(presentation.pendingRename == nil)
    }

    // MARK: - The floating field

    @Test func open_publishesTheRequest() {
        let presentation = PaneRenamePresentation()
        let paneID = UUID()
        presentation.open(paneID: paneID, name: "server", anchor: Self.anchor)

        #expect(presentation.request?.paneID == paneID)
        #expect(presentation.request?.name == "server")
        #expect(presentation.request?.anchor == Self.anchor)
    }

    @Test func finish_closesAndReturnsTheRequest() throws {
        let presentation = PaneRenamePresentation()
        presentation.open(paneID: UUID(), name: "server", anchor: Self.anchor)
        let request = try #require(presentation.request)

        #expect(presentation.finish(requestID: request.id) == request)
        #expect(presentation.request == nil)
        #expect(presentation.finish(requestID: request.id) == nil)
    }

    @Test func open_replacesAndTheReplacedCannotFinishIt() throws {
        let presentation = PaneRenamePresentation()
        presentation.open(paneID: UUID(), name: "server", anchor: Self.anchor)
        let replaced = try #require(presentation.request)
        let secondPane = UUID()
        presentation.open(paneID: secondPane, name: "logs", anchor: Self.anchor)

        #expect(presentation.finish(requestID: replaced.id) == nil)
        #expect(presentation.request?.paneID == secondPane)
    }

    @Test func headerDisappeared_closesOnlyItsOwnField() {
        let presentation = PaneRenamePresentation()
        let paneID = UUID()
        presentation.open(paneID: paneID, name: "server", anchor: Self.anchor)

        presentation.headerDisappeared(paneID: UUID())
        #expect(presentation.request != nil)

        presentation.headerDisappeared(paneID: paneID)
        #expect(presentation.request == nil)
    }

    @Test func updateAnchor_followsTheOwningHeaderOnly() {
        let presentation = PaneRenamePresentation()
        let paneID = UUID()
        presentation.open(paneID: paneID, name: "server", anchor: Self.anchor)
        let moved = CGRect(x: 300, y: 40, width: 60, height: 24)

        presentation.updateAnchor(paneID: UUID(), anchor: .zero)
        #expect(presentation.request?.anchor == Self.anchor)

        presentation.updateAnchor(paneID: paneID, anchor: moved)
        #expect(presentation.request?.anchor == moved)
    }

    // MARK: - Placement

    private static func origin(anchor: CGRect, container: CGSize = CGSize(width: 800, height: 600)) -> CGPoint {
        PaneRenamePresentation.panelOrigin(
            anchor: anchor,
            panelSize: CGSize(width: 240, height: 70),
            container: container,
            margin: 8,
            gap: 4
        )
    }

    @Test func panelOrigin_hangsBelowTheHeaderAtItsLeadingEdge() {
        let origin = Self.origin(anchor: CGRect(x: 100, y: 200, width: 60, height: 24))
        #expect(origin == CGPoint(x: 100, y: 228))
    }

    @Test func panelOrigin_staysInsideTheWindowHorizontally() {
        let maximumX: CGFloat = 800 - 240 - 8
        #expect(Self.origin(anchor: CGRect(x: 700, y: 200, width: 60, height: 24)).x == maximumX)
        #expect(Self.origin(anchor: CGRect(x: 2, y: 200, width: 60, height: 24)).x == CGFloat(8))
    }

    @Test func panelOrigin_flipsAboveTheHeaderNearTheBottom() {
        let origin = Self.origin(anchor: CGRect(x: 100, y: 540, width: 60, height: 24))
        let above: CGFloat = 540 - 4 - 70
        #expect(origin.y == above)
    }

    @Test func panelOrigin_pinsInsideWhenNeitherSideFits() {
        let origin = Self.origin(
            anchor: CGRect(x: 100, y: 40, width: 60, height: 24),
            container: CGSize(width: 800, height: 120)
        )
        let pinned: CGFloat = 120 - 70 - 8
        #expect(origin.y == pinned)
    }
}
