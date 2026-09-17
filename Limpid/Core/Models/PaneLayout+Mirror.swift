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
/// which leaf shows which tmux pane, and the pane tmux has zoomed. Built by
/// the view from the mirror and the tab, so the producer itself stays a
/// pure function.
struct TmuxMirrorGeometry: Equatable {
    let layout: TmuxLayout
    let cellSize: CellSize
    let leafIDs: [String: UUID]
    let zoomedPane: String?

    func resolve() -> PaneLayout {
        PaneLayout.resolve(mirror: layout, cellSize: cellSize, padding: .pinned, zoomedPane: zoomedPane) { leafIDs[$0] }
    }
}

/// The pane a divider drag resizes and its current extent along the axis.
struct MirrorResizeTarget: Equatable {
    let pane: String
    let direction: SplitDirection
    let extent: Int
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
    /// The layout is the tree `TmuxLayout.paneNode` projects, so the
    /// divider paths are the ones the ratio producer assigns to the same
    /// tree. A pane without a leaf id is skipped: the tab is rewritten
    /// from the same layout before this runs, so that only happens
    /// mid-update, and drawing nothing there is the safe choice.
    ///
    /// While tmux zooms `zoomedPane`, that pane is drawn alone over the
    /// whole window with every edge outer, which is the size tmux gave
    /// it. Its layout keeps the unzoomed rectangles, so we take the
    /// window's rather than the pane's.
    static func resolve(
        mirror layout: TmuxLayout,
        cellSize: CellSize,
        padding: OuterPadding,
        zoomedPane: String? = nil,
        leafID: (String) -> UUID?
    ) -> PaneLayout {
        withoutActuallyEscaping(leafID) { leafID in
            var builder = MirrorBuilder(window: layout.root.rect, cellSize: cellSize, padding: padding, leafID: leafID)
            if let zoomedPane {
                builder.place(.pane(id: zoomedPane, rect: layout.root.rect), path: [])
            } else {
                builder.place(layout.root, path: [])
            }
            return PaneLayout(leaves: builder.leaves, dividers: builder.dividers)
        }
    }

    /// What a divider drag on a mirror tab turns into: the pane tmux is
    /// told to resize and the size it currently has, in cells. The divider
    /// at `path` belongs to the split whose first side ends at it; tmux
    /// resizes a pane's enclosing cell along the axis, so any leaf of that
    /// side names it, and the first one is taken.
    static func mirrorResizeTarget(in layout: TmuxLayout, path: PaneSplitPath) -> MirrorResizeTarget? {
        guard case let .split(direction, _, _, first, _) = layout.root.node(at: path),
              let pane = first.paneIDs.first
        else { return nil }
        let extent = direction == .horizontal ? first.rect.width : first.rect.height
        return MirrorResizeTarget(pane: pane, direction: direction, extent: extent)
    }

    /// The cell count a divider drag asks for: the first side's current
    /// extent plus the drag in whole cells. The drag is measured from the
    /// divider's `ratio × bounds`, which the mirror producer sets to the
    /// band's center, so a pointer anywhere on the band asks for no change.
    static func mirrorResizeCells(target: MirrorResizeTarget, delta: Double, cellSize: CellSize) -> Int {
        let cell = target.direction == .horizontal ? cellSize.width : cellSize.height
        return target.extent + Int((delta / cell).rounded())
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
        case let .split(direction, rect, gap, first, second):
            let box = points(of: rect)
            let band = dividerRect(of: gap, within: box, direction: direction)
            // The drag measures the pointer against `ratio × bounds`, so
            // the ratio places that point at the band's center. The cell
            // ratio `TmuxLayout.paneNode` stores excludes the border and
            // the padding, and would put it up to a cell and a half off
            // the band near the window's edges.
            let ratio = switch direction {
            case .horizontal:
                box.width > 0 ? Double((band.midX - box.minX) / box.width) : 0.5
            case .vertical:
                box.height > 0 ? Double((band.midY - box.minY) / box.height) : 0.5
            }
            place(first, path: path + [.first])
            dividers.append(PaneLayout.Divider(
                path: path,
                direction: direction,
                rect: band,
                ratio: ratio,
                bounds: box.size,
                origin: box.origin
            ))
            place(second, path: path + [.second])
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
