// AgentStatePresentation.swift
// Limpid — the state glyph a session row's or a pane's state wears.
//
// Lives in the UI layer so the Core types that decide a state
// (`SessionRowFact`, `AgentState`) stay free of SwiftUI. The sidebar row,
// the session header, the pane header, and the pane's approval badge all
// go through this one mapping, so a state is the same icon wherever it
// shows.

extension StateGlyph.Kind {
    /// The icon for a row's or a pane's glyph; a shell has no state to draw.
    init(_ glyph: SessionRowFact.Glyph) {
        self = switch glyph {
        case .needsAnswer: .needsAnswer
        case .needsApproval: .needsApproval
        case .needsResponse: .needsResponse
        case .needsSignIn: .needsSignIn
        case .stopped: .stopped
        case .unread: .unread
        case .unreadWorkingAfterTurn: .unreadWorkingAfterTurn
        case .running: .running
        case .idle: .idle
        case .workingAfterTurn: .workingAfterTurn
        case .unknown, .shell: .unknown
        }
    }
}
