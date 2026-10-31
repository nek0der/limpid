// FloatingPanelPlacementTests.swift
// Weir — where a floating panel goes relative to its anchor, and where its
// arrow points. Shared by the pane rename field, the prompt cache panel and
// the container color picker.

import CoreGraphics
import Testing
@testable import Weir

struct FloatingPanelOriginTests {
    private static func origin(
        anchor: CGRect,
        container: CGSize = CGSize(width: 800, height: 600),
        alignment: FloatingPanelPlacement.Alignment = .leading
    ) -> CGPoint {
        FloatingPanelPlacement.origin(
            anchor: anchor,
            panelSize: CGSize(width: 240, height: 70),
            container: container,
            margin: 8,
            gap: 4,
            alignment: alignment
        )
    }

    @Test func leading_hangsBelowTheAnchorAtItsLeadingEdge() {
        let origin = Self.origin(anchor: CGRect(x: 100, y: 200, width: 60, height: 24))
        #expect(origin == CGPoint(x: 100, y: 228))
    }

    @Test func centered_hangsBelowTheAnchorAroundItsCenter() {
        let origin = Self.origin(anchor: CGRect(x: 300, y: 200, width: 10, height: 10), alignment: .centered)
        #expect(origin == CGPoint(x: 305 - 120, y: 214))
    }

    @Test func staysInsideTheWindowHorizontally() {
        let maximumX: CGFloat = 800 - 240 - 8
        #expect(Self.origin(anchor: CGRect(x: 700, y: 200, width: 60, height: 24)).x == maximumX)
        #expect(Self.origin(anchor: CGRect(x: 2, y: 200, width: 60, height: 24)).x == CGFloat(8))
        // A dot near the sidebar's edge: centering would put the panel past
        // the window's leading edge, so it is pulled in.
        let nearTheEdge = Self.origin(anchor: CGRect(x: 20, y: 200, width: 10, height: 10), alignment: .centered)
        #expect(nearTheEdge.x == CGFloat(8))
    }

    @Test func centered_staysInsideTheWindowAtTheTrailingEdge() {
        // The prompt cache panel's path: a clock in the last pane's header,
        // near the window's right edge.
        let origin = Self.origin(anchor: CGRect(x: 780, y: 200, width: 16, height: 16), alignment: .centered)
        let trailingmost: CGFloat = 800 - 240 - 8
        #expect(origin.x == trailingmost)
    }

    @Test func flipsAboveTheAnchorNearTheBottom() {
        let origin = Self.origin(anchor: CGRect(x: 100, y: 540, width: 60, height: 24))
        let above: CGFloat = 540 - 4 - 70
        #expect(origin.y == above)
    }

    @Test func pinsInsideWhenNeitherSideFits() {
        let origin = Self.origin(
            anchor: CGRect(x: 100, y: 40, width: 60, height: 24),
            container: CGSize(width: 800, height: 120)
        )
        let pinned: CGFloat = 120 - 70 - 8
        #expect(origin.y == pinned)
    }

    @Test func staysInsideTheWindowForAnAnchorAboveIt() {
        let origin = Self.origin(anchor: CGRect(x: 100, y: -400, width: 60, height: 16))
        #expect(origin.y == 8)
    }

    @Test func staysInsideTheWindowForAnAnchorBelowIt() {
        // Below the window, the "above" branch would leave it off the bottom.
        let origin = Self.origin(anchor: CGRect(x: 100, y: 1400, width: 60, height: 16))
        let lowest: CGFloat = 600 - 70 - 8
        #expect(abs(origin.y - lowest) < 0.001)
    }
}

struct FloatingPanelArrowTests {
    private let width: CGFloat = 300
    private let height: CGFloat = 140
    private let inset: CGFloat = 30

    private func arrow(anchor: CGRect, panelAt origin: CGPoint) -> FloatingPanelPlacement.Arrow? {
        FloatingPanelPlacement.arrow(
            anchor: anchor,
            panelOrigin: origin,
            panelSize: CGSize(width: width, height: height),
            minimumInset: inset
        )
    }

    @Test func belowTheAnchor_pointsUpAtItsCenter() {
        let anchor = CGRect(x: 400, y: 40, width: 16, height: 16)
        #expect(arrow(anchor: anchor, panelAt: CGPoint(x: 258, y: 66)) == .init(edge: .top, offset: 150))
    }

    @Test func aboveTheAnchor_pointsDown() {
        let anchor = CGRect(x: 400, y: 600, width: 16, height: 16)
        let placement = arrow(anchor: anchor, panelAt: CGPoint(x: 258, y: 600 - 13 - height))
        #expect(placement?.edge == .bottom)
        #expect(placement?.offset == 150)
    }

    @Test func panelClampedToTheWindow_stillPointsAtTheAnchor() {
        // An anchor near the window's right edge: the panel slid left, so the
        // arrow moves right within it, as far as the corner allows.
        let anchor = CGRect(x: 772, y: 40, width: 16, height: 16)
        #expect(arrow(anchor: anchor, panelAt: CGPoint(x: 492, y: 66)) == .init(edge: .top, offset: width - inset))
    }

    @Test func anchorPastTheLeadingCorner_keepsTheArrowOffTheRounding() {
        // A sidebar color dot, with the panel pulled in to the window margin.
        let anchor = CGRect(x: 0, y: 40, width: 16, height: 16)
        #expect(arrow(anchor: anchor, panelAt: CGPoint(x: 8, y: 66))?.offset == inset)
    }

    @Test func panelOverTheAnchor_hasNoArrow() {
        let anchor = CGRect(x: 400, y: 100, width: 16, height: 16)
        #expect(arrow(anchor: anchor, panelAt: CGPoint(x: 258, y: 50)) == nil)
    }

    @Test func panelNarrowerThanBothInsets_centersTheArrow() {
        let placement = FloatingPanelPlacement.arrow(
            anchor: CGRect(x: 0, y: 0, width: 16, height: 16),
            panelOrigin: CGPoint(x: 0, y: 30),
            panelSize: CGSize(width: 40, height: 50),
            minimumInset: 30
        )
        #expect(placement?.offset == 20)
    }
}

/// The two ways Weir's panels hang, as hosts lay them out: the presets,
/// with their sizes from `WeirLayout`. Where the origin rule itself lands
/// is `FloatingPanelOriginTests`; these check what each preset adds.
@MainActor
struct FloatingPanelLayoutTests {
    private let container = CGSize(width: 800, height: 600)
    private let panel = CGSize(width: WeirLayout.paneRenamePanelWidth, height: 70)

    private func layout(
        _ anchor: CGRect,
        style: FloatingPanelPlacement.Style
    ) -> (origin: CGPoint, arrow: FloatingPanelPlacement.Arrow?) {
        FloatingPanelPlacement.layout(
            anchor: anchor,
            panelSize: panel,
            container: container,
            margin: WeirLayout.floatingPanelWindowMargin,
            style: style
        )
    }

    @Test func aCardOpenedFromTheTitleBarPill_hangsBelowIt_pointingUp() {
        // The Needs Attention pill near the window's top-right corner.
        let pill = CGRect(x: 690, y: 12, width: 100, height: 24)
        let card = CGSize(width: 400, height: 180)
        let placed = FloatingPanelPlacement.layout(
            anchor: pill,
            panelSize: card,
            container: container,
            margin: 8,
            style: .init(
                alignment: .centered,
                gap: WeirLayout.floatingPanelArrowAnchorGap,
                arrowInset: WeirLayout.floatingPanelArrowInset
            )
        )
        #expect(placed.origin.y >= pill.maxY, "below the pill, not over it")
        #expect(placed.origin.x + card.width <= container.width - 8)
        #expect(placed.arrow?.edge == .top)
    }

    @Test func underHeader_hangsCloseUnderTheHeadersLeadingEdgeWithNoArrow() {
        let header = CGRect(x: 100, y: 200, width: 160, height: 24)
        let placed = layout(header, style: .underHeader)
        #expect(placed.origin.x == header.minX)
        #expect(placed.origin.y == header.maxY + WeirLayout.paneRenamePanelAnchorGap)
        #expect(placed.arrow == nil)
    }

    @Test func underHeader_nearTheBottom_sitsAboveWithNoArrow() {
        let header = CGRect(x: 100, y: 540, width: 160, height: 24)
        let placed = layout(header, style: .underHeader)
        #expect(placed.origin.y == header.minY - WeirLayout.paneRenamePanelAnchorGap - panel.height)
        #expect(placed.arrow == nil)
    }

    @Test func arrowed_centersOnTheAnchorAndPointsBackAtIt() throws {
        let dot = CGRect(x: 300, y: 200, width: 10, height: 10)
        let placed = layout(dot, style: .arrowed)
        #expect(placed.origin.y == dot.maxY + WeirLayout.floatingPanelArrowAnchorGap)
        let arrow = try #require(placed.arrow)
        #expect(arrow.edge == .top)
        #expect(placed.origin.x + arrow.offset == dot.midX)
    }

    @Test func arrowed_nearTheBottom_pointsDown() throws {
        let dot = CGRect(x: 300, y: 560, width: 10, height: 10)
        let arrow = try #require(layout(dot, style: .arrowed).arrow)
        #expect(arrow.edge == .bottom)
    }
}

/// The approval card beside the row that opened it.
struct FloatingPanelBesideTests {
    private static let container = CGSize(width: 1000, height: 700)
    private static let panel = CGSize(width: 400, height: 200)

    private static func beside(
        _ anchor: CGRect,
        panel: CGSize = Self.panel,
        placementHeight: CGFloat? = nil,
        container: CGSize = Self.container
    ) -> (origin: CGPoint, arrow: FloatingPanelPlacement.Arrow?) {
        FloatingPanelPlacement.beside(
            anchor: anchor,
            panelSize: panel,
            placementHeight: placementHeight ?? panel.height,
            container: container,
            style: .init(margin: 8, gap: 12, arrowInset: 30)
        )
    }

    @Test func standsBesideTheRowAndPointsAtItsMiddle() throws {
        let row = CGRect(x: 0, y: 300, width: 280, height: 40)
        let placed = Self.beside(row)
        #expect(placed.origin == CGPoint(x: 292, y: 220))
        let arrow = try #require(placed.arrow)
        #expect(arrow.edge == .leading)
        #expect(placed.origin.y + arrow.offset == row.midY)
    }

    @Test func nearTheTop_staysInsideAndStillPointsAtTheRow() throws {
        let row = CGRect(x: 0, y: 30, width: 280, height: 40)
        let placed = Self.beside(row)
        #expect(placed.origin.y == 8)
        let arrow = try #require(placed.arrow)
        #expect(placed.origin.y + arrow.offset == row.midY)
    }

    @Test func aRowTooCloseToTheCorner_getsNoArrow() {
        // The row's middle would put the arrow on the rounded corner.
        let row = CGRect(x: 0, y: 0, width: 280, height: 20)
        #expect(Self.beside(row).arrow == nil)
    }

    @Test func aRowScrolledAway_getsNoArrow() {
        let row = CGRect(x: 0, y: 900, width: 280, height: 40)
        let placed = Self.beside(row)
        #expect(placed.origin.y == Self.container.height - Self.panel.height - 8)
        #expect(placed.arrow == nil)
    }

    @Test func aNarrowWindow_overlapsTheRowWithNoArrow() {
        let row = CGRect(x: 0, y: 300, width: 400, height: 40)
        let placed = Self.beside(row, container: CGSize(width: 600, height: 700))
        #expect(placed.origin.x == 192)
        #expect(placed.arrow == nil)
    }

    @Test func aShrunkPanel_keepsItsTopWhereTheTallestPutIt() {
        let row = CGRect(x: 0, y: 300, width: 280, height: 40)
        let tall = Self.beside(row, panel: CGSize(width: 400, height: 300))
        let shrunk = Self.beside(row, panel: CGSize(width: 400, height: 200), placementHeight: 300)
        #expect(shrunk.origin.y == tall.origin.y)
    }
}

/// How tall a panel beside its anchor may be: a long reason or question
/// scrolls inside the card rather than pushing its actions off the window.
struct FloatingPanelHeightTests {
    @Test func aPanelIsAtMostTheWindowLessItsMargins() {
        #expect(FloatingPanelPlacement.maximumHeight(container: 600, margin: 8) == 584)
        // A window too short for any panel still gets one with some room.
        #expect(FloatingPanelPlacement.maximumHeight(container: 40, margin: 8) == FloatingPanelPlacement.minimumScrollingHeight)
    }

    @Test func theScrollingBodyGetsWhatTheHeadingAndActionsLeave() {
        #expect(FloatingPanelPlacement.scrollingBodyHeight(cap: 584, chrome: 120) == 464)
        // Before anything is measured, the whole cap; never below a few lines.
        #expect(FloatingPanelPlacement.scrollingBodyHeight(cap: 584, chrome: 0) == 584)
        #expect(FloatingPanelPlacement.scrollingBodyHeight(cap: 200, chrome: 190) == FloatingPanelPlacement.minimumScrollingHeight)
    }

    /// A dropdown's list stops at its own height while the panel has room,
    /// and gives up the rest when it does not. It never goes below the
    /// minimum scrolling height, which wins over the cap in a panel too
    /// short for it.
    @Test func aDropdownsList_keepsItsHeightUntilThePanelRunsOutOfRoom() {
        #expect(FloatingPanelPlacement.scrollingBodyHeight(preferred: 320, cap: 800, chrome: 200) == 320)
        #expect(FloatingPanelPlacement.scrollingBodyHeight(preferred: 320, cap: 400, chrome: 200) == 200)
        #expect(FloatingPanelPlacement.scrollingBodyHeight(preferred: 320, cap: 220, chrome: 200)
            == FloatingPanelPlacement.minimumScrollingHeight)
    }

    /// A title bar dropdown may reach down to the window's bottom margin,
    /// and the panel it is capped to then stands inside the window. In a
    /// window too short for any list, the minimum scrolling height wins and
    /// the panel can run past that margin.
    @Test func aDropdownBelowItsControl_endsAboveTheWindowsBottomMargin() {
        let anchor = CGRect(x: 100, y: 10, width: 120, height: 28)
        let room = FloatingPanelPlacement.roomBelow(anchor: anchor, containerMaxY: 500, gap: 4, margin: 8)
        #expect(room == 450)
        let origin = FloatingPanelPlacement.origin(
            anchor: anchor,
            panelSize: CGSize(width: 300, height: room),
            container: CGSize(width: 800, height: 500),
            margin: 8,
            gap: 4
        )
        #expect(origin.y == anchor.maxY + 4)
        let windowBottomLessMargin: CGFloat = 500 - 8
        #expect(origin.y + room == windowBottomLessMargin)
        // A window too short for any list still gets a few lines.
        #expect(FloatingPanelPlacement.roomBelow(anchor: anchor, containerMaxY: 60, gap: 4, margin: 8)
            == FloatingPanelPlacement.minimumScrollingHeight)
    }

    @Test func aCappedPanelStandsInsideTheWindow() {
        let container = CGSize(width: 800, height: 600)
        let height = FloatingPanelPlacement.maximumHeight(container: container.height, margin: 8)
        let placed = FloatingPanelPlacement.beside(
            anchor: CGRect(x: 0, y: 560, width: 240, height: 30),
            panelSize: CGSize(width: 400, height: height),
            placementHeight: height,
            container: container,
            style: .init(margin: 8, gap: 4, arrowInset: 12)
        )
        #expect(placed.origin.y >= 8)
        #expect(placed.origin.y + height <= container.height - 8)
    }
}

/// These cover the one horizontal clamp the floating panels and the command
/// palette's dropdown share.
struct FloatingPanelClampXTests {
    @Test func clampX_keepsAFittingPanelWhereItWasPreferred() {
        #expect(FloatingPanelPlacement.clampX(preferredX: 100, panelWidth: 240, containerWidth: 800, margin: 8) == 100)
    }

    @Test func clampX_pullsAPanelInsideEitherMargin() {
        #expect(FloatingPanelPlacement.clampX(preferredX: -20, panelWidth: 240, containerWidth: 800, margin: 8) == 8)
        #expect(FloatingPanelPlacement.clampX(preferredX: 700, panelWidth: 240, containerWidth: 800, margin: 8) == 552)
    }

    @Test func clampX_startsATooWidePanelAtTheLeftMargin() {
        #expect(FloatingPanelPlacement.clampX(preferredX: 100, panelWidth: 560, containerWidth: 500, margin: 8) == 8)
    }
}
