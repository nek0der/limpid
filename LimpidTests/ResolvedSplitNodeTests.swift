// ResolvedSplitNodeTests.swift
// Limpid — checks that a leaf without a surface keeps its place, so divider paths address the stored tree.

import CoreGraphics
import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Resolved split tree")
struct ResolvedSplitNodeTests {
    private let left = UUID()
    private let topRight = UUID()
    private let bottomRight = UUID()

    /// `left | (topRight / bottomRight)`: a divider at the root and one
    /// inside the second side.
    private var stored: PaneNode {
        .split(PaneSplit(
            direction: .horizontal,
            ratio: 0.4,
            first: .leaf(id: left),
            second: .split(PaneSplit(
                direction: .vertical,
                ratio: 0.5,
                first: .leaf(id: topRight),
                second: .leaf(id: bottomRight)
            ))
        ))
    }

    /// A drag on a divider resizes the stored tree at the divider's path.
    /// With the leaf dropped, the inner split collapsed and its sibling's
    /// divider took another path, so the drag moved another split.
    @Test("a leaf without a surface keeps the tree and its divider paths as stored")
    func unresolvedLeaf_keepsTheStoredShape() {
        let resolved = ResolvedSplitNode.build(stored) { _ in nil }

        #expect(resolved.paneNode == stored)
        let size = CGSize(width: 800, height: 600)
        let placed = PaneLayout.resolve(resolved.paneNode, in: size, minPaneSize: 0)
        let expected = PaneLayout.resolve(stored, in: size, minPaneSize: 0)
        #expect(placed.dividers.map(\.path) == expected.dividers.map(\.path))
        #expect(placed.dividers.count == 2)
    }

    /// The container draws a placeholder for a leaf that is present with no
    /// view, and nothing for an id that is not a leaf of the tree.
    @Test("every leaf is listed, with no view when it has no surface")
    func surfaceViews_listEveryLeaf() {
        let resolved = ResolvedSplitNode.build(stored) { _ in nil }
        let views = resolved.surfaceViews

        #expect(Set(views.keys) == [left, topRight, bottomRight])
        #expect(views.values.allSatisfy { $0 == nil })
        #expect(views[UUID()] == nil)
    }
}
