// SplitContainerView.swift
// Limpid — places a resolved split tree's leaves and dividers at the
// rectangles `PaneLayout` computed for them. Leaves carry live
// `SurfaceView` references so SwiftUI's view-tree diff anchors on the
// AppKit object; the geometry itself is a value computed once for the
// whole tree, top down, instead of per split inside nested
// `GeometryReader`s. The numbers are the same; they just live where a
// test can reach them and where a second producer (a tmux mirror tab
// laying panes out from tmux's cell layout) can plug in.
//
// Placement uses `ZStack` + `.frame()` + `.offset()` so divider drags share
// the absolute-position cursor anchoring that keeps the gutter under the
// mouse pointer.

import SwiftUI
import UniformTypeIdentifiers

struct SplitContainerView: View {
    let node: ResolvedSplitNode
    /// Whether this tab mirrors a tmux window. Only then does a leaf pin
    /// its padding (Limpid's on outer edges, none where panes meet); an
    /// ordinary tab hands every leaf `nil` and never touches the setter.
    let isMirrorTab: Bool
    /// tmux's cell layout for a connected mirror tab. When present the
    /// leaves and dividers come from it and the stored ratios are not
    /// consulted; a disconnected mirror, or one tmux has not described
    /// yet, is placed from ratios like any other tab (design §2 D0).
    var mirrorGeometry: TmuxMirrorGeometry?
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
    /// Smallest each side of a divider may shrink to, in points. Every
    /// split in the tree shares this floor; `PaneAreaView` resolves the
    /// value from `terminal.minPaneSize`.
    let minPaneSize: CGFloat

    /// Named space the divider drags read their location in, so a drag
    /// can be expressed relative to the split that owns the divider no
    /// matter how deep that split sits.
    private static let coordinateSpace = "SplitContainerView"

    var body: some View {
        switch node {
        case let .leaf(paneID, view) where !isMirrorTab:
            leaf(paneID: paneID, view: view, paddingOverride: nil)
        case .leaf, .split:
            // A mirror tab is placed the same way whether it has one leaf
            // or many, so the leaf keeps its view identity when the first
            // layout arrives. Switching from a bare leaf to a placed one
            // let the retiring host write its all-edges pin back over the
            // new one and leave the pane two columns short.
            GeometryReader { geo in
                placed(in: geo.size)
            }
        }
    }

    @ViewBuilder
    private func placed(in size: CGSize) -> some View {
        let layout = mirrorGeometry?.resolve()
            ?? PaneLayout.resolve(node.paneNode, in: size, minPaneSize: minPaneSize)
        let views = node.surfaceViews

        // A mirror window can be larger than the area when another client
        // sized it (design §8 D11): draw what fits, never over the chrome.
        ZStack(alignment: .topLeading) {
            ForEach(layout.leaves, id: \.id) { entry in
                if let view = views[entry.id] {
                    leaf(
                        paneID: entry.id,
                        view: view,
                        paddingOverride: PaddingOverride.forEdges(entry.edges, isMirror: isMirrorTab)
                    )
                    .frame(width: entry.rect.width, height: entry.rect.height)
                    .offset(x: entry.rect.minX, y: entry.rect.minY)
                }
            }
            ForEach(layout.dividers, id: \.path) { divider in
                SplitDividerView(direction: divider.direction == .horizontal ? .horizontal : .vertical)
                    .frame(width: divider.rect.width, height: divider.rect.height)
                    .offset(x: divider.rect.minX, y: divider.rect.minY)
                    .gesture(dragGesture(divider))
                    // Tap classification runs before `DragGesture` accumulates the
                    // 1px slop it needs to fire `onChanged`, so a clean double-
                    // click reaches us even though the drag modifier is attached
                    // above. `simultaneousGesture` avoids the priority struggle
                    // that an `.onTapGesture(count: 2)` modifier would force.
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            onEqualize(divider.path)
                        }
                    )
                    .help("Double-click to equalize")
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .coordinateSpace(name: Self.coordinateSpace)
    }

    private func leaf(paneID: UUID, view: SurfaceView, paddingOverride: PaddingOverride?) -> some View {
        PaneContainerView(paneID: paneID, surfaceView: view, paddingOverride: paddingOverride)
            .onTapGesture { onLeafFocus(paneID) }
            // SwiftUI identity ties to the pane id so a swap (one pane
            // reparented into another slot) keeps the split structure and
            // only trades the two leaves' ids — without this, SwiftUI sees
            // "same slot, changed paneID prop" and never visually moves the
            // panes. The resolved-view layer gives us a stable AppKit
            // reference; this gives SwiftUI the matching stable structural
            // identity.
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
    }

    /// The drag reads its location in the container's space, which is the
    /// space the layout was resolved in; `PaneLayout.Divider.dragDelta`
    /// converts it to the owning split's space.
    private func dragGesture(_ divider: PaneLayout.Divider) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordinateSpace))
            .onChanged { gesture in
                onResize(divider.path, divider.dragDelta(to: gesture.location), divider.bounds)
            }
    }
}
