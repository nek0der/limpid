// PaneLayoutMirrorTests.swift
// Limpid — pins the geometry a tmux mirror tab derives from tmux's cell layout.

import CoreGraphics
import Foundation
import Testing
@testable import Limpid

@Suite("Pane layout, tmux mirror producer")
struct PaneLayoutMirrorTests {
    /// The measured defaults at 13pt on a 2x display (implementation log,
    /// which corrects design §15's row height): the divider is one cell.
    private let cell = CellSize(width: 6.5, height: 15.0)
    private let padding = OuterPadding(horizontal: 8, vertical: 2)
    private let ids: [String: UUID] = ["%0": UUID(), "%1": UUID(), "%2": UUID()]
    private func leafID(_ pane: String) -> UUID? {
        ids[pane]
    }

    // Recorded by `record_tmux.py` (tmux 3.7c, 100x30 window); the same
    // strings `TmuxLayoutTests` parse.
    private let single = "a87d,100x30,0,0,0"
    private let mainVertical = "77dd,100x30,0,0{50x30,0,0,0,49x30,51,0[49x15,51,0,1,49x14,51,16,2]}"
    private let threeSiblings = "14f1,100x30,0,0{33x30,0,0,0,33x30,34,0,1,32x30,68,0,2}"

    private func resolve(_ text: String) throws -> (TmuxLayout, PaneLayout) {
        let layout = try #require(TmuxLayout.parse(text))
        return (layout, PaneLayout.resolve(mirror: layout, cellSize: cell, padding: padding, leafID: leafID))
    }

    /// Convert a leaf rectangle back to tmux's cell rectangle: strip the
    /// padding on the edges the leaf carries, then divide by the cell.
    private func cells(of leaf: PaneLayout.Leaf) -> TmuxCellRect {
        var rect = leaf.rect
        if leaf.edges.contains(.left) {
            rect.origin.x += padding.horizontal
            rect.size.width -= padding.horizontal
        }
        if leaf.edges.contains(.right) {
            rect.size.width -= padding.horizontal
        }
        if leaf.edges.contains(.top) {
            rect.origin.y += padding.vertical
            rect.size.height -= padding.vertical
        }
        if leaf.edges.contains(.bottom) {
            rect.size.height -= padding.vertical
        }
        let width = rect.width / cell.width
        let height = rect.height / cell.height
        let x = (rect.minX - padding.horizontal) / cell.width
        let y = (rect.minY - padding.vertical) / cell.height
        #expect(width == width.rounded(), "width \(rect.width) is not whole cells")
        #expect(height == height.rounded(), "height \(rect.height) is not whole cells")
        return TmuxCellRect(width: Int(width.rounded()), height: Int(height.rounded()), x: Int(x.rounded()), y: Int(y.rounded()))
    }

    private func paneRects(_ node: TmuxLayoutNode) -> [String: TmuxCellRect] {
        switch node {
        case let .pane(id, rect):
            [id: rect]
        case let .sideBySide(_, children), let .stacked(_, children):
            children.reduce(into: [:]) { $0.merge(paneRects($1)) { first, _ in first } }
        }
    }

    @Test("a single pane fills cells × cell size plus the padding on all four edges")
    func single_isWindowPlusPadding() throws {
        let (_, layout) = try resolve(single)

        #expect(try layout.leaves == [
            .init(
                id: #require(ids["%0"]),
                rect: CGRect(x: 0, y: 0, width: 8 + 100 * 6.5 + 8, height: 2 + 30 * 15 + 2),
                edges: .all
            )
        ])
        #expect(layout.dividers.isEmpty)
    }

    @Test("main-vertical places each pane at tmux's cell offset and leaves the border cell as the divider")
    func mainVertical_matchesCellArithmetic() throws {
        let (_, layout) = try resolve(mainVertical)

        // %0: 50 columns from the left edge, full height.
        // %1: 49 columns from column 51 to the right edge, 15 rows from the top.
        // %2: same columns, 14 rows from row 16 to the bottom.
        #expect(try layout.leaves == [
            .init(id: #require(ids["%0"]), rect: CGRect(x: 0, y: 0, width: 8 + 50 * 6.5, height: 454), edges: [.top, .bottom, .left]),
            .init(
                id: #require(ids["%1"]),
                rect: CGRect(x: 8 + 51 * 6.5, y: 0, width: 49 * 6.5 + 8, height: 2 + 15 * 15),
                edges: [.top, .right]
            ),
            .init(
                id: #require(ids["%2"]),
                rect: CGRect(x: 8 + 51 * 6.5, y: 2 + 16 * 15, width: 49 * 6.5 + 8, height: 14 * 15 + 2),
                edges: [.bottom, .right]
            )
        ])
        #expect(layout.dividers == [
            .init(
                path: [],
                direction: .horizontal,
                rect: CGRect(x: 8 + 50 * 6.5, y: 0, width: 6.5, height: 454),
                ratio: 50.0 / 99.0,
                bounds: CGSize(width: 666, height: 454),
                origin: .zero
            ),
            .init(
                path: [.second],
                direction: .vertical,
                rect: CGRect(x: 8 + 51 * 6.5, y: 2 + 15 * 15, width: 49 * 6.5 + 8, height: 15),
                ratio: 15.0 / 29.0,
                bounds: CGSize(width: 49 * 6.5 + 8, height: 454),
                origin: CGPoint(x: 8 + 51 * 6.5, y: 0)
            )
        ])
    }

    @Test("every leaf converts back to the WxH,x,y tmux reported", arguments: [
        "a87d,100x30,0,0,0",
        "77dd,100x30,0,0{50x30,0,0,0,49x30,51,0[49x15,51,0,1,49x14,51,16,2]}",
        "14f1,100x30,0,0{33x30,0,0,0,33x30,34,0,1,32x30,68,0,2}"
    ])
    func leaves_roundTripToCells(text: String) throws {
        let (tmux, layout) = try resolve(text)
        let expected = paneRects(tmux.root)
        let byID = Dictionary(uniqueKeysWithValues: ids.map { ($0.value, $0.key) })

        #expect(layout.leaves.count == expected.count)
        for leaf in layout.leaves {
            let pane = try #require(byID[leaf.id])
            #expect(cells(of: leaf) == expected[pane], "pane \(pane)")
        }
    }

    @Test("the divider paths and leaf order are the ones the ratio producer assigns to the folded tree")
    func dividers_shareThePathsOfTheFoldedTree() throws {
        for text in [mainVertical, threeSiblings] {
            let (tmux, mirror) = try resolve(text)
            let folded = PaneLayout.resolve(
                tmux.paneNode { ids[$0, default: UUID()] },
                in: CGSize(width: 1000, height: 500),
                minPaneSize: 10
            )

            #expect(mirror.dividers.map(\.path) == folded.dividers.map(\.path))
            #expect(mirror.dividers.map(\.direction) == folded.dividers.map(\.direction))
            #expect(mirror.leaves.map(\.id) == folded.leaves.map(\.id))
        }
    }

    @Test("three siblings get two one-cell dividers, and the inner one spans only the remainder box")
    func threeSiblings_foldRight() throws {
        let (_, layout) = try resolve(threeSiblings)

        // Spelled out with a type so the literal arithmetic does not send
        // the type checker off; the values are cells × 6.5 plus padding.
        let dividerStarts: [CGFloat] = [8 + 33 * 6.5, 8 + 67 * 6.5]
        let dividerWidths: [CGFloat] = [6.5, 6.5]
        let boxOrigins: [CGFloat] = [0, 8 + 34 * 6.5]
        let boxWidths: [CGFloat] = [666, 66 * 6.5 + 8]
        #expect(layout.dividers.map(\.rect.minX) == dividerStarts)
        #expect(layout.dividers.map(\.rect.width) == dividerWidths)
        #expect(layout.dividers.map(\.origin.x) == boxOrigins)
        #expect(layout.dividers.map(\.bounds.width) == boxWidths)
    }

    @Test("a pane the tab has no leaf for is skipped without disturbing the others")
    func missingLeaf_isSkipped() throws {
        let tmux = try #require(TmuxLayout.parse(mainVertical))
        let layout = PaneLayout.resolve(mirror: tmux, cellSize: cell, padding: padding) { pane in
            pane == "%1" ? nil : ids[pane]
        }

        #expect(try layout.leaves.map(\.id) == [#require(ids["%0"]), #require(ids["%2"])])
        #expect(layout.dividers.count == 2)
    }

    @Test("the window grid is the whole cells left once the outer padding is removed")
    func mirrorGrid_floorsToWholeCells() {
        /// 1000 − 16 = 984 → 151.38 columns; 600 − 4 = 596 → 39.73 rows.
        func grid(_ width: CGFloat, _ height: CGFloat, cell: CellSize? = nil) -> (columns: Int, rows: Int) {
            PaneLayout.mirrorGrid(areaSize: CGSize(width: width, height: height), cellSize: cell ?? self.cell, padding: padding)
        }
        #expect(grid(1000, 600) == (151, 39))
        // An exact fit stays exact: what the producer sizes a one-pane window to.
        #expect(grid(151 * 6.5 + 16, 41 * 15 + 4) == (151, 41))
        // Half a point short of a column drops it.
        #expect(grid(151 * 6.5 + 15.5, 600).columns == 150)
        // Nothing fits: report nothing rather than a negative grid.
        #expect(grid(10, 1) == (0, 0))
        #expect(grid(0, 0, cell: CellSize(width: 0, height: 0)) == (0, 0))
    }
}
