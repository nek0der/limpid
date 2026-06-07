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
    /// used by TabActions when a pane close mutates the tree so
    /// orphaned SurfaceViews don't pile up.
    func reconcile(activeIDs: Set<UUID>)
}

@MainActor
final class SurfaceRegistry: SurfaceViewProviding {
    private var views: [UUID: SurfaceView] = [:]

    /// Reverse index keyed by `ObjectIdentifier(view)` so
    /// `id(for view:)` is O(1). Every `register` / `unregister` keeps
    /// both maps in lockstep. Pre-Phase-3 this was a linear scan over
    /// `views`, which sat on the hot path of every libghostty
    /// callback that re-resolves the pane id (`GhosttyEventCoordinator`
    /// dispatch). Even at 5–10 panes the cost was non-trivial; the
    /// reverse index removes the n-factor entirely.
    private var idByView: [ObjectIdentifier: UUID] = [:]

    func view(for id: UUID) -> SurfaceView? {
        views[id]
    }

    func register(_ view: SurfaceView, for id: UUID) {
        // A re-register under the same id swaps the value side; clean
        // the reverse entry for the old view so it doesn't keep a stale
        // pointer to a paneID that now belongs to someone else.
        if let previous = views[id] {
            idByView.removeValue(forKey: ObjectIdentifier(previous))
        }
        views[id] = view
        idByView[ObjectIdentifier(view)] = id
    }

    func unregister(_ id: UUID) {
        guard let removed = views.removeValue(forKey: id) else { return }
        idByView.removeValue(forKey: ObjectIdentifier(removed))
    }

    /// Reverse lookup: which pane id owns this `SurfaceView`?
    /// O(1) via the `idByView` reverse index. Used by libghostty
    /// action routing on every callback to map a surface back to the
    /// SplitTree leaf it lives in.
    func id(for view: SurfaceView) -> UUID? {
        idByView[ObjectIdentifier(view)]
    }

    /// Snapshot of every live `SurfaceView` for callers that must
    /// iterate the surface set without holding the dictionary's
    /// internal storage. Used by `GhosttyConfigBridge.reloadConfig` to
    /// drive a per-surface `ghostty_surface_update_config` pass —
    /// libghostty's app-level `update_config` only delivers messages
    /// asynchronously, so panes whose renderer thread is parked (e.g.
    /// the occluded surface case) can stay stuck on the old config
    /// until they're revealed again. The per-surface call routes
    /// through `Surface.updateConfig` synchronously and avoids that.
    var allViews: [SurfaceView] {
        Array(views.values)
    }

    /// Drop any registry entries whose ids no longer appear in the given
    /// snapshot. Called whenever the SplitTree mutates so we don't leak
    /// orphaned SurfaceViews.
    func reconcile(activeIDs: Set<UUID>) {
        // Snapshot the keys before removing — `views.keys` is backed by
        // the dictionary's open-addressed buffer, so mutating during
        // iteration is undefined: the iterator's cursor can land in a
        // tombstoned slot or skip the entry that shuffled into the
        // just-visited bucket. The registry is small so this never
        // surfaced in practice, but the snapshot keeps the code
        // pattern-correct against a future stdlib bump.
        let stale = views.keys.filter { !activeIDs.contains($0) }
        for id in stale {
            if let removed = views.removeValue(forKey: id) {
                idByView.removeValue(forKey: ObjectIdentifier(removed))
            }
        }
    }

    // MARK: - Occlusion (energy)

    /// Mark surfaces visible/occluded based on the set of pane IDs that
    /// are actually on screen. Surfaces not in `visibleIDs` get their
    /// CVDisplayLink stopped, saving ~120 wakeups/s each on ProMotion.
    func updateOcclusion(visibleIDs: Set<UUID>) {
        for (id, view) in views {
            view.setOccluded(!visibleIDs.contains(id))
        }
    }

    /// Occlude every registered surface (e.g. window hidden / app occluded).
    func occludeAll() {
        for (_, view) in views {
            view.setOccluded(true)
        }
    }

    /// Reveal every registered surface (e.g. window reappears).
    func revealAll() {
        for (_, view) in views {
            view.setOccluded(false)
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
