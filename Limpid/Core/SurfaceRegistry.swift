// SurfaceRegistry.swift
// Limpid — maps pane-leaf UUIDs to their backing SurfaceView.
//
// SplitTree carries identity (UUIDs); the actual `NSView` instances live
// here. Lookup keeps SwiftUI re-renders cheap because views never have to
// hold the AppKit object directly.

import AppKit
import Foundation
import GhosttyKit

/// Read-side abstraction used by the Domain / event layer (the C-callback
/// coordinator, dock-badge sync). Keeping these consumers behind a
/// protocol means they don't reach into AppKit specifics and the
/// concrete `SurfaceView` type stays in the UI layer.
@MainActor
protocol SurfaceViewProviding: AnyObject {
    func view(for id: UUID) -> SurfaceView?
    func id(for view: SurfaceView) -> UUID?
    func register(_ view: SurfaceView, for id: UUID)
    func unregister(_ id: UUID)
    /// Drop any registry entries whose ids aren't in the given set —
    /// used by SessionActions when a pane close mutates the tree so
    /// orphaned SurfaceViews don't pile up.
    func reconcile(activeIDs: Set<UUID>)
}

@MainActor
final class SurfaceRegistry: SurfaceViewProviding {
    private var views: [UUID: SurfaceView] = [:]

    func view(for id: UUID) -> SurfaceView? {
        views[id]
    }

    func register(_ view: SurfaceView, for id: UUID) {
        views[id] = view
    }

    func unregister(_ id: UUID) {
        views.removeValue(forKey: id)
    }

    /// Reverse lookup: which pane id owns this `SurfaceView`?
    /// Used by libghostty action routing to map a surface back to the
    /// SplitTree leaf it lives in.
    func id(for view: SurfaceView) -> UUID? {
        for (id, candidate) in views where candidate === view {
            return id
        }
        return nil
    }

    /// Drop any registry entries whose ids no longer appear in the given
    /// snapshot. Called whenever the SplitTree mutates so we don't leak
    /// orphaned SurfaceViews.
    func reconcile(activeIDs: Set<UUID>) {
        for id in views.keys where !activeIDs.contains(id) {
            views.removeValue(forKey: id)
        }
    }

}

/// `SurfaceViewProviding` fallback used as the `EnvironmentValues`
/// default. The real registry is installed by `AppState`; this
/// no-op exists so views consumed outside the Limpid scene (SwiftUI
/// Previews, unit tests) compile and run without optional unwraps.
/// Production never hits it.
@MainActor
final class NoopSurfaceRegistry: SurfaceViewProviding {
    func view(for id: UUID) -> SurfaceView? {
        nil
    }

    func id(for view: SurfaceView) -> UUID? {
        nil
    }

    func register(_ view: SurfaceView, for id: UUID) {}
    func unregister(_ id: UUID) {}
    func reconcile(activeIDs: Set<UUID>) {}
}
