// TmuxPaneJob.swift
// Weir — what runs in the tmux pane a client in front of a Weir pane shows, for a resume's deadline.

import Darwin
import Foundation

/// What a tmux client in front of a pane is showing, as far as a resume's
/// deadline needs it (`AgentForeground.isAgentRunning`).
///
/// The client's own pty carries only the client; what the person sees runs
/// on a pane pty inside the server. So the server is asked for the active
/// pane of the client's session, and the kernel for that pane's foreground
/// job (`ProcessNames`), as review does for the terminal its text reaches.
enum TmuxPaneJob: Equatable, Sendable {
    /// A session of Weir's own agent server: the agent is its one
    /// command, so the session, and the client with it, ends with the agent.
    case agentHost
    /// The foreground job of the active pane of the client's session, its
    /// leader first: on the person's own tmux, whatever they run there.
    case pane([String])
    /// The server could not be asked, or did not say: no client matched to
    /// the pane yet, tmux not found, a server that did not answer in time.
    case unknown

    /// How long the server has to answer. A resume's deadline waits on it,
    /// off the main actor.
    static let queryTimeout = TmuxTiming.queryTimeout

    /// What the tmux client in front of a pane, if any, shows, for the job
    /// in front `names` (leader first): no tmux client in front is nothing
    /// to ask (`.unknown`, which `AgentForeground.isAgentRunning` never
    /// reads for a pane without one); a client of Weir's own agent server
    /// is the agent's host; one of the person's own tmux is asked about its
    /// active pane through `read`; a client the probe has not matched to
    /// the pane yet cannot be asked. Each lookup is handed in, and asked
    /// only when the one before did not decide, so a test needs no tmux
    /// and no terminal.
    @MainActor static func inFront(
        of names: [String],
        isAgentHost: () -> Bool,
        client: () -> TmuxBinding?,
        read: (TmuxBinding) async -> Self
    ) async -> Self {
        guard names.first == TmuxClientProbe.clientProcessName else { return .unknown }
        if isAgentHost() {
            return .agentHost
        }
        guard let binding = client() else { return .unknown }
        return await read(binding)
    }

    /// `inFront` for `paneID`, judged from what `presence` last matched to
    /// the pane: whether its tmux client is one of Weir's agent server,
    /// and which session it shows. The two readings of a pane's job in
    /// front (a resume's deadline, a badge) ask the same way, so the
    /// judgement is made here once. `read` asks the person's tmux, off the
    /// main actor unless a test hands in its own.
    @MainActor static func inFront(
        of names: [String],
        inPane paneID: UUID,
        presence: TmuxPanePresence,
        read: (TmuxBinding) async -> Self = { binding in await Task.detached { TmuxPaneJob.read(binding) }.value }
    ) async -> Self {
        await inFront(
            of: names,
            isAgentHost: { presence.isAgentHost(inPane: paneID) },
            client: { presence.client(inPane: paneID) },
            read: read
        )
    }

    /// Reads the job behind `binding`, the client in front of a pane, on
    /// the person's own tmux. `activePaneTTY` asks that client's server
    /// for its session's active pane; `foregroundNames` asks the kernel for
    /// the job in front on that pane's tty. Both are handed in so a test
    /// needs no tmux.
    static func read(
        _ binding: TmuxBinding,
        activePaneTTY: (TmuxBinding) -> String?,
        foregroundNames: (String) -> [String]
    ) -> Self {
        guard let tty = activePaneTTY(binding) else { return .unknown }
        let names = foregroundNames(tty)
        return names.isEmpty ? .unknown : .pane(names)
    }

    /// `read` against the machine: the located tmux, addressed by the
    /// client's socket, and the kernel's process table. Blocks on tmux for
    /// up to `queryTimeout`, so it is called off the main actor.
    static func read(_ binding: TmuxBinding) -> Self {
        guard let tmuxPath = TmuxClientProbe.locateTmux() else { return .unknown }
        return read(
            binding,
            activePaneTTY: {
                TmuxClientProbe.activePaneTTY(
                    tmuxPath: tmuxPath, socketPath: $0.socketPath, sessionID: $0.sessionID, timeout: queryTimeout
                )
            },
            foregroundNames: foregroundGroupNames(on:)
        )
    }

    /// The names of the foreground process group on `tty`, its leader
    /// first, read as a surface's are (`ProcessNames`): npm's Codex is
    /// `node` in front with `codex` in its group, and Codex's native
    /// `codex-darwin-arm64` keeps its whole name. Empty when the kernel
    /// does not say.
    static func foregroundGroupNames(on tty: String) -> [String] {
        guard let leader = ProcessNames.foregroundProcess(on: tty) else { return [] }
        let names = ProcessNames.foregroundGroupNames(leader: leader.pid)
        // The leader read by its start path, or failing that by the name the
        // tty's listing gave.
        return names.first?.isEmpty == false ? names : [leader.accountingName] + names.dropFirst()
    }
}
