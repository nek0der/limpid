// SplitTreeTests.swift
// Pure-data tests for the SplitTree pane layout primitive. No AppKit
// dependency — the tree is a value type and tests run in-process.

import Foundation
import Testing
@testable import Limpid

@Suite("SplitTree")
struct SplitTreeTests {

    // MARK: - Single-leaf basics

    @Test("a tree built from one leaf reports that leaf as focused")
    func singleLeafTree_hasOneLeafAndItIsFocused() {
        let leaf = UUID()
        let tree = SplitTree(leafID: leaf)
        #expect(tree.allLeafIDs() == [leaf])
        #expect(tree.focusedLeafID == leaf)
    }

    // MARK: - Insertion

    @Test(
        "inserting a leaf in either direction yields both leaves",
        arguments: [SplitDirection.horizontal, SplitDirection.vertical]
    )
    func insert_anyDirection_yieldsBothLeaves(direction: SplitDirection) {
        let a = UUID()
        let b = UUID()
        let result = SplitTree(leafID: a).insert(at: a, direction: direction, newID: b)
        #expect(Set(result.tree.allLeafIDs()) == [a, b])
    }

    @Test("insert at an unknown leaf is a no-op")
    func insert_atUnknownLeaf_returnsTreeUnchanged() {
        let a = UUID()
        let bogus = UUID()
        let new = UUID()
        let result = SplitTree(leafID: a).insert(at: bogus, direction: .horizontal, newID: new)
        #expect(result.tree.allLeafIDs() == [a])
    }

    // MARK: - Removal

    @Test("removing one of two leaves collapses to the survivor and hops focus")
    func remove_oneOfTwoLeaves_collapsesAndHopsFocus() {
        let a = UUID()
        let b = UUID()
        let split = SplitTree(leafID: a).insert(at: a, direction: .horizontal, newID: b).tree
        let removed = split.remove(b)
        #expect(removed.tree.allLeafIDs() == [a])
        #expect(removed.focusTarget == a)
    }

    @Test("removing the last leaf produces an empty tree")
    func remove_lastLeaf_producesEmptyTree() {
        let only = UUID()
        let removed = SplitTree(leafID: only).remove(only)
        #expect(removed.tree.allLeafIDs().isEmpty)
    }

    // MARK: - Resize ratio clamping

    // MARK: - Equalize

    @Test("equalize resets every split ratio to 0.5 while preserving leaves and focus")
    func equalize_nestedSplits_resetsAllRatiosToHalf() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        // Build a→b horizontal split, then b→c vertical split, then drag
        // both dividers off-center so equalize has something to reset.
        let one = SplitTree(leafID: a).insert(at: a, direction: .horizontal, newID: b).tree
        let two = one.insert(at: b, direction: .vertical, newID: c).tree
        let bounds = CGSize(width: 800, height: 600)
        let dragged = two
            .resize(node: a, by: 200, direction: .horizontal, bounds: bounds, minSize: 80)
            .resize(node: b, by: 150, direction: .vertical, bounds: bounds, minSize: 80)

        let leveled = dragged.equalize()

        /// Walk the tree and assert every split is back at 0.5.
        func collectRatios(_ node: SplitNode) -> [Double] {
            switch node {
            case .leaf: []
            case let .split(data):
                [data.ratio] + collectRatios(data.first) + collectRatios(data.second)
            }
        }
        let ratios = leveled.root.map(collectRatios) ?? []
        #expect(ratios.count == 2)
        #expect(ratios.allSatisfy { $0 == 0.5 })
        #expect(Set(leveled.allLeafIDs()) == [a, b, c])
        #expect(leveled.focusedLeafID == dragged.focusedLeafID)
    }

    @Test("equalize on an empty tree is a no-op")
    func equalize_emptyTree_remainsEmpty() {
        let empty = SplitTree()
        #expect(empty.equalize().root == nil)
    }

    // MARK: - Directional neighbor lookup

    @Test("neighborLeaf walks the immediate sibling of a single horizontal split")
    func neighborLeaf_horizontalSplit_findsLeftAndRight() {
        let a = UUID()
        let b = UUID()
        let tree = SplitTree(leafID: a).insert(at: a, direction: .horizontal, newID: b).tree
        // `.horizontal` direction means a divider runs vertically and `a`
        // sits on the left of `b`.
        #expect(tree.neighborLeaf(of: a, direction: .right) == b)
        #expect(tree.neighborLeaf(of: b, direction: .left) == a)
        #expect(tree.neighborLeaf(of: a, direction: .up) == nil)
        #expect(tree.neighborLeaf(of: a, direction: .down) == nil)
    }

    @Test("neighborLeaf walks the immediate sibling of a single vertical split")
    func neighborLeaf_verticalSplit_findsUpAndDown() {
        let a = UUID()
        let b = UUID()
        let tree = SplitTree(leafID: a).insert(at: a, direction: .vertical, newID: b).tree
        // `.vertical` stacks the panes — `a` on top.
        #expect(tree.neighborLeaf(of: a, direction: .down) == b)
        #expect(tree.neighborLeaf(of: b, direction: .up) == a)
        #expect(tree.neighborLeaf(of: a, direction: .left) == nil)
    }

    @Test("neighborLeaf finds the orthogonal neighbor of each corner in a 2x2 grid")
    func neighborLeaf_grid2x2_findsOrthogonalNeighbors() {
        // Build a 2x2 layout:
        //  +----+----+
        //  | a  | b  |
        //  +----+----+
        //  | c  | d  |
        //  +----+----+
        // Top horizontal split, then each top leaf split vertically.
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        let r1 = SplitTree(leafID: a).insert(at: a, direction: .horizontal, newID: b).tree
        let r2 = r1.insert(at: a, direction: .vertical, newID: c).tree
        let tree = r2.insert(at: b, direction: .vertical, newID: d).tree

        #expect(tree.neighborLeaf(of: a, direction: .right) == b)
        #expect(tree.neighborLeaf(of: a, direction: .down) == c)
        #expect(tree.neighborLeaf(of: d, direction: .left) == c)
        #expect(tree.neighborLeaf(of: d, direction: .up) == b)
    }

    @Test("neighborLeaf picks the immediately adjacent column in a 3-column row")
    func neighborLeaf_threeColumn_picksImmediateNeighbor() {
        // a | b | c, all full-height. Left from c must land on b, never a.
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let one = SplitTree(leafID: a).insert(at: a, direction: .horizontal, newID: b).tree
        let tree = one.insert(at: b, direction: .horizontal, newID: c).tree

        #expect(tree.neighborLeaf(of: c, direction: .left) == b)
        #expect(tree.neighborLeaf(of: b, direction: .left) == a)
        #expect(tree.neighborLeaf(of: a, direction: .right) == b)
        #expect(tree.neighborLeaf(of: b, direction: .right) == c)
    }

    @Test("neighborLeaf returns nil at the edge of a single-leaf tree")
    func neighborLeaf_singleLeaf_returnsNilInAllDirections() {
        let only = UUID()
        let tree = SplitTree(leafID: only)
        for d in [SpatialDirection.left, .right, .up, .down] {
            #expect(tree.neighborLeaf(of: only, direction: d) == nil)
        }
    }

    // MARK: - Resize ratio clamping

    @Test("resize clamps absurd drag deltas to a valid ratio without crashing")
    func resize_oversizedDelta_keepsBothLeavesIntact() {
        let a = UUID()
        let b = UUID()
        let tree = SplitTree(leafID: a).insert(at: a, direction: .horizontal, newID: b).tree
        let resized = tree.resize(
            node: a,
            by: 99999,
            direction: .horizontal,
            bounds: CGSize(width: 800, height: 600),
            minSize: 80
        )
        #expect(Set(resized.allLeafIDs()) == [a, b])
    }
}
