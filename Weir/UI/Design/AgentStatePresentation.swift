// AgentStatePresentation.swift
// Weir — the state glyph a session row's or a pane's state wears.
//
// Lives in the UI layer so the Core types that decide a state
// (`SessionRowFact`, `AgentState`) stay free of SwiftUI. The sidebar row,
// the session header, the pane header, and the pane's approval badge all
// go through this one mapping, so a state is the same icon wherever it
// shows.

import SwiftUI
import WeirDomain

extension SessionRowFact.Glyph? {
    /// The words beside a state: amber for a wait, red for a stop, and muted
    /// for anything that does not ask for the person, or for no state at all.
    var textColor: Color {
        switch self {
        case .needsAnswer?, .needsApproval?, .needsResponse?, .needsSignIn?: SupervisionTokens.waitingText.color
        case .stopped?: SupervisionTokens.stoppedText.color
        default: SupervisionTokens.muted.color
        }
    }
}

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
