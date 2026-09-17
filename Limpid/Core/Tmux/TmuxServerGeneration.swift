// TmuxServerGeneration.swift
// Limpid — tells whether the tmux server on a socket is the one a binding recorded, before a mirror attaches to it.

import Foundation

/// A socket path outlives its server: a restarted server listens on the
/// same path and numbers its sessions and windows from zero again, so a
/// session id alone could attach a tab to someone else's session. A
/// binding records the server's pid and start time, and the two together
/// name one server run.
enum TmuxServerGeneration {
    /// The server run a binding recorded.
    struct Recorded: Equatable {
        let pid: String
        let startedAt: String
    }

    enum Verdict: Equatable {
        /// The server is the recorded one. `hasSession` says whether it
        /// still lists the binding's session.
        case matches(hasSession: Bool)
        /// Another server answers on the socket.
        case replaced
        /// The binding does not say which server it was showing, so no
        /// answer could tell. Nothing is asked of tmux.
        case unrecorded
        /// No server is on the socket (`TmuxSessionProbe.isServerAbsent`),
        /// so none of its sessions exists any more.
        case serverGone
        /// No answer that says whether a server runs: the server hangs, the
        /// socket refuses us for another reason, the listing cannot be
        /// read, or tmux could not be run.
        case unreachable
    }

    /// The generation `binding` recorded, or `nil` when it has none. A
    /// binding restored from an agent record carries empty strings where
    /// the record had no values.
    static func recorded(in binding: TmuxBinding) -> Recorded? {
        guard let pid = binding.serverPID, let startedAt = binding.serverStartedAt,
              !pid.isEmpty, !startedAt.isEmpty
        else { return nil }
        return Recorded(pid: pid, startedAt: startedAt)
    }

    /// Blocks on a child process; `check` runs it off the caller's thread.
    ///
    /// One listing answers both questions asked of a socket — which server
    /// is on it, and which sessions it has — so it is asked for in one
    /// format (`TmuxServerSessions`) and read twice, rather than by two
    /// listings that could disagree about the same server.
    static func verdict(tmuxPath: String, binding: TmuxBinding) -> Verdict {
        guard let recorded = recorded(in: binding) else { return .unrecorded }
        return verdict(
            for: TmuxServerSessions.list(tmuxPath: tmuxPath, socketPath: binding.socketPath),
            recorded: recorded,
            sessionID: binding.sessionID
        )
    }

    /// A listing that failed is split the way the session check after a
    /// connection ended splits it (`TmuxServerSessions`), so a stopped
    /// server ends the tabs on either path.
    ///
    /// A server that answers with no sessions at all (`exit-empty off`)
    /// states no generation. It cannot hold the binding's session either
    /// way, and it is taken as replaced so the tab keeps what it showed
    /// rather than being closed as a session that ended.
    static func verdict(for sessions: TmuxServerSessions, recorded: Recorded, sessionID: String) -> Verdict {
        switch sessions {
        case .serverGone:
            return .serverGone
        case .unreachable:
            return .unreachable
        case let .sessions(rows):
            // Every row carries the server's own run, so the first one
            // answers for the server.
            guard let first = rows.first,
                  Recorded(pid: first.serverPID, startedAt: first.serverStartedAt) == recorded
            else { return .replaced }
            return .matches(hasSession: rows.contains { $0.sessionID == sessionID })
        }
    }

    /// A dispatch queue for the same reason as `TmuxSessionProbe.check`:
    /// the listing blocks on a child process, and this nonisolated function
    /// keeps main-actor isolation out of the closure Dispatch runs.
    nonisolated static func check(tmuxPath: String, binding: TmuxBinding) async -> Verdict {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: verdict(tmuxPath: tmuxPath, binding: binding))
            }
        }
    }
}
