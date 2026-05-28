// AgentStatePresentation.swift
// Limpid — SF Symbol + `Color` mapping for `AgentState`. Lives in the
// UI layer so `Core/Models/AgentState.swift` can stay free of SwiftUI
// imports. Both Claude and Codex panes feed through this — per-kind
// iconography (Claude vs Codex visual distinction) is a future PR;
// today every kind shares the same circle-family glyph.

import SwiftUI

extension AgentState {
    /// SF Symbol used for the L1 / L2 status icon. `nil` when nothing
    /// should be rendered (idle / unknown — keeps the row quiet).
    ///
    /// All visible states share the `.circle.fill` family so the row
    /// of status indicators reads as a single visual language —
    /// colour and the inner glyph distinguish the state, the
    /// surrounding circle stays constant.
    var iconName: String? {
        switch self {
        case .running, .compacting: "bolt.circle.fill"
        case .needsInput: "questionmark.circle.fill"
        case .error: "exclamationmark.circle.fill"
        case .idle, .unknown: nil
        }
    }

    /// System-tinted colour for the icon. `nil` when no icon renders.
    /// Dark / light mode is handled by the SwiftUI `Color(.system…)`
    /// initialiser.
    var iconColor: Color? {
        switch self {
        case .running, .compacting: Color(.systemBlue)
        case .needsInput: Color(.systemOrange)
        case .error: Color(.systemRed)
        case .idle, .unknown: nil
        }
    }
}
