// TmuxLayoutTests.swift
// Limpid — pins layout-string parsing and the right fold onto the split tree, using layouts a real tmux emitted.

import CoreGraphics
import Foundation
import Testing
@testable import Limpid

@Suite("tmux layout")
struct TmuxLayoutTests {
    /// Stable ids for `%0` … `%2` so folded trees can be compared.
    private let ids: [String: UUID] = ["%0": UUID(), "%1": UUID(), "%2": UUID()]
    private func leafID(_ pane: String) -> UUID {
        ids[pane, default: UUID()]
    }

    // Recorded by `record_tmux.py` (tmux 3.7c, 100x30 window).
    private let single = "a87d,100x30,0,0,0"
    private let sideBySide = "6b8b,100x30,0,0{50x30,0,0,0,49x30,51,0,1}"
    private let mainVertical = "77dd,100x30,0,0{50x30,0,0,0,49x30,51,0[49x15,51,0,1,49x14,51,16,2]}"
    private let threeSiblings = "14f1,100x30,0,0{33x30,0,0,0,33x30,34,0,1,32x30,68,0,2}"

    @Test("a single pane parses to one leaf covering the window")
    func parse_singlePane() throws {
        let layout = try #require(TmuxLayout.parse(single))
        #expect(layout.checksum == "a87d")
        #expect(layout.root == .pane(id: "%0", rect: TmuxCellRect(width: 100, height: 30, x: 0, y: 0)))
    }

    @Test("side-by-side panes parse to one split whose gap is tmux's one-cell border")
    func parse_sideBySide() throws {
        let layout = try #require(TmuxLayout.parse(sideBySide))
        #expect(layout.root == .split(
            direction: .horizontal,
            rect: TmuxCellRect(width: 100, height: 30, x: 0, y: 0),
            gap: TmuxCellRect(width: 1, height: 30, x: 50, y: 0),
            first: .pane(id: "%0", rect: TmuxCellRect(width: 50, height: 30, x: 0, y: 0)),
            second: .pane(id: "%1", rect: TmuxCellRect(width: 49, height: 30, x: 51, y: 0))
        ))
        #expect(layout.root.paneIDs == ["%0", "%1"])
    }

    @Test("main-vertical nests a vertical split inside a horizontal one")
    func parse_mainVertical() throws {
        let layout = try #require(TmuxLayout.parse(mainVertical))
        guard case let .split(.horizontal, _, _, _, second) = layout.root,
              case let .split(.vertical, rect, gap, first, last) = second
        else {
            Issue.record("expected {pane, [pane, pane]}")
            return
        }
        #expect(rect == TmuxCellRect(width: 49, height: 30, x: 51, y: 0))
        #expect(gap == TmuxCellRect(width: 49, height: 1, x: 51, y: 15))
        #expect(first.rect.height == 15)
        #expect(last.rect.height == 14)
        #expect(layout.root.paneIDs == ["%0", "%1", "%2"])
    }

    @Test("tmux flattens same-axis splits; three siblings fold right into a remainder box that starts at the second")
    func parse_threeSiblings_foldsRight() throws {
        let layout = try #require(TmuxLayout.parse(threeSiblings))
        #expect(layout.root == .split(
            direction: .horizontal,
            rect: TmuxCellRect(width: 100, height: 30, x: 0, y: 0),
            gap: TmuxCellRect(width: 1, height: 30, x: 33, y: 0),
            first: .pane(id: "%0", rect: TmuxCellRect(width: 33, height: 30, x: 0, y: 0)),
            second: .split(
                direction: .horizontal,
                rect: TmuxCellRect(width: 66, height: 30, x: 34, y: 0),
                gap: TmuxCellRect(width: 1, height: 30, x: 67, y: 0),
                first: .pane(id: "%1", rect: TmuxCellRect(width: 33, height: 30, x: 34, y: 0)),
                second: .pane(id: "%2", rect: TmuxCellRect(width: 32, height: 30, x: 68, y: 0))
            )
        ))
        #expect(layout.root.node(at: [.second, .first]) == .pane(
            id: "%1",
            rect: TmuxCellRect(width: 33, height: 30, x: 34, y: 0)
        ))
        #expect(layout.root.node(at: [.first, .first]) == nil)
    }

    @Test("malformed layout strings are rejected rather than partially accepted")
    func parse_rejectsMalformedInput() {
        #expect(TmuxLayout.parse("") == nil)
        #expect(TmuxLayout.parse("a87d") == nil)
        #expect(TmuxLayout.parse("a87d,100x30,0,0") == nil)
        #expect(TmuxLayout.parse("a87d,100x30,0,0{50x30,0,0,0") == nil)
        #expect(TmuxLayout.parse("a87d,100x30,0,0,0,junk") == nil)
        #expect(TmuxLayout.parse("a87d,100x30,0,0{}") == nil)
    }

    // MARK: - Fold onto PaneNode

    @Test("a two-pane row folds to one split whose ratio is the first pane's share excluding the border cell")
    func fold_sideBySide_ratioExcludesBorder() throws {
        let node = try #require(TmuxLayout.parse(sideBySide)).paneNode(leafID: leafID)
        guard case let .split(split) = node else {
            Issue.record("expected a split")
            return
        }
        #expect(split.direction == .horizontal)
        #expect(split.first == .leaf(id: leafID("%0")))
        #expect(split.second == .leaf(id: leafID("%1")))
        #expect(abs(split.ratio - 50.0 / 99.0) < 1e-12)
    }

    @Test("main-vertical folds to a horizontal split with a vertical split on the right")
    func fold_mainVertical() throws {
        let node = try #require(TmuxLayout.parse(mainVertical)).paneNode(leafID: leafID)
        guard case let .split(outer) = node, case let .split(inner) = outer.second else {
            Issue.record("expected H(a, V(b, c))")
            return
        }
        #expect(outer.direction == .horizontal)
        #expect(inner.direction == .vertical)
        #expect(inner.first == .leaf(id: leafID("%1")))
        #expect(inner.second == .leaf(id: leafID("%2")))
        #expect(abs(inner.ratio - 15.0 / 29.0) < 1e-12)
    }

    @Test("three siblings fold to the right, and the layout assigns the divider paths [] and [.second]")
    func fold_threeSiblings_isRightAssociative() throws {
        let node = try #require(TmuxLayout.parse(threeSiblings)).paneNode(leafID: leafID)
        guard case let .split(outer) = node, case let .split(inner) = outer.second else {
            Issue.record("expected H(a, H(b, c))")
            return
        }
        #expect(outer.first == .leaf(id: leafID("%0")))
        #expect(inner.first == .leaf(id: leafID("%1")))
        #expect(inner.second == .leaf(id: leafID("%2")))
        // Outer: 33 of (33 + 66); the remainder box starts at x = 34.
        #expect(abs(outer.ratio - 33.0 / 99.0) < 1e-12)
        // Inner: 33 of (33 + 32).
        #expect(abs(inner.ratio - 33.0 / 65.0) < 1e-12)

        let layout = PaneLayout.resolve(node, in: CGSize(width: 1000, height: 300), minPaneSize: 10)
        #expect(layout.dividers.map(\.path) == [[], [.second]])
        #expect(layout.leaves.map(\.id) == [leafID("%0"), leafID("%1"), leafID("%2")])
    }

    @Test("folding the same layout twice yields the same tree, so divider paths are stable across %layout-change")
    func fold_isDeterministic() throws {
        let first = try #require(TmuxLayout.parse(mainVertical)).paneNode(leafID: leafID)
        let second = try #require(TmuxLayout.parse(mainVertical)).paneNode(leafID: leafID)
        #expect(first == second)
    }

    // MARK: - Bounds

    // The string arrives on a stream we do not write, and it is parsed on
    // the routing queue, so every one of these would take the app down
    // rather than leave a tab unpainted.

    @Test("a field longer than a window's cell coordinates fails instead of overflowing")
    func parse_overlongField_fails() {
        let digits = String(repeating: "9", count: TmuxLayout.Bound.digitCount + 1)
        #expect(TmuxLayout.parse("a87d,\(digits)x30,0,0,0") == nil)
        #expect(TmuxLayout.parse("a87d,100x30,0,0,\(digits)") == nil)
        // One digit under the bound still parses, so the bound is not in
        // the way of anything tmux can describe.
        let widest = String(repeating: "9", count: TmuxLayout.Bound.digitCount)
        #expect(TmuxLayout.parse("a87d,\(widest)x30,0,0,0") != nil)
    }

    @Test("nesting past the bound fails, and nesting up to it parses")
    func parse_deepNesting_failsPastTheBound() {
        #expect(TmuxLayout.parse(nested(depth: TmuxLayout.Bound.depth - 1)) != nil)
        #expect(TmuxLayout.parse(nested(depth: TmuxLayout.Bound.depth + 2)) == nil)
        // Far past it, which is what a stream that is not tmux would send.
        #expect(TmuxLayout.parse(nested(depth: 200_000)) == nil)
    }

    /// `{100x30,0,0{100x30,0,0{…,0}}}`: one container per level, each with
    /// a single child, ending in a pane.
    private func nested(depth: Int) -> String {
        let box = "100x30,0,0"
        return "a87d," + String(repeating: "\(box){", count: depth) + "\(box),0" + String(repeating: "}", count: depth)
    }

    @Test("more panes than a window could hold fails, and a wide flat container folds without recursing")
    func parse_paneCount_isBounded() throws {
        let wide = try #require(TmuxLayout.parse(flat(panes: TmuxLayout.Bound.paneCount)))
        #expect(wide.root.paneIDs.count == TmuxLayout.Bound.paneCount)
        #expect(wide.root.paneRects.count == TmuxLayout.Bound.paneCount)
        #expect(TmuxLayout.parse(flat(panes: TmuxLayout.Bound.paneCount + 1)) == nil)
    }

    /// One horizontal container of `panes` one-cell panes, which is the
    /// shape that folds to a tree as deep as it is wide.
    private func flat(panes: Int) -> String {
        let children = (0..<panes).map { "1x30,\($0 * 2),0,\($0)" }.joined(separator: ",")
        return "a87d,\(panes * 2)x30,0,0{\(children)}"
    }
}
