// CodexAgentState.swift
// Limpid — lifecycle enum for the Codex agent-state visualisation.
// Mirrors `ClaudeAgentState` 1:1 so the L1 / L2 aggregation can stay
// kind-agnostic. Differences from Claude side: Codex emits
// `PermissionRequest` as its own event (not nested in `Notification`)
// and has no `StopFailure` — we still reserve `.error` for future use.

import Foundation
import SwiftUI

enum CodexAgentState: String, Codable, Equatable, CaseIterable {
    case unknown
    case idle
    case running
    case compacting
    case needsInput
    case error

    /// Aggregate priority. Same ordering as Claude side so a tab with
    /// one Claude `.running` pane and one Codex `.needsInput` pane
    /// resolves to needsInput without kind-specific logic.
    var priority: Int {
        switch self {
        case .error: 4
        case .needsInput: 3
        case .running, .compacting: 2
        case .idle: 1
        case .unknown: 0
        }
    }

    /// SF Symbol used for the L1 / L2 status icon. `nil` when no badge
    /// should render (idle / unknown).
    var iconName: String? {
        switch self {
        case .running, .compacting: "bolt.circle.fill"
        case .needsInput: "questionmark.circle.fill"
        case .error: "exclamationmark.circle.fill"
        case .idle, .unknown: nil
        }
    }

    /// System-tinted colour for the icon. `nil` when no icon renders.
    var iconColor: Color? {
        switch self {
        case .running, .compacting: Color(.systemBlue)
        case .needsInput: Color(.systemOrange)
        case .error: Color(.systemRed)
        case .idle, .unknown: nil
        }
    }
}

extension Sequence<CodexAgentState> {
    /// Collapse multiple pane states to the single state that should
    /// drive the aggregate icon. Returns `nil` when nothing warrants
    /// a visible badge.
    func aggregateCodexState() -> CodexAgentState? {
        var best: CodexAgentState?
        for state in self {
            guard state.iconName != nil else { continue }
            if best == nil || state.priority > best!.priority {
                best = state
            }
        }
        return best
    }
}
