// TmuxSecureInput.swift
// Limpid — where a mirror turns Secure Input on or off for one of its panes.

import Foundation

/// A mirror decides for itself when a pane is taking a password, because
/// libghostty cannot see a mirror pane's pty. What it decides is handed
/// over by leaf id, so the decision can be observed without a surface.
///
/// Secure Input is held per surface, not per leaf: the registry drops the
/// scope of a surface it lets go of, including one replaced by another
/// surface for the same leaf. So a request answers with the surface it
/// changed, and the mirror counts Secure Input as on only while that is
/// still the leaf's surface (`secureInputTarget`).
@MainActor
protocol TmuxSecureInputSwitching: AnyObject {
    /// The surface a request for leaf `paneID` would change now, or `nil`
    /// when the leaf has none yet.
    func secureInputTarget(paneID: UUID, registry: any SurfaceViewProviding) -> AnyObject?

    /// Turn Secure Input on or off for leaf `paneID`. Returns the surface
    /// whose scope changed, or `nil` when the leaf has no surface yet and
    /// nothing changed; the mirror asks again on its next check.
    func setSecureInput(_ isOn: Bool, paneID: UUID, registry: any SurfaceViewProviding) -> AnyObject?
}

extension SecureInputManager: TmuxSecureInputSwitching {
    func secureInputTarget(paneID: UUID, registry: any SurfaceViewProviding) -> AnyObject? {
        registry.view(for: paneID)
    }

    func setSecureInput(_ isOn: Bool, paneID: UUID, registry: any SurfaceViewProviding) -> AnyObject? {
        guard let view = registry.view(for: paneID) else { return nil }
        set(isOn ? .on : .off, for: view)
        return view
    }
}
