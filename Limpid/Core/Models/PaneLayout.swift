// PaneLayout.swift
// Limpid — resolves a pane tree into absolute leaf and divider rectangles.

import CoreGraphics
import Foundation

/// Which edges of a leaf coincide with the layout's outer bounds. A tmux
/// mirror tab keeps the configured padding only on these edges and none
/// where two panes meet, so the divider between them can be exactly one
/// cell wide; ordinary tabs ignore the mask.
struct PaneEdges: OptionSet, Equatable {
    let rawValue: UInt8

    static let top = PaneEdges(rawValue: 1 << 0)
    static let bottom = PaneEdges(rawValue: 1 << 1)
    static let left = PaneEdges(rawValue: 1 << 2)
    static let right = PaneEdges(rawValue: 1 << 3)
    static let all: PaneEdges = [.top, .bottom, .left, .right]
}

/// The geometry of one pane area: every leaf's rectangle plus every divider
/// band, all in the coordinate space of the bounds they were resolved in.
///
/// Producing this as a value keeps the arithmetic out of SwiftUI's body,
/// where nested `GeometryReader`s used to compute each split relative to its
/// parent. The numbers are the same; they are just computed once, top down,
/// and can be tested without a view. It is also the seam where a second
/// producer can plug in: a tmux mirror tab derives these rectangles from the
/// cell layout tmux reports instead of from stored ratios.
struct PaneLayout: Equatable {
    struct Leaf: Equatable {
        let id: UUID
        let rect: CGRect
        let edges: PaneEdges
    }

    /// One divider band. `rect` is both what is drawn and the drag target.
    /// `ratio`, `bounds`, and `origin` describe the split that owns the
    /// divider so a drag can be converted back into a ratio delta the same
    /// way it was when each split measured itself.
    struct Divider: Equatable {
        let path: PaneSplitPath
        let direction: SplitDirection
        let rect: CGRect
        let ratio: Double
        let bounds: CGSize
        let origin: CGPoint

        /// How far a drag at `location` (in the layout's space) has moved
        /// the divider along its axis, in points: the pointer's offset from
        /// `ratio × bounds` within the owning split. Both producers put that
        /// point at the band's center.
        func dragDelta(to location: CGPoint) -> Double {
            switch direction {
            case .horizontal:
                let extent = Double(bounds.width)
                return (Double(location.x - origin.x) / max(extent, 1) - ratio) * extent
            case .vertical:
                let extent = Double(bounds.height)
                return (Double(location.y - origin.y) / max(extent, 1) - ratio) * extent
            }
        }
    }

    let leaves: [Leaf]
    let dividers: [Divider]

    /// Lay out `node` inside `bounds`. Each split's ratio is first clamped
    /// against the minimum extent of both subtrees (`PaneSplit.resolvedRatio`),
    /// exactly as the renderer did per level, then the first child takes
    /// `extent × ratio − thickness / 2`, the divider takes `thickness`, and
    /// the second child takes the remainder.
    static func resolve(_ node: PaneNode, in bounds: CGSize, minPaneSize: CGFloat) -> PaneLayout {
        var leaves: [Leaf] = []
        var dividers: [Divider] = []
        place(
            node,
            in: CGRect(origin: .zero, size: bounds),
            path: [],
            outer: bounds,
            minPaneSize: minPaneSize,
            leaves: &leaves,
            dividers: &dividers
        )
        return PaneLayout(leaves: leaves, dividers: dividers)
    }

    // swiftlint:disable:next function_parameter_count
    private static func place(
        _ node: PaneNode,
        in box: CGRect,
        path: PaneSplitPath,
        outer: CGSize,
        minPaneSize: CGFloat,
        leaves: inout [Leaf],
        dividers: inout [Divider]
    ) {
        switch node {
        case let .leaf(id):
            leaves.append(Leaf(id: id, rect: box, edges: edges(of: box, within: outer)))
        case let .split(data):
            let size = box.size
            let extent = data.direction == .horizontal ? size.width : size.height
            let ratio = PaneSplit.resolvedRatio(
                data.ratio,
                extent: extent,
                firstMinimum: data.first.minimumExtent(along: data.direction, leafMinimum: minPaneSize),
                secondMinimum: data.second.minimumExtent(along: data.direction, leafMinimum: minPaneSize)
            )
            let thickness = PaneSplit.dividerThickness
            var first = box
            var second = box
            var divider = box
            switch data.direction {
            case .horizontal:
                first.size.width = max(0, size.width * ratio - thickness / 2)
                divider.origin.x = box.minX + first.width
                divider.size.width = thickness
                second.origin.x = box.minX + first.width + thickness
                second.size.width = max(0, size.width - (first.width + thickness))
            case .vertical:
                first.size.height = max(0, size.height * ratio - thickness / 2)
                divider.origin.y = box.minY + first.height
                divider.size.height = thickness
                second.origin.y = box.minY + first.height + thickness
                second.size.height = max(0, size.height - (first.height + thickness))
            }
            place(
                data.first,
                in: first,
                path: path + [.first],
                outer: outer,
                minPaneSize: minPaneSize,
                leaves: &leaves,
                dividers: &dividers
            )
            dividers.append(Divider(
                path: path,
                direction: data.direction,
                rect: divider,
                ratio: data.ratio,
                bounds: size,
                origin: box.origin
            ))
            place(
                data.second,
                in: second,
                path: path + [.second],
                outer: outer,
                minPaneSize: minPaneSize,
                leaves: &leaves,
                dividers: &dividers
            )
        }
    }

    /// A leaf touches an outer edge when its rectangle reaches the bounds
    /// there. Half a point of tolerance absorbs floating-point drift from
    /// the ratio arithmetic without ever matching an interior divider,
    /// which is at least `PaneSplit.dividerThickness` away. Internal rather
    /// than private so the tolerance itself is pinned by a test.
    static func edges(of rect: CGRect, within outer: CGSize) -> PaneEdges {
        let tolerance: CGFloat = 0.5
        var edges: PaneEdges = []
        if rect.minY <= tolerance {
            edges.insert(.top)
        }
        if rect.maxY >= outer.height - tolerance {
            edges.insert(.bottom)
        }
        if rect.minX <= tolerance {
            edges.insert(.left)
        }
        if rect.maxX >= outer.width - tolerance {
            edges.insert(.right)
        }
        return edges
    }
}
