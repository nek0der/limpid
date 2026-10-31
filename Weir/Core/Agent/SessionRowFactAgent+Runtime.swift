// SessionRowFactAgent+Runtime.swift
// Weir — a run as the row's rules take it, read from what the attention list holds.

import Foundation

extension SessionRowFact.Agent {
    /// `runtime` as the row's rules weigh it. Here rather than in the
    /// Domain value, so the rules take plain values and never the badge the
    /// projection writes: each place that marks a run (the row, the pane's
    /// header and tab, the decision bar) reads it through this one mapping.
    init(runtime: AgentRuntimePresentation) {
        self.init(
            provider: runtime.kind,
            state: runtime.badge.state,
            detail: runtime.badge.detail,
            backgroundWork: runtime.badge.backgroundWork,
            runtimeID: runtime.id
        )
    }
}
