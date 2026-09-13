// AgentStatePresentation.swift
// Limpid — SF Symbol + `Color` mapping for `AgentState`. Lives in the
// UI layer so `Core/Models/AgentState.swift` can stay free of SwiftUI
// imports. Both Claude and Codex panes feed through this — per-kind
// iconography (Claude vs Codex visual distinction) is a future PR;
// today every kind shares the same circle-family glyph.

import SwiftUI

extension AgentState {
    /// SF Symbol used for the container / tab column status icon. `nil` when nothing
    /// should be rendered (idle / unknown — keeps the row quiet).
    ///
    /// Active states share the `.circle.fill` family. A viewed completion uses
    /// an outline to communicate acknowledgement without relying on color alone.
    var iconName: String? {
        switch self {
        case .running, .compacting: "bolt.circle.fill"
        case .needsInput: "questionmark.circle.fill"
        case .error: "exclamationmark.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .idle, .unknown: nil
        }
    }

    /// System-tinted color for the icon. `nil` when no icon renders.
    /// Dark / light mode is handled by the SwiftUI `Color(.system…)`
    /// initializer.
    var iconColor: Color? {
        switch self {
        case .running, .compacting: Color(.systemBlue)
        case .needsInput: Color(.systemOrange)
        case .error: Color(.systemRed)
        case .finished: Color(.systemGreen)
        case .idle, .unknown: nil
        }
    }

    /// A viewed completion keeps its lifecycle meaning while changing both
    /// shape and color, so acknowledgement is not communicated by color alone.
    func iconName(isViewedFinished: Bool) -> String? {
        self == .finished && isViewedFinished ? "checkmark.circle" : iconName
    }

    func iconColor(isViewedFinished: Bool) -> Color? {
        self == .finished && isViewedFinished ? .secondary : iconColor
    }

    func accessibilityLabel(isViewedFinished: Bool) -> String {
        guard self == .finished, isViewedFinished else { return localizedLabel }
        return "\(localizedLabel), \(String(localized: "Viewed"))"
    }
}
