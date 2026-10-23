// SplitContainerView.swift
// Limpid — recursively renders a resolved split tree whose leaves are
// live `SurfaceView` references. The split structure walks down a value
// tree of node enums where each leaf carries the actual AppKit object
// instead of an opaque identifier — SwiftUI's view-tree diff stays sane
// because every leaf's identity is the SurfaceView reference itself,
// without a UUID→view indirection in the way of the AppKit reparent.
//
// Layout uses `ZStack` + `.frame()` + `.offset()` so divider drags share
// the absolute-position cursor anchoring that keeps the seam under
// the mouse pointer.

import SwiftUI
import UniformTypeIdentifiers

struct SplitContainerView: View {
    let node: ResolvedSplitNode
    let onLeafFocus: (UUID) -> Void
    let onResize: (PaneSplitPath, Double, CGSize) -> Void
    /// Invoked when a `pane:<uuid>` drag is dropped on a leaf inside the
    /// same window. `zone` distinguishes a center drop (swap the two
    /// panes' slots) from an edge drop (detach the source and insert it
    /// as a new split next to the target on the matching side).
    let onPaneSwapDrop: (_ source: UUID, _ target: UUID, _ zone: PaneDropZone) -> Void
    /// Pre-computed per-zone effectiveness. The drop overlay calls this
    /// to gray out zones whose drop wouldn't actually move the source
    /// (e.g. inserting into a slot the source is already in).
    let isZoneEffective: (_ source: UUID, _ target: UUID, _ zone: PaneDropZone) -> Bool
    /// Double-click on a divider — equalize the subtree rooted at that
    /// split. The structural path is shared with `onResize`, so nested
    /// same-axis dividers remain unambiguous.
    let onEqualize: (PaneSplitPath) -> Void
    /// Smallest each side of a divider may shrink to, in points. Threaded
    /// through to recursive calls so the whole tree shares one floor;
    /// `PaneAreaView` resolves the value from `terminal.paneMinimumSize`.
    let minPaneSize: PaneMinimumSize
    /// The pixel grid the seam between two panes is laid on.
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        switch node {
        case let .leaf(paneID, view):
            PaneContainerView(paneID: paneID, surfaceView: view)
                .onTapGesture { onLeafFocus(paneID) }
                // SwiftUI identity ties to the pane id so a swap (one
                // pane reparented into another slot) keeps the split
                // structure and only trades the two leaves' ids —
                // without this, SwiftUI sees "same slot, changed paneID
                // prop" and never visually moves the panes. The
                // resolved-view layer gives us a stable AppKit
                // reference; this gives SwiftUI the matching stable
                // structural identity.
                .id(paneID)
                .overlay {
                    PaneSwapDropOverlay(
                        targetPaneID: paneID,
                        onDrop: onPaneSwapDrop,
                        isZoneEffective: { source, zone in
                            isZoneEffective(source, paneID, zone)
                        }
                    )
                }
        case let .split(data):
            GeometryReader { geo in
                splitBody(data: data, size: geo.size)
            }
        }
    }

    @ViewBuilder
    private func splitBody(data: ResolvedSplit, size: CGSize) -> some View {
        let firstMinimum = data.first.minimumExtent(along: data.direction, leafMinimum: minPaneSize)
        let secondMinimum = data.second.minimumExtent(along: data.direction, leafMinimum: minPaneSize)
        let geometry = SplitSeamGeometry(
            size: size,
            ratio: PaneSplit.resolvedRatio(
                data.ratio,
                extent: data.direction == .horizontal ? size.width : size.height,
                firstMinimum: firstMinimum,
                secondMinimum: secondMinimum
            ),
            direction: data.direction,
            displayScale: displayScale,
            firstMinimum: firstMinimum,
            secondMinimum: secondMinimum
        )

        ZStack(alignment: .topLeading) {
            SplitContainerView(
                node: data.first,
                onLeafFocus: onLeafFocus,
                onResize: onResize,
                onPaneSwapDrop: onPaneSwapDrop,
                isZoneEffective: isZoneEffective,
                onEqualize: onEqualize,
                minPaneSize: minPaneSize
            )
            .frame(width: geometry.first.width, height: geometry.first.height)
            .offset(x: geometry.first.minX, y: geometry.first.minY)

            SplitContainerView(
                node: data.second,
                onLeafFocus: onLeafFocus,
                onResize: onResize,
                onPaneSwapDrop: onPaneSwapDrop,
                isZoneEffective: isZoneEffective,
                onEqualize: onEqualize,
                minPaneSize: minPaneSize
            )
            .frame(width: geometry.second.width, height: geometry.second.height)
            .offset(x: geometry.second.minX, y: geometry.second.minY)

            // Last, so its grab band, which lies over both panes' edges, is
            // in front of them (`SplitDividerView`).
            SplitDividerView(
                direction: data.direction,
                geometry: geometry,
                onDrag: { location in resize(data: data, size: size, to: location) },
                onEqualize: { onEqualize(data.path) }
            )
        }
    }

    private func resize(data: ResolvedSplit, size: CGSize, to location: CGPoint) {
        let newRatio = switch data.direction {
        case .horizontal:
            Double(location.x / max(size.width, 1))
        case .vertical:
            Double(location.y / max(size.height, 1))
        }
        let currentExtent = data.direction == .horizontal ? Double(size.width) : Double(size.height)
        let delta = (newRatio - data.ratio) * currentExtent
        onResize(data.path, delta, size)
    }
}
