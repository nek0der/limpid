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
            return first ?? second
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
