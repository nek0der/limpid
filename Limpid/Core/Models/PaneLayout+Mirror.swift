// PaneLayout+Mirror.swift
// Limpid — lays a tmux mirror tab out from the cell rectangles tmux reported.

import CoreGraphics
import Foundation

/// Padding a mirror tab keeps on the edges of its pane area, in points.
/// The same numbers are pinned on each outer leaf (`PaddingOverride`), so
/// a surface sized by this producer draws exactly the grid tmux gave it.
struct OuterPadding: Equatable {
    let horizontal: CGFloat
    let vertical: CGFloat

    /// What Limpid writes into the generated config.
    static let pinned = OuterPadding(
        horizontal: CGFloat(GhosttyConfigBridge.windowPaddingX),
        vertical: CGFloat(GhosttyConfigBridge.windowPaddingY)
    )
}

/// Everything the pane area needs to draw a mirror tab from tmux's layout
/// rather than from stored ratios: the layout, the cell it is measured in,
/// and which leaf shows which tmux pane. Built by the view from the mirror
/// and the tab, so the producer itself stays a pure function.
struct TmuxMirrorGeometry: Equatable {
    let layout: TmuxLayout
    let cellSize: CellSize
    let leafIDs: [String: UUID]

    func resolve() -> PaneLayout {
        PaneLayout.resolve(mirror: layout, cellSize: cellSize, padding: .pinned) { leafIDs[$0] }
    }
}

extension PaneLayout {
    /// Lay the panes of a tmux window out from the cell rectangles tmux
    /// reported, at `cellSize` points per cell. tmux has already decided
    /// every pane's size and position, so nothing is distributed here and
    /// a leaf's rectangle converts back to its `WxH,x,y` exactly. The
    /// window is anchored at the top-left of the pane area: a smaller
    /// window leaves the rest empty, a larger one is clipped by the
    /// renderer, because tmux's size is the authority (design §8 D11).
    ///
    /// A leaf that touches the window's edge carries `padding` on that
    /// edge, so its surface is `cells × cellSize + padding` and
    /// `ghostty_surface_size()` returns the cell count by construction.
    /// Siblings fold to the right exactly as `TmuxLayout.paneNode` folds
    /// them, so the divider paths are the ones the ratio producer assigns
    /// to the same tree. A pane without a leaf id is skipped: the tab is
    /// rewritten from the same layout before this runs, so that only
    /// happens mid-update, and drawing nothing there is the safe choice.
    static func resolve(
        mirror layout: TmuxLayout,
        cellSize: CellSize,
        padding: OuterPadding,
        leafID: (String) -> UUID?
    ) -> PaneLayout {
        withoutActuallyEscaping(leafID) { leafID in
            var builder = MirrorBuilder(window: layout.root.rect, cellSize: cellSize, padding: padding, leafID: leafID)
            builder.place(layout.root, path: [])
            return PaneLayout(leaves: builder.leaves, dividers: builder.dividers)
        }
    }

    /// The grid a mirror tab asks tmux for: whole cells that fit inside
    /// the pane area once the outer padding is taken off. This is the
    /// same floor libghostty applies to a single surface filling the
    /// area, so a one-pane window and the window grid agree.
    static func mirrorGrid(
        areaSize: CGSize,
        cellSize: CellSize,
        padding: OuterPadding
    ) -> (columns: Int, rows: Int) {
        guard cellSize.width > 0, cellSize.height > 0 else { return (0, 0) }
        let width = areaSize.width - 2 * padding.horizontal
        let height = areaSize.height - 2 * padding.vertical
        return (
            max(0, Int((width / cellSize.width).rounded(.down))),
            max(0, Int((height / cellSize.height).rounded(.down)))
        )
    }
}

private struct MirrorBuilder {
    let window: TmuxCellRect
    let cellSize: CellSize
    let padding: OuterPadding
    let leafID: (String) -> UUID?
    var leaves: [PaneLayout.Leaf] = []
    var dividers: [PaneLayout.Divider] = []

    mutating func place(_ node: TmuxLayoutNode, path: PaneSplitPath) {
        switch node {
        case let .pane(id, rect):
            guard let leaf = leafID(id) else { return }
            leaves.append(PaneLayout.Leaf(id: leaf, rect: points(of: rect), edges: edges(of: rect)))
        case let .sideBySide(rect, children):
            placeSiblings(children, of: rect, direction: .horizontal, path: path)
        case let .stacked(rect, children):
            placeSiblings(children, of: rect, direction: .vertical, path: path)
        }
    }

    /// The right fold of `TmuxLayout.foldSiblings`, with rectangles: the
    /// first sibling takes `.first`, everything after it is one box that
    /// starts where the second sibling starts and takes `.second`. The
    /// cell tmux left between them is the divider.
    private mutating func placeSiblings(
        _ children: [TmuxLayoutNode],
        of rect: TmuxCellRect,
        direction: SplitDirection,
        path: PaneSplitPath
    ) {
        guard let first = children.first else { return }
        guard children.count > 1 else {
            place(first, path: path)
            return
        }
        let rest = Array(children.dropFirst())
        let firstEnd: Int
        let restStart: Int
        let restRect: TmuxCellRect
        let gap: TmuxCellRect
        switch direction {
        case .horizontal:
            firstEnd = first.rect.x + first.rect.width
            restStart = rest[0].rect.x
            restRect = TmuxCellRect(width: rect.x + rect.width - restStart, height: rect.height, x: restStart, y: rect.y)
            gap = TmuxCellRect(width: restStart - firstEnd, height: rect.height, x: firstEnd, y: rect.y)
        case .vertical:
            firstEnd = first.rect.y + first.rect.height
            restStart = rest[0].rect.y
            restRect = TmuxCellRect(width: rect.width, height: rect.y + rect.height - restStart, x: rect.x, y: restStart)
            gap = TmuxCellRect(width: rect.width, height: restStart - firstEnd, x: rect.x, y: firstEnd)
        }
        let firstExtent = direction == .horizontal ? first.rect.width : first.rect.height
        let restExtent = direction == .horizontal ? restRect.width : restRect.height
        let total = firstExtent + restExtent
        let ratio = total > 0 ? Double(firstExtent) / Double(total) : 0.5
        let box = points(of: rect)

        place(first, path: path + [.first])
        dividers.append(PaneLayout.Divider(
            path: path,
            direction: direction,
            rect: dividerRect(of: gap, within: box, direction: direction),
            ratio: ratio,
            bounds: box.size,
            origin: box.origin
        ))
        if rest.count == 1 {
            place(rest[0], path: path + [.second])
        } else {
            placeSiblings(rest, of: restRect, direction: direction, path: path + [.second])
        }
    }

    // MARK: - Cells to points

    private func gridX(_ column: Int) -> CGFloat {
        padding.horizontal + CGFloat(column) * CGFloat(cellSize.width)
    }

    private func gridY(_ row: Int) -> CGFloat {
        padding.vertical + CGFloat(row) * CGFloat(cellSize.height)
    }

    /// A cell rectangle in points, extended over the outer padding on
    /// each edge where it reaches the window's edge.
    private func points(of rect: TmuxCellRect) -> CGRect {
        let edges = edges(of: rect)
        let minX = edges.contains(.left) ? 0 : gridX(rect.x)
        let maxX = edges.contains(.right) ? gridX(rect.x + rect.width) + padding.horizontal : gridX(rect.x + rect.width)
        let minY = edges.contains(.top) ? 0 : gridY(rect.y)
        let maxY = edges.contains(.bottom) ? gridY(rect.y + rect.height) + padding.vertical : gridY(rect.y + rect.height)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The border cell between two siblings, spanning the container's
    /// full breadth so the band reaches the pane area's edge where the
    /// container does.
    private func dividerRect(of gap: TmuxCellRect, within box: CGRect, direction: SplitDirection) -> CGRect {
        switch direction {
        case .horizontal:
            CGRect(
                x: gridX(gap.x),
                y: box.minY,
                width: CGFloat(gap.width) * CGFloat(cellSize.width),
                height: box.height
            )
        case .vertical:
            CGRect(
                x: box.minX,
                y: gridY(gap.y),
                width: box.width,
                height: CGFloat(gap.height) * CGFloat(cellSize.height)
            )
        }
    }

    private func edges(of rect: TmuxCellRect) -> PaneEdges {
        var edges: PaneEdges = []
        if rect.x == window.x {
            edges.insert(.left)
        }
        if rect.x + rect.width == window.x + window.width {
            edges.insert(.right)
        }
        if rect.y == window.y {
            edges.insert(.top)
        }
        if rect.y + rect.height == window.y + window.height {
            edges.insert(.bottom)
        }
        return edges
    }
}
