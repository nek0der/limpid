// TmuxSecureInput.swift
// Limpid — where a mirror turns Secure Input on or off for one of its panes.

import Foundation

/// A mirror decides for itself when a pane is taking a password, because
/// libghostty cannot see a mirror pane's pty. What it decides is handed
/// over by leaf id, so the decision can be observed without a surface.
@MainActor
protocol TmuxSecureInputSwitching: AnyObject {
    /// Turn Secure Input on or off for leaf `paneID`. Returns whether the
    /// request took effect: a leaf whose surface does not exist yet has no
    /// scope to change, and the mirror asks again on its next check.
    func setSecureInput(_ isOn: Bool, paneID: UUID, registry: any SurfaceViewProviding) -> Bool
}

extension SecureInputManager: TmuxSecureInputSwitching {
    func setSecureInput(_ isOn: Bool, paneID: UUID, registry: any SurfaceViewProviding) -> Bool {
        guard let view = registry.view(for: paneID) else { return false }
        set(isOn ? .on : .off, for: view)
        return true
    }
}
