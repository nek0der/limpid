// ResolvedSplitNode.swift
// Limpid — value-typed mirror of `PaneNode` whose leaves carry the
// resolved `SurfaceView` reference, not a UUID. The persisted tree
// (`PaneNode`) keeps using UUIDs so `state.json` round-trips don't have
// to know about AppKit; this mirror is built fresh on every render so
// SwiftUI sees a stable AppKit object reference for each leaf, mirroring
// the identity model used by other libghostty consumers' split-tree
// renderers.

import AppKit
import Foundation

@MainActor
indirect enum ResolvedSplitNode {
    /// `view` is `nil` for a leaf that has no surface (see `build`).
    case leaf(paneID: UUID, view: SurfaceView?)
    case split(ResolvedSplit)

    /// Walk the persisted `PaneNode` tree and resolve each leaf UUID to
    /// the live `SurfaceView` through the supplied closure. The closure
    /// is normally `registry.view(for:)` or a create-on-miss wrapper.
    ///
    /// A leaf the closure cannot resolve stays in the tree without a view,
    /// and the container draws a placeholder in its place
    /// (`PaneHostRepresentable.SurfaceBacking.noSurface`). Collapsing its
    /// split instead would number the dividers over a tree other than the
    /// stored one, while a divider drag or double-click resizes the stored
    /// tree by that number and would move another split.
    static func build(
        _ node: PaneNode,
        resolveOrCreate: (UUID) -> SurfaceView?
    ) -> ResolvedSplitNode {
        switch node {
        case let .leaf(id):
            .leaf(paneID: id, view: resolveOrCreate(id))
        case let .split(data):
            .split(ResolvedSplit(
                direction: data.direction,
                ratio: data.ratio,
                first: build(data.first, resolveOrCreate: resolveOrCreate),
                second: build(data.second, resolveOrCreate: resolveOrCreate)
            ))
        }
    }

    /// The tree with views stripped back to ids, the same shape as the
    /// stored one; `PaneLayout` takes a `PaneNode` so it stays free of
    /// AppKit and testable.
    var paneNode: PaneNode {
        switch self {
        case let .leaf(paneID, _):
            .leaf(id: paneID)
        case let .split(data):
            .split(PaneSplit(
                direction: data.direction,
                ratio: data.ratio,
                first: data.first.paneNode,
                second: data.second.paneNode
            ))
        }
    }

    /// Every leaf's view by pane id, for placing leaves once `PaneLayout`
    /// has decided where each one goes. A leaf without a surface is present
    /// with a `nil` view, so a lookup tells "draw a placeholder" apart from
    /// "not a leaf of this tree".
    var surfaceViews: [UUID: SurfaceView?] {
        var views: [UUID: SurfaceView?] = [:]
        collectViews(into: &views)
        return views
    }

    private func collectViews(into views: inout [UUID: SurfaceView?]) {
        switch self {
        case let .leaf(paneID, view):
            views[paneID] = view
        case let .split(data):
            data.first.collectViews(into: &views)
            data.second.collectViews(into: &views)
        }
    }
}

@MainActor
struct ResolvedSplit {
    let direction: SplitDirection
    let ratio: Double
    let first: ResolvedSplitNode
    let second: ResolvedSplitNode
}
