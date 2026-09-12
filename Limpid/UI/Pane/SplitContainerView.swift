// SplitContainerView.swift
// Limpid — recursively renders a resolved split tree whose leaves are
// live `SurfaceView` references. The split structure walks down a value
// tree of node enums where each leaf carries the actual AppKit object
// instead of an opaque identifier — SwiftUI's view-tree diff stays sane
// because every leaf's identity is the SurfaceView reference itself,
// without a UUID→view indirection in the way of the AppKit reparent.
//
// Layout uses `ZStack` + `.frame()` + `.offset()` so divider drags share
// the absolute-position cursor anchoring that keeps the gutter under
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
    /// `PaneAreaView` resolves the value from `terminal.minPaneSize`.
    let minPaneSize: CGFloat

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
        let ratio = resolvedRatio(for: data, size: size)
        let leftRect = leftRect(for: size, ratio: ratio, direction: data.direction)
        let rightRect = rightRect(for: size, leftRect: leftRect, direction: data.direction)
        let dividerCenter = dividerCenter(for: size, leftRect: leftRect, direction: data.direction)

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
            .frame(width: leftRect.width, height: leftRect.height)
            .offset(x: leftRect.origin.x, y: leftRect.origin.y)

            SplitContainerView(
                node: data.second,
                onLeafFocus: onLeafFocus,
                onResize: onResize,
                onPaneSwapDrop: onPaneSwapDrop,
                isZoneEffective: isZoneEffective,
                onEqualize: onEqualize,
                minPaneSize: minPaneSize
            )
            .frame(width: rightRect.width, height: rightRect.height)
            .offset(x: rightRect.origin.x, y: rightRect.origin.y)

            SplitDividerView(direction: data.direction == .horizontal ? .horizontal : .vertical)
                .position(dividerCenter)
                .gesture(dragGesture(data: data, size: size))
                // Tap classification runs before `DragGesture` accumulates the
                // 1px slop it needs to fire `onChanged`, so a clean double-
                // click reaches us even though the drag modifier is attached
                // above. `simultaneousGesture` avoids the priority struggle
                // that an `.onTapGesture(count: 2)` modifier would force.
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        onEqualize(data.path)
                    }
                )
                .help("Double-click to equalize")
        }
    }

    private func dragGesture(data: ResolvedSplit, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                let newRatio = switch data.direction {
                case .horizontal:
                    Double(gesture.location.x / max(size.width, 1))
                case .vertical:
                    Double(gesture.location.y / max(size.height, 1))
                }
                let currentExtent = data.direction == .horizontal ? Double(size.width) : Double(size.height)
                let delta = (newRatio - data.ratio) * currentExtent
                onResize(data.path, delta, size)
            }
    }

    private func leftRect(for size: CGSize, ratio: Double, direction: SplitDirection) -> CGRect {
        var rect = CGRect(origin: .zero, size: size)
        switch direction {
        case .horizontal:
            rect.size.width = max(0, size.width * ratio - PaneSplit.dividerThickness / 2)
        case .vertical:
            rect.size.height = max(0, size.height * ratio - PaneSplit.dividerThickness / 2)
        }
        return rect
    }

    private func rightRect(for size: CGSize, leftRect: CGRect, direction: SplitDirection) -> CGRect {
        var rect = CGRect(origin: .zero, size: size)
        switch direction {
        case .horizontal:
            rect.origin.x = leftRect.width + PaneSplit.dividerThickness
            rect.size.width = max(0, size.width - rect.origin.x)
        case .vertical:
            rect.origin.y = leftRect.height + PaneSplit.dividerThickness
            rect.size.height = max(0, size.height - rect.origin.y)
        }
        return rect
    }

    private func dividerCenter(for size: CGSize, leftRect: CGRect, direction: SplitDirection) -> CGPoint {
        switch direction {
        case .horizontal:
            CGPoint(x: leftRect.width + PaneSplit.dividerThickness / 2, y: size.height / 2)
        case .vertical:
            CGPoint(x: size.width / 2, y: leftRect.height + PaneSplit.dividerThickness / 2)
        }
    }

    private func resolvedRatio(for data: ResolvedSplit, size: CGSize) -> Double {
        let extent = data.direction == .horizontal ? size.width : size.height
        let firstMinimum = data.first.minimumExtent(along: data.direction, leafMinimum: minPaneSize)
        let secondMinimum = data.second.minimumExtent(along: data.direction, leafMinimum: minPaneSize)
        return PaneSplit.resolvedRatio(
            data.ratio,
            extent: extent,
            firstMinimum: firstMinimum,
            secondMinimum: secondMinimum
        )
    }
}
