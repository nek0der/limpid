// PaneAgentInFrontFollower.swift
// Weir — reads a pane's job in front when a command starts or ends, and keeps the agent it runs on the pane's tab.

import Foundation
import WeirDomain

/// Keeps `Tab.agentsInFront` up to date with what each pane's terminal
/// runs in front, so a pane wears its agent's badge from the moment
/// the agent starts rather than from its first hook.
///
/// Read on events, not polled. The job in front changes only when a
/// command starts or ends, and the shell integration marks both: its
/// preexec names the command as the title just before running it, and
/// the command's end is OSC 133 D (COMMAND_FINISHED). Those are the two
/// events this is told of. The title comes before the command's process
/// is in front, and a launcher (npm's `node …/bin/codex`) takes a moment
/// to start the agent itself, so a title is followed by a few readings
/// spaced out over a few seconds (`titleReadDelays`), which stop at the
/// first that finds an agent. One run of readings at a time per pane:
/// an agent that keeps renaming its terminal (Claude's spinner) costs at
/// most those few readings while it does. A command's end is read once,
/// at once: the shell's prompt is back.
///
/// Typed into a tmux the person runs, an agent reaches no title here
/// (tmux keeps its panes' titles to itself unless told otherwise), and
/// its badge comes with its record, from the agent's first hook.
@MainActor
final class PaneAgentInFrontFollower {
    /// When a title's readings are taken, from the title.
    static let titleReadDelays: [Duration] = [.milliseconds(150), .seconds(1), .seconds(3)]

    private weak var session: WorkspaceSession?
    /// Reads the agent in front of a pane's terminal; set by the app, which
    /// holds the terminals (`PaneForegroundWiring.agentInFront`). Until it
    /// is, nothing is read.
    var read: (@MainActor (UUID) async -> AgentInFrontReading)?
    private let titleReadDelays: [Duration]
    /// The readings a title started, by pane, until they end. Each holds
    /// the follower weakly and ends within seconds, so none outlives it
    /// for long.
    private var titleReads: [UUID: Task<Void, Never>] = [:]

    init(session: WorkspaceSession, titleReadDelays: [Duration] = PaneAgentInFrontFollower.titleReadDelays) {
        self.session = session
        self.titleReadDelays = titleReadDelays
    }

    /// A pane's terminal changed its title: a command may have started.
    func titleChanged(inPane paneID: UUID) {
        guard titleReads[paneID] == nil, let read, session?.tab(containing: paneID) != nil else { return }
        let delays = titleReadDelays
        titleReads[paneID] = Task { [weak self] in
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                let reading = await read(paneID)
                guard !Task.isCancelled else { return }
                apply(reading, at: .titleChanged, inPane: paneID)
                if case .agent = reading {
                    break
                }
            }
            self?.titleReads[paneID] = nil
        }
    }

    /// A pane's command finished: the shell's prompt is back, and an agent
    /// that ran there is gone. The readings a title started are dropped, as
    /// this one is later than any of them.
    func commandFinished(inPane paneID: UUID) {
        titleReads.removeValue(forKey: paneID)?.cancel()
        guard let read, session?.tab(containing: paneID) != nil else { return }
        Task { [weak self] in
            let reading = await read(paneID)
            self?.apply(reading, at: .commandFinished, inPane: paneID)
        }
    }

    /// The readings a title started in `paneID`, while they run; a test
    /// waits on them.
    func pendingTitleReads(inPane paneID: UUID) -> Task<Void, Never>? {
        titleReads[paneID]
    }

    /// Writes what `reading` makes of the pane's agent in front, only when
    /// that changes: every write redraws the pane strip.
    func apply(_ reading: AgentInFrontReading, at boundary: PaneAgentInFrontRules.Boundary, inPane paneID: UUID) {
        guard let session, let tab = session.tab(containing: paneID) else { return }
        let current = tab.agentsInFront[paneID]
        let next = PaneAgentInFrontRules.next(current, after: reading, at: boundary)
        guard next != current else { return }
        session.update(tab.id) { $0.agentsInFront[paneID] = next }
    }
}
