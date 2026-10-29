// PaneProgramStatusStore.swift
// Limpid — what each pane's program last reported about itself over OSC 7501.

import Foundation

/// One OSC 7501 report as libghostty forwards it (`GHOSTTY_ACTION_PROGRAM_STATUS`).
struct ProgramStatusReport: Equatable {
    enum State: String {
        case idle, working, done, blocked, error
        /// Not a state: removes the record the report names and every record
        /// beneath it.
        case clear
    }

    /// What a blocked program waits on, as the protocol names it.
    enum Kind: String {
        case permission, question, auth
    }

    /// The program's own name for itself (`claude-code`), empty when it sent
    /// none.
    var app: String
    /// The record the report is about; empty for the program itself.
    var recordID: String
    var state: State
    /// What a blocked program waits on. Optional because only a block
    /// carries one, and a block may leave it out (a dialog of the agent's
    /// own).
    var kind: Kind?
}

/// The latest report each pane's program made about itself, which the agent
/// projection reads (`AgentProjectionInput.programStatus`), and the titles an
/// agent that reports its status writes, which the tab leaves off.
///
/// Only the report about the program as a whole is kept: the records a
/// program keeps for parts of its work say nothing about the run in the pane.
@MainActor
final class PaneProgramStatusStore {
    struct Status: Equatable {
        var app: String
        var state: ProgramStatusReport.State
        /// What a blocked program waits on; `nil` for any other state.
        var kind: ProgramStatusReport.Kind?
        var observedAt: Date
    }

    private(set) var statuses: [UUID: Status] = [:]
    /// The `app` names of the agents Limpid supervises
    /// (`AgentProviderDescriptor.programStatusApp`). Their titles are left
    /// off, since the projection names an agent's tab.
    var agentApps: Set<String> = []
    /// Told when an agent's report changes what the projection reads.
    var onChange: (@MainActor () -> Void)?

    /// Panes whose agent cleared its status and has not been followed by a
    /// title of another program yet: Claude Code clears the title as it
    /// exits, right after it clears its status.
    private var panesAgentLeft: Set<UUID> = []
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func receive(_ report: ProgramStatusReport, in pane: UUID) {
        guard report.recordID.isEmpty else { return }
        let previous = statuses[pane]
        if report.state == .clear {
            guard let previous else { return }
            statuses[pane] = nil
            if agentApps.contains(previous.app) {
                panesAgentLeft.insert(pane)
                onChange?()
            }
            return
        }
        let kind = report.state == .blocked ? report.kind : nil
        statuses[pane] = Status(app: report.app, state: report.state, kind: kind, observedAt: now())
        panesAgentLeft.remove(pane)
        if agentApps.contains(report.app),
           previous?.app != report.app || previous?.state != report.state || previous?.kind != kind
        {
            onChange?()
        }
    }

    /// Whether the tab leaves off `title` from `pane`. While an agent reports
    /// its status there, every title is the agent's own. After it clears its
    /// status, an empty title is the one it writes on its way out; the first
    /// title with words in it is the next program's, and is let through.
    func silencesTitle(_ title: String, from pane: UUID) -> Bool {
        if let status = statuses[pane], agentApps.contains(status.app) {
            return true
        }
        guard panesAgentLeft.contains(pane) else { return false }
        if title.isEmpty {
            return true
        }
        panesAgentLeft.remove(pane)
        return false
    }

    /// Forgets what a pane's program reported, once its surface closed or its
    /// command returned to the shell.
    func forget(_ pane: UUID) {
        panesAgentLeft.remove(pane)
        guard let removed = statuses.removeValue(forKey: pane) else { return }
        if agentApps.contains(removed.app) {
            onChange?()
        }
    }

    /// The statuses as one pass reads them, keyed by pane.
    var projectionInput: [String: AgentProjectionProgramStatus] {
        var result: [String: AgentProjectionProgramStatus] = [:]
        for (pane, status) in statuses {
            // `clear` never stays in the store, so every kept state has a
            // name the rules know.
            guard status.state != .clear else { continue }
            result[pane.uuidString] = AgentProjectionProgramStatus(
                app: status.app,
                state: status.state.rawValue,
                kind: status.kind?.rawValue,
                observedAt: AgentDateParsing.formatISO8601(status.observedAt)
            )
        }
        return result
    }
}
