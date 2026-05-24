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
