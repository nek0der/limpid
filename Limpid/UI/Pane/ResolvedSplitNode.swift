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
    case leaf(paneID: UUID, view: SurfaceView)
    case split(ResolvedSplit)

    /// Walk the persisted `PaneNode` tree and resolve each leaf UUID to
    /// the live `SurfaceView` through the supplied closure. The closure
    /// is normally `registry.view(for:)` or a create-on-miss wrapper;
    /// returning `nil` drops the leaf (the parent split collapses to its
    /// surviving child).
    static func build(
        _ node: PaneNode,
        resolveOrCreate: (UUID) -> SurfaceView?
    ) -> ResolvedSplitNode? {
        switch node {
        case let .leaf(id):
            guard let view = resolveOrCreate(id) else { return nil }
            return .leaf(paneID: id, view: view)
        case let .split(data):
            let first = build(data.first, resolveOrCreate: resolveOrCreate)
            let second = build(data.second, resolveOrCreate: resolveOrCreate)
            if let l = first, let r = second {
                return .split(ResolvedSplit(
                    direction: data.direction,
                    ratio: data.ratio,
                    first: l,
                    second: r
                ))
            }
            // A dropped leaf collapses its split. Divider paths are assigned
            // afterwards by `PaneLayout` over this effective tree, so there
            // is exactly one source for them; a path computed here over the
            // persisted shape could disagree with it.
            return first ?? second
        }
    }

    /// The effective tree with views stripped back to ids. A missing surface
    /// collapses a persisted split during resolution, so geometry must be
    /// computed from this shape rather than the on-disk one; `PaneLayout`
    /// takes a `PaneNode` so it stays free of AppKit and testable.
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

    /// Every resolved leaf's view by pane id, for placing leaves once
    /// `PaneLayout` has decided where each one goes.
    var surfaceViews: [UUID: SurfaceView] {
        var views: [UUID: SurfaceView] = [:]
        collectViews(into: &views)
        return views
    }

    private func collectViews(into views: inout [UUID: SurfaceView]) {
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
