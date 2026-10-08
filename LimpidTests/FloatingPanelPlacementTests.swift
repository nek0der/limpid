// FloatingPanelPlacementTests.swift
// Limpid — where a floating panel goes relative to its anchor, and where its
// arrow points. Shared by the pane rename field, the prompt cache panel and
// the container color picker.

import CoreGraphics
import Testing
@testable import Limpid

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
        #expect(arrow(anchor: anchor, panelAt: CGPoint(x: 258, y: 66)) == .init(edge: .top, x: 150))
    }

    @Test func aboveTheAnchor_pointsDown() {
        let anchor = CGRect(x: 400, y: 600, width: 16, height: 16)
        let placement = arrow(anchor: anchor, panelAt: CGPoint(x: 258, y: 600 - 13 - height))
        #expect(placement?.edge == .bottom)
        #expect(placement?.x == 150)
    }

    @Test func panelClampedToTheWindow_stillPointsAtTheAnchor() {
        // An anchor near the window's right edge: the panel slid left, so the
        // arrow moves right within it, as far as the corner allows.
        let anchor = CGRect(x: 772, y: 40, width: 16, height: 16)
        #expect(arrow(anchor: anchor, panelAt: CGPoint(x: 492, y: 66)) == .init(edge: .top, x: width - inset))
    }

    @Test func anchorPastTheLeadingCorner_keepsTheArrowOffTheRounding() {
        // A sidebar color dot, with the panel pulled in to the window margin.
        let anchor = CGRect(x: 0, y: 40, width: 16, height: 16)
        #expect(arrow(anchor: anchor, panelAt: CGPoint(x: 8, y: 66))?.x == inset)
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
        #expect(placement?.x == 20)
    }
}

struct FloatingPanelAnchorPressTests {
    /// An anchor just above a 100-point-tall panel, in the panel's own
    /// coordinates, which run down from its top.
    private let anchor = CGRect(x: 40, y: -20, width: 16, height: 16)

    @Test func unflippedView_turnsThePressOverBeforeComparing() {
        // 110 points up from the bottom of a 100-point view is 10 above its
        // top: -10 in the panel's coordinates, on the anchor.
        #expect(FloatingPanelEventMonitor.isPress(
            at: CGPoint(x: 48, y: 110),
            onAnchor: anchor,
            panelHeight: 100,
            isFlipped: false
        ))
        #expect(!FloatingPanelEventMonitor.isPress(
            at: CGPoint(x: 48, y: -10),
            onAnchor: anchor,
            panelHeight: 100,
            isFlipped: false
        ), "unturned, the same numbers would hit")
    }

    @Test func flippedView_comparesAsIs() {
        #expect(FloatingPanelEventMonitor.isPress(
            at: CGPoint(x: 48, y: -10),
            onAnchor: anchor,
            panelHeight: 100,
            isFlipped: true
        ))
        #expect(!FloatingPanelEventMonitor.isPress(
            at: CGPoint(x: 200, y: -10),
            onAnchor: anchor,
            panelHeight: 100,
            isFlipped: true
        ))
    }
}

/// The two ways Limpid's panels hang, as hosts lay them out: the presets,
/// with their sizes from `LimpidLayout`. Where the origin rule itself lands
/// is `FloatingPanelOriginTests`; these check what each preset adds.
@MainActor
struct FloatingPanelLayoutTests {
    private let container = CGSize(width: 800, height: 600)
    private let panel = CGSize(width: LimpidLayout.paneRenamePanelWidth, height: 70)

    private func layout(
        _ anchor: CGRect,
        style: FloatingPanelPlacement.Style
    ) -> (origin: CGPoint, arrow: FloatingPanelPlacement.Arrow?) {
        FloatingPanelPlacement.layout(
            anchor: anchor,
            panelSize: panel,
            container: container,
            margin: LimpidLayout.floatingPanelWindowMargin,
            style: style
        )
    }

    @Test func underHeader_hangsCloseUnderTheHeadersLeadingEdgeWithNoArrow() {
        let header = CGRect(x: 100, y: 200, width: 160, height: 24)
        let placed = layout(header, style: .underHeader)
        #expect(placed.origin.x == header.minX)
        #expect(placed.origin.y == header.maxY + LimpidLayout.paneRenamePanelAnchorGap)
        #expect(placed.arrow == nil)
    }

    @Test func underHeader_nearTheBottom_sitsAboveWithNoArrow() {
        let header = CGRect(x: 100, y: 540, width: 160, height: 24)
        let placed = layout(header, style: .underHeader)
        #expect(placed.origin.y == header.minY - LimpidLayout.paneRenamePanelAnchorGap - panel.height)
        #expect(placed.arrow == nil)
    }

    @Test func arrowed_centersOnTheAnchorAndPointsBackAtIt() throws {
        let dot = CGRect(x: 300, y: 200, width: 10, height: 10)
        let placed = layout(dot, style: .arrowed)
        #expect(placed.origin.y == dot.maxY + LimpidLayout.floatingPanelArrowAnchorGap)
        let arrow = try #require(placed.arrow)
        #expect(arrow.edge == .top)
        #expect(placed.origin.x + arrow.x == dot.midX)
    }

    @Test func arrowed_nearTheBottom_pointsDown() throws {
        let dot = CGRect(x: 300, y: 560, width: 10, height: 10)
        let arrow = try #require(layout(dot, style: .arrowed).arrow)
        #expect(arrow.edge == .bottom)
    }
}
