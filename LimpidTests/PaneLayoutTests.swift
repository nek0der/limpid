// PaneLayoutTests.swift
// Limpid — pins the leaf and divider geometry the pane renderer places.

import CoreGraphics
import Foundation
import Testing
@testable import Limpid

@Suite("Pane layout")
struct PaneLayoutTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    private func split(_ direction: SplitDirection, _ ratio: Double, _ first: PaneNode, _ second: PaneNode) -> PaneNode {
        .split(PaneSplit(direction: direction, ratio: ratio, first: first, second: second))
    }

    @Test("a lone leaf fills the bounds and touches every edge")
    func singleLeaf_fillsBounds() {
        let layout = PaneLayout.resolve(.leaf(id: a), in: CGSize(width: 100, height: 50), minPaneSize: 10)

        #expect(layout.leaves == [.init(id: a, rect: CGRect(x: 0, y: 0, width: 100, height: 50), edges: .all)])
        #expect(layout.dividers.isEmpty)
    }

    @Test("a side-by-side split hands each child extent × ratio minus half the divider")
    func horizontalSplit_matchesRendererArithmetic() {
        let layout = PaneLayout.resolve(
            split(.horizontal, 0.5, .leaf(id: a), .leaf(id: b)),
            in: CGSize(width: 100, height: 50),
            minPaneSize: 10
        )

        #expect(layout.leaves == [
            .init(id: a, rect: CGRect(x: 0, y: 0, width: 47, height: 50), edges: [.top, .bottom, .left]),
            .init(id: b, rect: CGRect(x: 53, y: 0, width: 47, height: 50), edges: [.top, .bottom, .right])
        ])
        #expect(layout.dividers == [
            .init(
                path: [],
                direction: .horizontal,
                rect: CGRect(x: 47, y: 0, width: 6, height: 50),
                ratio: 0.5,
                bounds: CGSize(width: 100, height: 50),
                origin: .zero
            )
        ])
    }

    @Test("a nested split is resolved inside its parent's slot, with a path and origin the drag can use")
    func nestedSplit_isPlacedInsideParentSlot() {
        // tmux `main-vertical`: one pane on the left, two stacked on the right.
        let layout = PaneLayout.resolve(
            split(.horizontal, 0.5, .leaf(id: a), split(.vertical, 0.5, .leaf(id: b), .leaf(id: c))),
            in: CGSize(width: 100, height: 50),
            minPaneSize: 10
        )

        #expect(layout.leaves == [
            .init(id: a, rect: CGRect(x: 0, y: 0, width: 47, height: 50), edges: [.top, .bottom, .left]),
            .init(id: b, rect: CGRect(x: 53, y: 0, width: 47, height: 22), edges: [.top, .right]),
            .init(id: c, rect: CGRect(x: 53, y: 28, width: 47, height: 22), edges: [.bottom, .right])
        ])
        #expect(layout.dividers.map(\.path) == [[], [.second]])
        let inner = layout.dividers[1]
        #expect(inner.direction == .vertical)
        #expect(inner.rect == CGRect(x: 53, y: 22, width: 47, height: 6))
        #expect(inner.origin == CGPoint(x: 53, y: 0))
        #expect(inner.bounds == CGSize(width: 47, height: 50))
    }

    @Test("when both minimums cannot fit, the space is shared proportionally instead of inverting the clamp")
    func tooSmall_sharesSpaceProportionally() {
        let layout = PaneLayout.resolve(
            split(.horizontal, 0.9, .leaf(id: a), .leaf(id: b)),
            in: CGSize(width: 20, height: 10),
            minPaneSize: 10
        )

        // `PaneSplit.resolvedRatio` falls back to 0.5 here: 14pt of usable
        // width split evenly, so neither side collapses to zero.
        #expect(layout.leaves.map(\.rect.width) == [7, 7])
        #expect(layout.leaves[1].rect.minX == 13)
    }

    @Test("a stacked split at the root places the divider band horizontally")
    func verticalSplitAtRoot_placesHorizontalBand() {
        let layout = PaneLayout.resolve(
            split(.vertical, 0.5, .leaf(id: a), .leaf(id: b)),
            in: CGSize(width: 100, height: 50),
            minPaneSize: 10
        )

        #expect(layout.leaves.map(\.rect) == [
            CGRect(x: 0, y: 0, width: 100, height: 22),
            CGRect(x: 0, y: 28, width: 100, height: 22)
        ])
        #expect(layout.dividers.map(\.rect) == [CGRect(x: 0, y: 22, width: 100, height: 6)])
        #expect(layout.leaves.map(\.edges) == [[.top, .left, .right], [.bottom, .left, .right]])
    }

    @Test("a ratio below the first child's minimum is clamped up to it, not left to starve the pane")
    func ratioBelowMinimum_isClampedToTheFloor() {
        let layout = PaneLayout.resolve(
            split(.horizontal, 0.05, .leaf(id: a), .leaf(id: b)),
            in: CGSize(width: 100, height: 50),
            minPaneSize: 10
        )

        // lower bound = (10 + 3) / 100 = 0.13 → first = 100 × 0.13 − 3 = 10pt.
        #expect(layout.leaves[0].rect.width == 10)
        #expect(layout.leaves[1].rect.minX == 16)
    }

    @Test("a nested split's own divider counts toward the minimum its parent must reserve for it")
    func nestedMinimum_includesTheInnerDivider() {
        // Outer split must leave the inner H(B, C) at least 10 + 6 + 10 = 26pt.
        // With 40pt total that cannot coexist with A's 10pt, so the outer
        // split falls back to a proportional share: 34pt usable, A gets
        // 10 / 36 of it.
        let layout = PaneLayout.resolve(
            split(.horizontal, 0.5, .leaf(id: a), split(.horizontal, 0.5, .leaf(id: b), .leaf(id: c))),
            in: CGSize(width: 40, height: 50),
            minPaneSize: 10
        )

        let expectedFirst = 34.0 * 10.0 / 36.0
        #expect(abs(layout.leaves[0].rect.width - expectedFirst) < 0.001)
        #expect(layout.dividers.map(\.path) == [[], [.second]])
    }

    @Test("zero bounds produce empty rectangles, never negative ones")
    func zeroBounds_doNotGoNegative() {
        let layout = PaneLayout.resolve(
            split(.horizontal, 0.5, .leaf(id: a), split(.vertical, 0.5, .leaf(id: b), .leaf(id: c))),
            in: .zero,
            minPaneSize: 10
        )

        for leaf in layout.leaves {
            #expect(leaf.rect.width >= 0)
            #expect(leaf.rect.height >= 0)
        }
        for divider in layout.dividers {
            #expect(divider.rect.width >= 0)
            #expect(divider.rect.height >= 0)
        }
    }

    @Test("an edge counts as outer within half a point of the bounds and not beyond")
    func edges_toleranceIsHalfAPoint() {
        let outer = CGSize(width: 100, height: 50)
        #expect(PaneLayout.edges(of: CGRect(x: 0, y: 0, width: 99.6, height: 50), within: outer) == .all)
        #expect(PaneLayout.edges(of: CGRect(x: 0, y: 0, width: 99.4, height: 50), within: outer) == [.top, .bottom, .left])
        #expect(PaneLayout.edges(of: CGRect(x: 0.4, y: 0.6, width: 10, height: 10), within: outer) == [.left])
    }

    @Test("divider paths record the branch taken at every depth")
    func dividerPaths_areDepthFirst() {
        let d = UUID()
        let layout = PaneLayout.resolve(
            split(.vertical, 0.5, .leaf(id: a), split(.horizontal, 0.5, .leaf(id: b), split(.vertical, 0.5, .leaf(id: c), .leaf(id: d)))),
            in: CGSize(width: 200, height: 200),
            minPaneSize: 10
        )

        #expect(layout.dividers.map(\.path) == [[], [.second], [.second, .second]])
        #expect(layout.leaves.map(\.id) == [a, b, c, d])
    }
}
