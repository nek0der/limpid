// PaneMinimumSizeTests.swift
// Limpid — pins how the split floor is derived from settings and that its
// width and height each bound only their own axis.

import CoreGraphics
import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("PaneMinimumSize")
struct PaneMinimumSizeTests {

    // MARK: - Derivation

    @Test func resolved_headersOff_isUniform() {
        let size = PaneMinimumSize.resolved(minPaneSize: 80, showsHeaders: false)
        #expect(size == PaneMinimumSize(uniform: 80))
    }

    @Test func resolved_headersOn_addsHeaderHeightAndKeepsUserWidth() {
        let size = PaneMinimumSize.resolved(minPaneSize: 80, showsHeaders: true, headerHeight: 24)
        #expect(size.width == 80)
        #expect(size.height == 104)
    }

    @Test func resolved_defaultsReadTheHeaderLayout() {
        let size = PaneMinimumSize.resolved(minPaneSize: 60, showsHeaders: true)
        #expect(size.width == 60)
        #expect(size.height == 60 + LimpidLayout.paneHeaderHeight)
    }

    /// The width minimum is the user's number as-is only because no number
    /// they can pick is narrower than the header's glyph and menu. Pinned
    /// here so widening the header or lowering the range cannot quietly
    /// start cutting the menu off.
    @Test func minPaneSizeRange_startsAtTheHeadersNarrowestWidth() {
        #expect(CGFloat(TerminalSettings.minPaneSizeRange.lowerBound) >= PaneHeaderMetrics.minimumWidth)
    }

    @Test func terminalSettings_followsTheHeaderToggle() {
        var settings = TerminalSettings()
        settings.minPaneSize = 100
        settings.showsSplitPaneHeaders = true
        #expect(settings.paneMinimumSize.height == 100 + LimpidLayout.paneHeaderHeight)
        settings.showsSplitPaneHeaders = false
        #expect(settings.paneMinimumSize == PaneMinimumSize(uniform: 100))
    }

    @Test func extent_horizontalIsWidthAndVerticalIsHeight() {
        let size = PaneMinimumSize(width: 60, height: 120)
        #expect(size.extent(along: .horizontal) == 60)
        #expect(size.extent(along: .vertical) == 120)
        #expect(size.isEnforced)
        #expect(!PaneMinimumSize.zero.isEnforced)
    }

    // MARK: - Per-axis application

    private static func twoPaneTree(_ direction: SplitDirection) -> SplitTree {
        let first = UUID()
        return SplitTree(
            root: .split(PaneSplit(
                direction: direction,
                ratio: 0.5,
                first: .leaf(id: first),
                second: .leaf(id: UUID())
            )),
            focusedLeafID: first
        )
    }

    /// Width of the first pane once the divider is pushed as far toward it
    /// as the floor allows.
    private static func firstExtentAfterCollapsing(
        _ direction: SplitDirection,
        minimum: PaneMinimumSize
    ) throws -> CGFloat {
        let bounds = CGSize(width: 400, height: 400)
        let resized = twoPaneTree(direction).resize(splitAt: [], by: -1000, bounds: bounds, minSize: minimum)
        guard case let .split(data) = try #require(resized.root) else {
            Issue.record("expected a split")
            return 0
        }
        return CGFloat(data.ratio) * 400 - PaneSplit.dividerThickness / 2
    }

    @Test func resize_stopsAtTheMinimumForItsOwnAxis() throws {
        let minimum = PaneMinimumSize(width: 60, height: 150)
        let width = try Self.firstExtentAfterCollapsing(.horizontal, minimum: minimum)
        let height = try Self.firstExtentAfterCollapsing(.vertical, minimum: minimum)
        // Side by side, the width floor stops the drag and the taller height
        // floor plays no part; stacked, the height floor does.
        #expect(abs(width - 60) < 0.5)
        #expect(abs(height - 150) < 0.5)
    }

    @Test func minimumExtent_takesEachAxisFloor() {
        let minimum = PaneMinimumSize(width: 60, height: 150)
        let row = Self.twoPaneTree(.horizontal)
        #expect(row.root?.minimumExtent(along: .horizontal, leafMinimum: minimum) == 120 + PaneSplit.dividerThickness)
        #expect(row.root?.minimumExtent(along: .vertical, leafMinimum: minimum) == 150)
    }

    @Test func splitPreflight_refusesOnlyTheAxisBelowItsMinimum() {
        let leaf = UUID()
        let tree = SplitTree(leafID: leaf)
        let minimum = PaneMinimumSize(width: 60, height: 150)
        let area = CGSize(width: 400, height: 250)
        // Two stacked panes need 300pt of height plus the divider; two side by
        // side need only 120pt of width.
        #expect(!PaneActions.hasRoomToSplit(
            tree: tree,
            paneID: leaf,
            direction: .vertical,
            availableSize: area,
            minPaneSize: minimum
        ))
        #expect(PaneActions.hasRoomToSplit(
            tree: tree,
            paneID: leaf,
            direction: .horizontal,
            availableSize: area,
            minPaneSize: minimum
        ))
    }
}
