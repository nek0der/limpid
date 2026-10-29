// PlanUsagePresentation.swift
// Limpid — whether a window's plan usage panel is up, and the rail button it hangs from.

import Foundation
import Observation

/// Whether this window's plan usage panel is up. Each window has its own
/// (`ProjectWindowState.planUsage`): its rail button opens the panel in the
/// window it was clicked in. What the panel shows is shared
/// (`PlanUsageStore`).
@MainActor
@Observable
final class PlanUsagePresentation {
    var isPresented = false
    /// The rail button the panel hangs from. `nil` until the button has been
    /// laid out. Hiding the rails closes the panel rather than clearing this,
    /// as there is then no button to open it from.
    var anchor: RailPanelAnchor?
}
