// TmuxMirrorActions+AgentRun.swift
// Limpid — opens the tab of an agent run that is still in tmux with nothing showing it.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.mirror.agent")

extension TmuxMirrorActions {
    /// The session, window, and name a pane belongs to on the server that
    /// answered.
    struct LocatedAgentPane: Equatable {
        let sessionID: String
        let sessionName: String
        let windowID: String
    }

    /// The format the pane listing asks for. Tab-separated because a session
    /// name may contain spaces; every other field is an id or a number.
    nonisolated static let agentPaneArguments = [
        "list-panes", "-a", "-F",
        "#{pane_id}\t#{session_id}\t#{session_name}\t#{window_id}\t#{pid}\t#{start_time}"
    ]

    /// Show `run` again, in a tab of its own (design §5 decision 5).
    ///
    /// The record says which pane on which server the agent runs in, and not
    /// which window it is in now — tmux is asked that, because a pane can be
    /// moved between windows. The server run has to be the recorded one: pane
    /// ids start again with each server, so a pane of the same number on a
    /// later server is somebody else's.
    ///
    /// A tab that already holds the run's leaf is brought forward instead:
    /// one tmux pane feeds one sink, and that tab is the run's tab by the
    /// same rule this opens it under. Returns the task that finishes the
    /// open, or nil when it was answered without asking tmux.
    @discardableResult
    static func openDetachedAgentRun(
        _ run: AgentTmuxRun,
        session: WindowSession,
        store: TmuxConnectionStore,
        toastCenter: ToastCenter?
    ) -> Task<Void, Never>? {
        if let tab = session.tab(containing: run.leafID) {
            session.setActiveTab(tab.id)
            return nil
        }
        guard let tmuxPath = store.tmuxExecutable else {
            toastCenter?.show(ToastItem(message: agentRunGoneNotice(), undo: nil))
            return nil
        }
        return Task { [weak session, weak store] in
            let found = await locate(run, tmuxPath: tmuxPath)
            guard let session, let store else { return }
            guard let found else {
                log.notice("agent run pane \(run.endpoint.paneID, privacy: .public) is not on its server any more")
                toastCenter?.show(ToastItem(message: agentRunGoneNotice(), undo: nil))
                return
            }
            let request = AgentMirrorRequest(
                socketPath: TmuxClientProbe.normalizeSocketPath(run.endpoint.socketPath),
                sessionID: found.sessionID,
                sessionName: found.sessionName,
                windowID: found.windowID,
                paneID: run.endpoint.paneID,
                serverPID: run.endpoint.serverPID,
                serverStartedAt: run.endpoint.serverStartedAt,
                leafID: run.leafID,
                // Nothing launched this one: the user asked for it from a row
                // that stands for the run itself, so the tab opens where a new
                // tab would and takes the focus.
                launchPaneID: run.leafID,
                provider: run.kind
            )
            openAgentMirror(request, session: session, store: store, isUserAsked: true)
        }
    }

    /// What the user reads when the run's pane is not on its server any more:
    /// the server stopped, or it was killed, and there is nothing to show.
    static func agentRunGoneNotice() -> String {
        String(localized: "That agent is no longer running in tmux")
    }

    /// Where `run`'s pane sits now, or nil when its server does not answer or
    /// no longer has it.
    ///
    /// A dispatch queue for the same reason as the palette's listing: this
    /// blocks on a child process, and the closure is formed in a nonisolated
    /// function so Dispatch never runs one carrying main-actor isolation.
    private nonisolated static func locate(_ run: AgentTmuxRun, tmuxPath: String) async -> LocatedAgentPane? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = TmuxCommand().run(
                    executable: tmuxPath,
                    arguments: TmuxCommand.clientArguments(
                        socketPath: run.endpoint.socketPath,
                        agentPaneArguments
                    )
                )
                guard case let .success(output) = result else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: locatedPane(in: output, endpoint: run.endpoint))
            }
        }
    }

    /// The row of `output` describing `endpoint`'s pane on the server run it
    /// records. A malformed row is skipped rather than failing the listing:
    /// the rows are independent, and the one that matters either parses or
    /// the pane counts as gone.
    nonisolated static func locatedPane(in output: String, endpoint: TmuxRuntimeEndpoint) -> LocatedAgentPane? {
        guard !endpoint.serverPID.isEmpty, !endpoint.serverStartedAt.isEmpty else { return nil }
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6,
                  fields[0] == endpoint.paneID,
                  fields[4] == endpoint.serverPID,
                  fields[5] == endpoint.serverStartedAt,
                  fields[1].hasPrefix("$"), fields[3].hasPrefix("@")
            else { continue }
            return LocatedAgentPane(sessionID: fields[1], sessionName: fields[2], windowID: fields[3])
        }
        return nil
    }
}
