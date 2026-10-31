// AgentPermissionMode.swift
// Weir — how freely an agent's session may act without asking, as its hooks
// report it.

import Foundation

/// The session's permission mode in the projection's words, which are Claude
/// Code's (`PermissionMode` in `weir-agent-model`). Codex reports only
/// `default` and `bypassPermissions`: the latter for an approval policy that
/// never asks.
enum AgentPermissionMode: String, Sendable, CaseIterable {
    case `default`
    case acceptEdits
    case plan
    case auto
    case dontAsk
    case bypassPermissions

    /// Whether the agent runs every action without asking. The pane header
    /// warns of this mode with words and a symbol, never by color alone, and
    /// keeps the warning at every width that shows the state mark.
    var runsWithoutAsking: Bool {
        self == .bypassPermissions
    }

    /// The mode's name beside the model in the pane header, or `nil` for the
    /// default mode, which the header leaves unsaid, and for the mode that
    /// runs without asking, which the warning names instead.
    var headerName: LocalizedStringResource? {
        switch self {
        case .default, .bypassPermissions: nil
        case .acceptEdits:
            LocalizedStringResource("Accept edits", comment: "Pane header: a permission mode, after the model")
        case .plan:
            LocalizedStringResource("Plan", comment: "Pane header: a permission mode, after the model")
        case .auto:
            LocalizedStringResource("Auto", comment: "Pane header: a permission mode, after the model")
        case .dontAsk:
            LocalizedStringResource("Don’t ask", comment: "Pane header: a permission mode, after the model")
        }
    }

    /// The mode's full description, for the header's hover text and
    /// VoiceOver, and the warning's words for the mode that runs without
    /// asking.
    var spokenName: LocalizedStringResource {
        switch self {
        case .default:
            LocalizedStringResource("Asks as its settings say", comment: "Pane header hover: what a mode lets the agent do")
        case .acceptEdits:
            LocalizedStringResource("Accepts edits without asking", comment: "Pane header hover: what a mode lets the agent do")
        case .plan:
            LocalizedStringResource("Plans without making changes", comment: "Pane header hover: what a mode lets the agent do")
        case .auto:
            LocalizedStringResource("Auto mode decides what to ask", comment: "Pane header hover: what a mode lets the agent do")
        case .dontAsk:
            LocalizedStringResource("Refuses what is not allowed", comment: "Pane header hover: what a mode lets the agent do")
        case .bypassPermissions:
            LocalizedStringResource("Runs without asking", comment: "Pane header: the warning for a mode that never asks")
        }
    }
}
